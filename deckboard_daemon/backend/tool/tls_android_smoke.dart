import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/dart_server_service.dart';

const _timeout = Duration(seconds: 10);

Future<void> main() async {
  Directory? temporary;
  DartServerService? server;
  var reversePort = 0;
  var reverseConfigured = false;
  String? reverseDevice;

  try {
    temporary = await Directory.systemTemp.createTemp('kdedeck-tls-smoke-');
    final certificate = File('${temporary.path}/server.crt');
    final privateKey = File('${temporary.path}/server.key');
    await _generateCertificate(certificate, privateKey);
    await File('${temporary.path}/config.json').writeAsString(
      jsonEncode(<String, dynamic>{'boards': <dynamic>[]}),
      flush: true,
    );

    server = DartServerService.forTesting(
      port: 0,
      bindAddress: InternetAddress.anyIPv4,
      configPath: '${temporary.path}/config.json',
      environment: {
        'KDEDECK_TLS_CERT_FILE': certificate.path,
        'KDEDECK_TLS_KEY_FILE': privateKey.path,
      },
      authSessionManager: AuthSessionManager(issueCodeOnCreate: false),
    );
    await server.startServer().timeout(_timeout);
    if (!server.isRunning || !server.isSecure || server.port == 0) {
      throw const FormatException('daemon did not start a secure listener');
    }
    reversePort = server.port;
    reverseDevice = await _configureAdbReverse(reversePort);
    reverseConfigured = reverseDevice != null;

    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certificate.path);
    final client = HttpClient(context: trust);
    try {
      final socket = await WebSocket.connect(
        'wss://127.0.0.1:${server.port}/ws',
        customClient: client,
      ).timeout(_timeout);
      final messages = StreamIterator<dynamic>(socket);
      try {
        _expectType(await _next(messages), 'auth_required');
        final pairing = server.issueLocalPairingCode();
        socket.add(
          jsonEncode(<String, dynamic>{
            'type': 'authenticate',
            'protocol_version': 1,
            'pairing_code': pairing.code,
          }),
        );
        _expectType(await _next(messages), 'auth_success');
        _expectType(await _next(messages), 'init_state');
      } finally {
        await messages.cancel().timeout(_timeout);
        await socket.close().timeout(_timeout);
      }
    } finally {
      client.close(force: true);
    }

    stdout.writeln(
      reverseConfigured
          ? 'TLS daemon smoke: PASS (ADB reverse configured)'
          : 'TLS daemon smoke: PASS (no authorized ADB device)',
    );
  } catch (_) {
    stderr.writeln('TLS daemon smoke: FAIL');
    exitCode = 1;
  } finally {
    if (reverseConfigured && reversePort != 0) {
      await _removeAdbReverse(reverseDevice!, reversePort);
    }
    await server?.stopServer().timeout(_timeout);
    if (temporary != null) {
      await temporary.delete(recursive: true);
    }
  }
}

Future<void> _generateCertificate(File certificate, File privateKey) async {
  final result = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-sha256',
    '-days',
    '1',
    '-nodes',
    '-subj',
    '/CN=127.0.0.1',
    '-addext',
    'subjectAltName=IP:127.0.0.1,DNS:localhost',
    '-keyout',
    privateKey.path,
    '-out',
    certificate.path,
  ]).timeout(_timeout);
  if (result.exitCode != 0) {
    throw StateError('OpenSSL certificate generation failed');
  }
}

Future<String?> _configureAdbReverse(int port) async {
  if (!await _commandAvailable('adb')) return null;
  final devices = await Process.run('adb', ['devices']).timeout(_timeout);
  if (devices.exitCode != 0) return null;
  final device = _authorizedDeviceId(devices.stdout);
  if (device == null) return null;
  final reverse = await Process.run('adb', [
    '-s',
    device,
    'reverse',
    'tcp:$port',
    'tcp:$port',
  ]).timeout(_timeout);
  if (reverse.exitCode != 0) {
    throw StateError('ADB reverse setup failed');
  }
  return device;
}

Future<void> _removeAdbReverse(String device, int port) async {
  try {
    await Process.run('adb', [
      '-s',
      device,
      'reverse',
      '--remove',
      'tcp:$port',
    ]).timeout(_timeout);
  } catch (_) {
    // Cleanup is best effort; the daemon and temporary files are still closed.
  }
}

Future<bool> _commandAvailable(String command) async {
  try {
    final result = await Process.run(command, ['version']).timeout(_timeout);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String? _authorizedDeviceId(Object? output) {
  final lines = output.toString().split(RegExp(r'\r?\n'));
  for (final line in lines) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length >= 2 && fields[1] == 'device') return fields[0];
  }
  return null;
}

Future<Map<String, dynamic>> _next(StreamIterator<dynamic> messages) async {
  if (!await messages.moveNext().timeout(_timeout)) {
    throw StateError('daemon closed the WebSocket');
  }
  final decoded = jsonDecode(messages.current as String);
  if (decoded is! Map) throw const FormatException('invalid daemon response');
  return Map<String, dynamic>.from(decoded);
}

void _expectType(Map<String, dynamic> message, String type) {
  if (message['type'] != type) {
    throw const FormatException('unexpected daemon response');
  }
}
