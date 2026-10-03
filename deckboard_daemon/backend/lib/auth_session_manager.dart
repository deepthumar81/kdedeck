import 'dart:convert';
import 'dart:math';

/// In-memory pairing and bearer-session state for the standalone Dart backend.
///
/// The pairing code is consumed after a successful pairing and expires after a
/// short period. Session tokens are random bearer credentials and are never
/// included in diagnostic output. Persistence, secure client-side credential
/// storage, and embedded-client wiring remain outside this standalone-server
/// slice.
enum AuthRole { viewer, control, configAdmin }

/// Operations that can be authorized by an [AuthSession].
enum AuthCapability { view, control, configAdmin }

/// Why a pairing attempt did not produce a session.
///
/// The values are intentionally bounded and contain no credential details.
enum AuthAuthenticationFailure { invalidCredentials, capacityReached }

extension AuthRolePermissions on AuthRole {
  /// The capabilities granted by this role.
  Set<AuthCapability> get capabilities => switch (this) {
    AuthRole.viewer => const {AuthCapability.view},
    AuthRole.control => const {AuthCapability.view, AuthCapability.control},
    AuthRole.configAdmin => const {
      AuthCapability.view,
      AuthCapability.control,
      AuthCapability.configAdmin,
    },
  };

  /// Whether this role is at least as privileged as [requiredRole].
  bool satisfies(AuthRole requiredRole) => index >= requiredRole.index;

  /// Whether this role grants [capability].
  bool allows(AuthCapability capability) => capabilities.contains(capability);
}

/// A validated bearer session and its non-secret authorization metadata.
class AuthSession {
  AuthSession({
    required this.token,
    required this.role,
    required this.issuedAt,
    required this.expiresAt,
  });

  /// The bearer token. Callers must store this securely.
  final String token;

  final AuthRole role;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// Whether the session is expired at [now].
  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  /// Whether this session grants [capability].
  bool hasCapability(AuthCapability capability) => role.allows(capability);

  /// Whether this session has [requiredRole] or a more privileged role.
  bool hasRole(AuthRole requiredRole) => role.satisfies(requiredRole);

  @override
  String toString() =>
      'AuthSession(role: $role, issuedAt: $issuedAt, expiresAt: $expiresAt, '
      'token: [redacted])';
}

/// The bounded outcome of a pairing attempt.
///
/// [session] is non-null only for a successful pairing. Failure outcomes never
/// include the supplied pairing code, a token, or any other request data.
class AuthAuthenticationResult {
  const AuthAuthenticationResult.success(this.session) : failure = null;

  const AuthAuthenticationResult.failure(this.failure) : session = null;

  final AuthSession? session;
  final AuthAuthenticationFailure? failure;

  bool get succeeded => session != null;

  @override
  String toString() =>
      'AuthAuthenticationResult(status: ${succeeded ? 'success' : failure})';
}

/// Manages a one-time pairing code and in-memory bearer sessions.
class AuthSessionManager {
  AuthSessionManager({
    Duration pairingCodeLifetime = const Duration(minutes: 5),
    Duration sessionLifetime = const Duration(hours: 1),
    int maxActiveSessions = defaultMaxActiveSessions,
    String? pairingCode,
    bool issueCodeOnCreate = true,
    DateTime Function()? clock,
    Random? random,
  }) : _pairingCodeLifetime = pairingCodeLifetime,
       _sessionLifetime = sessionLifetime,
       _maxActiveSessions = maxActiveSessions,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _random = random ?? Random.secure() {
    if (pairingCodeLifetime <= Duration.zero) {
      throw ArgumentError.value(
        pairingCodeLifetime,
        'pairingCodeLifetime',
        'must be greater than zero',
      );
    }
    if (sessionLifetime <= Duration.zero) {
      throw ArgumentError.value(
        sessionLifetime,
        'sessionLifetime',
        'must be greater than zero',
      );
    }
    if (maxActiveSessions <= 0) {
      throw ArgumentError.value(
        maxActiveSessions,
        'maxActiveSessions',
        'must be greater than zero',
      );
    }

    if (pairingCode != null || issueCodeOnCreate) {
      issuePairingCode(code: pairingCode);
    }
  }

