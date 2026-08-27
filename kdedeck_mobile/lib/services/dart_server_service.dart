import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DartServerService extends ChangeNotifier {
  static final DartServerService _instance = DartServerService._internal();
  factory DartServerService() => _instance;
  DartServerService._internal();

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  bool isRunning = false;
  int port = 8484;

  Map<String, dynamic>? configData;
  int currentVolume = 50;
  int currentBrightness = 70;
  bool isMuted = false;
  Timer? _metricsTimer;
  String? _cachedDisplayOutput;

  Future<String> _getDisplayOutput() async {
    if (_cachedDisplayOutput != null) return _cachedDisplayOutput!;
    try {
      final res = await Process.run('xrandr', ['--query']);
      if (res.exitCode == 0) {
        for (var line in (res.stdout as String).split('\n')) {
          if (line.contains(' connected')) {
            _cachedDisplayOutput = line.split(' ').first;
            return _cachedDisplayOutput!;
          }
        }
      }
    } catch (_) {}
    return 'eDP-1';
  }

  Map<String, dynamic> metrics = {
    "cpu_temp": 45,
    "cpu_load": 15,
    "gpu_temp": 50,
    "gpu_load": 20,
    "ram_used_gb": 8.0,
    "ram_total_gb": 16.0,
    "ram_percent": 50,
  };

  Future<void> startServer() async {
    if (isRunning) return;

    await _loadConfig();

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      isRunning = true;
      debugPrint("🚀 [DartServerService] Running on port $port");
      notifyListeners();

      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/ws') {
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            _handleClientConnect(socket);
          } catch (e) {
            debugPrint("WS Upgrade Error: $e");
          }
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('KDeDeck Server Running')
            ..close();
        }
      });

      _startMetricsLoop();
    } catch (e) {
      debugPrint("❌ [DartServerService] Failed to bind port $port: $e");
    }
  }

  Future<void> stopServer() async {
    _metricsTimer?.cancel();
    for (var client in _clients) {
      await client.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    isRunning = false;
    notifyListeners();
  }

  void _handleClientConnect(WebSocket socket) {
    _clients.add(socket);
    debugPrint("📱 Client connected! Total clients: ${_clients.length}");

    if (configData == null) {
      configData = _getDefaultConfig();
    }

    // Send initial state upon connection
    _sendToSocket(socket, {
      "type": "init_state",
      "config": configData,
      "pin_required": false,
      "state": {
        "volume": currentVolume,
        "brightness": currentBrightness,
        "is_muted": isMuted,
        "metrics": metrics,
      }
    });

    socket.listen(
      (message) {
        _handleMessage(message, socket);
      },
      onDone: () {
        _clients.remove(socket);
        debugPrint("Client disconnected. Remaining: ${_clients.length}");
      },
      onError: (err) {
        _clients.remove(socket);
      },
    );
  }

  void _handleMessage(dynamic message, WebSocket socket) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'];

      if (type == 'trigger_action') {
        final action = data['action'] ?? '';
        final payload = data['payload']?.toString() ?? '';
        final value = data['value'];
        _executeAction(action, payload, value);
      } else if (type == 'save_config') {
        if (data['config'] != null) {
          configData = Map<String, dynamic>.from(data['config']);
          _saveConfigLocal();
          _broadcast({
            "type": "config_updated",
            "config": configData,
          });
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("Server message parse error: $e");
    }
  }

  void _broadcast(Map<String, dynamic> msgObj) {
    final msg = jsonEncode(msgObj);
    for (var client in List.from(_clients)) {
      try {
        client.add(msg);
      } catch (_) {}
    }
  }

  void _sendToSocket(WebSocket socket, Map<String, dynamic> msgObj) {
    try {
      socket.add(jsonEncode(msgObj));
    } catch (_) {}
  }

  // --- Linux System Execution Engine ---

  void _executeAction(String action, String payload, dynamic value) async {
    if (!Platform.isLinux) return;

    debugPrint("⚡ Executing Action: $action | payload: $payload | value: $value");

    switch (action) {
      case 'launch_app':
      case 'open_url':
        if (payload.isNotEmpty) {
          try {
            if (payload.startsWith('http://') || payload.startsWith('https://')) {
              await Process.run('xdg-open', [payload]);
            } else {
              await Process.run('sh', ['-c', payload]);
            }
          } catch (e) {
            debugPrint("Launch app error: $e");
          }
        }
        break;

      case 'audio_volume':
        if (value != null) {
          final vol = (value as num).toInt().clamp(0, 100);
          currentVolume = vol;

          bool success = false;
          try {
            final res = await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '$vol%']);
            if (res.exitCode == 0) success = true;
          } catch (_) {}

          if (!success) {
            try {
              await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', '$vol%']);
            } catch (_) {}
          }

          _broadcast({
            "type": "state_update",
            "key": "volume",
            "value": currentVolume,
          });
          notifyListeners();
        }
        break;

      case 'audio_mute_toggle':
        isMuted = !isMuted;

        bool success = false;
        try {
          final res = await Process.run('pactl', ['set-sink-mute', '@DEFAULT_SINK@', 'toggle']);
          if (res.exitCode == 0) success = true;
        } catch (_) {}

        if (!success) {
          try {
            await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', 'toggle']);
          } catch (_) {}
        }

        _broadcast({
          "type": "state_update",
          "key": "is_muted",
          "value": isMuted,
        });
        notifyListeners();
        break;

      case 'brightness':
        if (value != null) {
          final b = (value as num).toInt().clamp(5, 100);
          currentBrightness = b;
          final display = await _getDisplayOutput();

          bool success = false;
          try {
            final res = await Process.run('brightnessctl', ['set', '$b%']);
            if (res.exitCode == 0) success = true;
          } catch (_) {}

          if (!success) {
            try {
              final brightVal = (b / 100.0).toStringAsFixed(2);
              await Process.run('xrandr', ['--output', display, '--brightness', brightVal]);
            } catch (e) {
              debugPrint("Brightness execution error: $e");
            }
          }

          _broadcast({
            "type": "state_update",
            "key": "brightness",
            "value": currentBrightness,
          });
          notifyListeners();
        }
        break;

      case 'mpris_action':
        if (payload.isNotEmpty) {
          try {
            await Process.run('playerctl', [payload]);
          } catch (e) {
            debugPrint("MPRIS action error: $e");
          }
        }
        break;

      case 'kde_action':
        if (payload.isNotEmpty) {
          try {
            await Process.run('sh', ['-c', payload]);
          } catch (e) {
            debugPrint("KDE action error: $e");
          }
        }
        break;
    }
  }

  // --- Differential Metrics & State Tracking Loop ---

  void _startMetricsLoop() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      if (!Platform.isLinux || _clients.isEmpty) return;

      await _readLinuxMetrics();
      await _checkDifferentialStateChanges();
    });
  }

  Future<void> _checkDifferentialStateChanges() async {
    try {
      bool changed = false;

      // 1. Differential Audio Volume Query
      final pactlVol = await Process.run('pactl', ['get-sink-volume', '@DEFAULT_SINK@']);
      if (pactlVol.exitCode == 0) {
        final match = RegExp(r'(\d+)%').firstMatch(pactlVol.stdout as String);
        if (match != null) {
          final v = int.tryParse(match.group(1)!) ?? currentVolume;
          if (v != currentVolume) {
            currentVolume = v;
            changed = true;
            _broadcast({"type": "state_update", "key": "volume", "value": currentVolume});
          }
        }
      }

      // 2. Differential Audio Mute Query
      final pactlMute = await Process.run('pactl', ['get-sink-mute', '@DEFAULT_SINK@']);
      if (pactlMute.exitCode == 0) {
        final isMuteNow = (pactlMute.stdout as String).toLowerCase().contains('yes');
        if (isMuteNow != isMuted) {
          isMuted = isMuteNow;
          changed = true;
          _broadcast({"type": "state_update", "key": "is_muted", "value": isMuted});
        }
      }

      // 3. Zero-CPU Sysfs Brightness Query
      try {
        final sysDir = Directory('/sys/class/backlight');
        if (sysDir.existsSync()) {
          final entries = sysDir.listSync();
          if (entries.isNotEmpty) {
            final curFile = File('${entries.first.path}/actual_brightness');
            final maxFile = File('${entries.first.path}/max_brightness');
            if (curFile.existsSync() && maxFile.existsSync()) {
              final curB = int.tryParse(curFile.readAsStringSync().trim()) ?? 0;
              final maxB = int.tryParse(maxFile.readAsStringSync().trim()) ?? 100;
              if (maxB > 0) {
                final percent = ((curB / maxB) * 100).round();
                if ((percent - currentBrightness).abs() >= 2) {
                  currentBrightness = percent;
                  changed = true;
                  _broadcast({"type": "state_update", "key": "brightness", "value": currentBrightness});
                }
              }
            }
          }
        }
      } catch (_) {}

      if (changed) {
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _readLinuxMetrics() async {
    try {
      // Memory usage from free -m
      final memRes = await Process.run('free', ['-m']);
      if (memRes.exitCode == 0) {
        final lines = (memRes.stdout as String).split('\n');
        if (lines.length > 1) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 3) {
            final totalMb = double.tryParse(parts[1]) ?? 16000;
            final usedMb = double.tryParse(parts[2]) ?? 8000;
            metrics['ram_total_gb'] = (totalMb / 1024).toStringAsFixed(1);
            metrics['ram_used_gb'] = (usedMb / 1024).toStringAsFixed(1);
            metrics['ram_percent'] = ((usedMb / totalMb) * 100).round();
          }
        }
      }
    } catch (_) {}
  }

  // --- Persistence ---

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('deck_config_data');

    if (jsonStr != null) {
      try {
        configData = jsonDecode(jsonStr);
      } catch (_) {
        configData = _getDefaultConfig();
      }
    } else {
      configData = _getDefaultConfig();
    }
  }

  Future<void> _saveConfigLocal() async {
    if (configData == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deck_config_data', jsonEncode(configData));
  }

  Map<String, dynamic> _getDefaultConfig() {
    return {
      "boards": [
        {
          "id": "board_default",
          "title": "Main Deck",
          "grid_columns": 5,
          "grid_rows": 3,
          "items": [
            {
              "id": "btn_1",
              "title": "Terminal",
              "action": "launch_app",
              "payload": "konsole || gnome-terminal || xterm",
              "icon": "terminal",
              "span_cols": 1,
              "span_rows": 1,
            },
            {
              "id": "btn_2",
              "title": "Browser",
              "action": "open_url",
              "payload": "https://google.com",
              "icon": "web",
              "span_cols": 1,
              "span_rows": 1,
            },
            {
              "id": "slider_vol",
              "type": "volume_slider",
              "title": "Volume",
              "span_cols": 1,
              "span_rows": 3,
            },
            {
              "id": "slider_bright",
              "type": "brightness_slider",
              "title": "Brightness",
              "span_cols": 1,
              "span_rows": 3,
            }
          ]
        }
      ]
    };
  }
}
