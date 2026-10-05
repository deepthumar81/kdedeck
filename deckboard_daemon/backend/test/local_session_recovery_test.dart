import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/local_session_recovery.dart';
import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File primary;
  late File marker;
  late FileSessionStore store;
  final now = DateTime.utc(2026, 1, 1);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kdedeck-recovery-test-');
    primary = File('${directory.path}/sessions.json');
    marker = File('${primary.path}.pending');
    store = FileSessionStore(primary.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  String issueToken() => AuthSessionManager(
    pairingCode: 'test-code',
    clock: () => now,
    sessionStore: store,
  ).authenticate('test-code')!.token;

  AuthSessionManager reconstruct() => AuthSessionManager(
    issueCodeOnCreate: false,
    clock: () => now,
    sessionStore: store,
  );

  test(
    'nonterminal stdin or stdout refuses before reading or constructing store',
    () {
      for (final flags in [(false, true), (true, false)]) {
        var accesses = 0;
        final messages = <String>[];
        expect(
          resetLocalSessions(
            inputHasTerminal: () => flags.$1,
            outputHasTerminal: () => flags.$2,
            readLine: () {
              accesses++;
              return 'RESET';
            },
            writeLine: messages.add,
            createStore: () {
              accesses++;
              return store;
            },
          ),
          2,
        );
        expect(accesses, 0);
        expect(messages.single, contains('interactive stdin and stdout'));
        expect(directory.listSync(), isEmpty);
      }
    },
  );

  test('only exact RESET confirms, cancellation leaves snapshot unchanged', () {
    final token = issueToken();
    final snapshot = primary.readAsStringSync();
    for (final answer in ['reset', 'RESET ', '', null]) {
      var storeAccesses = 0;
      expect(
        resetLocalSessions(
          inputHasTerminal: () => true,
          outputHasTerminal: () => true,
          readLine: () => answer,
          writeLine: (_) {},
          createStore: () {
            storeAccesses++;
            return store;
          },
        ),
        1,
      );
      expect(storeAccesses, 0);
      expect(primary.readAsStringSync(), snapshot);
      expect(marker.existsSync(), isFalse);
      expect(reconstruct().validateToken(token), isNotNull);
    }
  });

  test('confirmed offline reset warns before touching store and revokes on restart', () {
    final token = issueToken();
    store.close();
    final events = <String>[];
    final status = resetLocalSessions(
      inputHasTerminal: () => true,
      outputHasTerminal: () => true,
      readLine: () {
        events.add('confirm');
        return 'RESET';
      },
      writeLine: (message) {
        events.add(message);
      },
      createStore: () {
        events.add('store');
        return FileSessionStore(primary.path);
      },
    );
    expect(status, 0);
    expect(events.first, contains('daemon MUST be stopped'));
    expect(events.first, contains('every device must re-pair'));
    expect(events.indexOf('confirm'), lessThan(events.indexOf('store')));
    expect(jsonDecode(primary.readAsStringSync()), {
      'version': 1,
      'sessions': [],
    });
    store = FileSessionStore(primary.path);
    expect(reconstruct().validateToken(token), isNull);
    expect(marker.existsSync(), isFalse);
    expect(directory.listSync().map((entity) => entity.path).toSet(), {
      primary.path,
      '${primary.path}.lock',
    });
  });

  test('corrupt snapshot and malformed pending marker recover only after empty commit', () {
    primary.writeAsStringSync('{broken');
    marker.writeAsStringSync('bad marker');
    var checkedCommit = false;
    final recovery = FileSessionStore(
      primary.path,
      beforeReplace: () {
        expect(primary.readAsStringSync(), '{broken');
        expect(marker.readAsStringSync(), 'bad marker');
        checkedCommit = true;
      },
      beforePendingClear: () {
        expect(checkedCommit, isTrue);
        expect(marker.readAsStringSync(), 'bad marker');
        expect(jsonDecode(primary.readAsStringSync()), {
          'version': 1,
          'sessions': [],
        });
      },
    );
    recovery.resetSessions();
    recovery.close();
    expect(checkedCommit, isTrue);
    expect(marker.existsSync(), isFalse);
    expect(store.read(maxSessions: 100), isEmpty);
    expect(jsonDecode(primary.readAsStringSync()), {
      'version': 1,
      'sessions': [],
    });
  });

  test('failed replacement retains marker, old snapshot cannot restore', () {
    final token = issueToken();
    final snapshot = primary.readAsStringSync();
    store.close();
    final recovery = FileSessionStore(
      primary.path,
      beforeReplace: () {
        expect(marker.readAsStringSync(), 'pending\n');
        expect(primary.readAsStringSync(), snapshot);
        throw StateError('injected replacement failure');
      },
    );
    expect(recovery.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(primary.readAsStringSync(), snapshot);
    expect(marker.existsSync(), isTrue);
    recovery.close();
    store = FileSessionStore(primary.path);
    expect(reconstruct().validateToken(token), isNull);
    expect(directory.listSync().map((entity) => entity.path).toSet(), {
      primary.path,
      marker.path,
      '${primary.path}.lock',
    });
    store.resetSessions();
    expect(reconstruct().validateToken(token), isNull);
  });

  test('CLI releases ownership even if reset fails', () {
    final failing = FileSessionStore(
      primary.path,
      beforeReplace: () => throw StateError('injected failure'),
    );
    final messages = <String>[];
    expect(
      resetLocalSessions(
        inputHasTerminal: () => true,
        outputHasTerminal: () => true,
        readLine: () => 'RESET',
        writeLine: messages.add,
        createStore: () => failing,
      ),
      1,
    );
    expect(messages.last, contains('Session reset failed'));
    expect(
      () => failing.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    // The pending barrier still blocks restore, but ownership is transferable.
    expect(store.resetSessions, returnsNormally);
  });

  test('failed replacement retains even malformed pending marker', () {
    primary.writeAsStringSync('{broken');
    marker.writeAsStringSync('invalid');
    final recovery = FileSessionStore(
      primary.path,
      beforeReplace: () => throw StateError('failure'),
    );
    expect(recovery.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(primary.readAsStringSync(), '{broken');
    expect(marker.readAsStringSync(), 'invalid');
    recovery.close();
  });

  test('symlink primary, marker, parent and ancestor are refused', () {
    if (Platform.isWindows) return;
    final outside = File('${directory.path}/outside')
      ..writeAsStringSync('untouched');
    Link(primary.path).createSync(outside.path);
    expect(store.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(outside.readAsStringSync(), 'untouched');
    expect(marker.existsSync(), isFalse);
    Link(primary.path).deleteSync();

    Link(marker.path).createSync(outside.path);
    expect(store.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(outside.readAsStringSync(), 'untouched');
    Link(marker.path).deleteSync();

    final target = Directory('${directory.path}/target')..createSync();
    final linkedParent = Link('${directory.path}/linked')
      ..createSync(target.path);
    expect(
      FileSessionStore('${linkedParent.path}/sessions.json').resetSessions,
      throwsA(isA<SessionStoreException>()),
    );
    expect(target.listSync(), isEmpty);
    final nested = FileSessionStore('${linkedParent.path}/child/sessions.json');
    expect(nested.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(
      () => FileSessionStore('${linkedParent.path}/../target/sessions.json'),
      throwsA(isA<SessionStoreException>()),
    );
    expect(target.listSync(), isEmpty);
  });

  test(
    'actual CLI rejects redirected streams without touching user config',
    () async {
      final config = Directory('${directory.path}/isolated-config');
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/backend.dart', '--reset-sessions'],
        environment: {'XDG_CONFIG_HOME': config.path},
      );
      expect(result.exitCode, 2);
      expect(
        result.stdout.toString(),
        contains('interactive stdin and stdout'),
      );
      expect(config.existsSync(), isFalse);
    },
  );
}
