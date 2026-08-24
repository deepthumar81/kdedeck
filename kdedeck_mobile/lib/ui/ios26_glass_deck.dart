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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF050811),
              Color(0xFF0F172A),
              Color(0xFF1E1B4B),
              Color(0xFF090D16),
            ],
            stops: [0.0, 0.35, 0.75, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Top iOS 26 Liquid Glass Header Bar
              _buildLiquidGlassHeader(ws),

              // Main Body (Left Metrics Panel + Center Slider Cards + Right Deck Grid)
              Expanded(
                child: boards.isEmpty
                    ? _buildConnectingState(ws)
                    : PageView.builder(
                        controller: _pageController,
                        onPageChanged: (idx) {
                          HapticFeedback.selectionClick();
                          setState(() => _activePageIndex = idx);
                        },
                        itemCount: boards.length,
                        itemBuilder: (context, bIdx) {
                          final board = boards[bIdx];
                          return _buildBoardContent(ws, board);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiquidGlassHeader(WebSocketService ws) {
    return Container(
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0x331E293B),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 16,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Left Title + Menu Icon
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.tune_rounded, color: Color(0xFF38BDF8), size: 22),
                    onPressed: () => _openSettingsSheet(context, ws),
                  ),
                  const SizedBox(width: 4),
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF38BDF8), Color(0xFF818CF8), Color(0xFFC084FC)],
                    ).createShader(bounds),
                    child: const Text(
                      "KDE DECK 26",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),

              // Page Indicator Dots
              Row(
                children: List.generate(
                  (ws.configData?['boards'] as List<dynamic>?)?.length ?? 1,
                  (idx) => GestureDetector(
                    onTap: () {
                      _pageController.animateToPage(
                        idx,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: idx == _activePageIndex ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        gradient: idx == _activePageIndex
                            ? const LinearGradient(colors: [Color(0xFF22C55E), Color(0xFF06B6D4)])
                            : null,
                        color: idx == _activePageIndex ? null : Colors.white24,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: idx == _activePageIndex
                            ? [BoxShadow(color: const Color(0xFF22C55E).withOpacity(0.5), blurRadius: 8)]
                            : [],
                      ),
                    ),
                  ),
                ),
              ),

              // Right Sync Status Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: ws.isConnected ? const Color(0x2B22C55E) : const Color(0x2BEF4444),
                  border: Border.all(
                    color: ws.isConnected ? const Color(0x9922C55E) : const Color(0x99EF4444),
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: ws.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: ws.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                            blurRadius: 6,
                          )
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      ws.isConnected ? "LIVE SYNCED" : "OFFLINE",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                        color: ws.isConnected ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBoardContent(WebSocketService ws, Map<String, dynamic> board) {
    final showMetrics = ws.configData?['show_metrics'] != false;
    final items = board['items'] as List<dynamic>? ?? [];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          // Left Hardware Gauges Panel
          if (showMetrics) _buildMetricsPanel(ws),
          if (showMetrics) const SizedBox(width: 12),

          // Center Quick Volume & Brightness Sliders Card
          _buildQuickSlidersCard(ws),
          const SizedBox(width: 12),

          // Right Squircle Button Matrix
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cols = ws.configData?['grid_columns'] ?? 4;
                final rows = ws.configData?['grid_rows'] ?? 3;
                final totalSlots = cols * rows;

                return GridView.builder(
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.05,
                  ),
                  itemCount: totalSlots,
                  itemBuilder: (context, itemIdx) {
                    if (itemIdx < items.length) {
                      final item = items[itemIdx];
                      return _buildiOS26SquircleTile(ws, item);
                    } else {
                      return _buildEmptyPlaceholderTile();
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

  Widget _buildMetricsPanel(WebSocketService ws) {
    final m = ws.metrics;
    return Container(
      width: 165,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x331E293B),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildGaugeRow("CPU", "${m['cpu_temp']}°C", "${m['cpu_load']}% Load", const Color(0xFF22C55E)),
              const Divider(color: Colors.white10, height: 12),
              _buildGaugeRow("GPU", "${m['gpu_temp']}°C", "${m['gpu_load']}% Load", const Color(0xFFF59E0B)),
              const Divider(color: Colors.white10, height: 12),
              _buildGaugeRow("RAM", "${m['ram_percent']}%", "${m['ram_used_gb']}/${m['ram_total_gb']}G", const Color(0xFF3B82F6)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGaugeRow(String label, String value, String subtext, Color color) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2.8),
            boxShadow: [BoxShadow(color: color.withOpacity(0.3), blurRadius: 6)],
          ),
          child: Center(
            child: Text(
              value,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70)),
              Text(subtext, style: const TextStyle(fontSize: 10, color: Colors.white38, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickSlidersCard(WebSocketService ws) {
    return Container(
      width: 130,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x331E293B),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Volume Slider Column
              Expanded(
                child: Column(
                  children: [
                    const Icon(Icons.volume_up_rounded, color: Color(0xFF38BDF8), size: 20),
                    const SizedBox(height: 4),
                    Text(
                      "${ws.currentVolume}%",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF38BDF8)),
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 12,
                            thumbShape: SliderComponentShape.noThumb,
                            activeTrackColor: const Color(0xFF38BDF8),
                            inactiveTrackColor: Colors.white10,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: ws.currentVolume.toDouble().clamp(0.0, 100.0),
                            min: 0,
                            max: 100,
                            onChanged: (val) {
                              HapticFeedback.selectionClick();
                              ws.triggerAction("audio_volume", value: val.toInt());
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 16),

              // Brightness Slider Column
              Expanded(
                child: Column(
                  children: [
                    const Icon(Icons.wb_sunny_rounded, color: Color(0xFFF59E0B), size: 20),
                    const SizedBox(height: 4),
                    Text(
                      "${ws.currentBrightness}%",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFFF59E0B)),
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 12,
                            thumbShape: SliderComponentShape.noThumb,
                            activeTrackColor: const Color(0xFFF59E0B),
                            inactiveTrackColor: Colors.white10,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: ws.currentBrightness.toDouble().clamp(5.0, 100.0),
                            min: 5,
                            max: 100,
                            onChanged: (val) {
                              HapticFeedback.selectionClick();
                              ws.triggerAction("brightness", value: val.toInt());
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildiOS26SquircleTile(WebSocketService ws, Map<String, dynamic> item) {
    final colorHex = _parseColor(item['color']);

    Widget cardBody = Container(
      decoration: BoxDecoration(
        color: const Color(0x401E293B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colorHex.withOpacity(0.7), width: 1.8),
        boxShadow: [
          BoxShadow(
            color: colorHex.withOpacity(0.30),
            blurRadius: 14,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          splashColor: colorHex.withOpacity(0.3),
          onTap: () {
            HapticFeedback.mediumImpact();
            ws.triggerAction(item['action'], payload: item['payload'], itemId: item['id']);
          },
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorHex.withOpacity(0.15),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: colorHex.withOpacity(0.2), blurRadius: 10)],
                  ),
                  child: Icon(_getLucideOrMaterialIcon(item['icon']), size: 26, color: colorHex),
                ),
                const SizedBox(height: 8),
                Text(
                  item['title'] ?? 'Button',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!ws.isBatterySaverMode) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: cardBody,
        ),
      );
    }
    return cardBody;
  }

  Widget _buildEmptyPlaceholderTile() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 1.2),
      ),
      child: const Center(
        child: Icon(Icons.add_rounded, color: Colors.white12, size: 24),
      ),
    );
  }

  Widget _buildConnectingState(WebSocketService ws) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0x661E293B),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF38BDF8), strokeWidth: 3),
            const SizedBox(height: 16),
            Text(
              "Connecting to KdeDeck PC Daemon at ${ws.serverIp}:${ws.serverPort}...",
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettingsSheet(BuildContext context, WebSocketService ws) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("SETTINGS & BATTERY SAVER", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const Divider(color: Colors.white12, height: 24),

              SwitchListTile(
                title: const Text("Battery Saver Mode"),
                subtitle: const Text("Disables GPU liquid glass backdrop blurs to save phone battery"),
                value: ws.isBatterySaverMode,
                activeColor: const Color(0xFF22C55E),
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

  IconData _getLucideOrMaterialIcon(String? iconName) {
    switch (iconName) {
      case 'terminal': return Icons.terminal_rounded;
      case 'folder': return Icons.folder_open_rounded;
      case 'firefox': return Icons.language_rounded;
      case 'chrome': return Icons.web_rounded;
      case 'code': return Icons.code_rounded;
      case 'music': return Icons.music_note_rounded;
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
      case 'gamepad': return Icons.sports_esports_rounded;
      case 'settings': return Icons.settings_rounded;
      case 'app_launcher': return Icons.apps_rounded;
      case 'layers': return Icons.layers_rounded;
      case 'tv': return Icons.tv_rounded;
      case 'cpu': return Icons.memory_rounded;
      case 'zap': return Icons.bolt_rounded;
      case 'wifi': return Icons.wifi_rounded;
      case 'camera': return Icons.camera_alt_rounded;
      case 'trash': return Icons.delete_outline_rounded;
      case 'shield': return Icons.shield_rounded;
      case 'power': return Icons.power_settings_new_rounded;
      default: return Icons.widgets_rounded;
    }
  }
}
