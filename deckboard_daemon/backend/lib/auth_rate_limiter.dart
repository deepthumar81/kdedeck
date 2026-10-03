/// In-memory failed-authentication limiter keyed by a client identity.
///
/// The limiter intentionally stores only a failure count and lockout expiry.
/// It does not retain attempted credentials or request payloads.
class AuthRateLimiter {
  AuthRateLimiter({
    int maxFailures = 5,
    Duration lockoutDuration = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _maxFailures = maxFailures,
       _lockoutDuration = lockoutDuration,
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
  }

  final int _maxFailures;
  final Duration _lockoutDuration;
  final DateTime Function() _clock;
  final Map<String, _AuthFailureState> _failures =
      <String, _AuthFailureState>{};

  /// The maximum number of failed attempts accepted before lockout.
  int get maxFailures => _maxFailures;

  /// How long an identity remains locked after reaching [maxFailures].
  Duration get lockoutDuration => _lockoutDuration;

  /// Whether [identity] may make another authentication attempt.
  bool isAllowed(String identity) {
    final state = _stateFor(identity, _now());
    return state == null || state.lockedUntil == null;
  }

  /// Records one failed authentication attempt for [identity].
  ///
  /// Calls made while the identity is already locked are ignored. This keeps
  /// the failure state bounded and prevents a lockout from being extended by a
  /// stream of rejected requests.
  void recordFailure(String identity) {
    final now = _now();
    final state = _stateFor(identity, now);
    if (state?.lockedUntil != null) return;

    final failures = (state?.failures ?? 0) + 1;
    _failures[identity] = _AuthFailureState(
      failures: failures,
      lockedUntil: failures >= _maxFailures ? now.add(_lockoutDuration) : null,
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
    final state = _failures[identity];
    if (state == null) return null;
    final lockedUntil = state.lockedUntil;
    if (lockedUntil != null && !now.isBefore(lockedUntil)) {
      _failures.remove(identity);
      return null;
    }
    return state;
  }
}

final class _AuthFailureState {
  const _AuthFailureState({required this.failures, required this.lockedUntil});

  final int failures;
  final DateTime? lockedUntil;
}
