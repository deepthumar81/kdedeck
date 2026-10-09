import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'credential_store.dart';

typedef SocketConnector = WebSocketChannel Function(Uri uri);

class _Endpoint {
  _Endpoint(this.host, this.port, this.secure) {
    if (port < 1 || port > 65535 || !_validHost(host)) {
      throw const FormatException('Invalid server endpoint');
    }
  }

  final String host;
  final int port;
  final bool secure;

  static bool _validHost(String host) {
    if (host.isEmpty ||
        host.length > 253 ||
        host != host.trim() ||
        host.contains(RegExp(r'[/@?#\s\[\]]'))) {
      return false;
    }
    if (host.contains(':')) {
      // IPv6 must be a bare numeric literal; URI builds the brackets.
      return InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6;
    }
    final labels = host.split('.');
    if (labels.length == 4 &&
        labels.every((s) => RegExp(r'^\d+$').hasMatch(s))) {
      return labels.every((s) =>
          s.length <= 3 &&
          (s.length == 1 || !s.startsWith('0')) &&
          int.parse(s) <= 255);
    }
    // Reject numeric aliases such as 127.1 and malformed IPv4 addresses.
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
    return labels.every((label) =>
        label.isNotEmpty &&
        label.length <= 63 &&
        RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$').hasMatch(label));
  }

  bool get loopback {
    if (host.toLowerCase() == '::1') return true;
    final octets = host.split('.');
    return octets.length == 4 &&
        octets.every((s) => RegExp(r'^\d+$').hasMatch(s)) &&
        octets.first == '127';
  }

  Uri get uri => Uri(
        scheme: secure ? 'wss' : 'ws',
        host: host,
        port: port,
        path: '/ws',
      );

  String get key => '${uri.scheme}://${uri.authority}';
}

class WebSocketService extends ChangeNotifier {
  static const int _maxFrameBytes = 1024 * 1024;
  static const int _maxQueuedFrames = 64;

  WebSocketService({
    CredentialStore? credentialStore,
    SocketConnector? connector,
    bool autoConnect = true,
    bool manageWakelock = true,
    Duration readyTimeout = const Duration(seconds: 8),
  })  : _credentialStore = credentialStore ?? SecureCredentialStore(),
        _connector = connector ?? WebSocketChannel.connect,
        _manageWakelock = manageWakelock,
        _readyTimeout = readyTimeout {
    if (autoConnect) unawaited(_loadSettingsAndConnect());
  }

  final CredentialStore _credentialStore;
  final SocketConnector _connector;
  final bool _manageWakelock;
  final Duration _readyTimeout;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  int _generation = 0;
  bool _disposed = false;
  bool _authRequested = false;
  String? _pairingToken;
  String? _pairingCode;
  String? _attemptedToken;
  bool _attemptedCode = false;
  Future<void> _frameQueue = Future<void>.value();
  int _queuedFrames = 0;
  _Endpoint? _activeEndpoint;
  final Set<String> _rejectedCredentials = {};

  /// True only after authorization (or a trusted loopback init_state).
  bool isConnected = false;
  bool authenticated = false;
  bool authRequired = false;
  String? authError;
  String status = 'disconnected';
  bool pinRequired = false;
  bool isBatterySaverMode = false;
  bool enableDragDrop = false;
  bool isMuted = false;
  bool showMetrics = true;

  String serverIp = '192.168.29.128';
  int serverPort = 8484;
  bool? _secureOverride;
  bool get secureConnection => _secureOverride ?? _defaultSecure(serverIp);
  set secureConnection(bool value) => _secureOverride = value;
  String activeServerName = 'Linux PC';
  List<Map<String, dynamic>> savedServers = [];

  /// Revision of the last server config; null for servers without revisions.
  int? configRevision;
  bool configConflict = false;
  String? configError;
  Map<String, dynamic>? remoteConfigData;
  Map<String, dynamic>? configData;
  Map<String, dynamic>? _pendingConfig;
  Map<String, dynamic>? _queuedConfig;
  bool _localDraftDirty = false;

  int currentVolume = 50;
  int currentBrightness = 70;
  Map<String, dynamic> metrics = {
    'cpu_temp': 45,
    'cpu_load': 15,
    'gpu_temp': 50,
    'gpu_load': 20,
    'ram_used_gb': 8.0,
    'ram_total_gb': 16.0,
    'ram_percent': 50,
  };

