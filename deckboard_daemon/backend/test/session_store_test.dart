import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;
  late FileSessionStore store;
  late DateTime now;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kdedeck-session-test-');
    file = File('${directory.path}/sessions.json');
    store = FileSessionStore(file.path);
    now = DateTime.utc(2026, 1, 1);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  AuthSessionManager manager({String code = 'pairing-secret', int max = 100}) =>
      AuthSessionManager(
        pairingCode: code,
        clock: () => now,
        maxActiveSessions: max,
        sessionStore: store,
      );

  test(
    'resolves production path under user config and refuses missing home',
    () {
      expect(
        FileSessionStore.inUserConfigDirectory(
          environment: {'XDG_CONFIG_HOME': directory.path},
        ).filePath,
        '${directory.path}/kdedeck/sessions.json',
      );
      expect(
        () => FileSessionStore.inUserConfigDirectory(environment: const {}),
        throwsA(isA<SessionStoreException>()),
      );
    },
  );

  test('stores a fingerprint, never bearer tokens or pairing codes', () {
    final session = manager().authenticate('pairing-secret')!;
    final contents = file.readAsStringSync();
    expect(contents, isNot(contains(session.token)));
    expect(contents, isNot(contains('pairing-secret')));
    expect(contents, contains(sessionTokenFingerprint(session.token)));
    expect(jsonDecode(contents)['sessions'], hasLength(1));
  });

  test('restores valid sessions with roles and expiry, not pairing codes', () {
    final session = manager().authenticate(
      'pairing-secret',
      role: AuthRole.control,
    )!;
    final restored = manager(code: 'new-code');
    final recovered = restored.validateToken(session.token);
    expect(recovered, isNotNull);
    expect(recovered!.role, AuthRole.control);
    expect(recovered.expiresAt, session.expiresAt);
    expect(restored.authenticate('pairing-secret'), isNull);
    expect(restored.validateToken('wrong'), isNull);
  });

  test('expired sessions do not restore and are removed from disk', () {
    final session = manager().authenticate('pairing-secret')!;
    now = now.add(const Duration(hours: 1));
    final recovered = manager();
    expect(recovered.activeSessionCount, 0);
    expect(recovered.validateToken(session.token), isNull);
    expect(jsonDecode(file.readAsStringSync())['sessions'], isEmpty);
  });

  test(
    'revoked sessions do not restore, including role and all revocation',
    () {
      final first = manager().authenticate('pairing-secret')!;
      final state = manager(code: 'next');
      expect(state.revokeToken(first.token), isTrue);
      expect(manager().validateToken(first.token), isNull);
      final viewer = manager().authenticate('pairing-secret')!;
      final next = manager(code: 'control');
      final control = next.authenticate('control', role: AuthRole.control)!;
      expect(next.revokeSessionsByRole(AuthRole.viewer), 1);
      expect(manager().validateToken(viewer.token), isNull);
      expect(manager().validateToken(control.token), isNotNull);
      expect(next.revokeAllSessions(), 1);
      expect(manager().validateToken(control.token), isNull);
    },
  );

  test(
    'rejects corrupt store without accepting tokens or issuing sessions',
    () {
      final old = manager().authenticate('pairing-secret')!;
      file.writeAsStringSync('{broken');
      final failed = manager();
      expect(failed.validateToken(old.token), isNull);
      expect(
        failed.authenticateWithStatus('pairing-secret').failure,
        AuthAuthenticationFailure.persistenceUnavailable,
      );
      expect(file.readAsStringSync(), '{broken');
    },
  );

  test('rejects excessive records rather than partially restoring', () {
    final first = manager(max: 2).authenticate('pairing-secret')!;
    final limited = manager(max: 1);
    limited.issuePairingCode(code: 'next');
    expect(
      limited.authenticateWithStatus('next').failure,
      AuthAuthenticationFailure.capacityReached,
    );
    final second = manager(max: 2);
    second.issuePairingCode(code: 'second');
    second.authenticate('second');
    final failed = manager(max: 1);
    expect(failed.activeSessionCount, 0);
    expect(failed.validateToken(first.token), isNull);
    expect(
      failed.authenticateWithStatus('pairing-secret').failure,
      AuthAuthenticationFailure.persistenceUnavailable,
    );
  });

  test(
    'atomically replaces file, leaves no temp files and restricts POSIX mode',
    () {
      final first = manager().authenticate('pairing-secret')!;
      final oldContents = file.readAsStringSync();
      final recovered = manager(code: 'another');
      final second = recovered.authenticate('another')!;
      expect(file.readAsStringSync(), isNot(oldContents));
      expect(manager().validateToken(first.token), isNotNull);
      expect(manager().validateToken(second.token), isNotNull);
      expect(directory.listSync().map((entry) => entry.path).toSet(), {
        file.path,
        '${file.path}.lock',
      });
      if (!Platform.isWindows) {
        final modeFlag = Platform.isMacOS ? '-f' : '-c';
        final modeFormat = Platform.isMacOS ? '%Lp' : '%a';
        expect(
          Process.runSync('stat', [
            modeFlag,
            modeFormat,
            file.path,
          ]).stdout.toString().trim(),
          '600',
        );
        expect(
          Process.runSync('stat', [
            modeFlag,
            modeFormat,
            '${file.path}.lock',
          ]).stdout.toString().trim(),
          '600',
        );
        expect(
          Process.runSync('stat', [
            modeFlag,
            modeFormat,
            directory.path,
          ]).stdout.toString().trim(),
          '700',
        );
      }
    },
  );

  test(
    'write failure closes the manager and retains the last complete file',
    () {
      final failing = _FailingStore(store);
      final active = AuthSessionManager(
        pairingCode: 'pairing-secret',
        clock: () => now,
        sessionStore: failing,
      );
      final old = active.authenticate('pairing-secret')!;
      final snapshot = file.readAsStringSync();
      failing.failWrites = true;
      active.issuePairingCode(code: 'another');
      expect(
        active.authenticateWithStatus('another').failure,
        AuthAuthenticationFailure.persistenceUnavailable,
      );
      expect(active.validateToken(old.token), isNull);
      expect(file.readAsStringSync(), snapshot);
      expect(directory.listSync().map((entry) => entry.path).toSet(), {
        file.path,
        '${file.path}.lock',
      });
    },
  );

  test('fails closed on revoked-session write failure in this process', () {
    final failing = _FailingStore(store);
    final active = AuthSessionManager(
      pairingCode: 'pairing-secret',
      clock: () => now,
      sessionStore: failing,
    );
    final old = active.authenticate('pairing-secret')!;
    failing.failWrites = true;
    expect(active.revokeToken(old.token), isFalse);
    expect(active.validateToken(old.token), isNull);
  });

  test('interruption before atomic replacement keeps a snapshot but blocks restore', () {
    final original = manager().authenticate('pairing-secret')!;
    final snapshot = file.readAsStringSync();
    store.close();
    final interrupted = FileSessionStore(
      file.path,
      beforeReplace: () => throw StateError('interrupted'),
    );
    final active = AuthSessionManager(
      pairingCode: 'another',
      clock: () => now,
      sessionStore: interrupted,
    );
    expect(
      active.authenticateWithStatus('another').failure,
      AuthAuthenticationFailure.persistenceUnavailable,
    );
    expect(active.validateToken(original.token), isNull);
    expect(file.readAsStringSync(), snapshot);
    final pending = File('${file.path}.pending');
    expect(pending.existsSync(), isTrue);
    expect(pending.readAsStringSync(), 'pending\n');
    expect(pending.readAsStringSync(), isNot(contains(original.token)));
    expect(pending.readAsStringSync(), isNot(contains(file.path)));
    expect(directory.listSync().map((entry) => entry.path).toSet(), {
      file.path,
      pending.path,
      '${file.path}.lock',
    });
    interrupted.close();
    store = FileSessionStore(file.path);
    expect(
      () => store.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    final restarted = manager(code: 'restart');
    expect(restarted.validateToken(original.token), isNull);
    expect(
      restarted.authenticateWithStatus('restart').failure,
      AuthAuthenticationFailure.persistenceUnavailable,
    );
  });

  for (final operation in ['token', 'role', 'all']) {
    test('failed $operation revocation cannot restore older tokens', () {
      final issuer = manager();
      final viewer = issuer.authenticate('pairing-secret')!;
      issuer.issuePairingCode(code: 'control');
      final control = issuer.authenticate('control', role: AuthRole.control)!;
      final snapshot = file.readAsStringSync();
      store.close();
      final interrupted = FileSessionStore(
        file.path,
        beforeReplace: () => throw StateError('interrupted'),
      );
      final active = AuthSessionManager(
        issueCodeOnCreate: false,
        clock: () => now,
        sessionStore: interrupted,
      );
      switch (operation) {
        case 'token':
          expect(active.revokeToken(viewer.token), isFalse);
        case 'role':
          expect(active.revokeSessionsByRole(AuthRole.viewer), 0);
        case 'all':
          expect(active.revokeAllSessions(), 0);
      }
      expect(active.validateToken(viewer.token), isNull);
      expect(active.validateToken(control.token), isNull);
      expect(file.readAsStringSync(), snapshot);
      expect(File('${file.path}.pending').existsSync(), isTrue);
      interrupted.close();
      store = FileSessionStore(file.path);
      final restarted = manager();
      expect(restarted.validateToken(viewer.token), isNull);
      expect(restarted.validateToken(control.token), isNull);
      expect(
        restarted.authenticateWithStatus('pairing-secret').failure,
        AuthAuthenticationFailure.persistenceUnavailable,
      );
    });
  }

  test(
    'successful revocation clears marker and restores unaffected session',
    () {
      final active = manager();
      final revoked = active.authenticate('pairing-secret')!;
      active.issuePairingCode(code: 'control');
      final retained = active.authenticate('control', role: AuthRole.control)!;
      expect(active.revokeToken(revoked.token), isTrue);
      expect(File('${file.path}.pending').existsSync(), isFalse);
      expect(manager().validateToken(revoked.token), isNull);
      expect(manager().validateToken(retained.token)?.role, AuthRole.control);
    },
  );

  test('malformed or symlinked marker refuses reads and writes', () {
    final original = manager().authenticate('pairing-secret')!;
    final snapshot = file.readAsStringSync();
    final pending = File('${file.path}.pending');
    pending.writeAsStringSync('corrupt');
    expect(
      () => store.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    expect(manager().validateToken(original.token), isNull);
    expect(file.readAsStringSync(), snapshot);
    pending.deleteSync();
    if (!Platform.isWindows) {
      Link(pending.path).createSync(file.path);
      expect(
        () => store.read(maxSessions: 100),
        throwsA(isA<SessionStoreException>()),
      );
      expect(
        () => store.write(const [], maxSessions: 100),
        throwsA(isA<SessionStoreException>()),
      );
      expect(file.readAsStringSync(), snapshot);
    }
  });

  test('pending marker has restrictive mode on POSIX', () {
    if (Platform.isWindows) return;
    final original = manager().authenticate('pairing-secret')!;
    store.close();
    final interrupted = FileSessionStore(
      file.path,
      beforeReplace: () => throw StateError('interrupted'),
    );
    final active = AuthSessionManager(
      issueCodeOnCreate: false,
      clock: () => now,
      sessionStore: interrupted,
    );
    expect(active.revokeToken(original.token), isFalse);
    final modeFlag = Platform.isMacOS ? '-f' : '-c';
    final modeFormat = Platform.isMacOS ? '%Lp' : '%a';
    expect(
      Process.runSync('stat', [
        modeFlag,
        modeFormat,
        '${file.path}.pending',
      ]).stdout.toString().trim(),
      '600',
    );
    interrupted.close();
  });

  test(
    'failure before marker creation rejects revoke without claiming safety',
    () {
      final original = manager().authenticate('pairing-secret')!;
      final snapshot = file.readAsStringSync();
      store.close();
      final unavailable = FileSessionStore(
        file.path,
        beforePendingCreate: () => throw const SessionStoreException(),
      );
      final active = AuthSessionManager(
        issueCodeOnCreate: false,
        clock: () => now,
        sessionStore: unavailable,
      );
      expect(active.revokeToken(original.token), isFalse);
      expect(active.validateToken(original.token), isNull);
      expect(File('${file.path}.pending').existsSync(), isFalse);
      expect(file.readAsStringSync(), snapshot);
      unavailable.close();
      store = FileSessionStore(file.path);
      // If no marker can be written, the old snapshot cannot be invalidated
      // durably. The caller must receive failure, not a successful revocation.
      expect(manager().validateToken(original.token), isNotNull);
    },
  );

  test('failed marker write stays bounded and refuses stale restore', () {
    final original = manager().authenticate('pairing-secret')!;
    final snapshot = file.readAsStringSync();
    store.close();
    final unavailable = FileSessionStore(
      file.path,
      beforePendingWrite: () =>
          throw StateError('injected marker write failure'),
    );
    final active = AuthSessionManager(
      issueCodeOnCreate: false,
      clock: () => now,
      sessionStore: unavailable,
    );
    expect(active.revokeToken(original.token), isFalse);
    final pending = File('${file.path}.pending');
    expect(pending.existsSync(), isTrue);
    expect(pending.readAsStringSync(), isEmpty);
    expect(file.readAsStringSync(), snapshot);
    unavailable.close();
    store = FileSessionStore(file.path);
    expect(
      () => store.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    expect(manager().validateToken(original.token), isNull);
  });
}

class _FailingStore implements SessionStore {
  _FailingStore(this.delegate);
  final SessionStore delegate;
  bool failWrites = false;

  @override
  List<StoredSession> read({required int maxSessions}) =>
      delegate.read(maxSessions: maxSessions);

  @override
  void write(List<StoredSession> sessions, {required int maxSessions}) {
    if (failWrites) throw const SessionStoreException();
    delegate.write(sessions, maxSessions: maxSessions);
  }
}
