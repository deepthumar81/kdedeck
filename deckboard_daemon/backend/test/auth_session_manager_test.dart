import 'package:backend/auth_session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('AuthSessionManager pairing', () {
    test('local-only mode stays closed until explicit issuance', () {
      final manager = AuthSessionManager(issueCodeOnCreate: false);
      expect(manager.pairingCode, isNull);
      expect(manager.authenticate('unrequested-code'), isNull);
      manager.issuePairingCode(code: 'dummy-local-code');
      expect(manager.authenticate('dummy-local-code'), isNotNull);
    });

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

    test('cleans up expired sessions before enforcing capacity', () {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final manager = AuthSessionManager(
        pairingCode: 'first-code',
        sessionLifetime: const Duration(seconds: 10),
        maxActiveSessions: 1,
        clock: clock.now,
      );
      final first = manager.authenticate('first-code')!;

      manager.issuePairingCode(code: 'second-code');
      clock.advance(const Duration(seconds: 10));
      final second = manager.authenticateWithStatus('second-code');

      expect(second.session, isNotNull);
      expect(manager.activeSessionCount, 1);
      expect(manager.validateToken(first.token), isNull);
    });

    test('rejects pairing at capacity without consuming the pairing code', () {
      final manager = AuthSessionManager(
        pairingCode: 'first-code',
        maxActiveSessions: 1,
      );
      final first = manager.authenticate('first-code')!;
      manager.issuePairingCode(code: 'second-code');

      final result = manager.authenticateWithStatus('second-code');

      expect(result.session, isNull);
      expect(result.failure, AuthAuthenticationFailure.capacityReached);
      expect(manager.pairingCode, 'second-code');
      expect(manager.validateToken(first.token), same(first));
      expect(manager.authenticate('wrong-code'), isNull);
      expect(manager.pairingCode, 'second-code');
      expect(result.toString(), isNot(contains(first.token)));
    });

    test('revokes sessions by role while preserving other active sessions', () {
      final manager = _managerWithCode('viewer-code');
      final viewer = manager.authenticate(
        'viewer-code',
        role: AuthRole.viewer,
      )!;
      manager.issuePairingCode(code: 'control-code');
      final control = manager.authenticate(
        'control-code',
        role: AuthRole.control,
      )!;
      manager.issuePairingCode(code: 'admin-code');
      final admin = manager.authenticate(
        'admin-code',
        role: AuthRole.configAdmin,
      )!;

      expect(manager.revokeSessionsByRole(AuthRole.control), 1);
      expect(manager.validateToken(viewer.token), same(viewer));
      expect(manager.validateToken(control.token), isNull);
      expect(manager.validateToken(admin.token), same(admin));
      expect(manager.revokeAllSessions(), 2);
      expect(manager.activeSessionCount, 0);
    });

    test('revokes a token', () {
      final manager = _managerWithCode('pair-me');
      final session = manager.authenticate('pair-me')!;

      expect(manager.revokeToken(session.token), isTrue);
      expect(manager.validateToken(session.token), isNull);
      expect(manager.revokeToken(session.token), isFalse);
    });

    test(
      'notifies only after effective revocations, without token payloads',
      () {
        final manager = _managerWithCode('viewer');
        final viewer = manager.authenticate('viewer', role: AuthRole.viewer)!;
        manager.issuePairingCode(code: 'control');
        final control = manager.authenticate(
          'control',
          role: AuthRole.control,
        )!;
        var notifications = 0;
        void listener() {
          notifications++;
          expect(manager.validateToken(viewer.token), isNull);
        }

        manager.addRevocationListener(listener);
        expect(manager.revokeToken('unknown'), isFalse);
        expect(manager.revokeSessionsByRole(AuthRole.configAdmin), 0);
        expect(notifications, 0);
        expect(manager.revokeToken(viewer.token), isTrue);
        expect(notifications, 1);
        expect(manager.revokeToken(viewer.token), isFalse);
        expect(manager.revokeSessionsByRole(AuthRole.control), 1);
        expect(manager.validateToken(control.token), isNull);
        expect(notifications, 2);
        expect(manager.revokeAllSessions(), 0);
        expect(notifications, 2);
        manager.removeRevocationListener(listener);
        manager.issuePairingCode(code: 'another');
        manager.authenticate('another');
        expect(manager.revokeAllSessions(), 1);
        expect(notifications, 2);
      },
    );

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
