import 'dart:async';
import 'dart:io';
import 'package:backend/dart_server_service.dart';

void main(List<String> arguments) async {
  print('Initializing Deckboard Daemon...');
  final server = DartServerService();
  
  // Handle graceful shutdown
  ProcessSignal.sigint.watch().listen((signal) async {
    print('\nShutting down Deckboard Daemon...');
    await server.stopServer();
    print('Shutdown complete.');
    exit(0);
  });
  
  ProcessSignal.sigterm.watch().listen((signal) async {
    print('\nShutting down Deckboard Daemon...');
    await server.stopServer();
    print('Shutdown complete.');
    exit(0);
  });

  await server.startServer();

  // Keep the script running
  await Completer<void>().future;
}
