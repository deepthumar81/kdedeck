import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/dart_server_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  DartServerService? server;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kdedeck-config-test',
    );
  });

  tearDown(() async {
    await server?.stopServer();
    await tempDirectory.delete(recursive: true);
  });

  test('defaults to loopback with an ephemeral test port', () async {
    server = _newServer('${tempDirectory.path}/deckboard_config.json');

    await server!.startServer();

    expect(server!.bindAddress.address, InternetAddress.loopbackIPv4.address);
    expect(server!.port, greaterThan(0));
    expect(server!.isRunning, isTrue);
    expect(server!.isSecure, isFalse);
    expect(server!.configData?['config_schema_version'], 1);
  });

  test('allow_lan true selects the LAN bind address', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    final config = _config('lan')..['allow_lan'] = true;
    await File(path).writeAsString(jsonEncode(config));
    server = _newServer(path);

    await server!.startServer();

    expect(server!.bindAddress.address, InternetAddress.anyIPv4.address);
    expect(server!.isRunning, isFalse);
    expect(server!.isSecure, isFalse);
  });

  test('invalid bind settings fail closed to loopback', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    final config = _config('invalid')
      ..['allow_lan'] = 'true'
      ..['bind_address'] = '192.0.2.10';
    await File(path).writeAsString(jsonEncode(config));
    server = _newServer(path);

    await server!.startServer();

    expect(server!.bindAddress.address, InternetAddress.loopbackIPv4.address);
  });

  test('bind setting and existing config remain preserved on load', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    final config = _config('preserved')
      ..['allow_lan'] = true
      ..['profile'] = 'phone';
    await File(path).writeAsString(jsonEncode(config));
    server = _newServer(path);

    await server!.startServer();

    expect(server!.configData?['allow_lan'], isTrue);
    expect(server!.configData?['profile'], 'phone');
    expect(server!.configData?['boards'][0]['id'], 'preserved');
    expect(server!.bindAddress.address, InternetAddress.anyIPv4.address);
    expect(server!.isRunning, isFalse);
  });

  test('injected test bind address overrides config mode', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    await File(path)
        .writeAsString(jsonEncode(_config('injected')..['allow_lan'] = true));
    server = DartServerService.forTesting(
      port: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      configPath: path,
      authSessionManager: AuthSessionManager(pairingCode: 'pairing-code'),
    );

    await server!.startServer();

    expect(server!.bindAddress.address, InternetAddress.loopbackIPv4.address);
  });

  test(
    'invalid save returns a bounded error and leaves active file unchanged',
    () async {
      final path = '${tempDirectory.path}/deckboard_config.json';
      final baseline = _config('baseline');
      await File(path).writeAsString(jsonEncode(baseline));
      final original = await File(path).readAsString();

      server = _newServer(path);
      final connection = await _authenticatedClient(server!);
      final client = connection.socket;
      final messages = connection.messages;

      client.add(
        jsonEncode({
          'type': 'save_config',
          'config': {'boards': null},
        }),
      );
      final error = await messages.next();
      expect(error, {'type': 'config_error', 'code': 'invalid_config'});
      expect(jsonEncode(error), isNot(contains('baseline')));
      expect(await File(path).readAsString(), original);

      await messages.close();
      await client.close();
    },
  );

  test('successful saves create an atomic last-known-good backup', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    server = _newServer(path);
    final connection = await _authenticatedClient(server!);
    final client = connection.socket;
    final messages = connection.messages;

    client.add(jsonEncode({'type': 'save_config', 'config': _config('first')}));
    expect((await messages.next())['type'], 'config_updated');
    final firstText = await File(path).readAsString();

    client.add(
      jsonEncode({'type': 'save_config', 'config': _config('second')}),
    );
    expect((await messages.next())['type'], 'config_updated');
    expect(File('$path.bak').existsSync(), isTrue);
    expect(await File('$path.bak').readAsString(), firstText);
    expect(
      jsonDecode(await File(path).readAsString())['boards'][0]['id'],
      'second',
    );

    await messages.close();
    await client.close();
  });

  test(
    'stop drains in-flight saves and fences queued saves across restart',
    () async {
      final path = '${tempDirectory.path}/deckboard_config.json';
      await File(path).writeAsString(jsonEncode(_config('existing')));
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<bool>();
      final writes = <String>[];

      server = DartServerService.forTesting(
        port: 0,
        configPath: path,
        authSessionManager: AuthSessionManager(pairingCode: 'pairing-code'),
        configWriter: (config, _) {
          writes.add(config['boards'][0]['id'] as String);
          if (!firstWriteStarted.isCompleted) {
            firstWriteStarted.complete();
            return releaseFirstWrite.future;
          }
          return Future<bool>.value(true);
        },
      );
      _Connection? connection;
      try {
        connection = await _authenticatedClient(server!);
        final client = connection.socket;

        client.add(
          jsonEncode({'type': 'save_config', 'config': _config('first')}),
        );
        await _bounded(firstWriteStarted.future);

        client.add(
          jsonEncode({'type': 'save_config', 'config': _config('queued')}),
        );
        // Let the websocket callback enqueue the second save without using an
        // arbitrary timing delay.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        var stopped = false;
        final stopping = server!.stopServer().then((_) => stopped = true);
        await Future<void>.value();
        expect(stopped, isFalse);
        expect(server!.isRunning, isTrue);

        releaseFirstWrite.complete(true);
        await _bounded(stopping);

        expect(writes, ['first']);
        expect(server!.configData?['boards'][0]['id'], 'existing');
        expect(
          jsonDecode(await File(path).readAsString())['boards'][0]['id'],
          'existing',
        );

        await _bounded(server!.startServer());
        expect(server!.configData?['boards'][0]['id'], 'existing');
      } finally {
        if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete(true);
        await connection?.messages.close();
        await connection?.socket.close();
      }
    },
  );

  test('startup recovers a valid backup when the primary is corrupt', () async {
    final path = '${tempDirectory.path}/deckboard_config.json';
    server = _newServer(path);
    final connection = await _authenticatedClient(server!);
    final client = connection.socket;
    final messages = connection.messages;
    client.add(
      jsonEncode({'type': 'save_config', 'config': _config('recover-me')}),
    );
    expect((await messages.next())['type'], 'config_updated');
    client.add(jsonEncode({'type': 'save_config', 'config': _config('newer')}));
    expect((await messages.next())['type'], 'config_updated');
    await messages.close();
    await client.close();
    await server!.stopServer();
    server = null;

    await File(path).writeAsString('{"boards": [');
    final recovered = _newServer(path);
    server = recovered;
    final recoveredConnection = await _authenticatedClient(recovered);
    final recoveredClient = recoveredConnection.socket;
    final recoveredMessages = recoveredConnection.messages;
    expect(recoveredConnection.init['config']['boards'][0]['id'], 'recover-me');

    await recoveredMessages.close();
    await recoveredClient.close();
  });
}

