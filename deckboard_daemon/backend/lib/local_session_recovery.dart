import 'dart:io';

import 'session_store.dart';

/// Offline-only local recovery. No store is constructed or accessed unless
/// both streams are terminals and the operator types the exact confirmation.
int resetLocalSessions({
  required bool Function() inputHasTerminal,
  required bool Function() outputHasTerminal,
  required String? Function() readLine,
  required void Function(String) writeLine,
  required FileSessionStore Function() createStore,
}) {
  try {
    if (!inputHasTerminal() || !outputHasTerminal()) {
      writeLine('Reset requires an interactive stdin and stdout terminal.');
      return 2;
    }
    writeLine(
      'The daemon MUST be stopped before resetting sessions. '
      'All stored sessions will be invalidated and every device must re-pair.',
    );
    writeLine('Type RESET exactly to confirm:');
    if (readLine() != 'RESET') {
      writeLine('Session reset cancelled.');
      return 1;
    }
    final store = createStore();
    try {
      store.resetSessions();
    } finally {
      store.close();
    }
    writeLine('Stored sessions reset. Re-pair all devices before use.');
    return 0;
  } catch (_) {
    // Never include a filesystem path, environment setting, or credential.
    writeLine(
      'Session reset failed. The daemon must remain stopped until recovery succeeds.',
    );
    return 1;
  }
}

int resetLocalSessionsFromTerminal() => resetLocalSessions(
  inputHasTerminal: () => stdin.hasTerminal,
  outputHasTerminal: () => stdout.hasTerminal,
  readLine: stdin.readLineSync,
  writeLine: stdout.writeln,
  createStore: FileSessionStore.inUserConfigDirectory,
);
