import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/dart_server_service.dart';
import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  final servers = <DartServerService>[];

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync(
      'kdedeck-server-persistence-',
    );
  });

  tearDown(() async {
    for (final server in servers) {
      await server.stopServer();
    }
    servers.clear();
    tempDirectory.deleteSync(recursive: true);
  });

  DartServerService newServer({void Function()? beforePendingClear}) {
    final server = DartServerService.forTesting(
      port: 0,
      configPath: '${tempDirectory.path}/deckboard_config.json',
      frontendRoot: tempDirectory.path,
      // Persistence is deliberately opt-in through the test-only seam.
      sessionStoreFactory: () => FileSessionStore(
        '${tempDirectory.path}/sessions.json',
        beforePendingClear: beforePendingClear,
      ),
    );
    servers.add(server);
    return server;
  }

  test('opt-in persistence preserves authenticated access across save, conflict, and restart', () async {
    final server = newServer();
    await server.startServer();
    final first = await _authenticateWithPairingCode(
      server,
      server.issueLocalPairingCode().code,
    );
    final token = first.token;

    first.socket.add(
      jsonEncode({'type': 'save_config', 'config': _config('saved')}),
    );
    expect((await first.messages.next())['type'], 'config_updated');
    expect(server.configRevision, 1);
    final savedConfig = await File(
      '${tempDirectory.path}/deckboard_config.json',
    ).readAsString();

    first.socket.add(
      jsonEncode({
        'type': 'save_config',
        'revision': 0,
        'config': _config('stale'),
      }),
    );
    expect(await first.messages.next(), {
      'type': 'config_error',
      'code': 'config_conflict',
      'revision': 1,
    });
    expect(
      await File('${tempDirectory.path}/deckboard_config.json').readAsString(),
      savedConfig,
    );

    await first.close();
    await server.stopServer();
    // A new instance models a fresh daemon process, rather than reusing the
    // in-memory revision counter of a stopped test instance.
    final successor = newServer();
    await successor.startServer();

    final restarted = await _authenticateWithToken(successor, token);
    expect(restarted.init['config']['boards'][0]['id'], 'saved');
    // Config revisions are process-lifetime conflict guards, not persisted
    // configuration fields; a restarted server starts a fresh revision.
    expect(restarted.init['revision'], 0);
    await restarted.close();
  });

  test('session-store write failure rejects pairing and blocks restart without listener', () async {
    var clearAttempts = 0;
    final server = newServer(
      beforePendingClear: () {
        clearAttempts++;
        throw StateError('injected persistence failure');
      },
    );
    await server.startServer();
    final pairingCode = server.issueLocalPairingCode().code;
    final connection = await _connect(server);
    expect(await connection.messages.next(), {'type': 'auth_required'});

    connection.socket.add(
      jsonEncode({'type': 'authenticate', 'pairing_code': pairingCode}),
    );
    // Persistence failures are intentionally credential-neutral at the
    // public protocol boundary and never produce a bearer token.
    expect(await connection.messages.next(), {
      'type': 'auth_error',
      'code': 'invalid_credentials',
    });
    expect(clearAttempts, 1);
    expect(
      File('${tempDirectory.path}/sessions.json.pending').existsSync(),
      isTrue,
    );
    await connection.close();

    await server.stopServer();
    await server.startServer();
    expect(server.isRunning, isFalse);
    expect(() => server.issueLocalPairingCode(), throwsStateError);
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
      throwsA(isA<SocketException>()),
    );
  });
}

Future<_AuthenticatedConnection> _authenticateWithPairingCode(
  DartServerService server,
  String pairingCode,
) async {
  final connection = await _connect(server);
  expect(await connection.messages.next(), {'type': 'auth_required'});
  connection.socket.add(
    jsonEncode({'type': 'authenticate', 'pairing_code': pairingCode}),
  );
  final success = await connection.messages.next();
  expect(success['type'], 'auth_success');
  final init = await connection.messages.next();
  expect(init['type'], 'init_state');
  return _AuthenticatedConnection(
    connection.socket,
    connection.messages,
    success['token'] as String,
    init,
  );
}

Future<_AuthenticatedConnection> _authenticateWithToken(
  DartServerService server,
  String token,
) async {
  final connection = await _connect(server);
  expect(await connection.messages.next(), {'type': 'auth_required'});
  connection.socket.add(jsonEncode({'type': 'authenticate', 'token': token}));
  final success = await connection.messages.next();
  expect(success['type'], 'auth_success');
  final init = await connection.messages.next();
  expect(init['type'], 'init_state');
  return _AuthenticatedConnection(
    connection.socket,
    connection.messages,
    token,
    init,
  );
}

Future<_Connection> _connect(DartServerService server) async {
  final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
  return _Connection(socket, _MessageReader(socket));
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

class _Connection {
  const _Connection(this.socket, this.messages);

  final WebSocket socket;
  final _MessageReader messages;

  Future<void> close() async {
    await messages.close();
    await socket.close();
  }
}

final class _AuthenticatedConnection extends _Connection {
  const _AuthenticatedConnection(
    super.socket,
    super.messages,
    this.token,
    this.init,
  );

  final String token;
  final Map<String, dynamic> init;
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