  String get _serverKey =>
      _Endpoint(serverIp, serverPort, secureConnection).key;

  /// Loopback uses the embedded server's plaintext transport by default.
  /// LAN connections require TLS with the platform's certificate validation.
  Uri get serverUri => _Endpoint(serverIp, serverPort, secureConnection).uri;

  Future<void> _loadSettingsAndConnect() async {
    final initialGeneration = _generation;
    final prefs = await SharedPreferences.getInstance();
    // Drop old plaintext credentials, including those embedded in saved servers.
    final savedJsonStr = prefs.getString('saved_servers_list');
    if (savedJsonStr != null) {
      try {
        final decoded = jsonDecode(savedJsonStr) as List<dynamic>;
        savedServers = decoded.map((entry) {
          final server = Map<String, dynamic>.from(entry as Map);
          server.remove('pin');
          server.remove('token');
          server.remove('pairing_token');
          server.remove('pairing_code');
          server.putIfAbsent('secure', () => _defaultSecure(server['ip']));
          return server;
        }).toList();
      } catch (_) {
        savedServers = [];
      }
    }
    await prefs.remove('server_pin');
    await prefs.remove('server_token');
    await prefs.remove('pairing_token');
    if (savedJsonStr != null) await _saveServersToPrefs();
    if (_disposed || _generation != initialGeneration) return;

    if (savedServers.isEmpty) {
      savedServers = [
        {
          'name': 'Default PC',
          'ip': '192.168.29.128',
          'port': 8484,
          'secure': true
        },
      ];
    }

    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    if (isDesktop) {
      serverIp = '127.0.0.1';
      serverPort = 8484;
      activeServerName = 'Local Desktop Engine';
    } else {
      serverIp = prefs.getString('server_ip') ?? savedServers.first['ip'];
      serverPort = prefs.getInt('server_port') ?? savedServers.first['port'];
      activeServerName =
          prefs.getString('server_name') ?? savedServers.first['name'];
    }
    secureConnection = !isDesktop &&
        (prefs.getBool('server_secure') ??
            (savedServers.first['secure'] == true));
    isBatterySaverMode = prefs.getBool('battery_saver') ?? false;
    enableDragDrop = prefs.getBool('enable_drag_drop') ?? false;
    connect();
  }

  static bool _defaultSecure(dynamic host) {
    try {
      return !_Endpoint(host as String, 8484, false).loopback;
    } catch (_) {
      return true;
    }
  }

  void _invalidEndpoint() {
    authError = 'invalid_endpoint';
    status = 'invalid_endpoint';
    notifyListeners();
  }

  Future<void> addServer(String name, String ip, int port, String pinCode,
      {bool? secure}) async {
    final selectedSecure = secure ?? _defaultSecure(ip);
    try {
      _Endpoint(ip, port, selectedSecure);
    } catch (_) {
      _invalidEndpoint();
      return;
    }
    // pinCode is retained for existing callers; credentials must be supplied
    // explicitly via pairWithToken, never written to SharedPreferences.
    final server = <String, dynamic>{
      'name': name.isNotEmpty ? name : 'PC ($ip)',
      'ip': ip,
      'port': port,
      'secure': selectedSecure,
    };
    savedServers.removeWhere((s) => s['ip'] == ip && s['port'] == port);
    savedServers.add(server);
    await selectServer(server);
    await _saveServersToPrefs();
  }

  Future<void> removeServer(int index) async {
    if (index < 0 || index >= savedServers.length) return;
    final server = savedServers.removeAt(index);
    for (final scheme in ['ws', 'wss']) {
      try {
        await _credentialStore.delete(_Endpoint(
                server['ip'] as String, server['port'] as int, scheme == 'wss')
            .key);
      } catch (_) {
        // A malformed legacy profile has no usable credential key.
      }
    }
    await _saveServersToPrefs();
    notifyListeners();
  }

