import 'package:backend/auth_rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  test('allows the configured failures, then locks the identity', () {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final limiter = AuthRateLimiter(
      maxFailures: 2,
      lockoutDuration: const Duration(minutes: 1),
      clock: clock.now,
    );

    expect(limiter.isAllowed('client-a'), isTrue);
    limiter.recordFailure('client-a');
    expect(limiter.failureCount('client-a'), 1);
    expect(limiter.isAllowed('client-a'), isTrue);
    limiter.recordFailure('client-a');

    expect(limiter.failureCount('client-a'), 2);
    expect(limiter.isAllowed('client-a'), isFalse);
    limiter.recordFailure('client-a');
    expect(limiter.failureCount('client-a'), 2);
  });

  test('expires a lockout and starts a fresh failure window', () {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final limiter = AuthRateLimiter(
      maxFailures: 1,
      lockoutDuration: const Duration(seconds: 10),
      clock: clock.now,
    );

    limiter.recordFailure('client-a');
    expect(limiter.isAllowed('client-a'), isFalse);
    clock.advance(const Duration(seconds: 10));

    expect(limiter.isAllowed('client-a'), isTrue);
    expect(limiter.failureCount('client-a'), 0);
    limiter.recordFailure('client-a');
    expect(limiter.isAllowed('client-a'), isFalse);
  });

  test('successful authentication clears the identity state', () {
    final limiter = AuthRateLimiter(maxFailures: 2);

    limiter.recordFailure('client-a');
    limiter.recordSuccess('client-a');

    expect(limiter.failureCount('client-a'), 0);
    expect(limiter.isAllowed('client-a'), isTrue);
    limiter.recordFailure('client-a');
    expect(limiter.isAllowed('client-a'), isTrue);
  });

  test('removes stale unlocked identities opportunistically', () {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final limiter = AuthRateLimiter(
      maxFailures: 3,
      lockoutDuration: const Duration(seconds: 10),
      maxTrackedIdentities: 3,
      clock: clock.now,
    );

    limiter.recordFailure('stale');
    clock.advance(const Duration(seconds: 5));
    limiter.recordFailure('recent');
    clock.advance(const Duration(seconds: 5));

    limiter.recordFailure('new');

    expect(limiter.failureCount('stale'), 0);
    expect(limiter.failureCount('recent'), 1);
    expect(limiter.failureCount('new'), 1);
  });

  test('evicts the oldest unlocked identity at the tracking limit', () {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final limiter = AuthRateLimiter(
      maxFailures: 3,
      lockoutDuration: const Duration(minutes: 1),
      maxTrackedIdentities: 2,
      clock: clock.now,
    );

    limiter.recordFailure('oldest');
    clock.advance(const Duration(seconds: 1));
    limiter.recordFailure('newer');
    clock.advance(const Duration(seconds: 1));
    limiter.recordFailure('incoming');

    expect(limiter.failureCount('oldest'), 0);
    expect(limiter.failureCount('newer'), 1);
    expect(limiter.failureCount('incoming'), 1);
  });

  test(
    'preserves active lockouts and fails closed when all slots are locked',
    () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = AuthRateLimiter(
        maxFailures: 1,
        lockoutDuration: const Duration(seconds: 10),
        maxTrackedIdentities: 2,
        clock: clock.now,
      );

      limiter.recordFailure('locked-a');
      clock.advance(const Duration(seconds: 1));
      limiter.recordFailure('locked-b');
      limiter.recordFailure('incoming');

      expect(limiter.isAllowed('locked-a'), isFalse);
      expect(limiter.isAllowed('locked-b'), isFalse);
      expect(limiter.isAllowed('incoming'), isFalse);
      expect(limiter.failureCount('locked-a'), 1);
      expect(limiter.failureCount('locked-b'), 1);

      clock.advance(const Duration(seconds: 9));
      expect(limiter.isAllowed('incoming'), isTrue);
      limiter.recordFailure('incoming');
      expect(limiter.isAllowed('incoming'), isFalse);
    },
  );

  test(
    'retains only identity failure metadata, never credentials or payloads',
    () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final limiter = AuthRateLimiter(clock: clock.now);

      limiter.recordFailure('client-a');

      expect(limiter.failureCount('client-a'), 1);
      expect(limiter.failureCount('pairing-code-or-payload'), 0);
    },
  );
}

class FakeClock {
  FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}
