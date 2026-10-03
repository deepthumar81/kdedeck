import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_rate_limiter.dart';
import 'package:backend/auth_session_manager.dart';
import 'package:backend/command_executor.dart';
import 'package:backend/dart_server_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  late _RecordingExecutor executor;
  DartServerService? server;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('kdedeck-auth-test');
    executor = _RecordingExecutor();
  });

  tearDown(() async {
    await server?.stopServer();
    await tempDirectory.delete(recursive: true);
  });

  test('sends only a challenge and rejects unauthenticated requests', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(manager, executor, tempDirectory);
    final client = await _connect(server!);
    final messages = _MessageReader(client);

    expect(await messages.next(), {'type': 'auth_required'});

    client.add(jsonEncode({'type': 'trigger_action', 'action': 'kde_action'}));
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'authentication_required',
    });
    client.add(
      jsonEncode({
        'type': 'save_config',
        'config': {'boards': []},
      }),
    );
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'authentication_required',
    });
    client.add(jsonEncode({'type': 'get_system_apps'}));
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'authentication_required',
    });

    expect(executor.invocations, isEmpty);
    await messages.close();
    await client.close();
  });

  test(
    'pairs once, ignores a supplied role, and sends init state after success',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(manager, executor, tempDirectory);
      final client = await _connect(server!);
      final messages = _MessageReader(client);
      await messages.next();

      client.add(
        jsonEncode({
          'type': 'authenticate',
          'pairing_code': 'pairing-code',
          'role': 'viewer',
        }),
      );
      final success = await messages.next();
      expect(success['type'], 'auth_success');
      expect(success['role'], 'configAdmin');
      expect(success['token'], isA<String>());
      expect(success, isNot(contains('pairing-code')));

      final init = await messages.next();
      expect(init['type'], 'init_state');
      expect(init['config'], isA<Map>());
      expect(init['state'], isA<Map>());

      client.add(
        jsonEncode({
          'type': 'save_config',
          'config': {'boards': []},
        }),
      );
      expect((await messages.next())['type'], 'config_updated');

      // Discovery remains the existing app/icon implementation, but is now
      // authorized by configAdmin rather than being callable anonymously.
      client.add(jsonEncode({'type': 'get_system_apps'}));
      expect((await messages.next())['type'], 'system_apps_list');
      expect(manager.authenticate('pairing-code'), isNull);

      await messages.close();
      await client.close();
    },
  );

  test(
    'reconnects with the bearer token after the original socket closes',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(manager, executor, tempDirectory);
      final first = await _connect(server!);
      final firstMessages = _MessageReader(first);
      await firstMessages.next();
      first.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
      );
      final token = (await firstMessages.next())['token'] as String;
      await firstMessages.next();
      await firstMessages.close();
      await first.close();

      final second = await _connect(server!);
      final secondMessages = _MessageReader(second);
      expect(await secondMessages.next(), {'type': 'auth_required'});
      second.add(jsonEncode({'type': 'authenticate', 'token': token}));
      final success = await secondMessages.next();
      expect(success['type'], 'auth_success');
      expect(success['token'], token);
      expect((await secondMessages.next())['type'], 'init_state');

      await secondMessages.close();
      await second.close();
    },
  );

  test(
    'reports session capacity, retains pairing, and pairs after revocation',
    () async {
      final manager = AuthSessionManager(
        pairingCode: 'first-code',
        maxActiveSessions: 1,
      );
      server = _newServer(manager, executor, tempDirectory);

      final first = await _connect(server!);
      final firstMessages = _MessageReader(first);
      await firstMessages.next();
      first.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'first-code'}),
      );
      final firstSuccess = await firstMessages.next();
      final firstToken = firstSuccess['token'] as String;
      expect(firstSuccess['type'], 'auth_success');
      await firstMessages.next();

      manager.issuePairingCode(code: 'second-code');
      final second = await _connect(server!);
      final secondMessages = _MessageReader(second);
      await secondMessages.next();

      second.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'wrong-code'}),
      );
      expect(await secondMessages.next(), {
        'type': 'auth_error',
        'code': 'invalid_credentials',
      });

      second.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'second-code'}),
      );
      final capacity = await secondMessages.next();
      expect(capacity, {'type': 'auth_error', 'code': 'session_capacity'});
      expect(manager.pairingCode, 'second-code');
      expect(jsonEncode(capacity), isNot(contains('second-code')));

      expect(manager.validateToken(firstToken), isNotNull);
      expect(manager.revokeToken(firstToken), isTrue);
      expect(manager.validateToken(firstToken), isNull);
      await firstMessages.expectClosed();

      // The same pairing code succeeds after the manager seam frees capacity.
      second.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'second-code'}),
      );
      final secondSuccess = await secondMessages.next();
      expect(secondSuccess['type'], 'auth_success');
      expect(secondSuccess['token'], isA<String>());
      expect((await secondMessages.next())['type'], 'init_state');

      await firstMessages.close();
      await first.close();
      await secondMessages.close();
      await second.close();
    },
  );

  test(
    'single revocation closes all sockets for a token, not survivors',
    () async {
      final manager = AuthSessionManager(pairingCode: 'old');
      final old = manager.authenticate('old')!;
      manager.issuePairingCode(code: 'survivor');
      final survivor = manager.authenticate('survivor')!;
      server = _newServer(manager, executor, tempDirectory);
      final first = await _authenticatedSocket(server!, old.token);
      final second = await _authenticatedSocket(server!, old.token);
      final kept = await _authenticatedSocket(server!, survivor.token);

      expect(manager.revokeToken(old.token), isTrue);
      await first.messages.expectClosed();
      await second.messages.expectClosed();
      expect(manager.revokeToken(old.token), isFalse);
      kept.socket.add(
        jsonEncode({'type': 'authenticate', 'token': survivor.token}),
      );
      expect((await kept.messages.next())['type'], 'auth_success');
      expect((await kept.messages.next())['type'], 'init_state');

      final reconnected = await _authenticatedSocket(server!, survivor.token);
      await reconnected.messages.close();
      await reconnected.socket.close();
      await first.messages.close();
      await second.messages.close();
      await kept.messages.close();
      await kept.socket.close();
    },
  );

  test('role revocation closes only matching sockets', () async {
    final manager = AuthSessionManager(pairingCode: 'viewer');
    final viewer = manager.authenticate('viewer', role: AuthRole.viewer)!;
    manager.issuePairingCode(code: 'control');
    final control = manager.authenticate('control', role: AuthRole.control)!;
    manager.issuePairingCode(code: 'admin');
    final admin = manager.authenticate('admin', role: AuthRole.configAdmin)!;
    server = _newServer(manager, executor, tempDirectory);
    final viewerClient = await _authenticatedSocket(server!, viewer.token);
    final controlClient = await _authenticatedSocket(server!, control.token);
    final adminClient = await _authenticatedSocket(server!, admin.token);

    expect(manager.revokeSessionsByRole(AuthRole.control), 1);
    await controlClient.messages.expectClosed();
    for (final client in [viewerClient, adminClient]) {
      final token = client == viewerClient ? viewer.token : admin.token;
      client.socket.add(jsonEncode({'type': 'authenticate', 'token': token}));
      expect((await client.messages.next())['type'], 'auth_success');
      expect((await client.messages.next())['type'], 'init_state');
    }
    final reconnected = await _authenticatedSocket(server!, admin.token);
    await reconnected.messages.close();
    await reconnected.socket.close();
    await controlClient.messages.close();
    await viewerClient.messages.close();
    await adminClient.messages.close();
    await viewerClient.socket.close();
    await adminClient.socket.close();
  });

  test(
    'revoke all closes active sockets and permits newly paired reconnect',
    () async {
      final manager = AuthSessionManager(pairingCode: 'first');
      final first = manager.authenticate('first')!;
      manager.issuePairingCode(code: 'second');
      final second = manager.authenticate('second')!;
      server = _newServer(manager, executor, tempDirectory);
      final firstClient = await _authenticatedSocket(server!, first.token);
      final secondClient = await _authenticatedSocket(server!, second.token);

      expect(manager.revokeAllSessions(), 2);
      await firstClient.messages.expectClosed();
      await secondClient.messages.expectClosed();
      expect(manager.revokeAllSessions(), 0);

      manager.issuePairingCode(code: 'new');
      final fresh = manager.authenticate('new')!;
      final reconnected = await _authenticatedSocket(server!, fresh.token);
      await reconnected.messages.close();
      await reconnected.socket.close();
      await firstClient.messages.close();
      await secondClient.messages.close();
    },
  );

  test('revocation notifications work after a server restart', () async {
    final manager = AuthSessionManager(pairingCode: 'first');
    server = _newServer(manager, executor, tempDirectory);
    final first = manager.authenticate('first')!;
    final initial = await _authenticatedSocket(server!, first.token);
    await server!.stopServer();
    await initial.messages.close();
    manager.revokeToken(first.token);

    // A restarted server subscribes anew without relying on a metrics tick.
    manager.issuePairingCode(code: 'second');
    final second = manager.authenticate('second')!;
    await server!.startServer();
    final restarted = await _authenticatedSocket(server!, second.token);
    expect(manager.revokeToken(second.token), isTrue);
    await restarted.messages.expectClosed();
    await restarted.messages.close();
  });

  test(
    'rate limits failed authentication without bypassing auth or actions',
    () async {
      final clock = _FakeClock(DateTime.utc(2026, 1, 1));
      final manager = AuthSessionManager(
        pairingCode: 'pairing-code',
        clock: clock.now,
      );
      final limiter = AuthRateLimiter(
        maxFailures: 2,
        lockoutDuration: const Duration(seconds: 10),
        clock: clock.now,
      );
      server = _newServer(
        manager,
        executor,
        tempDirectory,
        authRateLimiter: limiter,
        clientIdentityResolver: (_) => 'deterministic-client',
      );
      final client = await _connect(server!);
      final messages = _MessageReader(client);
      expect(await messages.next(), {'type': 'auth_required'});

      client.add(jsonEncode({'type': 'authenticate', 'token': 'wrong-1'}));
      expect(await messages.next(), {
        'type': 'auth_error',
        'code': 'invalid_credentials',
      });
      client.add(jsonEncode({'type': 'authenticate', 'token': 'wrong-2'}));
      expect(await messages.next(), {
        'type': 'auth_error',
        'code': 'invalid_credentials',
      });

      client.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
      );
      final limited = await messages.next();
      expect(limited, {'type': 'auth_error', 'code': 'rate_limited'});
      expect(jsonEncode(limited), isNot(contains('pairing-code')));

      // A valid credential cannot bypass a lockout, and no init state is sent.
      clock.advance(const Duration(seconds: 10));
      client.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
      );
      final success = await messages.next();
      expect(success['type'], 'auth_success');
      expect((await messages.next())['type'], 'init_state');

      // Subsequent invalid auth frames do not de-authenticate this socket or
      // rate-limit its already authenticated action path.
      client.add(jsonEncode({'type': 'authenticate', 'token': 'wrong-3'}));
      expect((await messages.next())['code'], 'invalid_credentials');
      client.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'launch_app',
          'payload': '/usr/bin/example',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(executor.invocations, hasLength(1));

      await messages.close();
      await client.close();
    },
  );

  for (final revoked in [true, false]) {
    test(
      'broadcast excludes ${revoked ? "revoked" : "expired"} session',
      () async {
        final clock = _FakeClock(DateTime.utc(2026, 1, 1));
        final manager = AuthSessionManager(
          pairingCode: 'first',
          clock: clock.now,
        );
        final old = manager.authenticate('first', role: AuthRole.configAdmin)!;
        server = _newServer(manager, executor, tempDirectory);
        final oldSocket = await _connect(server!);
        final oldMessages = _MessageReader(oldSocket);
        await oldMessages.next();
        oldSocket.add(jsonEncode({'type': 'authenticate', 'token': old.token}));
        await oldMessages.next();
        await oldMessages.next();
        if (revoked) {
          manager.revokeToken(old.token);
        } else {
          clock.advance(const Duration(hours: 1));
        }
        manager.issuePairingCode(code: 'new');
        final fresh = manager.authenticate('new', role: AuthRole.configAdmin)!;
        final socket = await _connect(server!);
        final messages = _MessageReader(socket);
        await messages.next();
        socket.add(jsonEncode({'type': 'authenticate', 'token': fresh.token}));
        await messages.next();
        await messages.next();
        socket.add(
          jsonEncode({
            'type': 'save_config',
            'config': {'boards': []},
          }),
        );
        expect((await messages.next())['type'], 'config_updated');
        if (revoked) {
          await oldMessages.expectClosed();
        } else {
          // Expiry remains request-driven; no revocation notification fires.
          oldSocket.add(jsonEncode({'type': 'get_system_apps'}));
          expect(await oldMessages.next().timeout(const Duration(seconds: 5)), {
            'type': 'auth_error',
            'code': 'authentication_required',
          });
        }
        expect(executor.invocations, isEmpty);
        await oldMessages.close();
        await messages.close();
        await oldSocket.close();
        await socket.close();
      },
    );
  }

  for (final revoked in [true, false]) {
    test(
      'delayed discovery rejects ${revoked ? "revoked" : "expired"} session',
      () async {
        final clock = _FakeClock(DateTime.utc(2026, 1, 1));
        final manager = AuthSessionManager(
          pairingCode: 'admin',
          clock: clock.now,
        );
        final session = manager.authenticate(
          'admin',
          role: AuthRole.configAdmin,
        )!;
        executor.discoveryStarted = Completer<void>();
        executor.discoveryRelease = Completer<void>();
        server = _newServer(manager, executor, tempDirectory);
        final socket = await _connect(server!);
        final messages = _MessageReader(socket);
        try {
          await messages.next();
          socket.add(
            jsonEncode({'type': 'authenticate', 'token': session.token}),
          );
          await messages.next();
          await messages.next();
          socket.add(jsonEncode({'type': 'get_system_apps'}));
          await executor.discoveryStarted!.future.timeout(
            const Duration(seconds: 10),
          );
          if (revoked) {
            manager.revokeToken(session.token);
            await messages.expectClosed();
          } else {
            clock.advance(const Duration(hours: 1));
          }
          executor.discoveryRelease!.complete();
          if (!revoked) {
            expect(await messages.next().timeout(const Duration(seconds: 15)), {
              'type': 'auth_error',
              'code': 'authentication_required',
            });
          }
        } finally {
          if (!executor.discoveryRelease!.isCompleted)
            executor.discoveryRelease!.complete();
          await messages.close();
          await socket.close();
        }
      },
      skip: !Platform.isLinux ? 'Linux discovery adapter test' : false,
    );
  }

  test('enforces control and configAdmin capabilities independently', () async {
    final manager = AuthSessionManager(pairingCode: 'viewer-code');
    final viewer = manager.authenticate('viewer-code', role: AuthRole.viewer)!;
    manager.issuePairingCode(code: 'control-code');
    final control = manager.authenticate(
      'control-code',
      role: AuthRole.control,
    )!;
    server = _newServer(manager, executor, tempDirectory);

    final viewerSocket = await _connect(server!);
    final viewerMessages = _MessageReader(viewerSocket);
    await viewerMessages.next();
    viewerSocket.add(
      jsonEncode({'type': 'authenticate', 'token': viewer.token}),
    );
    expect((await viewerMessages.next())['role'], 'viewer');
    await viewerMessages.next();

    viewerSocket.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'launch_app',
        'payload': 'example',
      }),
    );
    expect((await viewerMessages.next())['code'], 'insufficient_permissions');
    viewerSocket.add(
      jsonEncode({
        'type': 'save_config',
        'config': {'boards': []},
      }),
    );
    expect((await viewerMessages.next())['code'], 'insufficient_permissions');
    viewerSocket.add(jsonEncode({'type': 'get_system_apps'}));
    expect((await viewerMessages.next())['code'], 'insufficient_permissions');

    final controlSocket = await _connect(server!);
    final controlMessages = _MessageReader(controlSocket);
    await controlMessages.next();
    controlSocket.add(
      jsonEncode({'type': 'authenticate', 'token': control.token}),
    );
    expect((await controlMessages.next())['role'], 'control');
    await controlMessages.next();
    controlSocket.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'launch_app',
        'payload': '/usr/bin/example',
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, hasLength(1));

    controlSocket.add(
      jsonEncode({
        'type': 'save_config',
        'config': {'boards': []},
      }),
    );
    expect((await controlMessages.next())['code'], 'insufficient_permissions');
    controlSocket.add(jsonEncode({'type': 'get_system_apps'}));
    expect((await controlMessages.next())['code'], 'insufficient_permissions');
    await controlMessages.close();
    await controlSocket.close();
    await viewerMessages.close();
    await viewerSocket.close();
  });
}

