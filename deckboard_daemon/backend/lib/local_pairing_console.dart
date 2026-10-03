import 'dart:io';

import 'dart_server_service.dart';

/// Local interactive pairing only. The secret callback must write directly to
/// the user's terminal, not to a logger or a captured/redirected output stream.
final class LocalPairingConsole {
  LocalPairingConsole({
    required bool Function() inputHasTerminal,
    required bool Function() outputHasTerminal,
    required void Function(String) writeSecretToTerminal,
    required void Function(String) writeError,
  }) : _inputHasTerminal = inputHasTerminal,
       _outputHasTerminal = outputHasTerminal,
       _writeSecretToTerminal = writeSecretToTerminal,
       _writeError = writeError;

  factory LocalPairingConsole.system() => LocalPairingConsole(
    inputHasTerminal: () => stdin.hasTerminal,
    outputHasTerminal: () => stdout.hasTerminal,
    writeSecretToTerminal: stdout.write,
    writeError: stderr.writeln,
  );

  final bool Function() _inputHasTerminal;
  final bool Function() _outputHasTerminal;
  final void Function(String) _writeSecretToTerminal;
  final void Function(String) _writeError;

  bool get hasInteractiveTerminal =>
      _inputHasTerminal() && _outputHasTerminal();

  /// Checks both streams before invoking [issueCode]. Nothing secret is issued
  /// or written when either side is piped or redirected.
  bool issueCode(({String code, DateTime expiresAt}) Function() issueCode) {
    if (!hasInteractiveTerminal) {
      _writeError('Pairing requires an interactive stdin and stdout terminal.');
      return false;
    }
    try {
      final issued = issueCode();
      _writeSecretToTerminal(
        '\nManager pairing code: ${issued.code}\n'
        'Expires at ${issued.expiresAt.toLocal().toIso8601String()} '
        '(one use only). Type pair and Enter here to issue a new code.\n',
      );
      return true;
    } catch (_) {
      _writeError('Could not issue or display a pairing code.');
      return false;
    }
  }

  bool handleLine(String line, DartServerService server) {
    if (line.trim() != 'pair') return false;
    return issueCode(server.issueLocalPairingCode);
  }
}

/// Starts once and returns a bounded exit status, without keeping failed
/// startups alive. Used by the daemon entry point and isolated CLI tests.
Future<int> startLocalDaemon(
  List<String> arguments, {
  required Future<void> Function() startServer,
  required Future<void> Function() stopServer,
  required bool Function() isRunning,
  required ({String code, DateTime expiresAt}) Function() issueCode,
  required LocalPairingConsole console,
  required void Function(String) writeError,
}) async {
  if (arguments.isNotEmpty &&
      !(arguments.length == 1 && arguments.single == '--pair')) {
    writeError('Usage: backend [--pair]');
    return 2;
  }
  final pairOnStart = arguments.isNotEmpty;
  if (pairOnStart && !console.hasInteractiveTerminal) {
    writeError('Pairing requires an interactive stdin and stdout terminal.');
    return 2;
  }
  try {
    await startServer();
  } catch (_) {
    if (isRunning()) {
      try {
        await stopServer();
      } catch (_) {
        // Keep startup failures bounded even if cleanup also fails.
      }
    }
    writeError('Server failed to start.');
    return 1;
  }
  if (!isRunning()) {
    writeError('Server failed to start.');
    return 1;
  }
  if (pairOnStart && !console.issueCode(issueCode)) {
    try {
      await stopServer();
    } catch (_) {
      // The failure has already been reported without secret details.
    }
    return 1;
  }
  return 0;
}
