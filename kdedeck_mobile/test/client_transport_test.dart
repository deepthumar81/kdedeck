import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/services/credential_store.dart';
import 'package:kdedeck_mobile/services/websocket_service.dart';

class _Credentials implements CredentialStore {
  final values = <String, String>{};
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Client outcome timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('real connector pairs, saves with revision, and reconnects with bearer',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final received = <Map<String, dynamic>>[];
    final credentials = _Credentials();
    final client = WebSocketService(
      autoConnect: false,
      manageWakelock: false,
      credentialStore: credentials,
    )
      ..serverIp = '127.0.0.1'
      ..serverPort = server.port;
    addTearDown(() async {
      client.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(jsonEncode({'type': 'auth_required'}));
      socket.listen((raw) {
        final message = Map<String, dynamic>.from(jsonDecode(raw as String));
        received.add(message);
        if (message['type'] == 'authenticate') {
          expect(message['protocol_version'], 1);
          expect(
              message['pairing_code'] == 'fixture-code' ||
                  message['token'] == 'fixture-bearer',
              isTrue);
          socket.add(jsonEncode({
            'type': 'auth_success',
            'token': 'fixture-bearer',
            'role': 'configAdmin',
          }));
          socket.add(jsonEncode({
            'type': 'init_state',
            'protocol_version': 1,
            'config': {'boards': []},
            'revision': 3,
          }));
        } else if (message['type'] == 'save_config') {
          socket.add(jsonEncode({
            'type': 'config_updated',
            'config': message['config'],
            'revision': 4,
          }));
        }
      });
    });
    client.connect();
    await _until(() => client.authRequired);
    expect(received, isEmpty);
    await client.pairWithCode('fixture-code');
    await _until(() => client.isConnected);
    expect(credentials.values.values, ['fixture-bearer']);
    client.sendSaveConfig({'boards': []});
    await _until(() => client.configRevision == 4);
    expect(received.last['revision'], 3);
    client.connect();
    await _until(() => client.isConnected);
    expect(received.last['token'], 'fixture-bearer');
    expect(received.last.containsKey('pairing_code'), isFalse);
  });

  test('default WSS connector rejects an untrusted certificate before auth',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('kdedeck-client-tls-');
    addTearDown(() => directory.delete(recursive: true));
    final certificate = '${directory.path}/fixture.crt';
    final key = '${directory.path}/fixture.key';
    final process = await Process.start('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1',
      '-keyout',
      key,
      '-out',
      certificate,
    ]);
    final stdout = process.stdout.drain<void>();
    final stderr = process.stderr.drain<void>();
    try {
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      await Future.wait([stdout, stderr]);
    } finally {
      process.kill();
      await process.exitCode;
    }
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(certificate)
      ..usePrivateKey(key);
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.close();
    });
    final credentials = _Credentials();
    final client = WebSocketService(
      autoConnect: false,
      manageWakelock: false,
      credentialStore: credentials,
    )
      ..serverIp = '127.0.0.1'
      ..serverPort = server.port
      ..secureConnection = true;
    addTearDown(() async {
      client.dispose();
      await server.close(force: true);
    });
    client.connect();
    await _until(() => client.authError == 'connection_failed');
    expect(client.isConnected, isFalse);
    expect(client.authenticated, isFalse);
    expect(requests, 0);
    expect(credentials.reads, 0);
    expect(credentials.values, isEmpty);
  });
}
