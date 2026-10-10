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
  late Directory tlsFixtureDirectory;
  late String certificateFile;
  late String privateKeyFile;
  late String otherPrivateKeyFile;
  late String malformedCertificateFile;

  Future<void> runOpenSsl(List<String> arguments) async {
    final result = await Process.run('openssl', arguments);
    if (result.exitCode != 0) {
      throw StateError('openssl fixture generation failed');
    }
  }

  Future<DartServerService> startServer({
    InternetAddress? bindAddress,
    bool trustLoopback = false,
    Map<String, String>? environment,
  }) async {
    final service = DartServerService.withDependencies(
      tokenSource: tokenSource,
      bindAddress: bindAddress ?? InternetAddress.loopbackIPv4,
      trustLoopback: trustLoopback,
      environment: environment ?? const <String, String>{},
    )..port = 0;
    await service.startServer();
    return service;
  }

  Future<WebSocket> connectTls(int port) async {
    final client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate certificate, String host, int port) => true;
    final socket = await WebSocket.connect(
      'wss://127.0.0.1:$port/ws',
      customClient: client,
    );
    unawaited(socket.done.whenComplete(() => client.close(force: true)));
    return socket;
  }

  Map<String, String> tlsEnvironment({
    String? certificate,
    String? privateKey,
  }) {
    return {
      'KDEDECK_TLS_CERT_FILE': certificate ?? certificateFile,
      'KDEDECK_TLS_KEY_FILE': privateKey ?? privateKeyFile,
    };
  }

  Future<void> expectStartFailure(DartServerService service) async {
    expect(service.isRunning, isFalse);
    expect(service.isSecure, isFalse);
    expect(service.port, 0);
    await service.stopServer();
    await service.stopServer();
  }

  setUpAll(() async {
    tlsFixtureDirectory = await Directory.systemTemp.createTemp('kdedeck-tls-');
    certificateFile = '${tlsFixtureDirectory.path}/server-cert.pem';
    privateKeyFile = '${tlsFixtureDirectory.path}/server-key.pem';
    otherPrivateKeyFile = '${tlsFixtureDirectory.path}/other-key.pem';
    malformedCertificateFile = '${tlsFixtureDirectory.path}/malformed-cert.pem';
    await runOpenSsl([
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-sha256',
      '-days',
      '1',
      '-nodes',
      '-keyout',
      privateKeyFile,
      '-out',
      certificateFile,
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    await runOpenSsl([
      'genrsa',
      '-out',
      otherPrivateKeyFile,
      '2048',
    ]);
    await File(malformedCertificateFile).writeAsString('not a certificate');
  });

  tearDownAll(() async {
    await tlsFixtureDirectory.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tokenSource = StaticPairingTokenSource(const PairingCredential(token));
    server = DartServerService.withDependencies(
      tokenSource: tokenSource,
      bindAddress: InternetAddress.loopbackIPv4,
      trustLoopback: false,
      environment: const <String, String>{},
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

  test('loopback plaintext works and can use the local trusted shortcut',
      () async {
    final localServer = await startServer(trustLoopback: true);
    addTearDown(localServer.stopServer);

    final socket =
        await WebSocket.connect('ws://127.0.0.1:${localServer.port}/ws');
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);
    expect((await nextMessage(messages))['auth_required'], isFalse);
    expect((await nextMessage(messages))['type'], 'init_state');
    expect(localServer.isSecure, isFalse);
    await messages.cancel();
  });

  test('explicit TLS on loopback uses WSS and still requires authentication',
      () async {
    final tlsServer = await startServer(
      trustLoopback: true,
      environment: tlsEnvironment(),
    );
    addTearDown(tlsServer.stopServer);
    expect(tlsServer.isSecure, isTrue);

    final socket = await connectTls(tlsServer.port);
    addTearDown(socket.close);
    final first =
        jsonDecode((await socket.first).toString()) as Map<String, dynamic>;
    expect(first['type'], 'auth_required');
    expect(first['auth_required'], isTrue);
  });

  test('non-loopback bind requires TLS', () async {
    final unconfigured = DartServerService.withDependencies(
      tokenSource: tokenSource,
      environment: const <String, String>{},
    )..port = 0;
    await expectStartFailure(unconfigured);
  });

  test('non-loopback TLS does not trust a loopback peer', () async {
    final tlsServer = await startServer(
      bindAddress: InternetAddress.anyIPv4,
      trustLoopback: true,
      environment: tlsEnvironment(),
    );
    addTearDown(tlsServer.stopServer);

    final socket = await connectTls(tlsServer.port);
    addTearDown(socket.close);
    final first =
        jsonDecode((await socket.first).toString()) as Map<String, dynamic>;
    expect(first['auth_required'], isTrue);
  });

  test('valid TLS remote WSS clients receive an auth challenge', () async {
    final tlsServer = await startServer(
      bindAddress: InternetAddress.anyIPv4,
      environment: tlsEnvironment(),
    );
    addTearDown(tlsServer.stopServer);
    expect(tlsServer.isSecure, isTrue);

    final socket = await connectTls(tlsServer.port);
    addTearDown(socket.close);
    final messages = StreamIterator<dynamic>(socket);
    final first = await nextMessage(messages);
    expect(first['type'], 'auth_required');
    expect(first['auth_required'], isTrue);
    socket.add(jsonEncode({
      'type': 'authenticate',
      'protocol_version': 1,
      'token': token,
    }));
    expect((await nextMessage(messages))['type'], 'auth_success');
    expect((await nextMessage(messages))['type'], 'init_state');
    await messages.cancel();
  });

  test('partial, malformed, and mismatched TLS configurations fail closed',
      () async {
    final partial = await startServer(
      environment: {'KDEDECK_TLS_CERT_FILE': certificateFile},
    );
    await expectStartFailure(partial);

    final keyOnly = await startServer(
      environment: {'KDEDECK_TLS_KEY_FILE': privateKeyFile},
    );
    await expectStartFailure(keyOnly);

    final empty = await startServer(
      environment: tlsEnvironment(privateKey: ''),
    );
    await expectStartFailure(empty);

    final malformed = await startServer(
      environment: tlsEnvironment(
        certificate: '${tlsFixtureDirectory.path}/missing-cert.pem',
        privateKey: '${tlsFixtureDirectory.path}/missing-key.pem',
      ),
    );
    await expectStartFailure(malformed);

    final invalidPem = await startServer(
      environment: tlsEnvironment(certificate: malformedCertificateFile),
    );
    await expectStartFailure(invalidPem);

    final mismatch = await startServer(
      environment: tlsEnvironment(privateKey: otherPrivateKeyFile),
    );
    await expectStartFailure(mismatch);
  });

  test('plaintext WebSocket access fails against a secure listener', () async {
    final tlsServer = await startServer(environment: tlsEnvironment());
    addTearDown(tlsServer.stopServer);
    expect(tlsServer.isSecure, isTrue);

    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${tlsServer.port}/ws')
          .timeout(const Duration(seconds: 3)),
      throwsA(anything),
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      client
          .get('127.0.0.1', tlsServer.port, '/')
          .then((request) => request.close())
          .timeout(const Duration(seconds: 3)),
      throwsA(anything),
    );
  });
}
