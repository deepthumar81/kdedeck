import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/command_executor.dart';
import 'package:backend/dart_server_service.dart';
import 'package:test/test.dart';

void main() {
  late _RecordingExecutor executor;
  DartServerService? server;

  setUp(() {
    executor = _RecordingExecutor();
  });

  tearDown(() async {
    await server?.stopServer();
  });

  test('default policy denies every sensitive KDE action', () async {
    if (!Platform.isLinux) return;

    server = _newServer(executor: executor);
    final client = await _authenticatedClient(server!);
    for (final action in ['sleep', 'shutdown', 'logout', 'lock']) {
      client.socket.add(_triggerKdeAction(action));
      expect(await client.messages.next(), {
        'type': 'action_error',
        'action': 'kde_action',
        'code': 'action_failed',
      });
    }

    expect(executor.invocations, isEmpty);
    await client.close();
  });

  test(
    'policy and positive confirmation execute the expected KDE commands',
    () async {
      if (!Platform.isLinux) return;

      final confirmations = <String>[];
      server = _newServer(
        executor: executor,
        sensitiveActionPolicy: SensitiveActionPolicy(
          allowSensitiveActions: true,
          sensitiveActionConfirmation: (action) async {
            confirmations.add(action);
            return true;
          },
        ),
      );
      final client = await _authenticatedClient(server!);

      for (final action in ['sleep', 'shutdown', 'logout', 'lock']) {
        client.socket.add(_triggerKdeAction(action));
        expect(await client.messages.next(), {
          'type': 'action_result',
          'action': 'kde_action',
          'success': true,
        });
      }

      expect(confirmations, ['sleep', 'shutdown', 'logout']);
      expect(executor.invocations.map((invocation) => invocation.executable), [
        'systemctl',
        'systemctl',
        'qdbus',
        'qdbus',
      ]);
      expect(executor.invocations[0].arguments, ['suspend']);
      expect(executor.invocations[1].arguments, ['poweroff']);
      expect(executor.invocations[2].arguments, [
        'org.kde.ksmserver',
        '/KSMServer',
        'logout',
        '0',
        '0',
        '0',
      ]);
      await client.close();
    },
  );

  test('false or absent confirmation denies destructive KDE actions', () async {
    if (!Platform.isLinux) return;

    server = _newServer(
      executor: executor,
      sensitiveActionPolicy: const SensitiveActionPolicy(
        allowSensitiveActions: true,
      ),
    );
    final client = await _authenticatedClient(server!);
    for (final action in ['sleep', 'shutdown', 'logout']) {
      client.socket.add(_triggerKdeAction(action));
      expect(await client.messages.next(), _actionError());
    }
    expect(executor.invocations, isEmpty);
    await client.close();

    await server!.stopServer();
    server = _newServer(
      executor: executor,
      sensitiveActionPolicy: SensitiveActionPolicy(
        allowSensitiveActions: true,
        sensitiveActionConfirmation: (_) async => false,
      ),
    );
    final falseClient = await _authenticatedClient(server!);
    for (final action in ['sleep', 'shutdown', 'logout']) {
      falseClient.socket.add(_triggerKdeAction(action));
      expect(await falseClient.messages.next(), _actionError());
    }
    expect(executor.invocations, isEmpty);
    await falseClient.close();
  });

  test('lock can be enabled without a confirmation callback', () async {
    if (!Platform.isLinux) return;

    server = _newServer(
      executor: executor,
      sensitiveActionPolicy: const SensitiveActionPolicy(
        allowSensitiveActions: true,
      ),
    );
    final client = await _authenticatedClient(server!);
    client.socket.add(_triggerKdeAction('lock'));

    expect(await client.messages.next(), {
      'type': 'action_result',
      'action': 'kde_action',
      'success': true,
    });
    expect(executor.invocations.single.executable, 'qdbus');
    await client.close();
  });

  test(
    'confirmation is action-scoped and is not called for ordinary actions',
    () async {
      if (!Platform.isLinux) return;

      final confirmations = <String>[];
      server = _newServer(
        executor: executor,
        sensitiveActionPolicy: SensitiveActionPolicy(
          allowSensitiveActions: true,
          sensitiveActionConfirmation: (action) async {
            confirmations.add(action);
            return true;
          },
        ),
      );
      final client = await _authenticatedClient(server!);

      client.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'open_url',
          'payload': 'https://example.test/',
        }),
      );
      expect(await client.messages.next(), {
        'type': 'action_result',
        'action': 'open_url',
        'success': true,
      });
      expect(confirmations, isEmpty);

      client.socket.add(_triggerKdeAction('sleep'));
      expect(await client.messages.next(), {
        'type': 'action_result',
        'action': 'kde_action',
        'success': true,
      });
      expect(confirmations, ['sleep']);
      expect(executor.invocations.map((invocation) => invocation.executable), [
        'xdg-open',
        'systemctl',
      ]);
      await client.close();
    },
  );

  test('confirmation continuation is fenced after server stop', () async {
    if (!Platform.isLinux) return;

    final started = Completer<void>();
    final release = Completer<bool>();
    server = _newServer(
      executor: executor,
      sensitiveActionPolicy: SensitiveActionPolicy(
        allowSensitiveActions: true,
        sensitiveActionConfirmation: (action) {
          expect(action, 'shutdown');
          started.complete();
          return release.future;
        },
      ),
    );
    final client = await _authenticatedClient(server!);
    client.socket.add(_triggerKdeAction('shutdown'));
    await started.future;

    await server!.stopServer();
    release.complete(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(executor.invocations, isEmpty);
    await client.close();
  });

  test('sensitive action errors are sent only to the requester', () async {
    if (!Platform.isLinux) return;

    final manager = AuthSessionManager(pairingCode: 'pairing-code');
    final session = manager.authenticate(
      'pairing-code',
      role: AuthRole.configAdmin,
    )!;
    server = _newServer(executor: executor, authSessionManager: manager);
    final requester = await _authenticatedClient(server!, token: session.token);
    final other = await _authenticatedClient(server!, token: session.token);

    requester.socket.add(_triggerKdeAction('lock'));
    expect(await requester.messages.next(), _actionError());
    await expectLater(
      other.messages.next().timeout(const Duration(milliseconds: 250)),
      throwsA(isA<TimeoutException>()),
    );
    expect(executor.invocations, isEmpty);
    await requester.close();
    await other.close();
  });
}

