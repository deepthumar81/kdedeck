import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:provider/provider.dart';
import 'services/websocket_service.dart';
import 'ui/ios26_glass_deck.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable Permanent Screen WakeLock (Screen stays awake on desk)
  await WakelockPlus.enable();

  // Enable True Fullscreen Immersive Mode (Hide Android status & nav bars)
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Lock orientation to Landscape & Portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);

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
    return MaterialApp(
      title: 'KDE DECK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F17),
        cardColor: const Color(0x1AFFFFFF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF22C55E),
          surface: Color(0xFF0F172A),
        ),
      ),
      home: const Ios26GlassDeckScreen(),
    );
  }
}