  Future<void> selectServer(Map<String, dynamic> server) async {
    final host = server['ip'];
    final port = server['port'] ?? 8484;
    final secure = server['secure'] is bool
        ? server['secure'] as bool
        : _defaultSecure(host);
    try {
      _Endpoint(host as String, port as int, secure);
    } catch (_) {
      _invalidEndpoint();
      return;
    }
    _stopCurrent();
    serverIp = host;
    serverPort = port;
    activeServerName = server['name'] ?? 'PC ($serverIp)';
    secureConnection = secure;
    configRevision = null;
    configData = null;
    remoteConfigData = null;
    _pendingConfig = null;
    _queuedConfig = null;
    _localDraftDirty = false;
    configConflict = false;
    configError = null;
    _pairingToken = null;
    _pairingCode = null;
    connect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', serverIp);
    await prefs.setInt('server_port', serverPort);
    await prefs.setString('server_name', activeServerName);
    await prefs.setBool('server_secure', secureConnection);
  }

  /// Switch transport for a server with TLS configured. Certificate validation
  /// remains the platform default; no bad-certificate override is installed.
  Future<void> setSecureConnection(bool secure) async {
    if (secureConnection == secure) return;
    _stopCurrent();
    secureConnection = secure;
    connect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('server_secure', secure);
    for (final server in savedServers) {
      if (server['ip'] == serverIp && server['port'] == serverPort) {
        server['secure'] = secure;
      }
    }
    await _saveServersToPrefs();
  }

  Future<void> _saveServersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_servers_list', jsonEncode(savedServers));
  }

  /// Authenticate with a bearer token; an issued replacement token is stored.
  Future<void> pairWithToken(String token) => _pair(token, code: false);

  /// Exchange a one-time standalone pairing code for an issued bearer token.
  Future<void> pairWithCode(String code) => _pair(code, code: true);

  Future<void> _pair(String value, {required bool code}) async {
    if (value.isEmpty || value.length > 512) {
      authError = 'invalid_credentials';
      notifyListeners();
      return;
    }
    _Endpoint endpoint;
    try {
      endpoint = _Endpoint(serverIp, serverPort, secureConnection);
    } catch (_) {
      _invalidEndpoint();
      return;
    }
    if (!endpoint.secure && !endpoint.loopback) {
      connect();
      return;
    }
    _stopCurrent();
    final generation = _generation;
    _rejectCredential(endpoint.key);
    _pairingCode = code ? value : null;
    _pairingToken = code ? null : value;
    authError = null;
    authRequired = true;
    status = 'auth_required';
    notifyListeners();
    try {
      await _credentialStore.delete(endpoint.key);
    } catch (_) {
      if (!_disposed && generation == _generation) {
        authError = 'credential_unavailable';
        _pairingCode = null;
        _pairingToken = null;
        notifyListeners();
      }
      return;
    }
    if (_disposed || generation != _generation) return;
    _rejectedCredentials.remove(endpoint.key);
    connect();
  }

  Future<void> clearCredential() async {
    String key;
    try {
      key = _activeEndpoint?.key ?? _serverKey;
    } catch (_) {
      _invalidEndpoint();
      return;
    }
    _rejectCredential(key);
    _pairingToken = null;
    _pairingCode = null;
    _attemptedToken = null;
    _restart(authNeeded: true);
    final generation = _generation;
    try {
      await _credentialStore.delete(key);
    } catch (_) {
      if (!_disposed && generation == _generation) {
        authError = 'credential_unavailable';
        notifyListeners();
      }
    }
  }

  void _rejectCredential(String key) {
    _rejectedCredentials.remove(key);
    _rejectedCredentials.add(key);
    if (_rejectedCredentials.length > 32) {
      _rejectedCredentials.remove(_rejectedCredentials.first);
    }
  }

  void _closeChannel(WebSocketChannel channel) {
    unawaited(() async {
      try {
        await channel.sink.close().timeout(_readyTimeout);
      } catch (_) {
        // A stale or failed socket may already be closed.
      }
    }());
  }

  void _stopCurrent() {
    ++_generation;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    final previous = _channel;
    _channel = null;
    _activeEndpoint = null;
    if (previous != null) _closeChannel(previous);
    _authRequested = false;
    _attemptedToken = null;
    _attemptedCode = false;
    _frameQueue = Future<void>.value();
    _queuedFrames = 0;
    if (isConnected) _setWakelock(false);
    authenticated = false;
    isConnected = false;
  }

