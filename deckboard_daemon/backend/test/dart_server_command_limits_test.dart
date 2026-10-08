import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/approved_application_registry.dart';
import 'package:backend/app_discovery.dart';
import 'package:backend/command_executor.dart';
import 'package:backend/dart_server_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  DartServerService? server;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kdedeck-command-limits-test',
    );
  });

  tearDown(() async {
    await server?.stopServer();
    await tempDirectory.delete(recursive: true);
  });

  test('uses separate launch and bounded control executors', () async {
    if (!Platform.isLinux) return;

    final control = _RecordingExecutor();
    final launch = _RecordingExecutor();
    server = _newServer(
      commandExecutor: control,
      launchCommandExecutor: launch,
      sensitiveActionPolicy: const SensitiveActionPolicy(
        allowSensitiveActions: true,
      ),
    );
    final session = await _authenticatedSocket(server!);

    session.socket.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'open_url',
        'payload': 'https://example.test/',
      }),
    );
    expect(await session.messages.next(), {
      'type': 'action_result',
      'action': 'open_url',
      'success': true,
    });
    expect(launch.executables, ['xdg-open']);
    expect(control.executables, isEmpty);

    session.socket.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'kde_action',
        'payload': 'lock',
      }),
    );
    expect(await session.messages.next(), {
      'type': 'action_result',
      'action': 'kde_action',
      'success': true,
    });
    expect(control.executables, ['qdbus']);

    await session.messages.close();
    await session.socket.close();
  });

  test(
    'authenticated launch resolves only approved identities to fixed commands',
    () async {
      if (!Platform.isLinux) return;

      final injected = _RecordingExecutor();
      server = _newServer(commandExecutor: injected);
      final session = await _authenticatedSocket(server!);

      session.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'launch_app',
          'payload': 'example',
        }),
      );
      expect(await session.messages.next(), {
        'type': 'action_result',
        'action': 'launch_app',
        'success': true,
      });
      expect(injected.invocations, hasLength(1));
      expect(injected.invocations.single.executable, '/usr/bin/example');
      expect(injected.invocations.single.arguments, ['--test']);

      for (final request in [
        {'action': 'launch_app', 'payload': 'unknown-app'},
        {'action': 'launch_app', 'payload': '/bin/sh'},
        {'action': 'launch_app', 'payload': 'python3 -c print(1)'},
        {'action': 'launch_app', 'payload': 'example --extra'},
        {'action': 'launch_app', 'payload': 'https://example.test/'},
        {'action': 'open_url', 'payload': '/usr/bin/example'},
        {'action': 'open_url', 'payload': 'python3 -c print(1)'},
      ]) {
        session.socket.add(jsonEncode({'type': 'trigger_action', ...request}));
        expect(await session.messages.next(), {
          'type': 'action_error',
          'action': request['action'],
          'code': 'action_failed',
        });
        expect(injected.invocations, hasLength(1));
      }

      await session.messages.close();
      await session.socket.close();
    },
  );

  test('an empty approved registry denies a known-shaped identity', () async {
    if (!Platform.isLinux) return;

    final injected = _RecordingExecutor();
    server = _newServer(
      commandExecutor: injected,
      applicationRegistry: ApprovedApplicationRegistry({}),
    );
    final session = await _authenticatedSocket(server!);

    session.socket.add(
      jsonEncode({
        'type': 'trigger_action',
        'action': 'launch_app',
        'payload': 'example',
      }),
    );
    expect(await session.messages.next(), {
      'type': 'action_error',
      'action': 'launch_app',
      'code': 'action_failed',
    });
    expect(injected.invocations, isEmpty);

    await session.messages.close();
    await session.socket.close();
  });

  test(
    'returns bounded probe failure as action_error without changing state',
    () async {
      if (!Platform.isLinux) return;

      final probe = File('${tempDirectory.path}/command_probe.dart');
      await probe.writeAsString('''
import 'dart:async';

Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final bounded = ProcessCommandExecutor.bounded(
        timeout: const Duration(milliseconds: 100),
        terminationGrace: const Duration(milliseconds: 25),
        maxOutputBytes: 1024,
      );
      server = _newServer(
        commandExecutor: _ProbeRedirectingExecutor(bounded, probe.path),
      );
      final session = await _authenticatedSocket(server!);

      session.socket.add(
        jsonEncode({
          'type': 'trigger_action',
          'action': 'audio_volume',
          'value': 80,
        }),
      );
      expect(await session.messages.next(), {
        'type': 'action_error',
        'action': 'audio_volume',
        'code': 'action_failed',
      });
      expect(server!.currentVolume, 50);
      expect(server!.currentBrightness, 70);

      await session.messages.close();
      await session.socket.close();
    },
  );
}

DartServerService _newServer({
  required CommandExecutor commandExecutor,
  CommandExecutor? launchCommandExecutor,
  ApprovedApplicationRegistry? applicationRegistry,
  SensitiveActionPolicy sensitiveActionPolicy = const SensitiveActionPolicy(),
}) => DartServerService.forTesting(
  port: 0,
  authSessionManager: AuthSessionManager(pairingCode: 'pairing-code'),
  commandExecutor: commandExecutor,
  launchCommandExecutor: launchCommandExecutor,
  applicationRegistry:
      applicationRegistry ??
      ApprovedApplicationRegistry({
        'example': LaunchCommand('/usr/bin/example', ['--test']),
      }),
  sensitiveActionPolicy: sensitiveActionPolicy,
  configPath: '${Directory.systemTemp.path}/unused-deckboard-config.json',
  metricsInterval: const Duration(hours: 1),
);

Future<({WebSocket socket, _MessageReader messages})> _authenticatedSocket(
  DartServerService server,
) async {
  await server.startServer();
  final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
  final messages = _MessageReader(socket);
  expect(await messages.next(), {'type': 'auth_required'});
  socket.add(
    jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
  );
  expect((await messages.next())['type'], 'auth_success');
  expect((await messages.next())['type'], 'init_state');
  return (socket: socket, messages: messages);
}

final class _Invocation {
  _Invocation(this.executable, this.arguments, this.environment);

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

final class _RecordingExecutor implements CommandExecutor {
  final List<_Invocation> invocations = [];

  List<String> get executables =>
      invocations.map((invocation) => invocation.executable).toList();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add(
      _Invocation(executable, List<String>.from(arguments), environment),
    );
    return ProcessResult(0, 0, '', '');
  }
}

final class _ProbeRedirectingExecutor implements CommandExecutor {
  const _ProbeRedirectingExecutor(this.delegate, this.probePath);

  final CommandExecutor delegate;
  final String probePath;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    if (executable == 'pactl' || executable == 'amixer') {
      return delegate.run(Platform.resolvedExecutable, [
        probePath,
      ], environment: environment);
    }
    return delegate.run(executable, arguments, environment: environment);
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
