/// In-memory failed-authentication limiter keyed by a client identity.
///
/// The limiter intentionally stores only a client identity, failure count,
/// timestamps, and lockout expiry.
/// It does not retain attempted credentials or request payloads.
class AuthRateLimiter {
  static const int defaultMaxTrackedIdentities = 1024;

  AuthRateLimiter({
    int maxFailures = 5,
    Duration lockoutDuration = const Duration(minutes: 1),
    int maxTrackedIdentities = defaultMaxTrackedIdentities,
    DateTime Function()? clock,
  }) : _maxFailures = maxFailures,
       _lockoutDuration = lockoutDuration,
       _maxTrackedIdentities = maxTrackedIdentities,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (maxFailures <= 0) {
      throw ArgumentError.value(
        maxFailures,
        'maxFailures',
        'must be greater than zero',
      );
    }
    if (lockoutDuration <= Duration.zero) {
      throw ArgumentError.value(
        lockoutDuration,
        'lockoutDuration',
        'must be greater than zero',
      );
    }
    if (maxTrackedIdentities <= 0) {
      throw ArgumentError.value(
        maxTrackedIdentities,
        'maxTrackedIdentities',
        'must be greater than zero',
      );
    }
  }

  final int _maxFailures;
  final Duration _lockoutDuration;
  final int _maxTrackedIdentities;
  final DateTime Function() _clock;
  final Map<String, _AuthFailureState> _failures =
      <String, _AuthFailureState>{};

  /// The maximum number of failed attempts accepted before lockout.
  int get maxFailures => _maxFailures;

  /// How long an identity remains locked after reaching [maxFailures].
  Duration get lockoutDuration => _lockoutDuration;

  /// The maximum number of identities retained by this limiter.
  int get maxTrackedIdentities => _maxTrackedIdentities;

  /// Whether [identity] may make another authentication attempt.
  bool isAllowed(String identity) {
    final now = _now();
    _removeStaleStates(now);
    final state = _failures[identity];
    if (state != null) return state.lockedUntil == null;

    // If every retained identity is actively locked, reject new identities
    // until one of those lockouts expires rather than growing the map.
    return _failures.length < _maxTrackedIdentities || _hasUnlockedState;
  }

  /// Records one failed authentication attempt for [identity].
  ///
  /// Calls made while the identity is already locked are ignored. This keeps
  /// the failure state bounded and prevents a lockout from being extended by a
  /// stream of rejected requests.
  void recordFailure(String identity) {
    final now = _now();
    _removeStaleStates(now);
    final state = _failures[identity];
    if (state?.lockedUntil != null) return;

    if (state == null && !_makeRoomForIdentity()) return;

    final failures = (state?.failures ?? 0) + 1;
    _failures[identity] = _AuthFailureState(
      failures: failures,
      lockedUntil: failures >= _maxFailures ? now.add(_lockoutDuration) : null,
      lastFailureAt: now,
    );
  }

  /// Clears all failed-attempt state after successful authentication.
  void recordSuccess(String identity) {
    _failures.remove(identity);
  }

  /// Returns the currently retained failure count for [identity].
  ///
  /// This is primarily useful for diagnostics and deterministic tests; it does
  /// not expose any credential or request data.
  int failureCount(String identity) =>
      _stateFor(identity, _now())?.failures ?? 0;

  DateTime _now() => _clock().toUtc();

  _AuthFailureState? _stateFor(String identity, DateTime now) {
    _removeStaleStates(now);
    return _failures[identity];
  }

  void _removeStaleStates(DateTime now) {
    _failures.removeWhere((_, state) {
      final expiry =
          state.lockedUntil ?? state.lastFailureAt.add(_lockoutDuration);
      return !now.isBefore(expiry);
    });
  }

  bool get _hasUnlockedState =>
      _failures.values.any((state) => state.lockedUntil == null);

  bool _makeRoomForIdentity() {
    if (_failures.length < _maxTrackedIdentities) return true;

    String? oldestIdentity;
    DateTime? oldestFailureAt;
    for (final entry in _failures.entries) {
      final state = entry.value;
      if (state.lockedUntil != null) continue;
      if (oldestFailureAt == null ||
          state.lastFailureAt.isBefore(oldestFailureAt)) {
        oldestIdentity = entry.key;
        oldestFailureAt = state.lastFailureAt;
      }
    }

    if (oldestIdentity == null) return false;
    _failures.remove(oldestIdentity);
    return true;
  }
}

final class _AuthFailureState {
  const _AuthFailureState({
    required this.failures,
    required this.lockedUntil,
    required this.lastFailureAt,
  });

  final int failures;
  final DateTime? lockedUntil;
  final DateTime lastFailureAt;
}