DartServerService _newServer(String path) => DartServerService.forTesting(
  port: 0,
  configPath: path,
  authSessionManager: AuthSessionManager(pairingCode: 'pairing-code'),
);

Future<_Connection> _authenticatedClient(DartServerService server) async {
  if (!server.isRunning) await server.startServer();
  final client = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
  final messages = _MessageReader(client);
  expect(await messages.next(), {'type': 'auth_required'});
  client.add(
    jsonEncode({'type': 'authenticate', 'pairing_code': 'pairing-code'}),
  );
  expect((await messages.next())['type'], 'auth_success');
  final init = await messages.next();
  expect(init['type'], 'init_state');
  return _Connection(client, messages, init);
}

Map<String, dynamic> _config(String id) => {
  'boards': [
    {
      'id': id,
      'title': 'Board $id',
      'grid_columns': 2,
      'grid_rows': 2,
      'items': [
        {
          'id': 'item-$id',
          'title': 'Terminal',
          'type': 'button',
          'action': 'launch_app',
          'payload': 'konsole',
          'icon': 'terminal',
          'span_cols': 1,
          'span_rows': 1,
          'grid_x': 0,
          'grid_y': 0,
        },
      ],
    },
  ],
};

Future<T> _bounded<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 3));

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

final class _Connection {
  const _Connection(this.socket, this.messages, this.init);

  final WebSocket socket;
  final _MessageReader messages;
  final Map<String, dynamic> init;
}
