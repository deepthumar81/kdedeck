import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/dart_server_service.dart';
import 'package:backend/local_pairing_console.dart';

Future<void> main(List<String> arguments) async {
  final console = LocalPairingConsole.system();
  DartServerService? server;
  final status = await startLocalDaemon(
    arguments,
    startServer: () async {
      server = DartServerService();
      await server!.startServer();
    },
    stopServer: () => server!.stopServer(),
    isRunning: () => server?.isRunning ?? false,
    issueCode: () => server!.issueLocalPairingCode(),
    console: console,
    writeError: stderr.writeln,
  );
  if (status != 0) {
    exitCode = status;
    return;
  }

  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    await server!.stopServer();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
  }

  if (console.hasInteractiveTerminal) {
    stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => console.handleLine(line, server!),
          onError: (_) => stderr.writeln('Terminal input unavailable.'),
        );
  }
}
