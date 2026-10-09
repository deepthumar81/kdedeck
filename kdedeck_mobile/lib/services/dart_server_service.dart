import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'linux_actions_service.dart';

/// A credential used by the embedded server.  The token is never included in
/// protocol responses or logs.
class PairingCredential {
  const PairingCredential(this.token, {this.expiresAt});

  final String token;
  final DateTime? expiresAt;

  bool isUsable(DateTime now) =>
      token.isNotEmpty && (expiresAt == null || expiresAt!.isAfter(now));
}

/// Source for the credential used by the embedded server.
///
/// Keeping this behind an interface makes expiry and revocation testable and
/// lets an application replace SharedPreferences with a platform keystore.
abstract interface class PairingTokenSource {
  Future<PairingCredential?> read();
}

/// A deterministic source useful to embedders and tests.
class StaticPairingTokenSource implements PairingTokenSource {
  StaticPairingTokenSource(this.credential);

  PairingCredential? credential;

  @override
  Future<PairingCredential?> read() async => credential;
}

/// Local pairing storage for the embedded server.
///
/// An explicitly configured `DART_SERVER_PAIRING_TOKEN` takes precedence.
/// Otherwise a high-entropy token is generated once and persisted locally.
/// This deliberately does not fall back to the old short default PIN.
class LocalPairingTokenSource implements PairingTokenSource {
  LocalPairingTokenSource({SharedPreferences? preferences})
      : _preferences = preferences;

  static const tokenKey = 'dart_server_pairing_token';
  static const expiryKey = 'dart_server_pairing_token_expires_at';

  SharedPreferences? _preferences;

