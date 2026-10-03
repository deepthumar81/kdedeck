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
