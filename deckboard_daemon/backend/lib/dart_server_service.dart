import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_discovery.dart';
import 'auth_rate_limiter.dart';
import 'auth_session_manager.dart';
import 'command_executor.dart';
import 'config_validator.dart';
import 'protocol_metadata.dart';
import 'server_tls.dart';
import 'session_store.dart';
import 'system_actions_service.dart';
import 'websocket_rate_limiter.dart';

/// Server-level gate for remote KDE power and session actions.
///
/// The default policy denies every sensitive action. Enabling the policy is
/// sufficient for [lock], while destructive actions remain unavailable unless
/// a local confirmation callback is also supplied.
final class SensitiveActionPolicy {
  const SensitiveActionPolicy({
    this.allowSensitiveActions = false,
    this.sensitiveActionConfirmation,
  });

  final bool allowSensitiveActions;
  final Future<bool> Function(String action)? sensitiveActionConfirmation;

  bool allows(String action) {
    if (!allowSensitiveActions) return false;
    return action == 'lock' || sensitiveActionConfirmation != null;
  }

  bool requiresConfirmation(String action) =>
      action == 'sleep' || action == 'shutdown' || action == 'logout';
}

class DartServerService {
  static const int defaultMaxConnections = 100;
  static const int defaultMaxFrameBytes = 64 * 1024;
  static const int defaultMaxOversizedFrameViolations = 3;
  static const int defaultMaxRequestTargetBytes = 8 * 1024;
  static const int defaultMaxRequestHeaderBytes = 32 * 1024;
  static const int defaultMaxRequestHeaderCount = 100;
  static const int defaultMaxRequestBodyBytes = 1024 * 1024;
  static const String _contentSecurityPolicy =
      "default-src 'self'; base-uri 'none'; object-src 'none'; "
      "frame-ancestors 'none'; form-action 'self'; script-src 'self' "
      "'unsafe-inline'; style-src 'self' 'unsafe-inline' "
      'https://fonts.googleapis.com; font-src \'self\' '
      'https://fonts.gstatic.com; img-src \'self\' data:; connect-src \'self\'';
  static final DartServerService _instance = DartServerService._internal();
  factory DartServerService() => _instance;

  static int _validateMaxConnections(int value) {
    if (value <= 0) {
      throw ArgumentError.value(
        value,
        'maxConnections',
        'must be greater than zero',
      );
    }
    return value;
  }