final class _RecordingExecutor implements CommandExecutor {
  final List<String> invocations = [];
  Completer<void>? discoveryStarted;
  Completer<void>? discoveryRelease;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add('$executable ${arguments.join(' ')}');
    if (executable == 'snap' && discoveryStarted != null) {
      if (!discoveryStarted!.isCompleted) discoveryStarted!.complete();
      await discoveryRelease!.future;
    }
    return ProcessResult(0, 0, '', '');
  }
}

DartServerService _newServer(
  AuthSessionManager manager,
  CommandExecutor executor,
  Directory tempDirectory, {
  AuthRateLimiter? authRateLimiter,
  String Function(HttpRequest request)? clientIdentityResolver,
}) => DartServerService.forTesting(
  port: 0,
  authSessionManager: manager,
  authRateLimiter: authRateLimiter,
  clientIdentityResolver: clientIdentityResolver,
  commandExecutor: executor,
  configPath: '${tempDirectory.path}/deckboard_config.json',
);

Future<WebSocket> _connect(DartServerService server) async {
  if (!server.isRunning) await server.startServer();
  return WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
}

Future<({WebSocket socket, _MessageReader messages})> _authenticatedSocket(
  DartServerService server,
  String token,
) async {
  final socket = await _connect(server);
  final messages = _MessageReader(socket);
  expect(await messages.next(), {'type': 'auth_required'});
  socket.add(jsonEncode({'type': 'authenticate', 'token': token}));
  expect((await messages.next())['type'], 'auth_success');
  expect((await messages.next())['type'], 'init_state');
  return (socket: socket, messages: messages);
}

final class _MessageReader {
  _MessageReader(this.socket) : _iterator = StreamIterator<dynamic>(socket);

  final WebSocket socket;
  final StreamIterator<dynamic> _iterator;

  Future<Map<String, dynamic>> next() async {
    expect(await _iterator.moveNext(), isTrue);
    return Map<String, dynamic>.from(jsonDecode(_iterator.current as String));
  }

  Future<void> expectClosed() async {
    expect(
      await _iterator.moveNext().timeout(const Duration(seconds: 5)),
      isFalse,
    );
    expect(socket.closeCode, WebSocketStatus.policyViolation);
    expect(socket.closeReason, 'Session invalid');
  }

  Future<void> close() => _iterator.cancel();
}

final class _FakeClock {
  _FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}
