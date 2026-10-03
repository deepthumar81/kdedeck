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
}

class FakeClock {
  FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}