  void connect() {
    if (_disposed) return;
    _stopCurrent();
    final generation = _generation;
    configRevision = null;
    _pendingConfig = null;
    _queuedConfig = null;
    _Endpoint endpoint;
    try {
      endpoint = _Endpoint(serverIp, serverPort, secureConnection);
    } catch (_) {
      authError = 'invalid_endpoint';
      status = 'invalid_endpoint';
      authRequired = false;
      notifyListeners();
      return;
    }
    if (!endpoint.secure && !endpoint.loopback) {
      authError = 'tls_required';
      status = 'tls_required';
      authRequired = false;
      notifyListeners();
      return;
    }
    if (authError == 'tls_required' || authError == 'invalid_endpoint') {
      authError = null;
    }
    _activeEndpoint = endpoint;
    authRequired = false;
    status = 'connecting';
    notifyListeners();
    unawaited(_open(generation, endpoint));
  }

  Future<void> _open(int generation, _Endpoint endpoint) async {
    try {
      final channel = _connector(endpoint.uri);
      if (_disposed || generation != _generation) {
        _closeChannel(channel);
        return;
      }
      _channel = channel;
      _subscription = channel.stream.listen(
        (message) {
          // Reject non-text and oversized input before queuing or JSON parsing.
          if (message is! String || message.length > _maxFrameBytes) {
            _rejectFrame(generation, channel, 'invalid_frame');
            return;
          }
          try {
            if (utf8.encode(message).length > _maxFrameBytes) {
              _rejectFrame(generation, channel, 'invalid_frame');
              return;
            }
          } catch (_) {
            _rejectFrame(generation, channel, 'invalid_frame');
            return;
          }
          if (_queuedFrames >= _maxQueuedFrames) {
            _rejectFrame(generation, channel, 'overloaded');
            return;
          }
          _queuedFrames++;
          _frameQueue = _frameQueue
              .then((_) => _handleMessage(message, generation, endpoint))
              .catchError((Object _) {
            if (generation == _generation) {
              _handleDisconnect(generation, channel);
            }
          }).whenComplete(() {
            if (generation == _generation) _queuedFrames--;
          });
        },
        onError: (_) {
          if (!_disposed && generation == _generation) {
            authError = 'connection_failed';
          }
          _handleDisconnect(generation, channel);
        },
        onDone: () => _handleDisconnect(generation, channel),
      );
      await channel.ready.timeout(_readyTimeout);
      if (_disposed || generation != _generation) return;
      if (!_authRequested) status = 'awaiting_auth';
      notifyListeners();
    } catch (_) {
      if (generation == _generation && !_disposed) {
        authError = 'connection_failed';
      }
      _handleDisconnect(generation, _channel);
    }
  }

