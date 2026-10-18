import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/dart_server_service.dart';
import 'package:backend/enrollment_protocol.dart';
import 'package:backend/mdns_service_advertiser.dart';
import 'package:test/test.dart';

const _deadline = Duration(seconds: 5);

void main() {
  late Directory temp;
  DartServerService? server;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kdedeck-tls-test-');
  });

  tearDown(() async {
    await server?.stopServer().timeout(_deadline);
    await temp.delete(recursive: true);
  });

  test('LAN requires TLS even with an injected non-loopback address', () async {
    final advertiser = _RecordingAdvertiser();
    server = _server(
      temp,
      address: InternetAddress.anyIPv4,
      mdnsAdvertiser: advertiser,
    );
    await server!.startServer().timeout(_deadline);
    expect(server!.bindAddress, InternetAddress.anyIPv4);
    expect(server!.isRunning, isFalse);
    expect(server!.isSecure, isFalse);
    expect(server!.port, 0);
    expect(advertiser.startedPorts, isEmpty);
  });

  test('partial, empty, missing, and malformed TLS never downgrade', () async {
    final cert = File('${temp.path}/missing.crt').path;
    final key = File('${temp.path}/missing.key').path;
    for (final environment in [
      {'KDEDECK_TLS_CERT_FILE': cert},
      {'KDEDECK_TLS_KEY_FILE': key},
      {'KDEDECK_TLS_CERT_FILE': '', 'KDEDECK_TLS_KEY_FILE': key},
      {'KDEDECK_TLS_CERT_FILE': cert, 'KDEDECK_TLS_KEY_FILE': key},
    ]) {
      for (final address in [
        InternetAddress.loopbackIPv4,
        InternetAddress.anyIPv4,
      ]) {
        server = _server(temp, address: address, environment: environment);
        await server!.startServer().timeout(_deadline);
        expect(server!.isRunning, isFalse);
        expect(server!.isSecure, isFalse);
        expect(server!.port, 0);
        await server!.stopServer().timeout(_deadline);
      }
    }
    await File(cert).writeAsString('not a certificate');
    await File(key).writeAsString('not a key');
    server = _server(
      temp,
      environment: {'KDEDECK_TLS_CERT_FILE': cert, 'KDEDECK_TLS_KEY_FILE': key},
    );
    await server!.startServer().timeout(_deadline);
    expect(server!.isRunning, isFalse);
  });

  test('loopback with no explicit TLS accepts plaintext', () async {
    final advertiser = _RecordingAdvertiser();
    server = _server(temp, mdnsAdvertiser: advertiser);
    await server!.startServer().timeout(_deadline);
    expect(server!.isRunning, isTrue);
    expect(server!.isSecure, isFalse);
    expect(advertiser.startedPorts, isEmpty);
    final socket = await WebSocket.connect('ws://127.0.0.1:${server!.port}/ws')
        .timeout(_deadline);
    final messages = StreamIterator<dynamic>(socket);
    expect(await messages.moveNext().timeout(_deadline), isTrue);
    expect(jsonDecode(messages.current as String), {'type': 'auth_required'});
    await messages.cancel().timeout(_deadline);
    await socket.close().timeout(_deadline);
  });

  test('explicit valid TLS secures loopback too', () async {
    final files = await _generateCertificate(temp);
    server = _server(
      temp,
      environment: {
        'KDEDECK_TLS_CERT_FILE': files.$1,
        'KDEDECK_TLS_KEY_FILE': files.$2,
      },
    );
    await server!.startServer().timeout(_deadline);
    expect(server!.bindAddress.isLoopback, isTrue);
    expect(server!.isRunning, isTrue);
    expect(server!.isSecure, isTrue);
  });

  test(
    'secure enrollment binds endpoint, rejects bad payloads, and replays once',
    () async {
      final files = await _generateCertificate(temp);
      final certificatePem = await File(files.$1).readAsString();
      final fingerprint = certificateSha256FromPem(certificatePem);
      server = DartServerService.forTesting(
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        configPath: '${temp.path}/config.json',
        environment: {
          'KDEDECK_TLS_CERT_FILE': files.$1,
          'KDEDECK_TLS_KEY_FILE': files.$2,
        },
        authSessionManager: AuthSessionManager(issueCodeOnCreate: false),
        enrollmentCertificateSha256: fingerprint,
      );
      await server!.startServer().timeout(_deadline);

      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(files.$1);
      final http = HttpClient(context: trust);
      final wsClient = HttpClient(context: trust);
      try {
        final request = await http.getUrl(
          Uri.parse('https://localhost:${server!.port}/enrollment'),
        );
        final response = await request.close().timeout(_deadline);
        final payload = Map<String, dynamic>.from(
          jsonDecode(await response.transform(utf8.decoder).join()) as Map,
        );
        expect(payload['scheme'], 'https');
        expect(payload['host'], 'localhost');
        expect(payload['certificate_sha256'], fingerprint);

        final malformed = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: HttpClient(context: trust),
        );
        final malformedMessages = StreamIterator<dynamic>(malformed);
        expect(await _next(malformedMessages), {'type': 'auth_required'});
        malformed.add(
          jsonEncode({
            'type': 'authenticate',
            'protocol_version': 1,
            'enrollment': {'version': 1},
          }),
        );
        expect(await _next(malformedMessages), {
          'type': 'auth_error',
          'code': 'invalid_credentials',
        });
        await malformedMessages.cancel();
        await malformed.close();

        final expired = Map<String, dynamic>.of(payload)
          ..['expires_at'] = DateTime.now()
              .toUtc()
              .subtract(const Duration(seconds: 1))
              .toIso8601String();
        final expiredSocket = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: HttpClient(context: trust),
        );
        final expiredMessages = StreamIterator<dynamic>(expiredSocket);
        expect(await _next(expiredMessages), {'type': 'auth_required'});
        expiredSocket.add(
          jsonEncode({
            'type': 'authenticate',
            'protocol_version': 1,
            'enrollment': expired,
          }),
        );
        expect(await _next(expiredMessages), {
          'type': 'auth_error',
          'code': 'expired',
        });
        await expiredMessages.cancel();
        await expiredSocket.close();

        final wrongEndpoint = Map<String, dynamic>.of(payload)
          ..['port'] = server!.port + 1;
        final wrongSocket = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: HttpClient(context: trust),
        );
        final wrongMessages = StreamIterator<dynamic>(wrongSocket);
        expect(await _next(wrongMessages), {'type': 'auth_required'});
        wrongSocket.add(
          jsonEncode({
            'type': 'authenticate',
            'protocol_version': 1,
            'enrollment': wrongEndpoint,
          }),
        );
        expect(await _next(wrongMessages), {
          'type': 'auth_error',
          'code': 'invalid_credentials',
        });
        await wrongMessages.cancel();
        await wrongSocket.close();

        final socket = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: wsClient,
        );
        final messages = StreamIterator<dynamic>(socket);
        expect(await _next(messages), {'type': 'auth_required'});
        socket.add(
          jsonEncode({
            'type': 'authenticate',
            'protocol_version': 1,
            'enrollment': payload,
          }),
        );
        final success = await _next(messages);
        expect(success['type'], 'auth_success');
        expect(success['token'], isA<String>());
        expect((await _next(messages))['type'], 'init_state');
        await messages.cancel();
        await socket.close();

        final replay = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: HttpClient(context: trust),
        );
        final replayMessages = StreamIterator<dynamic>(replay);
        expect(await _next(replayMessages), {'type': 'auth_required'});
        replay.add(
          jsonEncode({
            'type': 'authenticate',
            'protocol_version': 1,
            'enrollment': payload,
          }),
        );
        expect(await _next(replayMessages), {
          'type': 'auth_error',
          'code': 'invalid_credentials',
        });
        await replayMessages.cancel();
        await replay.close();
      } finally {
        http.close(force: true);
        wsClient.close(force: true);
      }
    },
  );

  test('config-selected LAN starts only with valid TLS', () async {
    final files = await _generateCertificate(temp);
    final advertiser = _RecordingAdvertiser();
    await File('${temp.path}/config.json')
        .writeAsString(jsonEncode({'boards': <Object>[], 'allow_lan': true}));
    server = _server(
      temp,
      environment: {
        'KDEDECK_TLS_CERT_FILE': files.$1,
        'KDEDECK_TLS_KEY_FILE': files.$2,
      },
      mdnsAdvertiser: advertiser,
    );
    await server!.startServer().timeout(_deadline);
    expect(server!.bindAddress, InternetAddress.anyIPv4);
    expect(server!.isRunning, isTrue);
    expect(server!.isSecure, isTrue);
    if (Platform.isLinux) {
      expect(advertiser.startedPorts, [server!.port]);
    } else {
      expect(advertiser.startedPorts, isEmpty);
    }
    await server!.stopServer().timeout(_deadline);
    expect(advertiser.stopCount, Platform.isLinux ? 1 : 0);
  });

  test('certificate/key mismatch refuses startup', () async {
    final first = await _generateCertificate(temp);
    final secondDir = await Directory('${temp.path}/second').create();
    final second = await _generateCertificate(secondDir);
    server = _server(
      temp,
      address: InternetAddress.anyIPv4,
      environment: {
        'KDEDECK_TLS_CERT_FILE': first.$1,
        'KDEDECK_TLS_KEY_FILE': second.$2,
      },
    );
    await server!.startServer().timeout(_deadline);
    expect(server!.isRunning, isFalse);
    expect(server!.isSecure, isFalse);
    expect(server!.port, 0);
  });

  test(
    'HTTPS and WSS require trust and retain WebSocket authentication',
    () async {
      final files = await _generateCertificate(temp);
      server = _server(
        temp,
        address: InternetAddress.anyIPv4,
        environment: {
          'KDEDECK_TLS_CERT_FILE': files.$1,
          'KDEDECK_TLS_KEY_FILE': files.$2,
        },
      );
      await server!.startServer().timeout(_deadline);
      expect(server!.isRunning, isTrue);
      expect(server!.isSecure, isTrue);

      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(files.$1);
      final trustedHttp = HttpClient(context: trust);
      final untrustedHttp = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      );
      final plainHttp = HttpClient();
      try {
        final response =
            await (await trustedHttp
                    .getUrl(
                      Uri.parse('https://localhost:${server!.port}/not-found'),
                    )
                    .timeout(_deadline))
                .close()
                .timeout(_deadline);
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>().timeout(_deadline);

        await expectLater(
          untrustedHttp
              .getUrl(Uri.parse('https://localhost:${server!.port}/'))
              .then((request) => request.close())
              .timeout(_deadline),
          throwsA(isA<HandshakeException>()),
        );
        final untrustedWebSocketClient = HttpClient(
          context: SecurityContext(withTrustedRoots: false),
        );
        try {
          await expectLater(
            WebSocket.connect(
              'wss://localhost:${server!.port}/ws',
              customClient: untrustedWebSocketClient,
            ).timeout(_deadline),
            throwsA(isA<HandshakeException>()),
          );
        } finally {
          untrustedWebSocketClient.close(force: true);
        }
        await expectLater(
          plainHttp
              .getUrl(Uri.parse('http://127.0.0.1:${server!.port}/'))
              .then((request) => request.close())
              .timeout(_deadline),
          throwsA(anything),
        );
        await expectLater(
          WebSocket.connect('ws://127.0.0.1:${server!.port}/ws')
              .timeout(_deadline),
          throwsA(anything),
        );

        final socket = await WebSocket.connect(
          'wss://localhost:${server!.port}/ws',
          customClient: HttpClient(context: trust),
        ).timeout(_deadline);
        final messages = StreamIterator<dynamic>(socket);
        try {
          expect(await _next(messages), {'type': 'auth_required'});
          socket.add(jsonEncode({'type': 'get_system_apps'}));
          expect(await _next(messages), {
            'type': 'auth_error',
            'code': 'authentication_required',
          });
          socket.add(
            jsonEncode({
              'type': 'authenticate',
              'pairing_code': 'pairing-code',
            }),
          );
          expect((await _next(messages))['type'], 'auth_success');
          expect((await _next(messages))['type'], 'init_state');
        } finally {
          await messages.cancel().timeout(_deadline);
          await socket.close().timeout(_deadline);
        }
      } finally {
        trustedHttp.close(force: true);
        untrustedHttp.close(force: true);
        plainHttp.close(force: true);
      }

      await server!.stopServer().timeout(_deadline);
      expect(server!.isSecure, isFalse);
      await File(files.$1).delete();
      await server!.startServer().timeout(_deadline);
      expect(server!.isRunning, isFalse);
      expect(server!.isSecure, isFalse);
    },
  );
}