DartServerService _newServer({
  required _RecordingExecutor executor,
  AuthSessionManager? authSessionManager,
  SensitiveActionPolicy sensitiveActionPolicy = const SensitiveActionPolicy(),
}) => DartServerService.forTesting(
  port: 0,
  authSessionManager:
      authSessionManager ?? AuthSessionManager(pairingCode: 'pairing-code'),
  commandExecutor: executor,
  launchCommandExecutor: executor,
  sensitiveActionPolicy: sensitiveActionPolicy,
  configPath: '${Directory.systemTemp.path}/unused-deckboard-config.json',
  metricsInterval: const Duration(hours: 1),
);

String _triggerKdeAction(String action) => jsonEncode({
  'type': 'trigger_action',
  'action': 'kde_action',
  'payload': action,
});

Map<String, dynamic> _actionError() => {
  'type': 'action_error',
  'action': 'kde_action',
  'code': 'action_failed',
};

Future<_AuthenticatedClient> _authenticatedClient(
  DartServerService server, {
  String? token,
}) async {
  await server.startServer();
  final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
  final messages = _MessageReader(socket);
  expect(await messages.next(), {'type': 'auth_required'});
  socket.add(
    jsonEncode(
      token == null
          ? {'type': 'authenticate', 'pairing_code': 'pairing-code'}
          : {'type': 'authenticate', 'token': token},
    ),
  );
  expect((await messages.next())['type'], 'auth_success');
  expect((await messages.next())['type'], 'init_state');
  return _AuthenticatedClient(socket, messages);
}

final class _AuthenticatedClient {
  const _AuthenticatedClient(this.socket, this.messages);

  final WebSocket socket;
  final _MessageReader messages;

  Future<void> close() async {
    await messages.close();
    await socket.close();
  }
}

final class _Invocation {
  const _Invocation(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

final class _RecordingExecutor implements CommandExecutor {
  final List<_Invocation> invocations = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add(_Invocation(executable, List<String>.from(arguments)));
    return ProcessResult(0, 0, '', '');
  }
}

final class _MessageReader {
  _MessageReader(this.socket) : _iterator = StreamIterator<dynamic>(socket);

  final WebSocket socket;
  final StreamIterator<dynamic> _iterator;

  Future<Map<String, dynamic>> next() async {
    expect(
      await _iterator.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    return Map<String, dynamic>.from(jsonDecode(_iterator.current as String));
  }

  Future<void> close() => _iterator.cancel();
}
