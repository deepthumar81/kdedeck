import 'dart:io';

import 'package:backend/session_store.dart';

void main(List<String> args) {
  final store = FileSessionStore(args[0]);
  try {
    switch (args[1]) {
      case 'read':
        store.read(maxSessions: 100);
      case 'write':
        store.write(const [], maxSessions: 100);
      case 'reset':
        store.resetSessions();
      case 'hold':
        store.read(maxSessions: 100);
        stdout.writeln('ready');
        stdin.readLineSync();
    }
    if (args[1] != 'hold') stdout.writeln('ok');
  } on SessionStoreException {
    stdout.writeln('busy');
  } finally {
    store.close();
  }
}
