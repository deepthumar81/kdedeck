import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_discovery.dart';
import 'auth_rate_limiter.dart';
import 'auth_session_manager.dart';
import 'command_executor.dart';
import 'config_validator.dart';
import 'server_tls.dart';
import 'system_actions_service.dart';

class DartServerService {
  static final DartServerService _instance = DartServerService._internal();
  factory DartServerService() => _instance;

  DartServerService._internal()
    : port = 8484,
      _bindAddress = InternetAddress.loopbackIPv4,
      _bindAddressOverride = null,
      _configPath = 'deckboard_config.json',
      _authSessionManager = AuthSessionManager(issueCodeOnCreate: false),
      _authRateLimiter = AuthRateLimiter(),
      _clientIdentityResolver = _defaultClientIdentity,
      _configValidator = const ConfigValidator(),
      _environment = Platform.environment,
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
    AuthRateLimiter? authRateLimiter,
    String Function(HttpRequest request)? clientIdentityResolver,
    ConfigLimits? configLimits,
    CommandExecutor? commandExecutor,
    Map<String, String> environment = const {},
  }) : port = port,
       _bindAddress = bindAddress ?? InternetAddress.loopbackIPv4,
       _bindAddressOverride = bindAddress,
       _configPath = configPath,
       _authSessionManager =
           authSessionManager ?? AuthSessionManager(issueCodeOnCreate: false),
       _authRateLimiter = authRateLimiter ?? AuthRateLimiter(),
       _clientIdentityResolver =
           clientIdentityResolver ?? _defaultClientIdentity,
       _configValidator = ConfigValidator(
         limits: configLimits ?? const ConfigLimits(),
       ),
       _environment = Map<String, String>.of(environment),
       _commandExecutor = commandExecutor ?? const ProcessCommandExecutor();

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, AuthSession> _authenticatedClients = {};
  InternetAddress _bindAddress;
  final InternetAddress? _bindAddressOverride;
  final String _configPath;
  final AuthSessionManager _authSessionManager;
  final AuthRateLimiter _authRateLimiter;
  final String Function(HttpRequest request) _clientIdentityResolver;
  final ConfigValidator _configValidator;
  final Map<String, String> _environment;
  final CommandExecutor _commandExecutor;
  Future<void> _saveOperation = Future<void>.value();
  bool isRunning = false;
  bool isSecure = false;
  int port;

  /// The effective address selected for the next server start.
  InternetAddress get bindAddress => _bindAddress;

  /// Issues a new one-time code for a local, already-running daemon.
  ///
  /// Only the local terminal caller should display the returned secret. Never
  /// include it in server logs, exceptions, or network responses.
  ({String code, DateTime expiresAt}) issueLocalPairingCode() {
    if (!isRunning) throw StateError('Server is not running');
    final code = _authSessionManager.issuePairingCode();
    return (code: code, expiresAt: _authSessionManager.pairingCodeExpiresAt!);
  }

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
      final context = serverTlsContext(
        _environment,
        requireTls: !_bindAddress.isLoopback,
      );
      _server = context == null
          ? await HttpServer.bind(_bindAddress, port)
          : await HttpServer.bindSecure(_bindAddress, port, context);
      port = _server!.port;
      isSecure = context != null;
      isRunning = true;
      final mode = _bindAddress.address == InternetAddress.anyIPv4.address
          ? 'LAN'
          : 'loopback';
      print(
        "🚀 [DartServerService] Running in $mode mode (${isSecure ? 'HTTPS/WSS' : 'HTTP/WS'}) on ${_bindAddress.address}:$port",
      );

      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/ws') {
          try {
            final clientIdentity = _clientIdentityResolver(request);
            final socket = await WebSocketTransformer.upgrade(request);
            _handleClientConnect(socket, clientIdentity);
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

      _authSessionManager.addRevocationListener(_closeRevokedClients);
      _startMetricsLoop();
    } catch (_) {
      _authSessionManager.removeRevocationListener(_closeRevokedClients);
      await _server?.close(force: true);
      _server = null;
      isRunning = false;
      isSecure = false;
      print(
        "❌ [DartServerService] Failed to start server (check TLS settings and bind address)",
      );
    }
  }

  Future<void> stopServer() async {
    _authSessionManager.removeRevocationListener(_closeRevokedClients);
    _metricsTimer?.cancel();
    for (var client in _clients) {
      await client.close();
    }
    _clients.clear();
    _authenticatedClients.clear();
    _clientIdentities.clear();
    await _server?.close(force: true);
    _server = null;
    isRunning = false;
    isSecure = false;
  }

  void _handleClientConnect(WebSocket socket, String clientIdentity) {
    _clients.add(socket);
    _clientIdentities[socket] = clientIdentity;
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
        _clientIdentities.remove(socket);
        print("Client disconnected. Remaining: ${_clients.length}");
      },
      onError: (err) {
        _clients.remove(socket);
        _authenticatedClients.remove(socket);
        _clientIdentities.remove(socket);
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
          final savedConfig = await _saveConfigLocal(data['config']);
          if (savedConfig == null) {
            _sendToSocket(socket, {
              "type": "config_error",
              "code": "invalid_config",
            });
            return;
          }
          _broadcast({
            "type": "config_updated",
            "config": savedConfig,
          }, requiredCapability: AuthCapability.configAdmin);
        } else {
          _sendToSocket(socket, {
            "type": "config_error",
            "code": "invalid_config",
          });
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
    final existingSession = _sessionFor(socket);
    final clientIdentity = _clientIdentities[socket];
    if (existingSession == null &&
        (clientIdentity == null ||
            !_authRateLimiter.isAllowed(clientIdentity))) {
      _sendAuthError(socket, 'rate_limited');
      return;
    }

    final pairingCode = data['pairing_code'];
    final token = data['token'];
    AuthSession? session;
    AuthAuthenticationFailure? authenticationFailure;

    if (pairingCode is String && pairingCode.isNotEmpty && token == null) {
      // Bootstrap pairing is configAdmin-only in this first server slice. A
      // client-supplied role is deliberately ignored and cannot elevate or
      // downgrade the server-assigned bootstrap role.
      final result = _authSessionManager.authenticateWithStatus(
        pairingCode,
        role: AuthRole.configAdmin,
      );
      session = result.session;
      authenticationFailure = result.failure;
    } else if (token is String && token.isNotEmpty && pairingCode == null) {
      session = _authSessionManager.validateToken(token);
    }

    if (session == null) {
      if (existingSession == null && clientIdentity != null) {
        _authRateLimiter.recordFailure(clientIdentity);
      }
      _sendAuthError(
        socket,
        authenticationFailure == AuthAuthenticationFailure.capacityReached
            ? 'session_capacity'
            : 'invalid_credentials',
      );
      return;
    }

    if (clientIdentity != null) {
      _authRateLimiter.recordSuccess(clientIdentity);
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

  void _closeRevokedClients() {
    for (final entry in List<MapEntry<WebSocket, AuthSession>>.of(
      _authenticatedClients.entries,
    )) {
      if (_authSessionManager.validateToken(entry.value.token) != null) {
        continue;
      }
      final socket = entry.key;
      _authenticatedClients.remove(socket);
      _clients.remove(socket);
      _clientIdentities.remove(socket);
      unawaited(_closeInvalidSession(socket));
    }
  }

  Future<void> _closeInvalidSession(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.policyViolation, 'Session invalid');
    } catch (_) {
      // A disconnected client has no remaining authorization state to clear.
    }
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

  Future<void> _sendSystemApps(WebSocket socket) async {
    final apps = await SystemActionsService.getInstalledApps(
      executor: _commandExecutor,
    );
    if (!_clients.contains(socket)) return;
    if (!_requireCapability(
      socket,
      _sessionFor(socket),
      AuthCapability.configAdmin,
    )) {
      return;
    }
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
      final session = _sessionFor(entry.key);
      if (session == null || !session.hasCapability(requiredCapability))
        continue;
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

  final Map<WebSocket, String> _clientIdentities = {};

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
    final primary = await _readValidatedConfig(File(_configPath));
    if (primary != null) {
      configData = primary;
      _applyBindSetting(primary);
      return;
    }

    final backup = await _readValidatedConfig(File('$_configPath.bak'));
    if (backup != null) {
      configData = backup;
      _applyBindSetting(backup);
      return;
    }

    configData = _getDefaultConfig();
    _applyBindSetting(configData!);
  }

  void _applyBindSetting(Map<String, dynamic> config) {
    if (_bindAddressOverride != null) return;

    // LAN exposure is an explicit boolean opt-in. Never accept a caller
    // supplied address here: config data may originate from a WebSocket save.
    _bindAddress = config['allow_lan'] is bool && config['allow_lan'] == true
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
  }

  Future<Map<String, dynamic>?> _saveConfigLocal(Object? candidate) {
    final validation = _configValidator.validate(candidate);
    final validated = validation.config;
    if (validated == null) return Future<Map<String, dynamic>?>.value(null);

    final operation = _saveOperation.then((_) async {
      if (!await _writeConfigAtomically(validated, configData)) return null;
      configData = validated;
      return validated;
    });
    // A failed write must not poison later saves in the serialized queue.
    _saveOperation = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  Future<Map<String, dynamic>?> _readValidatedConfig(File file) async {
    try {
      if (!await file.exists()) return null;
      if (await file.length() > _configValidator.limits.maxSerializedBytes) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      return _configValidator.validate(decoded).config;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _writeConfigAtomically(
    Map<String, dynamic> config,
    Map<String, dynamic>? previousConfig,
  ) async {
    final target = File(_configPath);
    final tempPath =
        '$_configPath.tmp-${pid}-${DateTime.now().microsecondsSinceEpoch}';
    final backup = File('$_configPath.bak');
    final backupTemp = File('$tempPath.bak');
    try {
      final encoded = jsonEncode(config);
      await File(tempPath).writeAsString(encoded, flush: true);

      if (previousConfig != null) {
        await backupTemp.writeAsString(jsonEncode(previousConfig), flush: true);
        await backupTemp.rename(backup.path);
      }

      // On the daemon's supported POSIX runtime rename replaces the target as
      // one filesystem operation. The old target remains usable if any step
      // before this point fails, and the .bak is always last-known-good.
      await File(tempPath).rename(target.path);
      return true;
    } catch (_) {
      try {
        final temp = File(tempPath);
        if (await temp.exists()) await temp.delete();
        if (await backupTemp.exists()) await backupTemp.delete();
      } catch (_) {}
      return false;
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
              "payload": "konsole",
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

String _defaultClientIdentity(HttpRequest request) =>
    request.connectionInfo?.remoteAddress.address ?? 'unknown';