  void _handleDisconnect(int generation, WebSocketChannel? channel) {
    if (_disposed || generation != _generation) return;
    if (channel != _channel) return;
    if (_attemptedCode) _pairingCode = null;
    final needsAuth = authRequired;
    if (_pendingConfig != null || _queuedConfig != null) {
      _localDraftDirty = true;
    }
    _stopCurrent(); // Fence queued frames and delayed credential writes now.
    _pendingConfig = null;
    _queuedConfig = null;
    authRequired = needsAuth;
    status = needsAuth ? 'auth_required' : 'disconnected';
    notifyListeners();
    final retryGeneration = _generation;
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_disposed && retryGeneration == _generation) connect();
    });
  }

  void _rejectFrame(int generation, WebSocketChannel channel, String code) {
    if (_disposed || generation != _generation || channel != _channel) return;
    authError = code;
    _handleDisconnect(generation, channel);
  }

  void _restart({required bool authNeeded}) {
    _stopCurrent();
    authRequired = authNeeded;
    final generation = _generation;
    status = authNeeded ? 'auth_required' : 'disconnected';
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_disposed && generation == _generation) connect();
    });
  }

  void _setWakelock(bool enabled) {
    if (_manageWakelock &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      if (enabled) {
        unawaited(WakelockPlus.enable());
      } else {
        unawaited(WakelockPlus.disable());
      }
    }
  }

  Future<void> _sendAuthentication(
      String credential, bool code, int generation) async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.ready.timeout(_readyTimeout);
    } catch (_) {
      if (generation == _generation && !_disposed) {
        authError = 'connection_failed';
      }
      _handleDisconnect(generation, channel);
      return;
    }
    if (_disposed || generation != _generation || channel != _channel) return;
    if (_attemptedToken == credential && _attemptedCode == code) return;
    _attemptedToken = credential;
    _attemptedCode = code;
    channel.sink.add(jsonEncode({
      'type': 'authenticate',
      'protocol_version': 1,
      code ? 'pairing_code' : 'token': credential,
    }));
    status = 'authenticating';
    notifyListeners();
  }

  Future<void> _handleMessage(
      dynamic message, int generation, _Endpoint endpoint) async {
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(message as String) as Map);
    } catch (_) {
      // Do not print raw frames: malformed frames may contain credentials.
      return;
    }
    if (_disposed || generation != _generation) return;
    final type = data['type'];
    if (type == 'auth_required') {
      if (authenticated) {
        await _authFailed('auth_required', generation, endpoint);
        return;
      }
      _authRequested = true;
      if (data.containsKey('protocol_version') &&
          data['protocol_version'] != 1) {
        await _authFailed('unsupported_protocol', generation, endpoint);
        return;
      }
      if (endpoint.loopback &&
          !endpoint.secure &&
          data['auth_required'] == false) {
        authRequired = false;
        status = 'awaiting_state';
        notifyListeners();
        return;
      }
      authRequired = true;
      status = 'auth_required';
      notifyListeners();
      String? credential;
      bool code = false;
      try {
        credential = _rejectedCredentials.contains(endpoint.key)
            ? null
            : await _credentialStore.read(endpoint.key);
        if (credential == null || credential.isEmpty) {
          credential = _pairingCode ?? _pairingToken;
          code = _pairingCode != null;
        }
      } catch (_) {
        if (generation == _generation) {
          authError = 'credential_unavailable';
          notifyListeners();
        }
        return;
      }
      if (generation != _generation || _disposed) return;
      if (credential != null && credential.isNotEmpty) {
        await _sendAuthentication(credential, code, generation);
      }
    } else if (type == 'auth_success') {
      if (data.containsKey('protocol_version') &&
          data['protocol_version'] != 1) {
        await _authFailed('unsupported_protocol', generation, endpoint);
        return;
      }
      if (!_authRequested || _attemptedToken == null) return;
      final issued = data['token'];
      if (data.containsKey('token') &&
          (issued is! String || issued.isEmpty || issued.length > 512)) {
        await _authFailed('invalid_response', generation, endpoint);
        return;
      }
      final bearer =
          issued is String && issued.isNotEmpty && issued.length <= 512
              ? issued
              : (_attemptedCode ? null : _attemptedToken);
      if (bearer == null) {
        await _authFailed('invalid_response', generation, endpoint);
        return;
      }
      try {
        // Store the issued bearer, never the one-time pairing code. Frame
        // ordering holds init_state and revocation until this write completes.
        await _credentialStore.write(endpoint.key, bearer);
      } catch (_) {
        if (generation == _generation) {
          authError = 'credential_unavailable';
          _pairingCode = null;
          _pairingToken = null;
          _restart(authNeeded: true);
        }
        return;
      }
      if (_disposed || generation != _generation) return;
      _pairingCode = null;
      _pairingToken = null;
      authenticated = true;
      authRequired = false;
      authError = null;
      status = 'awaiting_state';
      notifyListeners();
    } else if (type == 'auth_error' ||
        type == 'authentication_required' ||
        type == 'unsupported_protocol_version' ||
        type == 'session_revoked' ||
        type == 'token_expired' ||
        type == 'session_expired' ||
        type == 'expired' ||
        type == 'revoked' ||
        type == 'rate_limited' ||
        type == 'permission_denied' ||
        type == 'capacity_exceeded' ||
        type == 'error' ||
        type == 'config_error' ||
        type == 'action_error') {
      final code = (data['code'] is String ? data['code'] : type) as String;
      const revoked = {
        'auth_required',
        'authentication_required',
        'invalid_credentials',
        'invalid_token',
        'expired',
        'revoked',
        'session_expired',
        'session_revoked',
        'token_expired',
        'token_revoked',
        'unsupported_protocol',
        'unsupported_protocol_version',
      };
      if (revoked.contains(code) ||
          (!authenticated &&
              (type == 'auth_error' || type == 'rate_limited') &&
              code == 'rate_limited')) {
        await _authFailed(code, generation, endpoint);
      } else if (type == 'config_error' &&
          (code == 'config_conflict' ||
              code == 'invalid_config' ||
              code == 'save_failed')) {
        _handleConfigError(data, code);
      } else if (type == 'auth_error' ||
          type == 'error' ||
          type == 'action_error' ||
          type == 'rate_limited' ||
          type == 'permission_denied' ||
          type == 'capacity_exceeded') {
        // A capacity/permission failure is not evidence that a valid bearer
        // was revoked. Preserve it and report the server's bounded code.
        authError = code;
        if (!authenticated) status = code;
        notifyListeners();
      } else if (type == 'config_error') {
        configError = code;
        _pendingConfig = null;
        _queuedConfig = null;
        notifyListeners();
      }
    } else if (type == 'init_state' || type == 'config_updated') {
      // A remote server must authenticate first. Trusted local transports send
      // init_state after auth_required(auth_required:false).
      if (type == 'config_updated' && !isConnected) return;
      if (!authenticated &&
          !(_authRequested &&
              !authRequired &&
              endpoint.loopback &&
              !endpoint.secure)) {
        return;
      }
      if (type == 'init_state' && data['config'] is! Map) return;
      if (!isConnected) {
        authenticated = true;
        isConnected = true;
        authError = null;
        status = 'connected';
        _setWakelock(true);
      }
      final incoming = data['config'];
      final revision = data['revision'];
      if (revision is int && revision >= 0) configRevision = revision;
      if (incoming is Map) {
        final remote = Map<String, dynamic>.from(incoming);
        remoteConfigData = remote;
        if (_pendingConfig != null) {
          if (_sameConfig(_pendingConfig, remote)) {
            _pendingConfig = null;
            if (_queuedConfig != null) {
              final queued = _queuedConfig!;
              _queuedConfig = null;
              sendSaveConfig(queued);
            } else {
              _localDraftDirty = false;
              configConflict = false;
              configError = null;
            }
          } else {
            configConflict = true;
            configError = 'config_conflict';
            _queuedConfig = null;
          }
        } else if (_localDraftDirty) {
          if (!_sameConfig(configData, remote)) {
            configConflict = true;
            configError = 'config_conflict';
          }
        } else if (!configConflict) {
          configData = remote;
        }
      }
      pinRequired = data['pin_required'] == true;
      _updateState(data['state']);
      notifyListeners();
    } else if (type == 'config_conflict') {
      _handleConfigError(data, 'config_conflict');
    } else if (isConnected && type == 'state_update') {
      final key = data['key'];
      final val = data['value'];
      if (key == 'volume' && val is int) currentVolume = val;
      if (key == 'brightness' && val is int) currentBrightness = val;
      if (key == 'is_muted' || key == 'muted') {
        isMuted = val == true || val == 1;
      }
      notifyListeners();
    } else if (isConnected && type == 'state_poll') {
      _updateState(data['state']);
      notifyListeners();
    }
  }

  Future<void> _authFailed(
      String code, int generation, _Endpoint endpoint) async {
    if (_disposed || generation != _generation) return;
    final key = endpoint.key;
    _rejectCredential(key);
    _pairingToken = null;
    _pairingCode = null;
    authError = code;
    _restart(authNeeded: true);
    try {
      await _credentialStore.delete(key);
    } catch (_) {
      // The endpoint remains rejected in memory if keystore deletion fails.
    }
  }

  void _handleConfigError(Map<String, dynamic> data, String code) {
    configError = code;
    _queuedConfig = null;
    _pendingConfig = null;
    if (code == 'config_conflict') {
      final revision = data['revision'];
      configRevision = revision is int && revision >= 0 ? revision : null;
      final remote = data['config'];
      remoteConfigData =
          remote is Map ? Map<String, dynamic>.from(remote) : null;
      configConflict = true;
    } else {
      // Invalid/rejected saves leave the draft intact, but do not hold the
      // in-flight slot forever. A corrected draft can be submitted again.
      configConflict = false;
    }
    notifyListeners();
  }

  void _updateState(dynamic state) {
    if (state is! Map) return;
    if (state['volume'] is int) currentVolume = state['volume'];
    if (state['brightness'] is int) currentBrightness = state['brightness'];
    isMuted = state['is_muted'] ?? state['muted'] ?? isMuted;
    if (state['metrics'] is Map) {
      metrics = Map<String, dynamic>.from(state['metrics']);
    }
  }

  bool _sameConfig(dynamic left, dynamic right) =>
      jsonEncode(_canonicalJson(left)) == jsonEncode(_canonicalJson(right));

  dynamic _canonicalJson(dynamic value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalJson(value[key])};
    }
    if (value is List) return value.map(_canonicalJson).toList();
    return value;
  }

  void triggerAction(String action,
      {String? payload, dynamic value, String? itemId}) {
    if (_channel == null || !isConnected || !authenticated) return;
    _channel!.sink.add(jsonEncode({
      'type': 'trigger_action',
      'action': action,
      'payload': payload,
      'value': value,
      'item_id': itemId,
    }));
  }

  void sendSaveConfig(Map<String, dynamic> newConfig) {
    if (configConflict) {
      configError = 'config_conflict';
      notifyListeners();
      return;
    }
    configData = newConfig;
    _localDraftDirty = true;
    final snapshot =
        Map<String, dynamic>.from(jsonDecode(jsonEncode(newConfig)));
    notifyListeners();
    if (_pendingConfig != null) {
      _queuedConfig = snapshot;
      return;
    }
    if (_channel == null || !isConnected || !authenticated) return;
    _pendingConfig = snapshot;
    _channel!.sink.add(jsonEncode({
      'type': 'save_config',
      'config': newConfig,
      if (configRevision != null) 'revision': configRevision,
    }));
  }

  /// Explicitly discard a local conflicting edit and adopt the server copy.
  void acceptRemoteConfig() {
    if (!configConflict || remoteConfigData == null) return;
    configData = remoteConfigData;
    _pendingConfig = null;
    _queuedConfig = null;
    _localDraftDirty = false;
    configConflict = false;
    configError = null;
    notifyListeners();
  }

  /// Explicitly rebase a local edit against the observed server revision.
  void resolveConfigConflict(Map<String, dynamic> mergedConfig) {
    if (!configConflict) return;
    if (configRevision == null ||
        remoteConfigData == null ||
        !authenticated ||
        !isConnected) {
      configError = 'reload_required';
      notifyListeners();
      return;
    }
    configConflict = false;
    configError = null;
    _pendingConfig = null;
    _queuedConfig = null;
    _localDraftDirty = false;
    sendSaveConfig(mergedConfig);
  }

  /// Discard the draft and reconnect to obtain a fresh server configuration.
  void reloadServerConfig() {
    configData = null;
    remoteConfigData = null;
    configRevision = null;
    _pendingConfig = null;
    _queuedConfig = null;
    _localDraftDirty = false;
    configConflict = false;
    configError = null;
    connect();
  }

  void toggleMetricsEnabled(bool val) async {
    showMetrics = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_metrics', val);
    if (_channel != null && isConnected && authenticated) {
      _channel!.sink.add(jsonEncode({
        'type': 'set_metrics_enabled',
        'enabled': val,
      }));
    }
  }

  void toggleBatterySaver(bool val) async {
    isBatterySaverMode = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('battery_saver', val);
  }

  void toggleDragDrop(bool val) async {
    enableDragDrop = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('enable_drag_drop', val);
  }

  Future<void> updateServerConnection(
      String ip, int port, String newPin) async {
    try {
      _Endpoint(ip, port, secureConnection);
    } catch (_) {
      _invalidEndpoint();
      return;
    }
    _stopCurrent();
    serverIp = ip;
    serverPort = port;
    configRevision = null;
    configData = null;
    remoteConfigData = null;
    _pendingConfig = null;
    _queuedConfig = null;
    _localDraftDirty = false;
    configConflict = false;
    _pairingToken = null;
    _pairingCode = null;
    connect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', ip);
    await prefs.setInt('server_port', port);
    await prefs.remove('server_pin');
  }

  @override
  void dispose() {
    _disposed = true;
    _stopCurrent();
    super.dispose();
  }
}
