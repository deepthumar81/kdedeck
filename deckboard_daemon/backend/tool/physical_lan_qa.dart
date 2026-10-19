import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/auth_session_manager.dart';
import 'package:backend/dart_server_service.dart';

/// Starts an isolated, disposable LAN-only TLS fixture for physical QA.
///
/// This is not the production daemon entry point. The fixed pairing code is
/// written only to the caller-supplied temporary output directory, and the
/// fixture must never be exposed beyond the controlled test network.
Future<void> main() async {
  final tlsDirectory = Platform.environment['KDEDECK_QA_TLS_DIR'];
  final outputDirectory = Platform.environment['KDEDECK_QA_OUTPUT_DIR'];
  if (tlsDirectory == null || outputDirectory == null) {
    throw const FormatException(
      'KDEDECK_QA_TLS_DIR and KDEDECK_QA_OUTPUT_DIR are required',
    );
  }

  final output = Directory(outputDirectory)..createSync(recursive: true);
  final config = File('${output.path}/config.json');
  await config.writeAsString(
    jsonEncode(<String, dynamic>{
      'config_schema_version': 1,
      'allow_lan': true,
      'boards': [
        {
          'id': 'qa_board',
          'title': 'Physical QA',
          'grid_columns': 1,
          'grid_rows': 1,
          'items': [
            {
              'id': 'qa_button',
              'title': 'QA Ready',
              'action': 'clock_widget',
              'payload': '',
              'icon': 'check_circle',
              'span_cols': 1,
              'span_rows': 1,
            },
          ],
        },
      ],
    }),
    flush: true,
  );

  final server = DartServerService.forTesting(
    port: 8484,
    bindAddress: InternetAddress.anyIPv4,
    configPath: config.path,
    frontendRoot: '../frontend',
    environment: {
      'KDEDECK_TLS_CERT_FILE': '$tlsDirectory/server.crt',
      'KDEDECK_TLS_KEY_FILE': '$tlsDirectory/server.key',
    },
    authSessionManager: AuthSessionManager(
      pairingCode: '123456',
      issueCodeOnCreate: false,
    ),
  );

  await server.startServer();
  if (!server.isRunning || !server.isSecure || server.port != 8484) {
    throw StateError('LAN QA daemon did not start a secure listener');
  }
  await File('${output.path}/pairing.txt').writeAsString('123456', flush: true);
  stdout.writeln('LAN_QA_READY port=${server.port}');
  stdout.flush();

  final stopFile = File('${output.path}/stop');
  while (!stopFile.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await server.stopServer();
}
