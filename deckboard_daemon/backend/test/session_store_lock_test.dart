import 'dart:convert';
import 'dart:io';

import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File primary;
  late FileSessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kdedeck-lock-test-');
    primary = File('${directory.path}/sessions.json');
    store = FileSessionStore(primary.path);
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  Future<String> probe(String operation) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/support/session_store_lock_probe.dart',
      primary.path,
      operation,
    ]).timeout(const Duration(seconds: 20));
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result.stdout.toString().trim();
  }

  test('same-process duplicate denied; close is idempotent and terminal', () {
    store.read(maxSessions: 100);
    final competing = FileSessionStore(primary.path);
    expect(
      () => competing.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    expect(competing.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(primary.existsSync(), isFalse);
    competing.close();
    store.close();
    store.close();
    expect(
      () => store.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    final successor = FileSessionStore(primary.path);
    expect(successor.read(maxSessions: 100), isEmpty);
    successor.close();
  });

  test(
    'other process cannot read, write or reset; succeeds after release',
    () async {
      store.write(const [], maxSessions: 100);
      final snapshot = primary.readAsStringSync();
      for (final operation in ['read', 'write', 'reset']) {
        expect(await probe(operation), 'busy');
        expect(primary.readAsStringSync(), snapshot);
        expect(File('${primary.path}.pending').existsSync(), isFalse);
      }
      store.close();
      expect(await probe('read'), 'ok');
      expect(await probe('write'), 'ok');
      expect(await probe('reset'), 'ok');
      expect(File('${primary.path}.lock').existsSync(), isTrue);
    },
  );

  test('lock held by child is released when child exits', () async {
    // Establish the snapshot without keeping ownership in the parent.
    store.write(const [], maxSessions: 100);
    store.close();
    final child = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/support/session_store_lock_probe.dart',
      primary.path,
      'hold',
    ]);
    try {
      expect(
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 20)),
        'ready',
      );
      store = FileSessionStore(primary.path);
      expect(
        () => store.read(maxSessions: 100),
        throwsA(isA<SessionStoreException>()),
      );
      expect(store.resetSessions, throwsA(isA<SessionStoreException>()));
      child.stdin.writeln('exit');
      await child.stdin.flush();
      expect(await child.exitCode.timeout(const Duration(seconds: 20)), 0);
      expect(store.read(maxSessions: 100), isEmpty);
    } finally {
      child.kill();
    }
  });

  test('unsafe lock symlink is rejected before opening or changing target', () {
    if (Platform.isWindows) return;
    final target = File('${directory.path}/outside')..writeAsStringSync('safe');
    Link('${primary.path}.lock').createSync(target.path);
    expect(
      () => store.read(maxSessions: 100),
      throwsA(isA<SessionStoreException>()),
    );
    expect(store.resetSessions, throwsA(isA<SessionStoreException>()));
    expect(target.readAsStringSync(), 'safe');
    expect(primary.existsSync(), isFalse);
  });

  test(
    'nonregular lock and symlink parent refuse without snapshot mutation',
    () {
      if (Platform.isWindows) return;
      final lockDirectory = Directory('${primary.path}.lock')..createSync();
      expect(
        () => store.write(const [], maxSessions: 100),
        throwsA(isA<SessionStoreException>()),
      );
      expect(primary.existsSync(), isFalse);
      lockDirectory.deleteSync();

      final target = Directory('${directory.path}/target')..createSync();
      final linked = Link('${directory.path}/linked')..createSync(target.path);
      final unsafe = FileSessionStore('${linked.path}/sessions.json');
      expect(
        () => unsafe.read(maxSessions: 100),
        throwsA(isA<SessionStoreException>()),
      );
      expect(target.listSync(), isEmpty);
      unsafe.close();
    },
  );
}
