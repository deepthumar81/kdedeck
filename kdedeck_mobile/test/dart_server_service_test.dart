import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/services/dart_server_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const token = 'test-pairing-token-0123456789abcdef';
  late StaticPairingTokenSource tokenSource;
  late DartServerService server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tokenSource = StaticPairingTokenSource(const PairingCredential(token));
    server = DartServerService.withDependencies(
      tokenSource: tokenSource,
      bindAddress: InternetAddress.loopbackIPv4,
      trustLoopback: false,
    )..port = 0;
    await server.startServer();
  });

  tearDown(() async {
    await server.stopServer();
  });

  Future<Map<String, dynamic>> nextMessage(
      StreamIterator<dynamic> messages) async {
    expect(await messages.moveNext(), isTrue);
    return jsonDecode(messages.current.toString()) as Map<String, dynamic>;
  }

  test('remote clients receive auth_required before state', () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    addTearDown(socket.close);

    final first =
        jsonDecode((await socket.first).toString()) as Map<String, dynamic>;
    expect(first['type'], 'auth_required');
    expect(first['protocol_version'], 1);
    expect(first['auth_required'], isTrue);
  });

  test('unauthenticated save is rejected, then protocol v1 authenticates',
      () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);

    expect((await nextMessage(messages))['type'], 'auth_required');
    socket.add(jsonEncode({
      'type': 'save_config',
      'config': <String, dynamic>{'boards': <dynamic>[]},
    }));
    expect(
      (await nextMessage(messages))['type'],
      'config_error',
    );

    socket.add(jsonEncode(
        {'type': 'authenticate', 'protocol_version': 1, 'token': token}));
    expect(
      (await nextMessage(messages))['type'],
      'auth_success',
    );
    expect(
      (await nextMessage(messages))['type'],
      'init_state',
    );
    await messages.cancel();
  });

  test('revoked credential prevents later privileged requests', () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);

    await messages.moveNext();
    socket.add(jsonEncode(
        {'type': 'authenticate', 'protocol_version': 1, 'token': token}));
    await messages.moveNext(); // auth_success
    await messages.moveNext(); // init_state

    tokenSource.credential = null;
    socket.add(jsonEncode({
      'type': 'save_config',
      'config': <String, dynamic>{'boards': <dynamic>[]},
    }));
    final response = await nextMessage(messages);
    expect(response['type'], 'config_error');
    expect(response['code'], 'auth_required');
    await messages.cancel();
  });

  test('authentication errors are bounded and do not echo credentials',
      () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);
    await nextMessage(messages);

    for (var attempt = 0; attempt < 5; attempt++) {
      socket.add(jsonEncode({
        'type': 'authenticate',
        'protocol_version': 1,
        'token': 'wrong-token-$attempt',
      }));
      final response = await nextMessage(messages);
      expect(response['type'], 'auth_error');
      expect(response.containsKey('token'), isFalse);
    }
    expect(
        await messages.moveNext().timeout(const Duration(seconds: 2)), isFalse);
    await messages.cancel();
  });
}
