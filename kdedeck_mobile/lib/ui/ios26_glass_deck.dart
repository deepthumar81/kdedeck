import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';

class Ios26GlassDeckScreen extends StatefulWidget {
  const Ios26GlassDeckScreen({super.key});

  @override
  State<Ios26GlassDeckScreen> createState() => _Ios26GlassDeckScreenState();
}

class _Ios26GlassDeckScreenState extends State<Ios26GlassDeckScreen> {
  final PageController _pageController = PageController();
  int _activePageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final ws = Provider.of<WebSocketService>(context);
    final config = ws.configData;
    final boards = config?['boards'] as List<dynamic>? ?? [];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top iOS 26 Glass Header Bar
            _buildHeader(ws),

            // Main Deck Body (Left Metrics Panel + Right Button Matrix)
            Expanded(
              child: boards.isEmpty
                  ? _buildConnectingState(ws)
                  : PageView.builder(
                      controller: _pageController,
                      onPageChanged: (idx) {
                        HapticFeedback.lightImpact();
                        setState(() => _activePageIndex = idx);
                      },
                      itemCount: boards.length,
                      itemBuilder: (context, bIdx) {
                        final board = boards[bIdx];
                        return _buildBoardPage(ws, board);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(WebSocketService ws) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0x990F172A),
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.1))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Brand Title
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu_rounded, color: Colors.white),
                onPressed: () => _openDrawer(context, ws),
              ),
              const Text(
                "KDE DECK",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.0),
              ),
            ],
          ),

          // Carousel Page Indicator Dots
          Row(
            children: List.generate(
              (ws.configData?['boards'] as List<dynamic>?)?.length ?? 1,
              (idx) => GestureDetector(
                onTap: () {
                  _pageController.animateToPage(
                    idx,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: idx == _activePageIndex ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: idx == _activePageIndex ? const Color(0xFF22C55E) : Colors.white24,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ws.isConnected ? const Color(0x2622C55E) : const Color(0x26EF4444),
              border: Border.all(
                color: ws.isConnected ? const Color(0x8022C55E) : const Color(0x80EF4444),
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: ws.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  ws.isConnected ? "DECK: Synced" : "Offline",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: ws.isConnected ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoardPage(WebSocketService ws, Map<String, dynamic> board) {
    final showMetrics = ws.configData?['show_metrics'] != false;
    final items = board['items'] as List<dynamic>? ?? [];

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          // Left System Metrics Panel
          if (showMetrics) _buildMetricsSidePanel(ws),
          if (showMetrics) const SizedBox(width: 12),

          // Right Button Grid Matrix
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cols = ws.configData?['grid_columns'] ?? 4;
                final rows = ws.configData?['grid_rows'] ?? 3;
                final totalSlots = cols * rows;

                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: totalSlots,
                  itemBuilder: (context, itemIdx) {
                    if (itemIdx < items.length) {
                      final item = items[itemIdx];
                      return _buildDeckTile(ws, item);
                    } else {
                      return _buildEmptySlot();
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsSidePanel(WebSocketService ws) {
    final m = ws.metrics;
    return Container(
      width: 180,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xBB1E293B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildGaugeCard("CPU", "${m['cpu_temp']}°C", "${m['cpu_load']}% Load", const Color(0xFF22C55E)),
          _buildGaugeCard("GPU", "${m['gpu_temp']}°C", "${m['gpu_load']}% Load", const Color(0xFFF59E0B)),
          _buildGaugeCard("RAM", "${m['ram_percent']}%", "${m['ram_used_gb']}/${m['ram_total_gb']}GB", const Color(0xFF3B82F6)),
        ],
      ),
    );
  }

  Widget _buildGaugeCard(String label, String value, String subtext, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2.5),
            ),
            child: Center(
              child: Text(
                value,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold)),
              Text(subtext, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeckTile(WebSocketService ws, Map<String, dynamic> item) {
    final colorHex = _parseColor(item['color']);

    Widget cardChild = Container(
      decoration: BoxDecoration(
        color: const Color(0xBB1E293B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorHex, width: 2.0),
        boxShadow: [
          BoxShadow(color: colorHex.withOpacity(0.25), blurRadius: 10, spreadRadius: 0),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            HapticFeedback.mediumImpact();
            ws.triggerAction(item['action'], payload: item['payload'], itemId: item['id']);
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_getIconData(item['icon']), size: 28, color: colorHex),
              const SizedBox(height: 6),
              Text(
                item['title'] ?? 'Button',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );

    // Apply BackdropFilter blur if battery saver mode is OFF
    if (!ws.isBatterySaverMode) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: cardChild,
        ),
      );
    }
    return cardChild;
  }

  Widget _buildEmptySlot() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10, width: 1.5),
      ),
      child: const Center(
        child: Icon(Icons.add_rounded, color: Colors.white12, size: 24),
      ),
    );
  }

  Widget _buildConnectingState(WebSocketService ws) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Color(0xFF22C55E)),
          const SizedBox(height: 16),
          Text(
            "Connecting to PC Daemon at ${ws.serverIp}:${ws.serverPort}...",
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  void _openDrawer(BuildContext context, WebSocketService ws) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("SETTINGS & BATTERY SAVER", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white12, height: 24),

              SwitchListTile(
                title: const Text("Battery Saver Mode"),
                subtitle: const Text("Disables GPU backdrop glass blur to save battery"),
                value: ws.isBatterySaverMode,
                onChanged: (val) {
                  ws.toggleBatterySaver(val);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Color _parseColor(String? colorStr) {
    switch (colorStr) {
      case 'neon-green': return const Color(0xFF22C55E);
      case 'neon-blue': return const Color(0xFF3B82F6);
      case 'neon-cyan': return const Color(0xFF06B6D4);
      case 'neon-purple': return const Color(0xFFA855F7);
      case 'neon-pink': return const Color(0xFFEC4899);
      case 'neon-amber': return const Color(0xFFF59E0B);
      case 'neon-red': return const Color(0xFFEF4444);
      case 'neon-orange': return const Color(0xFFF97316);
      case 'neon-yellow': return const Color(0xFFEAB308);
      default: return const Color(0xFF06B6D4);
    }
  }

  IconData _getIconData(String? iconName) {
    switch (iconName) {
      case 'terminal': return Icons.terminal_rounded;
      case 'folder': return Icons.folder_rounded;
      case 'lock': return Icons.lock_rounded;
      case 'moon': return Icons.nightlight_round;
      case 'sun': return Icons.wb_sunny_rounded;
      case 'volume-2': return Icons.volume_up_rounded;
      case 'volume-x': return Icons.volume_off_rounded;
      case 'skip-back': return Icons.skip_previous_rounded;
      case 'play': return Icons.play_arrow_rounded;
      case 'skip-forward': return Icons.skip_next_rounded;
      case 'bell': return Icons.notifications_active_rounded;
      case 'battery-charging': return Icons.battery_charging_full_rounded;
      case 'clipboard': return Icons.content_paste_rounded;
      default: return Icons.widgets_rounded;
    }
  }
}
