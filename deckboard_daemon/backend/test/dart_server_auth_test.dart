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

  test(
    'accepts WebSocket upgrades without Origin for native clients',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(manager, executor, tempDirectory);
      final client = await _connect(server!);
      final messages = _MessageReader(client);

      expect(await messages.next(), {'type': 'auth_required'});

      client.add(
        jsonEncode({'type': 'trigger_action', 'action': 'kde_action'}),
      );
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
    },
  );

  test(
    'accepts a same-origin WebSocket Origin before authentication',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(manager, executor, tempDirectory);
      await server!.startServer();
      final client = await _connect(
        server!,
        origin: 'http://127.0.0.1:${server!.port}',
      );
      final messages = _MessageReader(client);

      expect(await messages.next(), {'type': 'auth_required'});
      expect(manager.activeSessionCount, 0);

      await messages.close();
      await client.close();
    },
  );

  test(
    'rejects a cross-origin WebSocket before upgrade or auth state',
    () async {
      var identityLookups = 0;
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(
        manager,
        executor,
        tempDirectory,
        maxConnections: 1,
        clientIdentityResolver: (_) {
          identityLookups++;
          return 'test-client';
        },
      );

      final response = await _upgradeRequest(
        server!,
        origin: 'http://evil.example',
      );
      expect(response.statusCode, HttpStatus.forbidden);
      expect(response.body, 'Forbidden');
      expect(identityLookups, 0);
      expect(manager.activeSessionCount, 0);

      await server!.startServer();
      final survivor = await _connect(
        server!,
        origin: 'http://127.0.0.1:${server!.port}',
      );
      final messages = _MessageReader(survivor);
      expect(await messages.next(), {'type': 'auth_required'});
      await messages.close();
      await survivor.close();
    },
  );

  test('rejects a malformed WebSocket Origin before upgrade', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(manager, executor, tempDirectory);

    final response = await _upgradeRequest(server!, origin: 'not an origin');
    expect(response.statusCode, HttpStatus.forbidden);
    expect(response.body, 'Forbidden');
    expect(manager.activeSessionCount, 0);
  });

  test('caps sockets before auth while the survivor remains usable', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(manager, executor, tempDirectory, maxConnections: 1);
    final survivor = await _connect(server!);
    final survivorMessages = _MessageReader(survivor);
    expect(await survivorMessages.next(), {'type': 'auth_required'});

    final rejected = await _connect(server!);
    final rejectedMessages = _MessageReader(rejected);
    await rejectedMessages.expectClosedWith('Connection capacity reached');

    survivor.add(
      jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
    );
    expect((await survivorMessages.next())['type'], 'auth_success');
    await survivorMessages.next();
    survivor.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'launch_app',
        'payload': 'example',
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, hasLength(1));

    await rejectedMessages.close();
    await rejected.close();
    await survivorMessages.close();
    await survivor.close();

    final reconnected = await _connect(server!);
    final reconnectedMessages = _MessageReader(reconnected);
    expect(await reconnectedMessages.next(), {'type': 'auth_required'});
    await reconnectedMessages.close();
    await reconnected.close();
  });

  test('rejects message bursts for authenticated clients', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxMessagesPerWindow: 2,
      maxActionRequestsPerWindow: 10,
      rateLimitWindow: const Duration(seconds: 10),
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();
    client.add(
      jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
    );
    expect((await messages.next())['type'], 'auth_success');
    await messages.next();

    client.add(jsonEncode({'type': 'noop'}));
    client.add(jsonEncode({'type': 'get_system_apps'}));
    expect((await messages.next())['code'], 'rate_limited');
    expect(executor.invocations, isEmpty);

    await messages.close();
    await client.close();
  }, skip: !Platform.isLinux ? 'Linux discovery adapter test' : false);

  test('accepts a text frame exactly at the UTF-8 byte limit', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    final frame = jsonEncode({
      'type': 'authenticate',
      'pairing_code': 'pairing-code',
      'padding': 'é' * 24,
    });
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxFrameBytes: utf8.encode(frame).length,
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();

    client.add(frame);
    expect((await messages.next())['type'], 'auth_success');
    expect((await messages.next())['type'], 'init_state');

    await messages.close();
    await client.close();
  });

  test('rejects an oversized unauthenticated action before dispatch', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(manager, executor, tempDirectory, maxFrameBytes: 64);
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();

    client.add(
      _oversizedJsonFrame({
        'type': 'trigger_action',
        'action': 'launch_app',
        'payload': 'example',
      }, 64),
    );
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'message_too_large',
    });
    expect(executor.invocations, isEmpty);

    await messages.close();
    await client.close();
  });

  test(
    'rejects an oversized authenticated config before persistence',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(manager, executor, tempDirectory, maxFrameBytes: 128);
      final client = await _connect(server!);
      final messages = _MessageReader(client);
      await messages.next();
      client.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
      );
      await messages.next();
      await messages.next();

      client.add(
        _oversizedJsonFrame({
          'type': 'save_config',
          'config': {'boards': [], 'name': 'oversized'},
        }, 128),
      );
      expect(await messages.next(), {
        'type': 'auth_error',
        'code': 'message_too_large',
      });
      expect(
        await File('${tempDirectory.path}/deckboard_config.json').exists(),
        isFalse,
      );
      expect(executor.invocations, isEmpty);

      await messages.close();
      await client.close();
    },
  );

  test('rejects binary frames with a bounded protocol error', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(manager, executor, tempDirectory, maxFrameBytes: 64);
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();

    client.add(List<int>.filled(4, 0xff));
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'message_too_large',
    });
    expect(executor.invocations, isEmpty);

    await messages.close();
    await client.close();
  });

  test('closes after repeated oversized-frame violations', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxFrameBytes: 64,
      maxOversizedFrameViolations: 2,
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();
    final oversized = _oversizedJsonFrame({'type': 'noop'}, 64);

    client.add(oversized);
    client.add(oversized);
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'message_too_large',
    });
    expect(await messages.next(), {
      'type': 'auth_error',
      'code': 'message_too_large',
    });
    await messages.expectClosedWith('Message too large');

    await messages.close();
    await client.close();
  });

  test(
    'an oversized client cannot disrupt a surviving authenticated socket',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      final session = manager.authenticate(
        'pairing-code',
        role: AuthRole.control,
      )!;
      server = _newServer(
        manager,
        executor,
        tempDirectory,
        maxFrameBytes: 256,
        maxOversizedFrameViolations: 2,
      );
      final survivor = await _authenticatedSocket(server!, session.token);
      final violator = await _connect(server!);
      final violatorMessages = _MessageReader(violator);
      await violatorMessages.next();
      final oversized = _oversizedJsonFrame({'type': 'noop'}, 256);
      violator.add(oversized);
      violator.add(oversized);
      await violatorMessages.next();
      await violatorMessages.next();
      await violatorMessages.expectClosedWith('Message too large');

      survivor.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'launch_app',
          'payload': 'example',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(executor.invocations, hasLength(1));

      await violatorMessages.close();
      await violator.close();
      await survivor.messages.close();
      await survivor.socket.close();
    },
  );

  test('rejects action bursts without invoking the executor', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxMessagesPerWindow: 10,
      maxActionRequestsPerWindow: 1,
      rateLimitWindow: const Duration(seconds: 10),
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();
    client.add(
      jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
    );
    await messages.next();
    await messages.next();

    final action = jsonEncode({
      'type': 'trigger_action',
      'action': 'launch_app',
      'payload': 'example',
    });
    client.add(action);
    client.add(action);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, hasLength(1));
    expect((await messages.next())['code'], 'rate_limited');

    await messages.close();
    await client.close();
  });

  test('resets message and action windows using the injected clock', () async {
    final clock = _FakeClock(DateTime.utc(2026, 1, 1));
    final manager = AuthSessionManager(
      pairingCode: 'pairing-code',
      clock: clock.now,
    );
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxMessagesPerWindow: 2,
      maxActionRequestsPerWindow: 1,
      rateLimitWindow: const Duration(seconds: 10),
      clock: clock.now,
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();
    client.add(
      jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
    );
    await messages.next();
    await messages.next();

    final action = jsonEncode({
      'type': 'trigger_action',
      'action': 'launch_app',
      'payload': 'example',
    });
    client.add(action);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, hasLength(1));
    expect(await messages.next(), {
      'type': 'action_result',
      'action': 'launch_app',
      'success': true,
    });

    client.add(action);
    expect((await messages.next())['code'], 'rate_limited');
    clock.advance(const Duration(seconds: 10));
    client.add(action);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, hasLength(2));

    await messages.close();
    await client.close();
  });

  test(
    'closes after repeated rate-limit violations with a bounded reason',
    () async {
      final manager = AuthSessionManager(pairingCode: 'pairing-code');
      server = _newServer(
        manager,
        executor,
        tempDirectory,
        maxMessagesPerWindow: 1,
        maxRateLimitViolations: 2,
        rateLimitWindow: const Duration(seconds: 10),
      );
      final client = await _connect(server!);
      final messages = _MessageReader(client);
      await messages.next();
      client.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
      );
      await messages.next();
      await messages.next();

      client.add(jsonEncode({'type': 'noop'}));
      client.add(jsonEncode({'type': 'noop'}));
      expect((await messages.next())['code'], 'rate_limited');
      expect((await messages.next())['code'], 'rate_limited');
      await messages.expectClosedWith('Rate limit exceeded');

      await messages.close();
      await client.close();
    },
  );

  test('unauthenticated action bursts cannot bypass either limiter', () async {
    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    server = _newServer(
      manager,
      executor,
      tempDirectory,
      maxMessagesPerWindow: 10,
      maxActionRequestsPerWindow: 1,
      rateLimitWindow: const Duration(seconds: 10),
    );
    final client = await _connect(server!);
    final messages = _MessageReader(client);
    await messages.next();
    final action = jsonEncode({
      'type': 'trigger_action',
      'action': 'launch_app',
      'payload': 'example',
    });
    client.add(action);
    expect((await messages.next())['code'], 'authentication_required');
    client.add(action);
    expect((await messages.next())['code'], 'rate_limited');
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
      expect(init['protocol_version'], isA<int>());
      expect(init['protocol_version'], 1);
      expect(init['capabilities'], [
        'trigger_action',
        'save_config',
        'get_system_apps',
      ]);
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
    'rejects unsupported protocol versions without consuming pairing code',
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
          'protocol_version': 2,
        }),
      );
      expect(await messages.next(), {
        'type': 'auth_error',
        'code': 'unsupported_protocol_version',
      });

      client.add(
        jsonEncode({
          'type': 'authenticate',
          'pairing_code': 'pairing-code',
          'protocol_version': 1,
        }),
      );
      expect((await messages.next())['type'], 'auth_success');
      expect((await messages.next())['type'], 'init_state');

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

  for (final (role, expectedCapabilities) in [
    (AuthRole.viewer, ['view']),
    (AuthRole.control, ['view', 'control']),
    (AuthRole.configAdmin, ['view', 'control', 'configAdmin']),
  ]) {
    test(
      'token reconnect advertises only $role session capabilities',
      () async {
        final manager = AuthSessionManager(pairingCode: 'role-code');
        final session = manager.authenticate('role-code', role: role)!;
        server = _newServer(manager, executor, tempDirectory);
        for (var connection = 0; connection < 2; connection++) {
          final socket = await _connect(server!);
          final messages = _MessageReader(socket);
          expect(await messages.next(), {'type': 'auth_required'});
          if (connection == 0) {
            socket.add(
              jsonEncode({'type': 'authenticate', 'token': 'invalid'}),
            );
            expect(await messages.next(), {
              'type': 'auth_error',
              'code': 'invalid_credentials',
            });
          }

          socket.add(
            jsonEncode({'type': 'authenticate', 'token': session.token}),
          );
          final success = await messages.next();
          expect(success['type'], 'auth_success');
          expect(success['role'], role.name);
          final init = await messages.next();
          expect(init['type'], 'init_state');
          expect(init['protocol_version'], 1);
          expect(init['capabilities'], [
            'trigger_action',
            'save_config',
            'get_system_apps',
          ]);
          expect(init['session_capabilities'], expectedCapabilities);
          expect(
            jsonEncode(init['session_capabilities']),
            isNot(contains(session.token)),
          );
          expect(
            jsonEncode(init['session_capabilities']),
            isNot(contains('/')),
          );

          await messages.close();
          await socket.close();
        }
      },
    );
  }

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

  test('does not apply an in-flight action after stop and restart', () async {
    final manager = AuthSessionManager(pairingCode: 'first');
    final session = manager.authenticate('first', role: AuthRole.configAdmin)!;
    executor.actionStarted = Completer<void>();
    executor.actionRelease = Completer<void>();
    server = _newServer(manager, executor, tempDirectory);
    final initial = await _authenticatedSocket(server!, session.token);

    initial.socket.add(
      jsonEncode({'type': 'trigger_action', 'action': 'audio_mute_toggle'}),
    );
    await executor.actionStarted!.future.timeout(const Duration(seconds: 5));
    expect(server!.isMuted, isFalse);

    await server!.stopServer();
    await initial.messages.close();
    await initial.socket.close();

    await server!.startServer();
    final restarted = await _authenticatedSocket(server!, session.token);
    expect(server!.isMuted, isFalse);

    executor.actionRelease!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server!.isMuted, isFalse);
    await expectLater(
      restarted.messages.next().timeout(const Duration(milliseconds: 250)),
      throwsA(isA<TimeoutException>()),
    );

    await restarted.messages.close();
    await restarted.socket.close();
  }, skip: !Platform.isLinux ? 'Linux command executor test' : false);

  test(
    'failed state actions preserve state and send bounded action errors',
    () async {
      if (!Platform.isLinux) return;

      final manager = AuthSessionManager(pairingCode: 'actions');
      final session = manager.authenticate(
        'actions',
        role: AuthRole.configAdmin,
      )!;
      executor.exitCodes
        ..['pactl'] = 1
        ..['amixer'] = 1
        ..['brightnessctl'] = 1
        ..['xrandr'] = 1;
      server = _newServer(manager, executor, tempDirectory);
      server!
        ..currentVolume = 41
        ..currentBrightness = 63
        ..isMuted = true;
      final client = await _authenticatedSocket(server!, session.token);

      client.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'audio_volume',
          'value': 90,
        }),
      );
      expect(await client.messages.next(), {
        'type': 'action_error',
        'action': 'audio_volume',
        'code': 'action_failed',
      });
      expect(server!.currentVolume, 41);

      client.socket.add(
        jsonEncode({'type': 'trigger_action', 'action': 'audio_mute_toggle'}),
      );
      expect(await client.messages.next(), {
        'type': 'action_error',
        'action': 'audio_mute_toggle',
        'code': 'action_failed',
      });
      expect(server!.isMuted, isTrue);

      client.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'brightness',
          'value': 90,
        }),
      );
      expect(await client.messages.next(), {
        'type': 'action_error',
        'action': 'brightness',
        'code': 'action_failed',
      });
      expect(server!.currentBrightness, 63);

      await client.messages.close();
      await client.socket.close();
    },
    skip: !Platform.isLinux ? 'Linux command executor test' : false,
  );

  test(
    'successful state actions send state update before action result',
    () async {
      if (!Platform.isLinux) return;

      final manager = AuthSessionManager(pairingCode: 'success');
      final session = manager.authenticate(
        'success',
        role: AuthRole.configAdmin,
      )!;
      server = _newServer(manager, executor, tempDirectory);
      final client = await _authenticatedSocket(server!, session.token);

      client.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'audio_volume',
          'value': 88,
        }),
      );
      expect(await client.messages.next(), {
        'type': 'state_update',
        'key': 'volume',
        'value': 88,
      });
      expect(await client.messages.next(), {
        'type': 'action_result',
        'action': 'audio_volume',
        'success': true,
      });
      expect(server!.currentVolume, 88);

      await client.messages.close();
      await client.socket.close();
    },
    skip: !Platform.isLinux ? 'Linux command executor test' : false,
  );

  test('unknown actions and invalid media/KDE payloads fail', () async {
    if (!Platform.isLinux) return;

    final manager = AuthSessionManager(pairingCode: 'invalid-actions');
    final session = manager.authenticate(
      'invalid-actions',
      role: AuthRole.configAdmin,
    )!;
    server = _newServer(manager, executor, tempDirectory);
    final client = await _authenticatedSocket(server!, session.token);

    for (final action in [
      {'action': 'unsupported_action'},
      {'action': 'mpris_action', 'payload': 'unsupported_media'},
      {'action': 'kde_action', 'payload': 'unsupported_kde'},
    ]) {
      client.socket.add(jsonEncode({'type': 'trigger_action', ...action}));
      expect(await client.messages.next(), {
        'type': 'action_error',
        'action': action['action'],
        'code': 'action_failed',
      });
    }

    await client.messages.close();
    await client.socket.close();
  }, skip: !Platform.isLinux ? 'Linux command executor test' : false);

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
          'payload': 'example',
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
        'payload': 'example',
      }),
    );
    expect(await controlMessages.next(), {
      'type': 'action_result',
      'action': 'launch_app',
      'success': true,
    });
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
  final Map<String, int> exitCodes = {};
  final Set<String> throwingExecutables = {};
  Completer<void>? discoveryStarted;
  Completer<void>? discoveryRelease;
  Completer<void>? actionStarted;
  Completer<void>? actionRelease;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add('$executable ${arguments.join(' ')}');
    if (throwingExecutables.contains(executable)) {
      throw StateError('injected command failure');
    }
    if (executable == 'snap' && discoveryStarted != null) {
      if (!discoveryStarted!.isCompleted) discoveryStarted!.complete();
      await discoveryRelease!.future;
    }
    if (executable == 'pactl' &&
        arguments.length >= 2 &&
        arguments[0] == 'set-sink-mute' &&
        actionStarted != null) {
      if (!actionStarted!.isCompleted) actionStarted!.complete();
      await actionRelease!.future;
    }
    return ProcessResult(0, exitCodes[executable] ?? 0, '', '');
  }
}

