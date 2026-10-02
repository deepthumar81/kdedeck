import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add('$executable ${arguments.join(' ')}');
    return ProcessResult(0, 0, '', '');
  }
}

DartServerService _newServer(
  AuthSessionManager manager,
  CommandExecutor executor,
  Directory tempDirectory,
) => DartServerService.forTesting(
  port: 0,
  authSessionManager: manager,
  commandExecutor: executor,
  configPath: '${tempDirectory.path}/deckboard_config.json',
);

Future<WebSocket> _connect(DartServerService server) async {
  if (!server.isRunning) await server.startServer();
  return WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
}

final class _MessageReader {
  _MessageReader(this.socket) : _iterator = StreamIterator<dynamic>(socket);

  final WebSocket socket;
  final StreamIterator<dynamic> _iterator;

  Future<Map<String, dynamic>> next() async {
    expect(await _iterator.moveNext(), isTrue);
    return Map<String, dynamic>.from(jsonDecode(_iterator.current as String));
  }

  Future<void> close() => _iterator.cancel();
}
