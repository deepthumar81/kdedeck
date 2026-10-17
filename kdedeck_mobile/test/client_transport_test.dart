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

class _Certificates implements CertificateTrustStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String certificatePem) async =>
      values[key] = certificatePem;

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

class _TlsFixture {
  _TlsFixture(this.directory, this.certificatePath, this.keyPath);

  final Directory directory;
  final String certificatePath;
  final String keyPath;
}

Future<_TlsFixture> _createTlsFixture({
  required String subjectAltName,
  bool expired = false,
}) async {
  final directory =
      await Directory.systemTemp.createTemp('kdedeck-client-tls-');
  final certificate = '${directory.path}/fixture.crt';
  final key = '${directory.path}/fixture.key';
  try {
    if (!expired) {
      final result = await Process.run('openssl', [
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
        'subjectAltName=$subjectAltName',
        '-keyout',
        key,
        '-out',
        certificate,
      ]);
      if (result.exitCode != 0) {
        throw StateError('OpenSSL certificate fixture generation failed');
      }
    } else {
      final csr = '${directory.path}/fixture.csr';
      final config = '${directory.path}/openssl.cnf';
      final database = '${directory.path}/index.txt';
      final newCertificates = '${directory.path}/newcerts';
      final serial = '${directory.path}/serial';
      await File(config).writeAsString('''
[ca]
default_ca = CA_default
[CA_default]
database = $database
new_certs_dir = $newCertificates
serial = $serial
default_md = sha256
policy = policy_any
copy_extensions = copy
[policy_any]
commonName = supplied
''');
      await File(database).writeAsString('');
      await Directory(newCertificates).create();
      await File(serial).writeAsString('01\n');
      final request = await Process.run('openssl', [
        'req',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=$subjectAltName',
        '-keyout',
        key,
        '-out',
        csr,
      ]);
      if (request.exitCode != 0) {
        throw StateError('OpenSSL certificate request failed');
      }
      final signing = await Process.run('openssl', [
        'ca',
        '-selfsign',
        '-batch',
        '-config',
        config,
        '-in',
        csr,
        '-keyfile',
        key,
        '-startdate',
        '20000101000000Z',
        '-enddate',
        '20000102000000Z',
        '-out',
        certificate,
        '-notext',
      ]);
      if (signing.exitCode != 0) {
        throw StateError('OpenSSL expired certificate generation failed');
      }
    }
    return _TlsFixture(directory, certificate, key);
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
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
    final fixture = await _createTlsFixture(
      subjectAltName: 'DNS:localhost,IP:127.0.0.1',
    );
    addTearDown(() => fixture.directory.delete(recursive: true));
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(fixture.certificatePath)
      ..usePrivateKey(fixture.keyPath);
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

  test('verified self-signed WSS certificate reaches auth', () async {
    final fixture = await _createTlsFixture(subjectAltName: 'DNS:localhost');
    addTearDown(() => fixture.directory.delete(recursive: true));
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(fixture.certificatePath)
      ..usePrivateKey(fixture.keyPath);
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(jsonEncode({'type': 'auth_required'}));
    });
    final credentials = _Credentials();
    final certificates = _Certificates();
    final client = WebSocketService(
      autoConnect: false,
      manageWakelock: false,
      credentialStore: credentials,
      certificateTrustStore: certificates,
    )
      ..serverIp = 'localhost'
      ..serverPort = server.port
      ..secureConnection = true;
    addTearDown(() async {
      client.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    await client
        .trustServerCertificate(await File(fixture.certificatePath).readAsString());
    client.connect();
    await _until(() => client.authRequired);
    expect(client.authError, isNull);
    expect(credentials.values, isEmpty);

    final mismatchedCredentials = _Credentials();
    final mismatched = WebSocketService(
      autoConnect: false,
      manageWakelock: false,
      credentialStore: mismatchedCredentials,
      certificateTrustStore: certificates,
    )
      ..serverIp = '127.0.0.1'
      ..serverPort = server.port
      ..secureConnection = true;
    addTearDown(mismatched.dispose);
    await mismatched.trustServerCertificate(
        await File(fixture.certificatePath).readAsString());
    mismatched.connect();
    await _until(() => mismatched.authError == 'connection_failed');
    expect(mismatched.authRequired, isFalse);
    expect(mismatchedCredentials.reads, 0);
    expect(mismatchedCredentials.values, isEmpty);
  });

  test('expired trusted certificate fails TLS before authentication', () async {
    final fixture = await _createTlsFixture(
      subjectAltName: 'DNS:localhost',
      expired: true,
    );
    addTearDown(() => fixture.directory.delete(recursive: true));
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(fixture.certificatePath)
      ..usePrivateKey(fixture.keyPath);
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.close();
    });
    final credentials = _Credentials();
    final certificates = _Certificates();
    final client = WebSocketService(
      autoConnect: false,
      manageWakelock: false,
      credentialStore: credentials,
      certificateTrustStore: certificates,
    )
      ..serverIp = 'localhost'
      ..serverPort = server.port
      ..secureConnection = true;
    addTearDown(() async {
      client.dispose();
      await server.close(force: true);
    });
    await client.trustServerCertificate(
        await File(fixture.certificatePath).readAsString());

    client.connect();
    await _until(() => client.authError == 'connection_failed');

    expect(client.isConnected, isFalse);
    expect(client.authenticated, isFalse);
    expect(requests, 0);
    expect(credentials.reads, 0);
    expect(credentials.values, isEmpty);
  });
}