  static const _pairingAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _sessionTokenByteLength = 32;
  static const _generatedPairingCodeLength = 12;

  /// Safe default bound for the in-memory bearer-session table.
  static const defaultMaxActiveSessions = 100;

  final Duration _pairingCodeLifetime;
  final Duration _sessionLifetime;
  final int _maxActiveSessions;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, AuthSession> _sessions = <String, AuthSession>{};
  final Set<void Function()> _revocationListeners = {};

  String? _pairingCode;
  DateTime? _pairingCodeExpiresAt;

  /// The current pairing code, for display by the local backend only.
  ///
  /// This value is intentionally not included in [toString]. It becomes null
  /// after successful pairing or expiry.
  String? get pairingCode {
    _expirePairingCodeIfNeeded(_now());
    return _pairingCode;
  }

  /// When the current pairing code expires.
  DateTime? get pairingCodeExpiresAt {
    _expirePairingCodeIfNeeded(_now());
    return _pairingCodeExpiresAt;
  }

  /// Number of currently retained sessions, excluding expired sessions.
  int get activeSessionCount {
    _removeExpiredSessions(_now());
    return _sessions.length;
  }

  /// Maximum number of non-expired bearer sessions retained by this manager.
  int get maxActiveSessions => _maxActiveSessions;

  /// Issues a fresh pairing code and invalidates any previously issued code.
  ///
  /// A supplied [code] is useful when an external local mechanism has already
  /// generated a code. Otherwise a cryptographically secure random code is
  /// generated by this manager.
  String issuePairingCode({String? code}) {
    final nextCode = code ?? _generatePairingCode();
    if (nextCode.isEmpty) {
      throw ArgumentError.value(code, 'code', 'must not be empty');
    }

    _pairingCode = nextCode;
    _pairingCodeExpiresAt = _now().add(_pairingCodeLifetime);
    return nextCode;
  }

  /// Exchanges the one-time [code] for a session with [role].
  ///
  /// A wrong code does not consume the valid code, while a successful match
  /// consumes it immediately. Returns null for a wrong or expired code.
  AuthSession? authenticate(String code, {AuthRole role = AuthRole.viewer}) =>
      authenticateWithStatus(code, role: role).session;

  /// Exchanges the one-time [code] for a session and reports a bounded status.
  ///
  /// Expired sessions are removed before capacity is checked, so they never
  /// prevent a valid pairing from succeeding. At capacity, the pairing code is
  /// retained so an administrator can revoke a session and retry pairing.
  AuthAuthenticationResult authenticateWithStatus(
    String code, {
    AuthRole role = AuthRole.viewer,
  }) {
    final now = _now();
    _removeExpiredSessions(now);
    _expirePairingCodeIfNeeded(now);
    final expectedCode = _pairingCode;
    if (expectedCode == null || !_constantTimeEquals(code, expectedCode)) {
      return const AuthAuthenticationResult.failure(
        AuthAuthenticationFailure.invalidCredentials,
      );
    }
    if (_sessions.length >= _maxActiveSessions) {
      return const AuthAuthenticationResult.failure(
        AuthAuthenticationFailure.capacityReached,
      );
    }

    _pairingCode = null;
    _pairingCodeExpiresAt = null;

    final session = AuthSession(
      token: _generateUniqueSessionToken(),
      role: role,
      issuedAt: now,
      expiresAt: now.add(_sessionLifetime),
    );
    _sessions[session.token] = session;
    return AuthAuthenticationResult.success(session);
  }

  /// Alias for [authenticate] using pairing terminology.
  AuthSession? pair(String code, {AuthRole role = AuthRole.viewer}) =>
      authenticate(code, role: role);

  /// Validates [token] and returns its session, or null if invalid, expired,
  /// or revoked.
  AuthSession? validateToken(
    String token, {
    AuthRole? requiredRole,
    AuthCapability? requiredCapability,
  }) {
    if (token.isEmpty) return null;

    final session = _sessions[token];
    if (session == null) return null;
    if (session.isExpired(_now())) {
      _sessions.remove(token);
      return null;
    }
    if (requiredRole != null && !session.hasRole(requiredRole)) return null;
    if (requiredCapability != null &&
        !session.hasCapability(requiredCapability)) {
      return null;
    }
    return session;
  }