  @override
  Future<PairingCredential?> read() async {
    final configured = Platform.environment['DART_SERVER_PAIRING_TOKEN'];
    if (configured != null && configured.length >= 16) {
      return PairingCredential(configured);
    }

    final prefs = _preferences ??= await SharedPreferences.getInstance();
    var token = prefs.getString(tokenKey);
    if (token == null || token.length < 32) {
      token = _newToken();
      await prefs.setString(tokenKey, token);
    }

    final expiryMillis = prefs.getInt(expiryKey);
    return PairingCredential(
      token,
      expiresAt: expiryMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiryMillis),
    );
  }

  static String _newToken() {
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _ClientSession {
  _ClientSession({required this.localTrusted});

  final bool localTrusted;
  bool authenticated = false;
  int authenticationErrors = 0;
  String? token;
  DateTime? expiresAt;
}

class DartServerService extends ChangeNotifier {
  static final DartServerService _instance = DartServerService._internal();

  factory DartServerService() => _instance;

  /// Constructor for tests and hosts that need an injectable credential
  /// source. The production singleton above remains unchanged.
  DartServerService.withDependencies({
    required PairingTokenSource tokenSource,
    DateTime Function()? now,
    Duration sessionDuration = const Duration(minutes: 30),
    bool trustLoopback = true,
    InternetAddress? bindAddress,
  })  : _tokenSource = tokenSource,
        _now = now ?? DateTime.now,
        _sessionDuration = sessionDuration,
        _trustLoopback = trustLoopback,
        _bindAddress = bindAddress,
        _isSingleton = false;

  DartServerService._internal()
      : _tokenSource = LocalPairingTokenSource(),
        _now = DateTime.now,
        _sessionDuration = const Duration(minutes: 30),
        _trustLoopback = true,
        _bindAddress = null,
        _isSingleton = true;

  final PairingTokenSource _tokenSource;
  final DateTime Function() _now;
  final Duration _sessionDuration;
  final bool _trustLoopback;
  final InternetAddress? _bindAddress;
  final bool _isSingleton;

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, _ClientSession> _sessions = {};
  bool isRunning = false;
  int port = 8484;

  Map<String, dynamic>? configData;
  int currentVolume = 50;
  int currentBrightness = 70;
  bool isMuted = false;
  Timer? _metricsTimer;
  static const int _maxAuthErrors = 5;
  static const int _maxMessageBytes = 64 * 1024;
  static const int _maxConfigBytes = 1024 * 1024;

  Map<String, dynamic> metrics = {
    'cpu_temp': 45,
    'cpu_load': 15,
    'gpu_temp': 50,
    'gpu_load': 20,
    'ram_used_gb': 8.0,
    'ram_total_gb': 16.0,
    'ram_percent': 50,
  };

  Future<void> startServer() async {
    if (isRunning) return;

    await _loadConfig();
    // Load/generate the local credential before accepting a socket. This also
    // means a persistence failure cannot accidentally create an open server.
    final credential = await _tokenSource.read();
    if (credential == null || !credential.isUsable(_now())) {
      debugPrint('[DartServerService] No usable local pairing credential');
      return;
    }

    try {
      _server = await HttpServer.bind(
        _bindAddress ?? InternetAddress.anyIPv4,
        port,
      );
      port = _server!.port;
      isRunning = true;
      debugPrint('[DartServerService] Running on port $port');
      notifyListeners();

      _server!.listen((request) async {
        if (request.uri.path == '/ws') {
          try {
            final remoteAddress = request.connectionInfo?.remoteAddress;
            final socket = await WebSocketTransformer.upgrade(request);
            _handleClientConnect(socket, _isLoopback(remoteAddress));
          } catch (_) {
            // Do not log request data or handshake details.
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
      debugPrint('[DartServerService] Failed to bind port $port: $e');
    }
  }

  Future<void> stopServer() async {
    _metricsTimer?.cancel();
    for (final client in List<WebSocket>.from(_clients)) {
      await client.close();
    }
    _clients.clear();
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    isRunning = false;
    if (_isSingleton) notifyListeners();
  }

  bool _isLoopback(InternetAddress? address) {
    if (!_trustLoopback || address == null) return false;
    return address.isLoopback ||
        address.address == '::ffff:127.0.0.1' ||
        address.address == '::1';
  }

  void _handleClientConnect(WebSocket socket, bool localTrusted) {
    final session = _ClientSession(localTrusted: localTrusted);
    _clients.add(socket);
    _sessions[socket] = session;

    // This is intentionally the first frame. Local loopback is treated as a
    // trusted desktop transport so the existing desktop client keeps working;
    // remote clients must authenticate before any state is disclosed.
    _sendToSocket(socket, {
      'type': 'auth_required',
      'protocol_version': 1,
      'auth_required': !localTrusted,
      'methods': ['token'],
    });

    if (localTrusted) {
      session.authenticated = true;
      _sendInitState(socket);
    }

    socket.listen(
      (message) => unawaited(_handleMessage(message, socket)),
      onDone: () {
        _clients.remove(socket);
        _sessions.remove(socket);
      },
      onError: (_) {
        _clients.remove(socket);
        _sessions.remove(socket);
      },
    );
  }

  Future<void> _handleMessage(dynamic message, WebSocket socket) async {
    final session = _sessions[socket];
    if (session == null) return;

    final raw = message.toString();
    if (utf8.encode(raw).length > _maxMessageBytes) {
      await _sendAuthError(socket, session, 'message_too_large');
      return;
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      await _sendAuthError(socket, session, 'invalid_message');
      return;
    }
    if (decoded is! Map) {
      await _sendAuthError(socket, session, 'invalid_message');
      return;
    }

    late final Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      await _sendAuthError(socket, session, 'invalid_message');
      return;
    }
    final type = data['type'];
    if (type == 'authenticate') {
      await _authenticate(data, socket, session);
      return;
    }

    if (type == 'trigger_action') {
      if (!await _isAuthorized(socket, session)) {
        await _rejectUnauthenticated(socket, session, 'action_error');
        return;
      }
      final action = data['action'];
      if (action is! String || action.isEmpty || action.length > 128) {
        _sendToSocket(socket, {
          'type': 'action_error',
          'protocol_version': 1,
          'code': 'invalid_action',
        });
        return;
      }
      final payload = data['payload'];
      if (payload != null && payload is! String) {
        _sendToSocket(socket, {
          'type': 'action_error',
          'protocol_version': 1,
          'action': action,
          'code': 'invalid_payload',
        });
        return;
      }
      await _executeAction(
          action, payload as String? ?? '', data['value'], socket);
      return;
    }

    if (type == 'save_config') {
      if (!await _isAuthorized(socket, session)) {
        await _rejectUnauthenticated(socket, session, 'config_error');
        return;
      }
      await _saveConfigFromMessage(data, socket);
    }
  }

  Future<void> _authenticate(
    Map<String, dynamic> data,
    WebSocket socket,
    _ClientSession session,
  ) async {
    if (session.authenticationErrors >= _maxAuthErrors) {
      await _sendAuthError(socket, session, 'rate_limited');
      return;
    }
    if (data['protocol_version'] != 1) {
      await _sendAuthError(socket, session, 'unsupported_protocol');
      return;
    }

    final token = data['token'] ?? data['pairing_token'] ?? data['pin'];
    if (token is! String || token.isEmpty || token.length > 512) {
      await _sendAuthError(socket, session, 'invalid_credentials');
      return;
    }

    final credential = await _tokenSource.read();
    final valid = credential != null &&
        credential.isUsable(_now()) &&
        _constantTimeEquals(token, credential.token);
    if (!valid) {
      await _sendAuthError(socket, session, 'invalid_credentials');
      return;
    }

    session.authenticationErrors = 0;
    session.authenticated = true;
    session.token = token;
    final sessionExpiry = _now().add(_sessionDuration);
    session.expiresAt = credential.expiresAt == null ||
            credential.expiresAt!.isAfter(sessionExpiry)
        ? sessionExpiry
        : credential.expiresAt;
    _sendToSocket(socket, {
      'type': 'auth_success',
      'protocol_version': 1,
      'expires_at': session.expiresAt!.toUtc().toIso8601String(),
    });
    _sendInitState(socket);
  }

  Future<void> _sendAuthError(
    WebSocket socket,
    _ClientSession session,
    String code,
  ) async {
    session.authenticationErrors++;
    _sendToSocket(socket, {
      'type': 'auth_error',
      'protocol_version': 1,
      'code': code,
    });
    await _closeAfterTooManyErrors(socket, session);
  }

  Future<void> _rejectUnauthenticated(
    WebSocket socket,
    _ClientSession session,
    String responseType,
  ) async {
    session.authenticationErrors++;
    _sendToSocket(socket, {
      'type': responseType,
      'protocol_version': 1,
      'code': 'auth_required',
    });
    await _closeAfterTooManyErrors(socket, session);
  }

  Future<void> _closeAfterTooManyErrors(
    WebSocket socket,
    _ClientSession session,
  ) async {
    if (session.authenticationErrors >= _maxAuthErrors) {
      await socket.close(
          WebSocketStatus.policyViolation, 'authentication failed');
      _clients.remove(socket);
      _sessions.remove(socket);
    }
  }

  Future<bool> _isAuthorized(WebSocket socket, _ClientSession session) async {
    if (!session.authenticated) return false;
    final now = _now();
    if (session.expiresAt != null && !session.expiresAt!.isAfter(now)) {
      session.authenticated = false;
      session.token = null;
      return false;
    }
    if (session.localTrusted) return true;

    final credential = await _tokenSource.read();
    if (credential == null ||
        !credential.isUsable(now) ||
        session.token == null ||
        !_constantTimeEquals(session.token!, credential.token)) {
      session.authenticated = false;
      session.token = null;
      return false;
    }
    return true;
  }

  static bool _constantTimeEquals(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    var result = a.length ^ b.length;
    final length = min(a.length, b.length);
    for (var i = 0; i < length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  void _sendInitState(WebSocket socket) {
    configData ??= _getDefaultConfig();
    _sendToSocket(socket, {
      'type': 'init_state',
      'protocol_version': 1,
      'config': configData,
      'pin_required': false,
      'auth_required': false,
      'state': {
        'volume': currentVolume,
        'brightness': currentBrightness,
        'is_muted': isMuted,
        'metrics': metrics,
      },
    });
  }

  Future<void> _saveConfigFromMessage(
    Map<String, dynamic> data,
    WebSocket socket,
  ) async {
    final incoming = data['config'];
    if (incoming is! Map) {
      _sendToSocket(socket, {
        'type': 'config_error',
        'protocol_version': 1,
        'code': 'invalid_config',
      });
      return;
    }
    Map<String, dynamic>? candidate;
    try {
      candidate = Map<String, dynamic>.from(incoming);
      if (utf8.encode(jsonEncode(candidate)).length > _maxConfigBytes) {
        throw const FormatException('config too large');
      }
      final prefs = await SharedPreferences.getInstance();
      final saved =
          await prefs.setString('deck_config_data', jsonEncode(candidate));
      if (!saved) throw const FormatException('config save failed');
      configData = candidate;
      await _broadcast({
        'type': 'config_updated',
        'protocol_version': 1,
        'config': configData,
      });
      notifyListeners();
    } catch (_) {
      _sendToSocket(socket, {
        'type': 'config_error',
        'protocol_version': 1,
        'code': 'save_failed',
      });
    }
  }

  Future<void> _broadcast(Map<String, dynamic> msgObj) async {
    final msg = jsonEncode(msgObj);
    for (final client in List<WebSocket>.from(_clients)) {
      final session = _sessions[client];
      if (session != null && await _isAuthorized(client, session)) {
        try {
          client.add(msg);
        } catch (_) {}
      }
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
    WebSocket socket,
  ) async {
    if (!Platform.isLinux) {
      _sendToSocket(socket, {
        'type': 'action_error',
        'protocol_version': 1,
        'action': action,
        'code': 'unsupported_platform',
      });
      return;
    }

    try {
      var success = true;
      switch (action) {
        case 'launch_app':
        case 'open_url':
          success = await LinuxActionsService.executeLaunch(payload);
          break;
        case 'audio_volume':
          if (value is! num) throw const FormatException('invalid volume');
          final vol = value.toInt().clamp(0, 100);
          success = await LinuxActionsService.setVolume(vol);
          if (success) {
            currentVolume = vol;
            await _broadcast({
              'type': 'state_update',
              'key': 'volume',
              'value': currentVolume
            });
            notifyListeners();
          }
          break;
        case 'audio_mute_toggle':
          success = await LinuxActionsService.toggleMute();
          if (success) {
            isMuted = !isMuted;
            await _broadcast(
                {'type': 'state_update', 'key': 'is_muted', 'value': isMuted});
            notifyListeners();
          }
          break;
        case 'brightness':
          if (value is! num) throw const FormatException('invalid brightness');
          final brightness = value.toInt().clamp(5, 100);
          success = await LinuxActionsService.setBrightness(brightness);
          if (success) {
            currentBrightness = brightness;
            await _broadcast({
              'type': 'state_update',
              'key': 'brightness',
              'value': currentBrightness
            });
            notifyListeners();
          }
          break;
        case 'mpris_action':
          success = await LinuxActionsService.executeMpris(payload);
          break;
        case 'kde_action':
          success = await LinuxActionsService.executeLaunch(payload);
          break;
        default:
          _sendToSocket(socket, {
            'type': 'action_error',
            'protocol_version': 1,
            'action': action,
            'code': 'unknown_action',
          });
          return;
      }

      _sendToSocket(socket, {
        'type': success ? 'action_result' : 'action_error',
        'protocol_version': 1,
        'action': action,
        if (success) 'success': true,
        'code': success ? 'ok' : 'action_failed',
      });
    } catch (_) {
      _sendToSocket(socket, {
        'type': 'action_error',
        'protocol_version': 1,
        'action': action,
        'code': 'invalid_action',
      });
    }
  }

  // --- Differential Metrics & State Tracking Loop ---

  void _startMetricsLoop() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!Platform.isLinux) return;
      await _readLinuxMetrics();
      if (_clients.isNotEmpty) await _checkDifferentialStateChanges();
    });
  }

  Future<void> _checkDifferentialStateChanges() async {
    try {
      var changed = false;
      final pactlVol =
          await Process.run('pactl', ['get-sink-volume', '@DEFAULT_SINK@']);
      if (pactlVol.exitCode == 0) {
        final match = RegExp(r'(\d+)%').firstMatch(pactlVol.stdout as String);
        if (match != null) {
          final volume = int.tryParse(match.group(1)!) ?? currentVolume;
          if (volume != currentVolume) {
            currentVolume = volume;
            changed = true;
            await _broadcast({
              'type': 'state_update',
              'key': 'volume',
              'value': currentVolume
            });
          }
        }
      }

      final pactlMute =
          await Process.run('pactl', ['get-sink-mute', '@DEFAULT_SINK@']);
      if (pactlMute.exitCode == 0) {
        final isMuteNow =
            (pactlMute.stdout as String).toLowerCase().contains('yes');
        if (isMuteNow != isMuted) {
          isMuted = isMuteNow;
          changed = true;
          await _broadcast(
              {'type': 'state_update', 'key': 'is_muted', 'value': isMuted});
        }
      }

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
                  await _broadcast({
                    'type': 'state_update',
                    'key': 'brightness',
                    'value': currentBrightness
                  });
                }
              }
            }
          }
        }
      } catch (_) {}
      if (changed) notifyListeners();
    } catch (_) {}
  }

  Future<void> _readLinuxMetrics() async {
    try {
      final memFile = File('/proc/meminfo');
      if (memFile.existsSync()) {
        final content = await memFile.readAsString();
        double totalKb = 0;
        double availableKb = 0;
        for (final line in content.split('\n')) {
          if (line.startsWith('MemTotal:')) {
            final match = RegExp(r'\d+').firstMatch(line);
            if (match != null) {
              totalKb = double.tryParse(match.group(0)!) ?? 0;
            }
          } else if (line.startsWith('MemAvailable:')) {
            final match = RegExp(r'\d+').firstMatch(line);
            if (match != null) {
              availableKb = double.tryParse(match.group(0)!) ?? 0;
            }
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
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('deck_config_data');
    if (jsonStr != null) {
      try {
        final decoded = jsonDecode(jsonStr);
        configData = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : _getDefaultConfig();
      } catch (_) {
        configData = _getDefaultConfig();
      }
    } else {
      configData = _getDefaultConfig();
    }
  }

  Map<String, dynamic> _getDefaultConfig() {
    return {
      'boards': [
        {
          'id': 'board_default',
          'title': 'Main Deck',
          'grid_columns': 5,
          'grid_rows': 3,
          'items': [
            {
              'id': 'btn_1',
              'title': 'Terminal',
              'action': 'launch_app',
              'payload': 'konsole || gnome-terminal || xterm',
              'icon': 'terminal',
              'span_cols': 1,
              'span_rows': 1,
            },
            {
              'id': 'btn_2',
              'title': 'Browser',
              'action': 'open_url',
              'payload': 'https://google.com',
              'icon': 'web',
              'span_cols': 1,
              'span_rows': 1,
            },
            {
              'id': 'slider_vol',
              'type': 'volume_slider',
              'title': 'Volume',
              'span_cols': 1,
              'span_rows': 3,
            },
            {
              'id': 'slider_bright',
              'type': 'brightness_slider',
              'title': 'Brightness',
              'span_cols': 1,
              'span_rows': 3,
            },
          ],
        },
      ],
    };
  }
}