  static int _validatePositiveLimit(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'must be greater than zero');
    }
    return value;
  }

  static Duration _validateMetricsInterval(Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(
        value,
        'metricsInterval',
        'must be greater than zero',
      );
    }
    return value;
  }

  DartServerService._internal()
    : port = 8484,
      _bindAddress = InternetAddress.loopbackIPv4,
      _bindAddressOverride = null,
      _configPath = 'deckboard_config.json',
      _frontendRoot = '../frontend',
      _authSessionManager = AuthSessionManager(issueCodeOnCreate: false),
      _sessionStoreFactory = null,
      _authRateLimiter = AuthRateLimiter(),
      _clientIdentityResolver = _defaultClientIdentity,
      _configValidator = const ConfigValidator(),
      _environment = Platform.environment,
      _commandExecutor = ProcessCommandExecutor.bounded(),
      _launchCommandExecutor = const ProcessCommandExecutor(),
      _sensitiveActionPolicy = const SensitiveActionPolicy(),
      _maxConnections = defaultMaxConnections,
      _maxFrameBytes = defaultMaxFrameBytes,
      _maxOversizedFrameViolations = defaultMaxOversizedFrameViolations,
      _maxRequestTargetBytes = defaultMaxRequestTargetBytes,
      _maxRequestHeaderBytes = defaultMaxRequestHeaderBytes,
      _maxRequestHeaderCount = defaultMaxRequestHeaderCount,
      _maxRequestBodyBytes = defaultMaxRequestBodyBytes,
      _webSocketRateLimiter = WebSocketRateLimiter(),
      _metricsInterval = const Duration(seconds: 4),
      _configWriter = null;

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
    String frontendRoot = '../frontend',
    AuthSessionManager? authSessionManager,
    FileSessionStore Function()? sessionStoreFactory,
    AuthRateLimiter? authRateLimiter,
    String Function(HttpRequest request)? clientIdentityResolver,
    ConfigLimits? configLimits,
    CommandExecutor? commandExecutor,
    CommandExecutor? launchCommandExecutor,
    SensitiveActionPolicy sensitiveActionPolicy = const SensitiveActionPolicy(),
    Map<String, String> environment = const {},
    int maxConnections = defaultMaxConnections,
    int maxFrameBytes = defaultMaxFrameBytes,
    int maxOversizedFrameViolations = defaultMaxOversizedFrameViolations,
    int maxRequestTargetBytes = defaultMaxRequestTargetBytes,
    int maxRequestHeaderBytes = defaultMaxRequestHeaderBytes,
    int maxRequestHeaderCount = defaultMaxRequestHeaderCount,
    int maxRequestBodyBytes = defaultMaxRequestBodyBytes,
    WebSocketRateLimiter? webSocketRateLimiter,
    int maxMessagesPerWindow = WebSocketRateLimiter.defaultMaxMessagesPerWindow,
    int maxActionRequestsPerWindow =
        WebSocketRateLimiter.defaultMaxActionRequestsPerWindow,
    Duration rateLimitWindow = WebSocketRateLimiter.defaultWindow,
    int maxRateLimitViolations = WebSocketRateLimiter.defaultMaxViolations,
    DateTime Function()? clock,
    Duration metricsInterval = const Duration(seconds: 4),
    Future<bool> Function(Map<String, dynamic>, Map<String, dynamic>?)?
    configWriter,
  }) : port = port,
       _bindAddress = bindAddress ?? InternetAddress.loopbackIPv4,
       _bindAddressOverride = bindAddress,
       _configPath = configPath,
       _frontendRoot = frontendRoot,
       _authSessionManager =
           authSessionManager ?? AuthSessionManager(issueCodeOnCreate: false),
       _sessionStoreFactory = sessionStoreFactory,
       _authRateLimiter = authRateLimiter ?? AuthRateLimiter(),
       _clientIdentityResolver =
           clientIdentityResolver ?? _defaultClientIdentity,
       _configValidator = ConfigValidator(
         limits: configLimits ?? const ConfigLimits(),
       ),
       _environment = Map<String, String>.of(environment),
       _commandExecutor = commandExecutor ?? ProcessCommandExecutor.bounded(),
       _launchCommandExecutor =
           launchCommandExecutor ??
           (commandExecutor ?? const ProcessCommandExecutor()),
       _sensitiveActionPolicy = sensitiveActionPolicy,
       _maxConnections = _validateMaxConnections(maxConnections),
       _maxFrameBytes = _validatePositiveLimit(maxFrameBytes, 'maxFrameBytes'),
       _maxOversizedFrameViolations = _validatePositiveLimit(
         maxOversizedFrameViolations,
         'maxOversizedFrameViolations',
       ),
       _maxRequestTargetBytes = _validatePositiveLimit(
         maxRequestTargetBytes,
         'maxRequestTargetBytes',
       ),
       _maxRequestHeaderBytes = _validatePositiveLimit(
         maxRequestHeaderBytes,
         'maxRequestHeaderBytes',
       ),
       _maxRequestHeaderCount = _validatePositiveLimit(
         maxRequestHeaderCount,
         'maxRequestHeaderCount',
       ),
       _maxRequestBodyBytes = _validatePositiveLimit(
         maxRequestBodyBytes,
         'maxRequestBodyBytes',
       ),
       _webSocketRateLimiter =
           webSocketRateLimiter ??
           WebSocketRateLimiter(
             maxMessagesPerWindow: maxMessagesPerWindow,
             maxActionRequestsPerWindow: maxActionRequestsPerWindow,
             window: rateLimitWindow,
             maxViolations: maxRateLimitViolations,
             clock: clock,
           ),
       _metricsInterval = _validateMetricsInterval(metricsInterval),
       _configWriter = configWriter {
    if (authSessionManager != null && sessionStoreFactory != null) {
      throw ArgumentError(
        'authSessionManager and sessionStoreFactory are mutually exclusive',
      );
    }
  }

  HttpServer? _server;
  final List<WebSocket> _clients = [];
  final Map<WebSocket, AuthSession> _authenticatedClients = {};
  InternetAddress _bindAddress;
  final InternetAddress? _bindAddressOverride;
  final String _configPath;
  final String _frontendRoot;
  AuthSessionManager _authSessionManager;
  final FileSessionStore Function()? _sessionStoreFactory;
  FileSessionStore? _ownedSessionStore;
  Future<void> _lifecycleTail = Future<void>.value();
  final AuthRateLimiter _authRateLimiter;
  final String Function(HttpRequest request) _clientIdentityResolver;
  final ConfigValidator _configValidator;
  final Map<String, String> _environment;
  final CommandExecutor _commandExecutor;
  final CommandExecutor _launchCommandExecutor;
  SensitiveActionPolicy _sensitiveActionPolicy;
  final int _maxConnections;
  final int _maxFrameBytes;
  final int _maxOversizedFrameViolations;
  final int _maxRequestTargetBytes;
  final int _maxRequestHeaderBytes;
  final int _maxRequestHeaderCount;
  final int _maxRequestBodyBytes;
  final WebSocketRateLimiter _webSocketRateLimiter;
  final Duration _metricsInterval;
  final Future<bool> Function(Map<String, dynamic>, Map<String, dynamic>?)?
  _configWriter;
  Future<void> _saveOperation = Future<void>.value();
  bool isRunning = false;
  bool isSecure = false;
  int port;
  int _pendingConnections = 0;
  int _lifecycleGeneration = 0;
  final Set<WebSocket> _rateLimitedClosing = <WebSocket>{};
  final Set<WebSocket> _oversizedFrameClosing = <WebSocket>{};
  final Map<WebSocket, int> _oversizedFrameViolations = <WebSocket, int>{};
  String? _canonicalFrontendRoot;

  /// The effective address selected for the next server start.
  InternetAddress get bindAddress => _bindAddress;

  int get maxConnections => _maxConnections;

  int get maxFrameBytes => _maxFrameBytes;

  int get maxRequestTargetBytes => _maxRequestTargetBytes;

  int get maxRequestHeaderBytes => _maxRequestHeaderBytes;

  int get maxRequestHeaderCount => _maxRequestHeaderCount;

  int get maxRequestBodyBytes => _maxRequestBodyBytes;

  SensitiveActionPolicy get sensitiveActionPolicy => _sensitiveActionPolicy;

  int get configRevision => _configRevision;

  /// Configures the production singleton's remote sensitive-action policy.
  ///
  /// Call this during local daemon setup, before accepting remote clients. No
  /// credentials or request payloads are part of this configuration seam.
  void configureSensitiveActionPolicy(SensitiveActionPolicy policy) {
    _sensitiveActionPolicy = policy;
  }

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
  // Keep revisions out of persisted configs so legacy files remain compatible.
  // They protect concurrent explicit saves for this daemon process lifetime.
  int _configRevision = 0;
  int currentVolume = 50;
  int currentBrightness = 70;
  bool isMuted = false;
  Timer? _metricsTimer;
  Object? _metricsProbeToken;

  String? _resolveSystemIconPath(String requestedPath) {
    if (!Platform.isLinux) return null;
    return IconPathValidator(SystemActionsService.linuxIconRoots)
        .resolve(requestedPath);
  }

  Future<String?> _resolveFrontendRoot() async {
    try {
      final resolved = await Directory(_frontendRoot).resolveSymbolicLinks();
      final stat = await FileStat.stat(resolved);
      if (stat.type != FileSystemEntityType.directory) return null;
      return path.normalize(resolved);
    } catch (_) {
      return null;
    }
  }

  Future<File?> _resolveFrontendFile(Uri uri, {required int generation}) async {
    final root = _canonicalFrontendRoot;
    if (root == null) return null;

    final rawPath = uri.path;
    if (!rawPath.startsWith('/') ||
        rawPath.startsWith('//') ||
        rawPath.contains('\u0000')) {
      return null;
    }

    // Decode repeatedly so encoded separators, dot segments, and double
    // encoded traversal cannot become filesystem syntax after validation.
    var decodedPath = rawPath;
    for (var i = 0; i < 3; i++) {
      String next;
      try {
        next = Uri.decodeComponent(decodedPath);
      } catch (_) {
        return null;
      }
      if (next == decodedPath) break;
      decodedPath = next;
    }
    if (decodedPath.contains('\u0000') || decodedPath.startsWith('//')) {
      return null;
    }

    final segments = decodedPath.split('/');
    if (segments.any(
      (segment) =>
          segment == '.' ||
          segment == '..' ||
          segment.contains('\\') ||
          segment.startsWith('/') ||
          segment.contains('\u0000'),
    )) {
      return null;
    }

    final uriSegments = uri.pathSegments;
    if (uriSegments.any(
      (segment) =>
          segment == '.' ||
          segment == '..' ||
          segment.contains('\\') ||
          segment.startsWith('/') ||
          segment.contains('\u0000'),
    )) {
      return null;
    }

    final relativeSegments = uriSegments.where((segment) => segment.isNotEmpty);
    final requestedPath = path.joinAll([root, ...relativeSegments]);
    String canonicalPath;
    try {
      canonicalPath = await File(requestedPath).resolveSymbolicLinks();
    } catch (_) {
      return null;
    }
    if (!_isCurrentHttpGeneration(generation)) return null;
    if (!path.isWithin(root, canonicalPath)) return null;

    try {
      final stat = await FileStat.stat(canonicalPath);
      if (!_isCurrentHttpGeneration(generation)) return null;
      if (stat.type != FileSystemEntityType.file) return null;
      return File(canonicalPath);
    } catch (_) {
      return null;
    }
  }

  ContentType _frontendContentType(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return switch (extension) {
      '.html' || '.htm' => ContentType.html,
      '.css' => ContentType('text', 'css', charset: 'utf-8'),
      '.js' || '.mjs' => ContentType('application', 'javascript'),
      '.json' => ContentType.json,
      '.png' => ContentType('image', 'png'),
      '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
      '.gif' => ContentType('image', 'gif'),
      '.svg' => ContentType('image', 'svg+xml'),
      '.webp' => ContentType('image', 'webp'),
      '.ico' => ContentType('image', 'x-icon'),
      '.woff' => ContentType('font', 'woff'),
      '.woff2' => ContentType('font', 'woff2'),
      '.ttf' => ContentType('font', 'ttf'),
      _ => ContentType.text,
    };
  }

  void _sendFrontendNotFound(HttpResponse response) {
    try {
      response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found')
        ..close();
    } catch (_) {
      // The response may already have started if a file disappeared mid-read.
    }
  }

  /// Applies the standalone server's response policy before any route writes.
  ///
  /// The frontend is served from a mutable local directory and its assets are
  /// not content-addressed, so responses are deliberately not cached. The
  /// policy can be relaxed for fingerprinted immutable assets in a future
  /// release without changing the security headers.
  void _applyHttpResponsePolicy(HttpResponse response) {
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('X-Frame-Options', 'DENY')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Content-Security-Policy', _contentSecurityPolicy)
      ..set('Cache-Control', 'no-store');
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

  Future<void> _enqueueLifecycle(Future<void> Function() operation) {
    // Queue at invocation time; a start requested during shutdown must wait
    // for disposal rather than returning based on the old isRunning flag.
    final request = _lifecycleTail.then<void>((_) => operation());
    // Preserve this request's error for its caller without poisoning the queue.
    _lifecycleTail = request.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return request;
  }

  Future<void> startServer() {
    return _enqueueLifecycle(() async {
      if (isRunning) return;
      await _startServer();
    });
  }

  Future<void> _startServer() async {
    try {
      await _loadConfig();
      _canonicalFrontendRoot = await _resolveFrontendRoot();
      final factory = _sessionStoreFactory;
      if (factory != null) {
        // A fresh store/manager pair is owned by each successful start. Read
        // acquires the lock before the listener can accept any requests.
        final store = factory();
        _ownedSessionStore = store;
        final manager = AuthSessionManager(
          issueCodeOnCreate: false,
          sessionStore: store,
        );
        if (!manager.persistenceHealthy) {
          throw const SessionStoreException();
        }
        _authSessionManager = manager;
      }
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

      _server!.listen(
        (HttpRequest request) async {
          final generation = _lifecycleGeneration;
          if (!_isCurrentHttpGeneration(generation)) {
            await _rejectStaleHttpRequest(request);
            return;
          }
          if (!await _prepareHttpRequest(request, generation: generation)) {
            return;
          }
          if (!_isCurrentHttpGeneration(generation)) {
            await _rejectStaleHttpRequest(request, bodyAlreadyOwned: true);
            return;
          }
          await _routeHttpRequest(request, generation: generation);
        },
        onError: (_, __) {
          // Dart's HttpServer parser closes malformed request-line/header
          // connections before a request callback exists. Never expose parser
          // exception text or raw request data through the server log.
        },
      );
      _authSessionManager.addRevocationListener(_closeRevokedClients);
      _startMetricsLoop();
    } catch (_) {
      await _disposeServer();
      print(
        '❌ [DartServerService] Failed to start server '
        '(check session storage, TLS settings and bind address)',
      );
    }
  }

  Future<void> _routeHttpRequest(
    HttpRequest request, {
    required int generation,
  }) async {
    if (!_isCurrentHttpGeneration(generation)) {
      await _rejectStaleHttpRequest(request, bodyAlreadyOwned: true);
      return;
    }
    _applyHttpResponsePolicy(request.response);
    if (request.uri.path == '/ws') {
      if (!_originMatchesRequestHost(request)) {
        await _rejectInvalidOrigin(request);
        return;
      }
      if (_clients.length + _pendingConnections >= _maxConnections) {
        await _rejectConnectionAtCapacity(request);
        return;
      }
      _pendingConnections++;
      try {
        final clientIdentity = _clientIdentityResolver(request);
        final socket = await WebSocketTransformer.upgrade(request);
        if (!_isCurrentGeneration(generation) || !isRunning) {
          await socket.close(WebSocketStatus.goingAway, 'Server stopping');
          return;
        }
        _handleClientConnect(socket, clientIdentity, generation);
      } catch (_) {
        print("WS Upgrade Error");
      } finally {
        if (_lifecycleGeneration == generation && _pendingConnections > 0) {
          _pendingConnections--;
        }
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
          final exists = await file.exists();
          if (!_isCurrentHttpGeneration(generation)) {
            await _rejectStaleHttpRequest(request, bodyAlreadyOwned: true);
            return;
          }
          if (exists) {
            final ext = resolvedPath.split('.').last.toLowerCase();
            var contentType = 'image/png';
            if (ext == 'svg')
              contentType = 'image/svg+xml';
            else if (ext == 'xpm')
              contentType = 'image/x-xpixmap';

            request.response.headers.contentType = ContentType.parse(
              contentType,
            );
            if (!await _serveHttpFile(request, file, generation)) {
              request.response
                ..statusCode = HttpStatus.internalServerError
                ..close();
            }
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
        final requestedUri = request.requestedUri;
        final uri = requestedUri.path == '/'
            ? requestedUri.replace(path: '/index.html')
            : requestedUri;
        final file = await _resolveFrontendFile(uri, generation: generation);
        if (!_isCurrentHttpGeneration(generation)) {
          await _rejectStaleHttpRequest(request, bodyAlreadyOwned: true);
          return;
        }
        if (file == null) {
          _sendFrontendNotFound(request.response);
          return;
        }

        request.response.headers.contentType = _frontendContentType(file.path);
        if (!await _serveHttpFile(request, file, generation)) {
          _sendFrontendNotFound(request.response);
        }
      } catch (_) {
        if (_isCurrentHttpGeneration(generation)) {
          _sendFrontendNotFound(request.response);
        } else {
          await _closeHttpResponse(request.response);
        }
      }
    }
  }

  Future<bool> _serveHttpFile(
    HttpRequest request,
    File file,
    int generation,
  ) async {
    try {
      await for (final chunk in file.openRead()) {
        if (!_isCurrentHttpGeneration(generation)) {
          await _closeHttpResponse(request.response);
          return true;
        }
        request.response.add(chunk);
      }
      if (!_isCurrentHttpGeneration(generation)) {
        await _closeHttpResponse(request.response);
        return true;
      }
      await request.response.close();
      return true;
    } catch (_) {
      if (!_isCurrentHttpGeneration(generation)) {
        await _closeHttpResponse(request.response);
        return true;
      }
      return false;
    }
  }

  Future<_RequestLimitFailure?> _validateHttpRequestEnvelope(
    HttpRequest request,
  ) async {
    try {
      if (utf8.encode(request.uri.toString()).length > _maxRequestTargetBytes) {
        return _RequestLimitFailure.tooLarge;
      }
      if (request.uri.fragment.isNotEmpty) {
        return _RequestLimitFailure.malformed;
      }

      var headerCount = 0;
      var headerBytes = 2; // The empty line terminating the header section.
      request.headers.forEach((name, values) {
        headerCount += values.length;
        for (final value in values) {
          // HttpHeaders exposes normalized fields rather than the raw wire
          // bytes. This conservative serialization is the controllable
          // application-level approximation of total field-line bytes.
          headerBytes +=
              utf8.encode(name).length + 2 + utf8.encode(value).length + 2;
        }
      });
      if (headerCount > _maxRequestHeaderCount ||
          headerBytes > _maxRequestHeaderBytes) {
        return _RequestLimitFailure.tooLarge;
      }

      if (request.contentLength < -1) {
        return _RequestLimitFailure.malformed;
      }
    } catch (_) {
      return _RequestLimitFailure.malformed;
    }
    return null;
  }

  Future<_RequestLimitFailure?> _validateHttpRequestBody(
    HttpRequest request,
  ) async {
    final contentLength = request.contentLength;
    if (_isHttpUpgrade(request)) {
      // Dart's parser switches the request stream to upgraded mode and
      // reports no readable HTTP body. Do not consume it before the
      // WebSocketTransformer takes ownership of the connection.
      if (contentLength > _maxRequestBodyBytes) {
        return _RequestLimitFailure.tooLarge;
      }
      return null;
    }
    if (contentLength > _maxRequestBodyBytes) {
      // Mark the body as owned before closing the response. Otherwise the
      // public HttpResponse.close() API may drain an unbounded body for us.
      request.listen(null, onError: (_, _) {});
      return _RequestLimitFailure.tooLarge;
    }
    if (contentLength == 0) return null;

    var received = 0;
    try {
      await for (final chunk in request) {
        received += chunk.length;
        if (received > _maxRequestBodyBytes) {
          return _RequestLimitFailure.tooLarge;
        }
      }
      return null;
    } catch (_) {
      return _RequestLimitFailure.malformed;
    }
  }

  bool _isHttpUpgrade(HttpRequest request) {
    final connection = request.headers.value(HttpHeaders.connectionHeader);
    final upgrade = request.headers.value(HttpHeaders.upgradeHeader);
    if (connection == null || upgrade == null) return false;
    return connection
        .split(',')
        .map((token) => token.trim().toLowerCase())
        .contains('upgrade');
  }

  Future<bool> _prepareHttpRequest(
    HttpRequest request, {
    required int generation,
  }) async {
    if (!_isCurrentHttpGeneration(generation)) {
      await _rejectStaleHttpRequest(request);
      return false;
    }
    _applyHttpResponsePolicy(request.response);
    final envelopeFailure = await _validateHttpRequestEnvelope(request);
    if (!_isCurrentHttpGeneration(generation)) {
      await _rejectStaleHttpRequest(request, bodyAlreadyOwned: false);
      return false;
    }
    if (envelopeFailure != null) {
      await _rejectHttpRequest(request, envelopeFailure);
      return false;
    }

    final bodyFailure = await _validateHttpRequestBody(request);
    if (!_isCurrentHttpGeneration(generation)) {
      await _rejectStaleHttpRequest(request, bodyAlreadyOwned: true);
      return false;
    }
    if (bodyFailure != null) {
      await _rejectHttpRequest(request, bodyFailure);
      return false;
    }
    return true;
  }

  Future<void> _rejectHttpRequest(
    HttpRequest request,
    _RequestLimitFailure failure,
  ) async {
    final response = request.response;
    final message = switch (failure) {
      _RequestLimitFailure.malformed => 'Bad Request',
      _RequestLimitFailure.tooLarge => 'Payload Too Large',
    };
    try {
      response
        ..statusCode = failure.statusCode
        ..persistentConnection = false
        ..headers.contentLength = message.length
        ..write(message);
      await response.close();
    } catch (_) {
      // The peer may have closed the connection after sending the invalid
      // request. Do not expose request details or parser errors.
    }
  }

  Future<void> _rejectStaleHttpRequest(
    HttpRequest request, {
    bool bodyAlreadyOwned = false,
  }) async {
    _applyHttpResponsePolicy(request.response);
    if (!bodyAlreadyOwned && !_isHttpUpgrade(request)) {
      // Take ownership before closing the response. Otherwise the HTTP
      // response API may try to drain a body that belongs to a stale request.
      request.listen(null, onError: (_, _) {});
    }
    try {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..persistentConnection = false
        ..headers.contentLength = 0;
      await request.response.close();
    } catch (_) {
      // The listener may already have been closed by server shutdown.
    }
  }

  Future<void> _closeHttpResponse(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {
      // The listener may already have been closed by server shutdown.
    }
  }

  Future<void> stopServer() => _enqueueLifecycle(_disposeServer);

  Future<void> _disposeServer() async {
    // Invalidate every callback that was started by the previous listener
    // before awaiting any socket or server shutdown operation. Dart futures
    // cannot be cancelled, so continuations must fence themselves instead.
    _lifecycleGeneration++;
    // Do not release the old server/store or let a queued restart load the
    // config until every save already in the queue has settled. The queue is
    // kept error-safe by [_saveConfigLocal], so this await cannot poison the
    // lifecycle queue or deadlock on a failed write.
    await _saveOperation;
    _authSessionManager.removeRevocationListener(_closeRevokedClients);
    _metricsTimer?.cancel();
    try {
      for (final client in List<WebSocket>.of(_clients)) {
        try {
          await client.close();
        } catch (_) {
          // A disconnected peer must not prevent release of the store lock.
        }
      }
    } finally {
      _clients.clear();
      _authenticatedClients.clear();
      _clientIdentities.clear();
      _rateLimitedClosing.clear();
      _oversizedFrameClosing.clear();
      _oversizedFrameViolations.clear();
      _webSocketRateLimiter.clear();
      _pendingConnections = 0;
      try {
        await _server?.close(force: true);
      } finally {
        _server = null;
        _canonicalFrontendRoot = null;
        isRunning = false;
        isSecure = false;
        final store = _ownedSessionStore;
        _ownedSessionStore = null;
        store?.close();
      }
    }
  }

  bool _isCurrentGeneration(int generation) =>
      generation == _lifecycleGeneration;

  bool _isCurrentHttpGeneration(int generation) =>
      _isCurrentGeneration(generation) && isRunning;

  bool _isCurrentMetricsGeneration(int generation) =>
      _isCurrentGeneration(generation) && isRunning;

  bool _isCurrentSocket(WebSocket socket, int generation) =>
      _isCurrentGeneration(generation) &&
      isRunning &&
      _clients.contains(socket);

  bool _isCurrentClient(WebSocket socket, int generation) {
    if (!_isCurrentSocket(socket, generation)) return false;
    return _sessionFor(socket) != null;
  }

  void _handleClientConnect(
    WebSocket socket,
    String clientIdentity,
    int generation,
  ) {
    if (!_isCurrentGeneration(generation) || !isRunning) {
      unawaited(socket.close(WebSocketStatus.goingAway, 'Server stopping'));
      return;
    }
    _clients.add(socket);
    _clientIdentities[socket] = clientIdentity;
    print("📱 Client connected! Total clients: ${_clients.length}");

    // Do not disclose config, metrics, or pairing material before auth.
    _sendToSocket(socket, {"type": "auth_required"});

    socket.listen(
      (message) {
        unawaited(_handleMessage(message, socket, generation));
      },
      onDone: () {
        _removeClient(socket);
        print("Client disconnected. Remaining: ${_clients.length}");
      },
      onError: (err) {
        _removeClient(socket);
      },
    );
  }

  Future<void> _handleMessage(
    dynamic message,
    WebSocket socket,
    int generation,
  ) async {
    if (!_isCurrentGeneration(generation) || !_clients.contains(socket)) return;
    if (!_acceptFrame(message, socket)) return;

    final messageLimit = _webSocketRateLimiter.allowMessage(socket);
    if (!messageLimit.isAllowed) {
      _handleRateLimitViolation(socket, messageLimit);
      return;
    }

    try {
      final data = jsonDecode(message.toString());
      if (data is! Map) return;
      final type = data['type'];

      if (type == 'authenticate') {
        _authenticate(data, socket);
      } else if (type == 'trigger_action') {
        final actionLimit = _webSocketRateLimiter.allowAction(socket);
        if (!actionLimit.isAllowed) {
          _handleRateLimitViolation(socket, actionLimit);
          return;
        }
        final session = _sessionFor(socket);
        if (!_requireCapability(socket, session, AuthCapability.control)) {
          return;
        }
        final action = data['action'] is String ? data['action'] as String : '';
        final payload = data['payload']?.toString() ?? '';
        final value = data['value'];
        final success = await _executeAction(
          action,
          payload,
          value,
          socket: socket,
          generation: generation,
        );
        if (!_isCurrentClient(socket, generation)) return;
        if (success) {
          _sendToSocket(socket, {
            "type": "action_result",
            "action": action,
            "success": true,
          });
        } else {
          _sendToSocket(socket, {
            "type": "action_error",
            "action": action,
            "code": "action_failed",
          });
        }
      } else if (type == 'save_config') {
        final session = _sessionFor(socket);
        if (!_requireCapability(socket, session, AuthCapability.configAdmin)) {
          return;
        }
        if (data['config'] != null) {
          final hasRevision = data.containsKey('revision');
          final requestedRevision = hasRevision ? data['revision'] : null;
          if (hasRevision &&
              (requestedRevision is! int || requestedRevision < 0)) {
            _sendToSocket(socket, {
              "type": "config_error",
              "code": "invalid_revision",
            });
            return;
          }

          final saveResult = await _saveConfigLocal(
            data['config'],
            expectedRevision: requestedRevision is int
                ? requestedRevision
                : null,
            generation: generation,
          );
          if (!_isCurrentSocket(socket, generation)) return;
          if (!saveResult.isSuccessful) {
            _sendToSocket(socket, {
              "type": "config_error",
              "code": saveResult.errorCode,
              if (saveResult.isConflict) "revision": _configRevision,
            });
            return;
          }
          _broadcast({
            "type": "config_updated",
            "config": saveResult.config,
            "revision": saveResult.revision,
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
        await _sendSystemApps(socket, generation: generation);
      }
    } catch (_) {
      // Invalid or malformed frames are ignored without logging their data.
    }
  }

  /// Checks the protocol frame representation before any JSON work occurs.
  ///
  /// WebSocket binary frames are intentionally not coerced to strings: doing
  /// so could turn arbitrary bytes into an expensive or ambiguous JSON input.
  bool _acceptFrame(dynamic message, WebSocket socket) {
    if (message is! String || utf8.encode(message).length > _maxFrameBytes) {
      _handleOversizedFrameViolation(socket);
      return false;
    }
    return true;
  }

  void _handleOversizedFrameViolation(WebSocket socket) {
    if (!_clients.contains(socket) || _oversizedFrameClosing.contains(socket)) {
      return;
    }

    final violations = (_oversizedFrameViolations[socket] ?? 0) + 1;
    _oversizedFrameViolations[socket] = violations;
    _sendAuthError(socket, 'message_too_large');
    if (violations < _maxOversizedFrameViolations) return;

    _oversizedFrameClosing.add(socket);
    unawaited(_closeOversizedFrame(socket));
  }

  Future<void> _closeOversizedFrame(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.policyViolation, 'Message too large');
    } catch (_) {
      // The disconnect callback still clears all per-client state.
    }
  }

  void _handleRateLimitViolation(
    WebSocket socket,
    WebSocketRateLimitResult result,
  ) {
    if (!_clients.contains(socket) || _rateLimitedClosing.contains(socket)) {
      return;
    }
    _sendAuthError(socket, 'rate_limited');
    if (!result.shouldClose) return;

    _rateLimitedClosing.add(socket);
    unawaited(_closeRateLimited(socket));
  }

  Future<void> _closeRateLimited(WebSocket socket) async {
    try {
      await socket.close(
        WebSocketStatus.policyViolation,
        'Rate limit exceeded',
      );
    } catch (_) {
      // The disconnect callback still clears all per-client state.
    }
  }

  void _authenticate(Map<dynamic, dynamic> data, WebSocket socket) {
    if (!StandaloneProtocolMetadata.acceptsClientVersion(
      data['protocol_version'],
    )) {
      _sendAuthError(socket, 'unsupported_protocol_version');
      return;
    }

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
      _removeClient(socket);
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

  void _removeClient(WebSocket socket) {
    _clients.remove(socket);
    _authenticatedClients.remove(socket);
    _clientIdentities.remove(socket);
    _rateLimitedClosing.remove(socket);
    _oversizedFrameClosing.remove(socket);
    _oversizedFrameViolations.remove(socket);
    _webSocketRateLimiter.removeClient(socket);
  }

  Future<void> _rejectConnectionAtCapacity(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close(
        WebSocketStatus.policyViolation,
        'Connection capacity reached',
      );
    } catch (_) {
      // Do not retain request, socket, identity, or authentication state.
    }
  }

  /// Validates browser-supplied WebSocket origins without requiring an Origin
  /// header from native clients. The listener's transport determines the
  /// expected HTTP scheme; the Host header supplies the authority.
  bool _originMatchesRequestHost(HttpRequest request) {
    final originHeader = request.headers.value('origin');
    if (originHeader == null) return true;

    final origin = _parseOriginEndpoint(originHeader);
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    final requestHost = hostHeader == null
        ? null
        : _parseHostEndpoint(hostHeader, isSecure ? 'https' : 'http');
    if (origin == null || requestHost == null) return false;

    return origin.scheme == requestHost.scheme &&
        origin.host == requestHost.host &&
        origin.port == requestHost.port;
  }

  Future<void> _rejectInvalidOrigin(HttpRequest request) async {
    try {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden');
      await request.response.close();
    } catch (_) {
      // The request may already have been closed by the peer.
    }
  }

  void _sendInitState(WebSocket socket) {
    final session = _sessionFor(socket);
    if (session == null) return;
    if (configData == null) {
      configData = _getDefaultConfig();
    }

    _sendToSocket(socket, {
      "type": "init_state",
      ...StandaloneProtocolMetadata.advertisement,
      "session_capabilities": AuthCapability.values
          .where(session.hasCapability)
          .map((capability) => capability.name)
          .toList(growable: false),
      "config": configData,
      "revision": _configRevision,
      "pin_required": true,
      "state": {
        "volume": currentVolume,
        "brightness": currentBrightness,
        "is_muted": isMuted,
        "metrics": metrics,
      },
    });
  }

  Future<void> _sendSystemApps(
    WebSocket socket, {
    required int generation,
  }) async {
    final apps = await SystemActionsService.getInstalledApps(
      executor: _commandExecutor,
    );
    if (!_isCurrentSocket(socket, generation)) return;
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

  Future<bool> _executeAction(
    String action,
    String payload,
    dynamic value, {
    required WebSocket socket,
    required int generation,
  }) async {
    switch (action) {
      case 'launch_app':
      case 'open_url':
        return SystemActionsService.executeLaunch(
          payload,
          executor: _launchCommandExecutor,
        );

      case 'audio_volume':
        if (value is! num) return false;
        final vol = value.toInt().clamp(0, 100);
        final volumeSucceeded = await SystemActionsService.setVolume(
          vol,
          executor: _commandExecutor,
        );
        if (!volumeSucceeded) return false;
        if (!_isCurrentClient(socket, generation)) return true;
        currentVolume = vol;
        _broadcast({
          "type": "state_update",
          "key": "volume",
          "value": currentVolume,
        });
        return true;

      case 'audio_mute_toggle':
        final muteSucceeded = await SystemActionsService.toggleMute(
          executor: _commandExecutor,
        );
        if (!muteSucceeded) return false;
        if (!_isCurrentClient(socket, generation)) return true;
        isMuted = !isMuted;
        _broadcast({
          "type": "state_update",
          "key": "is_muted",
          "value": isMuted,
        });
        return true;

      case 'brightness':
        if (value is! num) return false;
        final b = value.toInt().clamp(5, 100);
        final brightnessSucceeded = await SystemActionsService.setBrightness(
          b,
          executor: _commandExecutor,
        );
        if (!brightnessSucceeded) return false;
        if (!_isCurrentClient(socket, generation)) return true;
        currentBrightness = b;
        _broadcast({
          "type": "state_update",
          "key": "brightness",
          "value": currentBrightness,
        });
        return true;

      case 'mpris_action':
        return SystemActionsService.executeMpris(
          payload,
          executor: _commandExecutor,
        );

      case 'kde_action':
        const sensitiveActions = {'sleep', 'shutdown', 'logout', 'lock'};
        if (!sensitiveActions.contains(payload) ||
            !_sensitiveActionPolicy.allows(payload)) {
          return false;
        }

        if (_sensitiveActionPolicy.requiresConfirmation(payload)) {
          final confirmation =
              _sensitiveActionPolicy.sensitiveActionConfirmation;
          if (confirmation == null || !_isCurrentClient(socket, generation)) {
            return false;
          }
          bool confirmed;
          try {
            confirmed = await confirmation(payload);
          } catch (_) {
            confirmed = false;
          }
          if (!confirmed ||
              !_isCurrentClient(socket, generation) ||
              !_sensitiveActionPolicy.allows(payload)) {
            return false;
          }
        }
        if (!_isCurrentClient(socket, generation)) return false;
        return SystemActionsService.executeKdeAction(
          payload,
          executor: _commandExecutor,
        );
    }
    return false;
  }

  // --- Differential Metrics & State Tracking Loop ---

  void _startMetricsLoop() {
    _metricsTimer?.cancel();
    final generation = _lifecycleGeneration;
    _metricsTimer = Timer.periodic(_metricsInterval, (_) {
      final tickGeneration = generation;
      unawaited(_runMetricsTick(tickGeneration));
    });
  }

  Future<void> _runMetricsTick(int generation) async {
    if (!Platform.isLinux || !_isCurrentMetricsGeneration(generation)) return;

    // A periodic timer does not await an async callback. Keep the token until
    // the entire old-generation probe has finished so a restart cannot start
    // a second external command while the first one is still blocked.
    if (_metricsProbeToken != null) return;
    final probeToken = Object();
    _metricsProbeToken = probeToken;
    try {
      await _readLinuxMetrics(generation);
      if (!_isCurrentMetricsGeneration(generation)) return;
      if (_clients.isNotEmpty) {
        await _checkDifferentialStateChanges(generation);
      }
    } catch (_) {
      // Metrics are best-effort and must never affect lifecycle operations.
    } finally {
      // Never let an old probe clear a token belonging to a newer probe.
      if (identical(_metricsProbeToken, probeToken)) {
        _metricsProbeToken = null;
      }
    }
  }

  Future<void> _checkDifferentialStateChanges(int generation) async {
    try {
      bool changed = false;

      // 1. Differential Audio Volume Query
      final pactlVol = await _commandExecutor.run('pactl', [
        'get-sink-volume',
        '@DEFAULT_SINK@',
      ]);
      if (!_isCurrentMetricsGeneration(generation)) return;
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
      final pactlMute = await _commandExecutor.run('pactl', [
        'get-sink-mute',
        '@DEFAULT_SINK@',
      ]);
      if (!_isCurrentMetricsGeneration(generation)) return;
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

  Future<void> _readLinuxMetrics(int generation) async {
    try {
      final memFile = File('/proc/meminfo');
      if (memFile.existsSync()) {
        final content = await memFile.readAsString();
        if (!_isCurrentMetricsGeneration(generation)) return;
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

  Future<_ConfigSaveResult> _saveConfigLocal(
    Object? candidate, {
    int? expectedRevision,
    required int generation,
  }) {
    final validation = _configValidator.validate(candidate);
    final validated = validation.config;
    if (validated == null) {
      return Future<_ConfigSaveResult>.value(const _ConfigSaveResult.invalid());
    }

    final operation = _saveOperation.then((_) async {
      if (!_isCurrentSaveGeneration(generation)) {
        return const _ConfigSaveResult.unavailable();
      }
      if (expectedRevision != null && expectedRevision != _configRevision) {
        return _ConfigSaveResult.conflict(_configRevision);
      }
      final writer = _configWriter;
      final wrote = writer == null
          ? await _writeConfigAtomically(validated, configData)
          : await writer(validated, configData);
      if (!wrote || !_isCurrentSaveGeneration(generation)) {
        return const _ConfigSaveResult.unavailable();
      }
      _configRevision++;
      configData = validated;
      return _ConfigSaveResult.success(validated, _configRevision);
    });
    // A failed write must not poison later saves in the serialized queue.
    _saveOperation = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  bool _isCurrentSaveGeneration(int generation) =>
      _isCurrentGeneration(generation) && isRunning;

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
      "config_schema_version": currentConfigSchemaVersion,
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

final class _ConfigSaveResult {
  const _ConfigSaveResult.success(this.config, this.revision)
    : errorCode = null;

  const _ConfigSaveResult.invalid()
    : config = null,
      revision = null,
      errorCode = 'invalid_config';

  const _ConfigSaveResult.unavailable()
    : config = null,
      revision = null,
      errorCode = 'invalid_config';

  const _ConfigSaveResult.conflict(this.revision)
    : config = null,
      errorCode = 'config_conflict';

  final Map<String, dynamic>? config;
  final int? revision;
  final String? errorCode;

  bool get isSuccessful => config != null;
  bool get isConflict => errorCode == 'config_conflict';
}

enum _RequestLimitFailure {
  malformed,
  tooLarge;

  int get statusCode => switch (this) {
    malformed => HttpStatus.badRequest,
    tooLarge => HttpStatus.requestEntityTooLarge,
  };
}

String _defaultClientIdentity(HttpRequest request) =>
    request.connectionInfo?.remoteAddress.address ?? 'unknown';

final class _OriginEndpoint {
  const _OriginEndpoint({
    required this.scheme,
    required this.host,
    required this.port,
  });

  final String scheme;
  final String host;
  final int port;
}

final class _AuthorityParts {
  const _AuthorityParts(this.host, this.port);

  final String host;
  final int? port;
}

_OriginEndpoint? _parseOriginEndpoint(String value) {
  if (value.isEmpty || value.trim() != value || _containsWhitespace(value)) {
    return null;
  }

  try {
    final uri = Uri.parse(value);
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }

    final authority = _parseAuthority(uri.authority);
    if (authority == null ||
        authority.host.toLowerCase() != uri.host.toLowerCase()) {
      return null;
    }
    return _OriginEndpoint(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: authority.port ?? _defaultOriginPort(scheme),
    );
  } catch (_) {
    return null;
  }
}

_OriginEndpoint? _parseHostEndpoint(String value, String scheme) {
  if (value.isEmpty || value.trim() != value || _containsWhitespace(value)) {
    return null;
  }

  try {
    final authority = _parseAuthority(value);
    if (authority == null) return null;
    final uri = Uri.parse('http://$value');
    if (!uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.path.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        authority.host.toLowerCase() != uri.host.toLowerCase()) {
      return null;
    }
    return _OriginEndpoint(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: authority.port ?? _defaultOriginPort(scheme),
    );
  } catch (_) {
    return null;
  }
}

_AuthorityParts? _parseAuthority(String authority) {
  if (authority.isEmpty || _containsWhitespace(authority)) return null;

  String host;
  String? portText;
  if (authority.startsWith('[')) {
    final closingBracket = authority.indexOf(']');
    if (closingBracket <= 1) return null;
    host = authority.substring(1, closingBracket);
    final suffix = authority.substring(closingBracket + 1);
    if (suffix.isNotEmpty) {
      if (!suffix.startsWith(':') || suffix.length == 1) return null;
      portText = suffix.substring(1);
    }
  } else {
    final colon = authority.lastIndexOf(':');
    if (colon == -1) {
      host = authority;
    } else {
      if (authority.indexOf(':') != colon ||
          colon == 0 ||
          colon == authority.length - 1) {
        return null;
      }
      host = authority.substring(0, colon);
      portText = authority.substring(colon + 1);
    }
  }

  if (host.isEmpty ||
      host.contains('@') ||
      host.contains('[') ||
      host.contains(']')) {
    return null;
  }
  if (portText == null) return _AuthorityParts(host, null);

  final port = int.tryParse(portText);
  if (port == null || port < 0 || port > 65535) return null;
  return _AuthorityParts(host, port);
}

int _defaultOriginPort(String scheme) => scheme == 'https' ? 443 : 80;

bool _containsWhitespace(String value) => value.contains(RegExp(r'\s'));
