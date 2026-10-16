import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/dart_server_service.dart';
import 'package:backend/local_pairing_console.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  DartServerService? server;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('kdedeck-pair-test');
  });
  tearDown(() async {
    await server?.stopServer();
    await tempDirectory.delete(recursive: true);
  });

  test(
    'redirected --pair denies before startup, issuance and output',
    () async {
      for (final (input, output) in [(false, true), (true, false)]) {
        final secretOutput = <String>[];
        final errors = <String>[];
        final manager = _DummyManager();
        server = _server(manager, tempDirectory);
        final console = _console(input, output, secretOutput, errors);
        var starts = 0;

        expect(
          await startLocalDaemon(
            ['--pair'],
            startServer: () async {
              starts++;
            },
            stopServer: server!.stopServer,
            isRunning: () => server!.isRunning,
            issueCode: server!.issueLocalPairingCode,
            console: console,
            writeError: errors.add,
          ),
          2,
        );
        expect(starts, 0);
        expect(manager.issuedLocally, 0);
        expect(secretOutput, isEmpty);
        expect(errors.single, contains('interactive'));
      }
    },
  );

  test(
    'invalid arguments and unsuccessful startup exit without issuance',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      final output = <String>[];
      final errors = <String>[];
      final console = _console(true, true, output, errors);
      var starts = 0;
      Future<void> start() async {
        starts++;
      }

      expect(
        await startLocalDaemon(
          ['--pair', 'DUMMY-ARG'],
          startServer: start,
          stopServer: server!.stopServer,
          isRunning: () => false,
          issueCode: server!.issueLocalPairingCode,
          console: console,
          writeError: errors.add,
        ),
        2,
      );
      expect(starts, 0);
      expect(
        await startLocalDaemon(
          ['--pair'],
          startServer: start,
          stopServer: server!.stopServer,
          isRunning: () => false,
          issueCode: server!.issueLocalPairingCode,
          console: console,
          writeError: errors.add,
        ),
        1,
      );
      expect(starts, 1);
      expect(
        await startLocalDaemon(
          ['--pair'],
          startServer: () async => throw StateError('DUMMY-ARG'),
          stopServer: server!.stopServer,
          isRunning: () => false,
          issueCode: server!.issueLocalPairingCode,
          console: console,
          writeError: errors.add,
        ),
        1,
      );
      expect(manager.issuedLocally, 0);
      expect(output, isEmpty);
      expect(errors, everyElement(isNot(contains('DUMMY-ARG'))));
    },
  );

  test('normal startup does not invoke local issuance or display', () async {
    final manager = _DummyManager();
    server = _server(manager, tempDirectory);
    final output = <String>[];
    final console = _console(true, true, output, []);
    expect(
      await startLocalDaemon(
        [],
        startServer: server!.startServer,
        stopServer: server!.stopServer,
        isRunning: () => server!.isRunning,
        issueCode: server!.issueLocalPairingCode,
        console: console,
        writeError: (_) {},
      ),
      0,
    );
    expect(manager.issuedLocally, 0);
    expect(output, isEmpty);
  });

  test('interactive startup displays dummy code and expiry hint', () async {
    final manager = _DummyManager();
    server = _server(manager, tempDirectory);
    final output = <String>[];
    final console = _console(true, true, output, []);
    expect(
      await startLocalDaemon(
        ['--pair'],
        startServer: server!.startServer,
        stopServer: server!.stopServer,
        isRunning: () => server!.isRunning,
        issueCode: server!.issueLocalPairingCode,
        console: console,
        writeError: (_) {},
      ),
      0,
    );
    expect(manager.issuedLocally, 1);
    expect(output.single, contains('DUMMY-ONE'));
    expect(output.single, contains('Expires at'));
    expect(output.single, contains('one use only'));
  });

  test(
    'terminal lost after startup shuts server down without issuing',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      var terminal = true;
      final output = <String>[];
      final errors = <String>[];
      final console = LocalPairingConsole(
        inputHasTerminal: () => terminal,
        outputHasTerminal: () => terminal,
        writeSecretToTerminal: output.add,
        writeToTerminal: output.add,
        writeError: errors.add,
      );
      expect(
        await startLocalDaemon(
          ['--pair'],
          startServer: () async {
            await server!.startServer();
            terminal = false;
          },
          stopServer: server!.stopServer,
          isRunning: () => server!.isRunning,
          issueCode: server!.issueLocalPairingCode,
          console: console,
          writeError: errors.add,
        ),
        1,
      );
      expect(server!.isRunning, isFalse);
      expect(manager.issuedLocally, 0);
      expect(output, isEmpty);
      expect(errors.single, contains('interactive'));
    },
  );

  test('rechecked terminal and stopped server refuse issuance', () async {
    final manager = _DummyManager();
    server = _server(manager, tempDirectory);
    await server!.startServer();
    var input = true;
    final output = <String>[];
    final errors = <String>[];
    final console = LocalPairingConsole(
      inputHasTerminal: () => input,
      outputHasTerminal: () => true,
      writeSecretToTerminal: output.add,
      writeToTerminal: output.add,
      writeError: errors.add,
    );
    input = false;
    expect(console.handleLine('pair', server!), isFalse);
    expect(manager.issuedLocally, 0);
    expect(output, isEmpty);

    input = true;
    await server!.stopServer();
    expect(() => server!.issueLocalPairingCode(), throwsStateError);
    expect(console.handleLine('pair', server!), isFalse);
    expect(manager.issuedLocally, 0);
    expect(output, isEmpty);
    expect(errors.last, contains('Could not issue'));
  });

  test(
    'local status and revoke commands expose counts but never credentials',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      await server!.startServer();

      final viewer = manager.authenticate(
        'DUMMY-INITIAL',
        role: AuthRole.viewer,
      )!;
      manager.issuePairingCode(code: 'DUMMY-CONTROL');
      final control = manager.authenticate(
        'DUMMY-CONTROL',
        role: AuthRole.control,
      )!;
      final output = <String>[];
      final errors = <String>[];
      final console = LocalPairingConsole(
        inputHasTerminal: () => true,
        outputHasTerminal: () => true,
        writeSecretToTerminal: output.add,
        writeToTerminal: output.add,
        writeError: errors.add,
      );

      expect(console.handleLine('status', server!), isTrue);
      expect(output.single, 'Active sessions: 2/100\n');
      expect(output.single, isNot(contains(viewer.token)));
      expect(output.single, isNot(contains(control.token)));

      expect(console.handleLine('revoke role viewer', server!), isTrue);
      expect(output.last, 'Revoked 1 viewer session.\n');
      expect(manager.validateToken(viewer.token), isNull);
      expect(manager.validateToken(control.token), isNotNull);

      expect(console.handleLine('revoke all', server!), isTrue);
      expect(output.last, 'Revoked 1 session.\n');
      expect(manager.activeSessionCount, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'local administrative commands fail closed without a running server',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      final output = <String>[];
      final errors = <String>[];
      final console = _console(true, true, output, errors);

      expect(console.handleLine('status', server!), isFalse);
      expect(output, isEmpty);
      expect(errors.single, 'Could not apply local administrative command.');
    },
  );

  test(
    'local pairing can select a bounded role before displaying the code',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      await server!.startServer();
      final output = <String>[];
      final errors = <String>[];
      final console = _console(true, true, output, errors);

      expect(console.handleLine('pair role viewer', server!), isTrue);
      expect(output.single, contains('DUMMY-ONE'));
      expect(errors, isEmpty);

      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/ws',
      );
      final messages = StreamIterator<dynamic>(socket);
      addTearDown(() async {
        await messages.cancel();
        await socket.close();
      });
      expect(await _next(messages), {'type': 'auth_required'});
      socket.add(
        jsonEncode({
          'type': 'authenticate',
          'pairing_code': 'DUMMY-ONE',
          'role': 'configAdmin',
        }),
      );
      final success = await _next(messages);
      expect(success['role'], 'viewer');
      expect(await _next(messages), containsPair('type', 'init_state'));
    },
  );

  test(
    'same-terminal pair rotates code and keeps existing token on WebSocket',
    () async {
      final manager = _DummyManager();
      server = _server(manager, tempDirectory);
      await server!.startServer();
      final output = <String>[];
      final console = _console(true, true, output, []);

      final firstSocket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/ws',
      );
      final first = StreamIterator<dynamic>(firstSocket);
      expect(await _next(first), {'type': 'auth_required'});
      expect(console.handleLine('pair', server!), isTrue);
      firstSocket.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'DUMMY-ONE'}),
      );
      final firstSuccess = await _next(first);
      final token = firstSuccess['token'] as String;
      expect(firstSuccess['type'], 'auth_success');
      expect(await _next(first), containsPair('type', 'init_state'));

      // A remote request must not invoke the local terminal issuance path.
      firstSocket.add(jsonEncode({'type': 'pair'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(manager.issuedLocally, 1);

      expect(console.handleLine(' pair ', server!), isTrue);
      expect(console.handleLine('not-pair', server!), isFalse);
      expect(console.handleLine('pair', server!), isTrue);
      expect(manager.issuedLocally, 3);
      expect(output, hasLength(3));
      expect(output.last, contains('DUMMY-THREE'));
      expect(manager.validateToken(token), isNotNull);

      final secondSocket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/ws',
      );
      final second = StreamIterator<dynamic>(secondSocket);
      expect(await _next(second), {'type': 'auth_required'});
      secondSocket.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'DUMMY-TWO'}),
      );
      expect(await _next(second), {
        'type': 'auth_error',
        'code': 'invalid_credentials',
      });
      secondSocket.add(
        jsonEncode({'type': 'authenticate', 'pairing_code': 'DUMMY-THREE'}),
      );
      final success = await _next(second);
      expect(success['type'], 'auth_success');
      expect(jsonEncode(success), isNot(contains('DUMMY-THREE')));
      expect(await _next(second), containsPair('type', 'init_state'));

      final tokenSocket = await WebSocket.connect(
        'ws://127.0.0.1:${server!.port}/ws',
      );
      final reconnect = StreamIterator<dynamic>(tokenSocket);
      expect(await _next(reconnect), {'type': 'auth_required'});
      tokenSocket.add(jsonEncode({'type': 'authenticate', 'token': token}));
      expect(await _next(reconnect), containsPair('token', token));
      expect(await _next(reconnect), containsPair('type', 'init_state'));

      await first.cancel();
      await second.cancel();
      await reconnect.cancel();
      await firstSocket.close();
      await secondSocket.close();
      await tokenSocket.close();
    },
  );
}

