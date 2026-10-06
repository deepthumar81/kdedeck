import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/command_executor.dart';
import 'package:backend/dart_server_service.dart';
import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String storePath;
  final servers = <DartServerService>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('kdedeck-server-store-');
    storePath = '${temp.path}/sessions.json';
  });
  tearDown(() async {
    for (final server in servers) {
      await server.stopServer();
    }
    servers.clear();
    temp.deleteSync(recursive: true);
  });

  DartServerService newServer({
    String? path,
    int port = 0,
    Map<String, String> environment = const {},
    AuthSessionManager? manager,
    CommandExecutor? commandExecutor,
    Duration metricsInterval = const Duration(seconds: 4),
  }) {
    final server = DartServerService.forTesting(
      port: port,
      configPath: '${temp.path}/config.json',
      frontendRoot: temp.path,
      environment: environment,
      authSessionManager: manager,
      sessionStoreFactory: manager == null
          ? () => FileSessionStore(path ?? storePath)
          : null,
      commandExecutor: commandExecutor,
      metricsInterval: metricsInterval,
    );
    servers.add(server);
    return server;
  }

  test('store and injected manager cannot both own session state', () {
    expect(
      () => DartServerService.forTesting(
        authSessionManager: AuthSessionManager(issueCodeOnCreate: false),
        sessionStoreFactory: () => FileSessionStore(storePath),
      ),
      throwsArgumentError,
    );
  });

  test(
    'running server holds lock against second server and offline reset',
    () async {
      final first = newServer();
      await first.startServer();
      expect(first.isRunning, isTrue);
      final competing = FileSessionStore(storePath);
      expect(competing.resetSessions, throwsA(isA<SessionStoreException>()));
      competing.close();

      final second = newServer();
      await second.startServer();
      expect(second.isRunning, isFalse);
      expect(() => second.issueLocalPairingCode(), throwsStateError);

      await first.stopServer();
      await second.startServer();
      expect(second.isRunning, isTrue);
      await second.stopServer();
      final reset = FileSessionStore(storePath);
      reset.resetSessions();
      reset.close();
    },
  );

  test(
    'restart restores valid token without restoring pairing secret',
    () async {
      final server = newServer();
      await server.startServer();
      final code = server.issueLocalPairingCode().code;
      final client = await _connect(server);
      final messages = StreamIterator<Map<String, dynamic>>(
        client.map(
          (message) => jsonDecode(message as String) as Map<String, dynamic>,
        ),
      );
      expect(await _next(messages), {'type': 'auth_required'});
      client.add(jsonEncode({'type': 'authenticate', 'pairing_code': code}));
      final success = await _next(messages);
      expect(success['type'], 'auth_success');
      final token = success['token'] as String;
      expect((await _next(messages))['type'], 'init_state');
      final snapshot = File(storePath).readAsStringSync();
      expect(snapshot, isNot(contains(token)));
      expect(snapshot, isNot(contains(code)));
      expect(snapshot, contains(sessionTokenFingerprint(token)));
      await server.stopServer();
      await messages.cancel();

      await server.startServer();
      final reconnected = await _connect(server);
      final replies = StreamIterator<Map<String, dynamic>>(
        reconnected.map(
          (message) => jsonDecode(message as String) as Map<String, dynamic>,
        ),
      );
      expect(await _next(replies), {'type': 'auth_required'});
      reconnected.add(jsonEncode({'type': 'authenticate', 'token': token}));
      expect((await _next(replies))['type'], 'auth_success');
      expect((await _next(replies))['type'], 'init_state');
      await replies.cancel();
      await reconnected.close();
    },
  );

  test('revoked token is not restored by a new server', () async {
    final store = FileSessionStore(storePath);
    final manager = AuthSessionManager(
      pairingCode: 'local-only',
      sessionStore: store,
    );
    final token = manager.authenticate('local-only')!.token;
    expect(manager.revokeToken(token), isTrue);
    store.close();

    final server = newServer();
    await server.startServer();
    final client = await _connect(server);
    final replies = StreamIterator<Map<String, dynamic>>(
      client.map(
        (message) => jsonDecode(message as String) as Map<String, dynamic>,
      ),
    );
    expect(await _next(replies), {'type': 'auth_required'});
    client.add(jsonEncode({'type': 'authenticate', 'token': token}));
    expect(await _next(replies), {
      'type': 'auth_error',
      'code': 'invalid_credentials',
    });
    await replies.cancel();
    await client.close();
  });

  test('unconsumed pairing code is not persisted or restored', () async {
    final server = newServer();
    await server.startServer();
    final oldCode = server.issueLocalPairingCode().code;
    expect(File(storePath).existsSync(), isFalse);
    await server.stopServer();
    await server.startServer();
    final client = await _connect(server);
    final replies = StreamIterator<Map<String, dynamic>>(
      client.map(
        (message) => jsonDecode(message as String) as Map<String, dynamic>,
      ),
    );
    expect(await _next(replies), {'type': 'auth_required'});
    client.add(jsonEncode({'type': 'authenticate', 'pairing_code': oldCode}));
    expect(await _next(replies), {
      'type': 'auth_error',
      'code': 'invalid_credentials',
    });
    await replies.cancel();
    await client.close();
  });

  test(
    'corrupt and pending snapshots refuse startup without a listener',
    () async {
      final reservation = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final unavailablePort = reservation.port;
      await reservation.close(force: true);
      for (final content in ['not json', '{"version":1,"sessions":[]}']) {
        File(storePath).writeAsStringSync(content);
        final pending = File('$storePath.pending');
        if (content.startsWith('{')) pending.writeAsStringSync('pending\n');
        final server = newServer(port: unavailablePort);
        await server.startServer();
        expect(server.isRunning, isFalse);
        expect(() => server.issueLocalPairingCode(), throwsStateError);
        await expectLater(
          Socket.connect(InternetAddress.loopbackIPv4, unavailablePort),
          throwsA(isA<SocketException>()),
        );
        final successor = FileSessionStore(storePath);
        // Startup failure releases its lock even when the snapshot remains bad.
        expect(successor.resetSessions, returnsNormally);
        successor.close();
        if (pending.existsSync()) pending.deleteSync();
      }
    },
  );

  test('TLS and bind failures release lock and never listen', () async {
    final tls = newServer(
      environment: {
        'KDEDECK_TLS_CERT_FILE': '${temp.path}/missing-certificate',
        'KDEDECK_TLS_KEY_FILE': '${temp.path}/missing-key',
      },
    );
    await tls.startServer();
    expect(tls.isRunning, isFalse);
    final afterTls = FileSessionStore(storePath);
    expect(afterTls.read(maxSessions: 100), isEmpty);
    afterTls.close();

    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final bindFailure = newServer(port: occupied.port);
      await bindFailure.startServer();
      expect(bindFailure.isRunning, isFalse);
      final afterBind = FileSessionStore(storePath);
      expect(afterBind.read(maxSessions: 100), isEmpty);
      afterBind.close();
    } finally {
      await occupied.close(force: true);
    }
  });

  test(
    'injected in-memory manager retains ownership and one listener',
    () async {
      final manager = _CountingManager();
      final server = newServer(manager: manager);
      for (var i = 0; i < 2; i++) {
        await server.startServer();
        expect(manager.listeners, 1);
        await server.stopServer();
        expect(manager.listeners, 0);
      }
      expect(manager.additions, 2);
    },
  );

  test(
    'running stop/start without an intermediate await leaves one listener',
    () async {
      final manager = _CountingManager();
      final server = newServer(manager: manager);
      await _bounded(server.startServer());

      final stopping = server.stopServer();
      final starting = server.startServer();
      await _bounded(Future.wait([stopping, starting]));

      expect(server.isRunning, isTrue);
      expect(manager.listeners, 1);
      await _expectReachable(server);
    },
  );

  test(
    'start/stop/start before initial startup completes finishes running',
    () async {
      final manager = _CountingManager();
      final server = newServer(manager: manager);

      final initialStart = server.startServer();
      final queuedStop = server.stopServer();
      final queuedStart = server.startServer();
      await _bounded(Future.wait([initialStart, queuedStop, queuedStart]));

      expect(server.isRunning, isTrue);
      expect(manager.listeners, 1);
      await _expectReachable(server);
    },
  );

  test(
    'duplicate concurrent stops cannot close the store of a queued restart',
    () async {
      final server = newServer();
      await _bounded(server.startServer());

      final firstStop = server.stopServer();
      final secondStop = server.stopServer();
      final restart = server.startServer();
      await _bounded(Future.wait([firstStop, secondStop, restart]));

      expect(server.isRunning, isTrue);
      final competing = FileSessionStore(storePath);
      expect(competing.resetSessions, throwsA(isA<SessionStoreException>()));
      competing.close();
      await _expectReachable(server);
    },
  );

  test('duplicate concurrent stops leave one listener after restart', () async {
    final manager = _CountingManager();
    final server = newServer(manager: manager);
    await _bounded(server.startServer());

    final firstStop = server.stopServer();
    final secondStop = server.stopServer();
    final restart = server.startServer();
    await _bounded(Future.wait([firstStop, secondStop, restart]));

    expect(server.isRunning, isTrue);
    expect(manager.listeners, 1);
    expect(manager.additions, 2);
    await _expectReachable(server);
  });

  test('failed bind queues stop, releases the lock, and can restart', () async {
    final occupied = await _bounded(
      HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final server = newServer(port: occupied.port);
    try {
      final failedStart = server.startServer();
      final queuedStop = server.stopServer();
      await _bounded(Future.wait([failedStart, queuedStop]));
      expect(server.isRunning, isFalse);

      await _bounded(occupied.close(force: true));
      final recovered = FileSessionStore(storePath);
      expect(recovered.resetSessions, returnsNormally);
      recovered.close();

      await _bounded(server.startServer());
      expect(server.isRunning, isTrue);
      await _expectReachable(server);
    } finally {
      await occupied.close(force: true);
    }
  });

  test('metrics probes are fenced and never overlap across restart', () async {
    if (!Platform.isLinux) return;

    final executor = _BlockingMetricsExecutor();
    final server = newServer(
      commandExecutor: executor,
      metricsInterval: const Duration(milliseconds: 1),
    );
    WebSocket? client;
    WebSocket? restartedClient;
    try {
      await _bounded(server.startServer());
      client = await _bounded(_connect(server));
      await _bounded(executor.firstPactlStarted.future);

      // Timer.periodic does not await an async callback. Repeated ticks while
      // pactl is blocked must still leave only one external probe in flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(executor.callCount, 1);
      expect(executor.maxConcurrent, 1);

      final initialVolume = server.currentVolume;
      final initialMute = server.isMuted;
      final initialBrightness = server.currentBrightness;

      await _bounded(server.stopServer());
      await _bounded(server.startServer());
      final connectedClient = await _bounded(_connect(server));
      restartedClient = connectedClient;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(executor.callCount, 1);
      expect(executor.maxConcurrent, 1);

      // The old generation returns a value that would be observable if its
      // continuation were allowed to mutate state after restart.
      await connectedClient.close();
      restartedClient = null;
      executor.releaseFirst(ProcessResult(0, 0, '10%\n', ''));
      await _bounded(executor.firstPactlCompleted.future);
      await Future<void>.delayed(Duration.zero);
      expect(server.currentVolume, initialVolume);
      expect(server.isMuted, initialMute);
      expect(server.currentBrightness, initialBrightness);
    } finally {
      executor.releaseFirst(ProcessResult(0, 0, '10%\n', ''));
      await client?.close();
      await restartedClient?.close();
      await server.stopServer();
    }
  });
}