DartServerService _newServer(
  AuthSessionManager manager,
  CommandExecutor executor,
  Directory tempDirectory, {
  AuthRateLimiter? authRateLimiter,
  String Function(HttpRequest request)? clientIdentityResolver,
  int maxConnections = 100,
  int maxFrameBytes = DartServerService.defaultMaxFrameBytes,
  int maxOversizedFrameViolations =
      DartServerService.defaultMaxOversizedFrameViolations,
  int maxMessagesPerWindow = 120,
  int maxActionRequestsPerWindow = 30,
  Duration rateLimitWindow = const Duration(seconds: 1),
  int maxRateLimitViolations = 3,
  DateTime Function()? clock,
}) => DartServerService.forTesting(
  port: 0,
  authSessionManager: manager,
  authRateLimiter: authRateLimiter,
  clientIdentityResolver: clientIdentityResolver,
  commandExecutor: executor,
  configPath: '${tempDirectory.path}/deckboard_config.json',
  maxConnections: maxConnections,
  maxFrameBytes: maxFrameBytes,
  maxOversizedFrameViolations: maxOversizedFrameViolations,
  maxMessagesPerWindow: maxMessagesPerWindow,
  maxActionRequestsPerWindow: maxActionRequestsPerWindow,
  rateLimitWindow: rateLimitWindow,
  maxRateLimitViolations: maxRateLimitViolations,
  clock: clock,
);