LocalPairingConsole _console(
  bool input,
  bool output,
  List<String> secretOutput,
  List<String> errors,
) => LocalPairingConsole(
  inputHasTerminal: () => input,
  outputHasTerminal: () => output,
  writeSecretToTerminal: secretOutput.add,
  writeToTerminal: secretOutput.add,
  writeError: errors.add,
);

DartServerService _server(AuthSessionManager manager, Directory directory) =>
    DartServerService.forTesting(
      port: 0,
      authSessionManager: manager,
      configPath: '${directory.path}/config.json',
    );

Future<Map<String, dynamic>> _next(StreamIterator<dynamic> messages) async {
  expect(await messages.moveNext(), isTrue);
  return Map<String, dynamic>.from(jsonDecode(messages.current as String));
}

final class _DummyManager extends AuthSessionManager {
  _DummyManager() : super(pairingCode: 'DUMMY-INITIAL');

  int issuedLocally = 0;

  @override
  String issuePairingCode({String? code}) {
    if (code != null) return super.issuePairingCode(code: code);
    issuedLocally++;
    final next = switch (issuedLocally) {
      1 => 'DUMMY-ONE',
      2 => 'DUMMY-TWO',
      _ => 'DUMMY-THREE',
    };
    return super.issuePairingCode(code: next);
  }
}
