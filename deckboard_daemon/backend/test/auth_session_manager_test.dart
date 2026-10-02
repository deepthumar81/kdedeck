import 'package:backend/auth_session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('AuthSessionManager pairing', () {
    test('generates a pairing code when one is not supplied', () {
      final manager = AuthSessionManager();

      expect(manager.pairingCode, isNotNull);
      expect(manager.pairingCode, hasLength(12));
      expect(manager.authenticate(manager.pairingCode!), isNotNull);
    });

    test('accepts a valid pairing code once', () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final manager = AuthSessionManager(
        pairingCode: 'pair-me',
        clock: clock.now,
      );

      final session = manager.authenticate('pair-me', role: AuthRole.control);

      expect(session, isNotNull);
      expect(session!.role, AuthRole.control);
      expect(manager.authenticate('pair-me'), isNull);
      expect(manager.pairingCode, isNull);
    });

    test('does not consume a code on mismatch and rejects it after expiry', () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final manager = AuthSessionManager(
        pairingCode: 'pair-me',
        pairingCodeLifetime: const Duration(seconds: 10),
        clock: clock.now,
      );

      expect(manager.authenticate('wrong'), isNull);
      expect(manager.pairingCode, 'pair-me');

      clock.advance(const Duration(seconds: 10));
      expect(manager.authenticate('pair-me'), isNull);
      expect(manager.pairingCode, isNull);
    });
  });

  group('AuthSessionManager sessions', () {
    test('validates tokens and enforces role capabilities', () {
      final manager = _managerWithCode('control-code');
      final session = manager.authenticate(
        'control-code',
        role: AuthRole.control,
      )!;

      expect(session.token.length, greaterThanOrEqualTo(40));
      expect(manager.validateToken(session.token), same(session));
      expect(manager.hasRole(session.token, AuthRole.viewer), isTrue);
      expect(manager.hasRole(session.token, AuthRole.control), isTrue);
      expect(manager.hasRole(session.token, AuthRole.configAdmin), isFalse);
      expect(manager.hasCapability(session.token, AuthCapability.view), isTrue);
      expect(
        manager.hasCapability(session.token, AuthCapability.control),
        isTrue,
      );
      expect(
        manager.hasCapability(session.token, AuthCapability.configAdmin),
        isFalse,
      );
      expect(manager.validateToken('not-a-token'), isNull);
      expect(
        manager.validateToken(
          session.token,
          requiredCapability: AuthCapability.configAdmin,
        ),
        isNull,
      );
    });

    test('configAdmin has every capability', () {
      final manager = _managerWithCode('admin-code');
      final session = manager.authenticate(
        'admin-code',
        role: AuthRole.configAdmin,
      )!;

      expect(session.hasRole(AuthRole.configAdmin), isTrue);
      for (final capability in AuthCapability.values) {
        expect(session.hasCapability(capability), isTrue);
        expect(manager.hasCapability(session.token, capability), isTrue);
      }
    });

    test('expires sessions', () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final manager = AuthSessionManager(
        pairingCode: 'pair-me',
        sessionLifetime: const Duration(seconds: 10),
        clock: clock.now,
      );
      final session = manager.authenticate('pair-me')!;

      clock.advance(const Duration(seconds: 9));
      expect(manager.validateToken(session.token), same(session));
      clock.advance(const Duration(seconds: 1));
      expect(manager.validateToken(session.token), isNull);
      expect(manager.activeSessionCount, 0);
    });

    test('revokes a token', () {
      final manager = _managerWithCode('pair-me');
      final session = manager.authenticate('pair-me')!;

      expect(manager.revokeToken(session.token), isTrue);
      expect(manager.validateToken(session.token), isNull);
      expect(manager.revokeToken(session.token), isFalse);
    });

    test('does not expose pairing codes or tokens in diagnostics', () {
      final manager = _managerWithCode('pairing-secret');
      final session = manager.authenticate('pairing-secret')!;

      expect(manager.toString(), isNot(contains('pairing-secret')));
      expect(manager.toString(), isNot(contains(session.token)));
      expect(session.toString(), isNot(contains(session.token)));
      expect(session.toString(), contains('[redacted]'));
    });
  });
}

AuthSessionManager _managerWithCode(String code) => AuthSessionManager(
  pairingCode: code,
  clock: FakeClock(DateTime.utc(2026, 1, 1)).now,
);

class FakeClock {
  FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}
