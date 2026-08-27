import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:provider/provider.dart';
import 'services/websocket_service.dart';
import 'services/dart_server_service.dart';
import 'ui/neumorphic_deck.dart';
import 'ui/desktop_configurator.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable Screen WakeLock on Mobile devices
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await WakelockPlus.enable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } else if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    await windowManager.ensureInitialized();
    
    // Launch embedded native Dart WebSocket Server on Desktop!
    await DartServerService().startServer();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(900, 600),
      minimumSize: Size(900, 600),
      center: true,
      title: "KDE Deck Configurator",
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => WebSocketService(),
      child: const KdeDeckApp(),
    ),
  );
}

class KdeDeckApp extends StatelessWidget {
  const KdeDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Detect target platform (PC Desktop Parent vs Mobile Phone Child)
    final bool isDesktop = !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

    return MaterialApp(
      title: 'KDE DECK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF0F172A),
        ),
      ),
      home: isDesktop ? const DesktopConfiguratorScreen() : const NeumorphicDeckScreen(),
    );
  }
}