Future<WebSocket> _connect(DartServerService server, {String? origin}) async {
  if (!server.isRunning) await server.startServer();
  return WebSocket.connect(
    'ws://127.0.0.1:${server.port}/ws',
    headers: origin == null ? null : {'Origin': origin},
  );
}

Future<_UpgradeResponse> _upgradeRequest(
  DartServerService server, {
  required String origin,
}) async {
  if (!server.isRunning) await server.startServer();
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/ws'),
    );
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', base64Encode(List<int>.filled(16, 7)))
      ..set('Origin', origin);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return _UpgradeResponse(response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

String _oversizedJsonFrame(Map<String, dynamic> value, int maxBytes) {
  final minimumFrame = jsonEncode({...value, 'padding': ''});
  if (utf8.encode(minimumFrame).length > maxBytes) return minimumFrame;
  return _jsonFrameWithExactUtf8Bytes(value, maxBytes + 1);
}

String _jsonFrameWithExactUtf8Bytes(
  Map<String, dynamic> value,
  int byteLength,
) {
  final emptyPadding = jsonEncode({...value, 'padding': ''});
  final paddingBytes = byteLength - utf8.encode(emptyPadding).length;
  if (paddingBytes < 0) {
    throw ArgumentError.value(byteLength, 'byteLength', 'frame is too small');
  }
  final frame = jsonEncode({...value, 'padding': 'a' * paddingBytes});
  if (utf8.encode(frame).length != byteLength) {
    throw StateError('Could not construct an exact-size JSON frame');
  }
  return frame;
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
    await expectClosedWith('Session invalid');
  }

  Future<void> expectClosedWith(String reason) async {
    expect(
      await _iterator.moveNext().timeout(const Duration(seconds: 5)),
      isFalse,
    );
    expect(socket.closeCode, WebSocketStatus.policyViolation);
    expect(socket.closeReason, reason);
  }

  Future<void> close() => _iterator.cancel();
}

final class _UpgradeResponse {
  const _UpgradeResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

final class _FakeClock {
  _FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}
