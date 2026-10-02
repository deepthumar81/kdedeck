import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_discovery.dart';
import 'auth_session_manager.dart';
import 'command_executor.dart';
import 'system_actions_service.dart';

class DartServerService {
  static final DartServerService _instance = DartServerService._internal();
  factory DartServerService() => _instance;

  DartServerService._internal()
    : port = 8484,
      _bindAddress = InternetAddress.anyIPv4,
      _configPath = 'deckboard_config.json',
      _authSessionManager = AuthSessionManager(),
      _commandExecutor = const ProcessCommandExecutor();

  /// Creates an isolated server for protocol tests.
  ///
  /// Production startup uses the [DartServerService] singleton above. This
  /// constructor intentionally makes the network address, auth state,
  /// persistence path, and command executor injectable without changing that
  /// startup path.
  DartServerService.forTesting({
    int port = 0,
    InternetAddress? bindAddress,
    String configPath = 'deckboard_config.json',
    AuthSessionManager? authSessionManager,
    CommandExecutor? commandExecutor,
  }) : port = port,
       _bindAddress = bindAddress ?? InternetAddress.loopbackIPv4,
       _configPath = configPath,
       _authSessionManager = authSessionManager ?? AuthSessionManager(),
       _commandExecutor = commandExecutor ?? const ProcessCommandExecutor();

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, AuthSession> _authenticatedClients = {};
  final InternetAddress _bindAddress;
  final String _configPath;
  final AuthSessionManager _authSessionManager;
  final CommandExecutor _commandExecutor;
  bool isRunning = false;
  int port;

  Map<String, dynamic>? configData;
  int currentVolume = 50;
  int currentBrightness = 70;
  bool isMuted = false;
  Timer? _metricsTimer;