  /// Whether [token] is valid and grants [capability].
  bool hasCapability(String token, AuthCapability capability) =>
      validateToken(token, requiredCapability: capability) != null;

  /// Whether [token] is valid and has [requiredRole] or a more privileged role.
  bool hasRole(String token, AuthRole requiredRole) =>
      validateToken(token, requiredRole: requiredRole) != null;

  /// Notifies local consumers after active sessions have been revoked.
  ///
  /// No token or session data is delivered to listeners; consumers revalidate
  /// their own sessions. Expiry cleanup does not trigger this notification.
  void addRevocationListener(void Function() listener) =>
      _revocationListeners.add(listener);

  void removeRevocationListener(void Function() listener) =>
      _revocationListeners.remove(listener);

  /// Revokes [token]. Returns false when no active session matched it.
  bool revokeToken(String token) {
    if (validateToken(token) == null || _sessions.remove(token) == null) {
      return false;
    }
    _notifyRevocation();
    return true;
  }

  /// Revokes every active session and returns the number removed.
  int revokeAllSessions() {
    _removeExpiredSessions(_now());
    final revokedCount = _sessions.length;
    _sessions.clear();
    if (revokedCount > 0) _notifyRevocation();
    return revokedCount;
  }

  /// Revokes sessions with [role] and returns the number removed.
  ///
  /// When [includeMorePrivileged] is true, sessions with a role at least as
  /// privileged as [role] are revoked; otherwise only the exact role matches.
  int revokeSessionsByRole(
    AuthRole role, {
    bool includeMorePrivileged = false,
  }) {
    final now = _now();
    _removeExpiredSessions(now);
    final before = _sessions.length;
    _sessions.removeWhere(
      (_, session) => includeMorePrivileged
          ? session.role.satisfies(role)
          : session.role == role,
    );
    final revokedCount = before - _sessions.length;
    if (revokedCount > 0) _notifyRevocation();
    return revokedCount;
  }

  void _notifyRevocation() {
    for (final listener in List<void Function()>.of(_revocationListeners)) {
      listener();
    }
  }

  @override
  String toString() =>
      'AuthSessionManager(activeSessions: $activeSessionCount, '
      'pairingCode: [redacted], pairingCodeExpiresAt: $pairingCodeExpiresAt)';

  DateTime _now() => _clock().toUtc();

  void _expirePairingCodeIfNeeded(DateTime now) {
    final expiresAt = _pairingCodeExpiresAt;
    if (expiresAt != null && !now.isBefore(expiresAt)) {
      _pairingCode = null;
      _pairingCodeExpiresAt = null;
    }
  }

  void _removeExpiredSessions(DateTime now) {
    _sessions.removeWhere((_, session) => session.isExpired(now));
  }

  String _generatePairingCode() {
    final buffer = StringBuffer();
    for (var index = 0; index < _generatedPairingCodeLength; index++) {
      buffer.write(_pairingAlphabet[_random.nextInt(_pairingAlphabet.length)]);
    }
    return buffer.toString();
  }

  String _generateUniqueSessionToken() {
    String token;
    do {
      final bytes = List<int>.generate(
        _sessionTokenByteLength,
        (_) => _random.nextInt(256),
        growable: false,
      );
      token = base64Url.encode(bytes).replaceAll('=', '');
    } while (_sessions.containsKey(token));
    return token;
  }

  /// Compares UTF-8 bytes without returning early for a mismatch or length.
  static bool _constantTimeEquals(String left, String right) {
    final leftBytes = utf8.encode(left);
    final rightBytes = utf8.encode(right);
    var difference = leftBytes.length ^ rightBytes.length;
    final length = max(leftBytes.length, rightBytes.length);
    for (var index = 0; index < length; index++) {
      final leftByte = index < leftBytes.length ? leftBytes[index] : 0;
      final rightByte = index < rightBytes.length ? rightBytes[index] : 0;
      difference |= leftByte ^ rightByte;
    }
    return difference == 0;
  }
}