Future<T> _bounded<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 3));

Future<void> _expectReachable(DartServerService server) async {
  final client = await _bounded(_connect(server));
  final messages = StreamIterator<Map<String, dynamic>>(
    client.map(
      (message) => jsonDecode(message as String) as Map<String, dynamic>,
    ),
  );
  try {
    expect(await _next(messages), {'type': 'auth_required'});
  } finally {
    await _bounded(messages.cancel());
    await _bounded(client.close());
  }
}

Future<WebSocket> _connect(DartServerService server) =>
    WebSocket.connect('ws://127.0.0.1:${server.port}/ws');

Future<Map<String, dynamic>> _next(
  StreamIterator<Map<String, dynamic>> iterator,
) async {
  expect(await iterator.moveNext().timeout(const Duration(seconds: 3)), isTrue);
  return iterator.current;
}

class _CountingManager extends AuthSessionManager {
  _CountingManager() : super(issueCodeOnCreate: false);

  int listeners = 0;
  int additions = 0;

  @override
  void addRevocationListener(void Function() listener) {
    super.addRevocationListener(listener);
    additions++;
    listeners++;
  }

  @override
  void removeRevocationListener(void Function() listener) {
    super.removeRevocationListener(listener);
    if (listeners > 0) listeners--;
  }
}

final class _BlockingMetricsExecutor implements CommandExecutor {
  final Completer<void> firstPactlStarted = Completer<void>();
  final Completer<void> firstPactlCompleted = Completer<void>();
  final Completer<ProcessResult> _firstPactlResult = Completer<ProcessResult>();

  int callCount = 0;
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    if (executable != 'pactl') {
      return Future<ProcessResult>.value(ProcessResult(0, 0, '', ''));
    }

    callCount++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    final result = callCount == 1
        ? _firstPactlResult.future
        : Future<ProcessResult>.value(ProcessResult(0, 0, '50%\n', ''));
    if (callCount == 1) firstPactlStarted.complete();
    return result.whenComplete(() {
      concurrent--;
      if (callCount == 1 && !firstPactlCompleted.isCompleted) {
        firstPactlCompleted.complete();
      }
    });
  }

  void releaseFirst(ProcessResult result) {
    if (!_firstPactlResult.isCompleted) _firstPactlResult.complete(result);
  }
}