  String? _resolveSystemIconPath(String requestedPath) {
    if (!Platform.isLinux) return null;
    return IconPathValidator(SystemActionsService.linuxIconRoots)
        .resolve(requestedPath);
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
      _server = await HttpServer.bind(_bindAddress, port);
      port = _server!.port;
      isRunning = true;
      print("🚀 [DartServerService] Running on port $port");

      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/ws') {
          try {
            final socket = await WebSocketTransformer.upgrade(request);
            _handleClientConnect(socket);
          } catch (_) {
            print("WS Upgrade Error");
          }
        } else if (request.uri.path == '/system_icons' ||
            request.uri.path == '/system_icons/') {
          try {
            final iconPath = request.uri.queryParameters['path'];
            if (iconPath != null && iconPath.isNotEmpty) {
              final resolvedPath = _resolveSystemIconPath(iconPath);
              if (resolvedPath == null) {
                request.response
                  ..statusCode = HttpStatus.notFound
                  ..close();
                return;
              }

              final file = File(resolvedPath);
              if (await file.exists()) {
                final ext = resolvedPath.split('.').last.toLowerCase();
                var contentType = 'image/png';
                if (ext == 'svg')
                  contentType = 'image/svg+xml';
                else if (ext == 'xpm')
                  contentType = 'image/x-xpixmap';

                request.response.headers.contentType = ContentType.parse(
                  contentType,
                );
                request.response.headers.add('Cache-Control', 'max-age=86400');
                await file.openRead().pipe(request.response);
                return;
              }
            }
            request.response
              ..statusCode = HttpStatus.notFound
              ..close();
          } catch (_) {
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..close();
          }
        } else {
          try {
            final uri = request.uri.path == '/'
                ? '/index.html'
                : request.uri.path;
            final file = File('../frontend$uri');
            if (await file.exists()) {
              final ext = uri.split('.').last;
              var contentType = 'text/plain';
              if (ext == 'html') contentType = 'text/html';
              if (ext == 'css') contentType = 'text/css';
              if (ext == 'js') contentType = 'application/javascript';
              if (ext == 'png') contentType = 'image/png';

              request.response.headers.contentType = ContentType.parse(
                contentType,
              );
              await file.openRead().pipe(request.response);
            } else {
              request.response
                ..statusCode = HttpStatus.notFound
                ..write('Not Found')
                ..close();
            }
          } catch (_) {
            request.response
              ..statusCode = HttpStatus.internalServerError
              ..close();
          }
        }
      });

      _startMetricsLoop();
    } catch (_) {
      print("❌ [DartServerService] Failed to bind server");
    }
  }

  Future<void> stopServer() async {
    _metricsTimer?.cancel();
    for (var client in _clients) {
      await client.close();
    }
    _clients.clear();
    _authenticatedClients.clear();
    await _server?.close(force: true);
    isRunning = false;
  }

  void _handleClientConnect(WebSocket socket) {
    _clients.add(socket);
    print("📱 Client connected! Total clients: ${_clients.length}");

    // Do not disclose config, metrics, or pairing material before auth.
    _sendToSocket(socket, {"type": "auth_required"});

    socket.listen(
      (message) {
        unawaited(_handleMessage(message, socket));
      },
      onDone: () {
        _clients.remove(socket);
        _authenticatedClients.remove(socket);
        print("Client disconnected. Remaining: ${_clients.length}");
      },
      onError: (err) {
        _clients.remove(socket);
        _authenticatedClients.remove(socket);
      },
    );
  }

  Future<void> _handleMessage(dynamic message, WebSocket socket) async {
    try {
      final data = jsonDecode(message.toString());
      if (data is! Map) return;
      final type = data['type'];

      if (type == 'authenticate') {
        _authenticate(data, socket);
      } else if (type == 'trigger_action') {
        final session = _sessionFor(socket);
        if (!_requireCapability(socket, session, AuthCapability.control)) {
          return;
        }
        final action = data['action'] ?? '';
        final payload = data['payload']?.toString() ?? '';
        final value = data['value'];
        await _executeAction(action, payload, value);
      } else if (type == 'save_config') {
        final session = _sessionFor(socket);
        if (!_requireCapability(socket, session, AuthCapability.configAdmin)) {
          return;
        }
        if (data['config'] != null) {
          final rawConfig = Map<String, dynamic>.from(data['config']);
          _validateConfig(rawConfig);
          configData = rawConfig;
          _saveConfigLocal();
          _broadcast({
            "type": "config_updated",
            "config": configData,
          }, requiredCapability: AuthCapability.configAdmin);
        }
      } else if (type == 'get_system_apps') {
        final session = _sessionFor(socket);
        if (!_requireCapability(socket, session, AuthCapability.configAdmin)) {
          return;
        }
        await _sendSystemApps(socket);
      }
    } catch (_) {
      // Invalid or malformed frames are ignored without logging their data.
    }
  }

  void _authenticate(Map<dynamic, dynamic> data, WebSocket socket) {
    final pairingCode = data['pairing_code'];
    final token = data['token'];
    AuthSession? session;

    if (pairingCode is String && pairingCode.isNotEmpty && token == null) {
      // Bootstrap pairing is configAdmin-only in this first server slice. A
      // client-supplied role is deliberately ignored and cannot elevate or
      // downgrade the server-assigned bootstrap role.
      session = _authSessionManager.authenticate(
        pairingCode,
        role: AuthRole.configAdmin,
      );
    } else if (token is String && token.isNotEmpty && pairingCode == null) {
      session = _authSessionManager.validateToken(token);
    }

    if (session == null) {
      _sendAuthError(socket, 'invalid_credentials');
      return;
    }

    _authenticatedClients[socket] = session;
    _sendToSocket(socket, {
      "type": "auth_success",
      "token": session.token,
      "role": session.role.name,
    });
    _sendInitState(socket);
  }

  AuthSession? _sessionFor(WebSocket socket) {
    final session = _authenticatedClients[socket];
    if (session == null) return null;
    final validated = _authSessionManager.validateToken(session.token);
    if (validated == null) {
      _authenticatedClients.remove(socket);
      return null;
    }
    return validated;
  }

  bool _requireCapability(
    WebSocket socket,
    AuthSession? session,
    AuthCapability capability,
  ) {
    if (session == null) {
      _sendAuthError(socket, 'authentication_required');
      return false;
    }
    if (!session.hasCapability(capability)) {
      _sendAuthError(socket, 'insufficient_permissions');
      return false;
    }
    return true;
  }

  void _sendAuthError(WebSocket socket, String code) {
    _sendToSocket(socket, {"type": "auth_error", "code": code});
  }

  void _sendInitState(WebSocket socket) {
    if (configData == null) {
      configData = _getDefaultConfig();
    }

    _sendToSocket(socket, {
      "type": "init_state",
      "config": configData,
      "pin_required": true,
      "state": {
        "volume": currentVolume,
        "brightness": currentBrightness,
        "is_muted": isMuted,
        "metrics": metrics,
      },
    });
  }

  void _validateConfig(Map<String, dynamic> config) {
    if (config['boards'] == null) return;
    for (var board in config['boards']) {
      int cols = board['grid_columns'] ?? 4;
      int rows = board['grid_rows'] ?? 3;
      if (board['items'] == null) continue;

      for (var item in board['items']) {
        // Enforce slider security
        if (item['type'] == 'volume_slider' ||
            item['type'] == 'brightness_slider') {
          item['span_cols'] = 1;
          item['span_rows'] = 4;
        }

        // Clamp spans to not exceed board dimensions
        int spanCols = item['span_cols'] ?? 1;
        int spanRows = item['span_rows'] ?? 1;
        if (spanCols > cols) item['span_cols'] = cols;
        if (spanRows > rows) item['span_rows'] = rows;

        // Ensure positions are within bounds
        int x = item['grid_x'] ?? 0;
        int y = item['grid_y'] ?? 0;
        if (x + (item['span_cols'] as int) > cols)
          item['grid_x'] = cols - (item['span_cols'] as int);
        if (y + (item['span_rows'] as int) > rows)
          item['grid_y'] = rows - (item['span_rows'] as int);
        if ((item['grid_x'] as int) < 0) item['grid_x'] = 0;
        if ((item['grid_y'] as int) < 0) item['grid_y'] = 0;
      }
    }
  }

  Future<void> _sendSystemApps(WebSocket socket) async {
    final apps = await SystemActionsService.getInstalledApps(
      executor: _commandExecutor,
    );
    _sendToSocket(socket, {"type": "system_apps_list", "apps": apps});
  }

  void _broadcast(
    Map<String, dynamic> msgObj, {
    AuthCapability requiredCapability = AuthCapability.view,
  }) {
    final msg = jsonEncode(msgObj);
    for (final entry in List<MapEntry<WebSocket, AuthSession>>.from(
      _authenticatedClients.entries,
    )) {
      if (!entry.value.hasCapability(requiredCapability)) continue;
      try {
        entry.key.add(msg);
      } catch (_) {}
    }
  }

  void _sendToSocket(WebSocket socket, Map<String, dynamic> msgObj) {
    try {
      socket.add(jsonEncode(msgObj));
    } catch (_) {}
  }

  // --- Linux System Execution Engine ---

  Future<void> _executeAction(
    String action,
    String payload,
    dynamic value,
  ) async {
    switch (action) {
      case 'launch_app':
      case 'open_url':
        await SystemActionsService.executeLaunch(
          payload,
          executor: _commandExecutor,
        );
        break;

      case 'audio_volume':
        if (value != null) {
          final vol = (value as num).toInt().clamp(0, 100);
          currentVolume = vol;
          await SystemActionsService.setVolume(vol, executor: _commandExecutor);
          _broadcast({
            "type": "state_update",
            "key": "volume",
            "value": currentVolume,
          });
        }
        break;

      case 'audio_mute_toggle':
        isMuted = !isMuted;
        await SystemActionsService.toggleMute(executor: _commandExecutor);
        _broadcast({
          "type": "state_update",
          "key": "is_muted",
          "value": isMuted,
        });
        break;

      case 'brightness':
        if (value != null) {
          final b = (value as num).toInt().clamp(5, 100);
          currentBrightness = b;
          await SystemActionsService.setBrightness(
            b,
            executor: _commandExecutor,
          );
          _broadcast({
            "type": "state_update",
            "key": "brightness",
            "value": currentBrightness,
          });
        }
        break;

      case 'mpris_action':
        await SystemActionsService.executeMpris(
          payload,
          executor: _commandExecutor,
        );
        break;

      case 'kde_action':
        await SystemActionsService.executeKdeAction(
          payload,
          executor: _commandExecutor,
        );
        break;
    }
  }

  // --- Differential Metrics & State Tracking Loop ---

  void _startMetricsLoop() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!Platform.isLinux) return;

      await _readLinuxMetrics();
      if (_clients.isNotEmpty) {
        await _checkDifferentialStateChanges();
      }
    });
  }

  Future<void> _checkDifferentialStateChanges() async {
    try {
      bool changed = false;

      // 1. Differential Audio Volume Query
      final pactlVol = await Process.run('pactl', [
        'get-sink-volume',
        '@DEFAULT_SINK@',
      ]);
      if (pactlVol.exitCode == 0) {
        final match = RegExp(r'(\d+)%').firstMatch(pactlVol.stdout as String);
        if (match != null) {
          final v = int.tryParse(match.group(1)!) ?? currentVolume;
          if (v != currentVolume) {
            currentVolume = v;
            changed = true;
            _broadcast({
              "type": "state_update",
              "key": "volume",
              "value": currentVolume,
            });
          }
        }
      }

      // 2. Differential Audio Mute Query
      final pactlMute = await Process.run('pactl', [
        'get-sink-mute',
        '@DEFAULT_SINK@',
      ]);
      if (pactlMute.exitCode == 0) {
        final isMuteNow = (pactlMute.stdout as String).toLowerCase().contains(
          'yes',
        );
        if (isMuteNow != isMuted) {
          isMuted = isMuteNow;
          changed = true;
          _broadcast({
            "type": "state_update",
            "key": "is_muted",
            "value": isMuted,
          });
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
              final maxB =
                  int.tryParse(maxFile.readAsStringSync().trim()) ?? 100;
              if (maxB > 0) {
                final percent = ((curB / maxB) * 100).round();
                if ((percent - currentBrightness).abs() >= 2) {
                  currentBrightness = percent;
                  changed = true;
                  _broadcast({
                    "type": "state_update",
                    "key": "brightness",
                    "value": currentBrightness,
                  });
                }
              }
            }
          }
        }
      } catch (_) {}

      if (changed) {}
    } catch (_) {}
  }

  Future<void> _readLinuxMetrics() async {
    try {
      final memFile = File('/proc/meminfo');
      if (memFile.existsSync()) {
        final content = await memFile.readAsString();
        double totalKb = 0;
        double availableKb = 0;
        for (var line in content.split('\n')) {
          if (line.startsWith('MemTotal:')) {
            final match = RegExp(r'\d+').firstMatch(line);
            if (match != null) totalKb = double.tryParse(match.group(0)!) ?? 0;
          } else if (line.startsWith('MemAvailable:')) {
            final match = RegExp(r'\d+').firstMatch(line);
            if (match != null)
              availableKb = double.tryParse(match.group(0)!) ?? 0;
          }
        }
        if (totalKb > 0) {
          final usedKb = totalKb - availableKb;
          final totalMb = totalKb / 1024;
          final usedMb = usedKb / 1024;
          metrics['ram_total_gb'] = (totalMb / 1024).toStringAsFixed(1);
          metrics['ram_used_gb'] = (usedMb / 1024).toStringAsFixed(1);
          metrics['ram_percent'] = ((usedMb / totalMb) * 100).round();
        }
      }
    } catch (_) {}
  }

  // --- Persistence ---

  Future<void> _loadConfig() async {
    try {
      final file = File(_configPath);
      if (await file.exists()) {
        final str = await file.readAsString();
        configData = jsonDecode(str);
      } else {
        configData = _getDefaultConfig();
      }
    } catch (_) {
      print("Error loading config");
      configData = _getDefaultConfig();
    }
  }

  Future<void> _saveConfigLocal() async {
    if (configData == null) return;
    try {
      final file = File(_configPath);
      await file.writeAsString(jsonEncode(configData));
    } catch (_) {
      print("Error saving config");
    }
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
            },
          ],
        },
      ],
    };
  }
}