DartServerService _server(
  Directory temp, {
  InternetAddress? address,
  Map<String, String> environment = const {},
  MdnsAdvertiser? mdnsAdvertiser,
}) => DartServerService.forTesting(
  port: 0,
  bindAddress: address,
  configPath: '${temp.path}/config.json',
  environment: environment,
  authSessionManager: AuthSessionManager(pairingCode: 'pairing-code'),
  mdnsAdvertiser: mdnsAdvertiser,
);

final class _RecordingAdvertiser implements MdnsAdvertiser {
  final List<int> startedPorts = <int>[];
  int stopCount = 0;

  @override
  Future<void> start({required int port}) async => startedPorts.add(port);

  @override
  Future<void> stop() async => stopCount++;
}

Future<Map<String, dynamic>> _next(StreamIterator<dynamic> messages) async {
  expect(await messages.moveNext().timeout(_deadline), isTrue);
  return Map<String, dynamic>.from(jsonDecode(messages.current as String));
}

Future<(String, String)> _generateCertificate(Directory temp) async {
  final certificate = '${temp.path}/server.crt';
  final key = '${temp.path}/server.key';
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
  ]).timeout(_deadline);
  // Drain both streams so openssl cannot block on its progress output.
  final output = process.stdout.drain<void>();
  final errors = process.stderr.drain<void>();
  try {
    expect(await process.exitCode.timeout(_deadline), 0);
    await Future.wait([output, errors]).timeout(_deadline);
  } finally {
    process.kill();
  }
  return (certificate, key);
}
