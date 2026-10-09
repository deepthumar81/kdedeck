import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dynamic_matrix_grid.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';

Uri? _httpEndpoint(WebSocketService ws) {
  try {
    final uri = ws.serverUri;
    return uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http', path: '', query: null);
  } catch (_) {
    return null;
  }
}

@visibleForTesting
Uri? systemIconUri(WebSocketService ws, String path) => _httpEndpoint(ws)?.replace(
      path: '/system_icons', queryParameters: {'path': path},
    );

class NeumorphicDeckScreen extends StatefulWidget {
  const NeumorphicDeckScreen({super.key});

  @override
  State<NeumorphicDeckScreen> createState() => _NeumorphicDeckScreenState();
}

class _NeumorphicDeckScreenState extends State<NeumorphicDeckScreen> {
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _activePageIndex = 0;
  final _pairingCodeController = TextEditingController();
  final _embeddedTokenController = TextEditingController();
  bool _showEmbeddedToken = false;
  bool _conflictDialogShown = false;

  bool _isDarkMode = true;

  Color get bgColor => _isDarkMode ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0);
  Color get lightShadow => _isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFFFFFFF);
  Color get darkShadow => _isDarkMode ? const Color(0xFF050914) : const Color(0xFFCBD5E1);
  Color get accentBlue => _isDarkMode ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
  Color get textPrimary => _isDarkMode ? Colors.white70 : const Color(0xFF0F172A);

  @override
  void dispose() {
    _sliderDebounceTimer?.cancel();
    _pairingCodeController.dispose();
    _embeddedTokenController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  String? _connectionError(String? code) {
    switch (code) {
      case null:
        return null;
      case 'invalid_credentials':
      case 'invalid_token':
      case 'invalid_code':
      case 'pairing_rejected':
      case 'revoked':
      case 'session_revoked':
      case 'token_revoked':
        return 'Pairing rejected. Check the code and try again.';
      case 'expired':
      case 'session_expired':
      case 'token_expired':
      case 'expired_code':
      case 'pairing_expired':
        return 'Pairing code expired. Request a new code on your PC.';
      case 'tls_required':
        return 'This PC requires a secure WSS connection.';
      case 'invalid_endpoint':
        return 'Check the PC address and port.';
      case 'rate_limited':
        return 'Too many attempts. Please wait before trying again.';
      case 'credential_unavailable':
        return 'Could not save the credential securely. Please try again.';
       case 'unsupported_protocol':
       case 'unsupported_protocol_version':
         return 'This PC uses an unsupported pairing protocol.';
       case 'connection_failed':
         return 'Connection failed. Check the address, PC server and certificate trust.';
      default:
        return 'Unable to pair. Check the PC and try again.';
    }
  }

  void _showConfigConflict(WebSocketService ws) {
    if (!ws.configConflict) {
      _conflictDialogShown = false;
      return;
    }
    if (_conflictDialogShown) return;
    _conflictDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ws.configConflict) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Configuration conflict'),
          content: const Text('The PC configuration changed while you were editing. Your local draft is still here. Discard your draft and load the PC version?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Keep local draft')),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                ws.reloadServerConfig();
              },
              child: const Text('Discard draft & reload'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = Provider.of<WebSocketService>(context);
    final config = ws.configData;
    final boards = config?['boards'] as List<dynamic>? ?? [];
    _showConfigConflict(ws);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgColor,
      drawer: _buildNeumorphicDrawer(context, ws),
      body: SafeArea(
         child: !ws.isConnected || !ws.authenticated || ws.authRequired || boards.isEmpty
            ? _buildConnectingState(ws)
            : PageView.builder(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: (idx) {
                  HapticFeedback.selectionClick();
                  setState(() => _activePageIndex = idx);
                },
                itemCount: boards.length,
                itemBuilder: (context, bIdx) {
                  final board = boards[bIdx];
                  return _buildBoardContent(ws, board, boards.length);
                },
              ),
      ),
    );
  }

  void _handleItemDroppedMobile(WebSocketService ws, Map<String, dynamic> board, int draggedIndex, int targetCol, int targetRow) {
    final items = board['items'] as List<dynamic>? ?? [];
    if (draggedIndex < 0 || draggedIndex >= items.length) return;

    final draggedItem = items[draggedIndex];
    final targetItemIdx = items.indexWhere((item) => item['grid_x'] == targetCol && item['grid_y'] == targetRow);
    
    if (targetItemIdx != -1) {
      items[targetItemIdx]['grid_x'] = draggedItem['grid_x'];
      items[targetItemIdx]['grid_y'] = draggedItem['grid_y'];
    }
    
    draggedItem['grid_x'] = targetCol;
    draggedItem['grid_y'] = targetRow;

    if (ws.configData != null) {
      ws.sendSaveConfig(ws.configData!);
    }
  }

  Widget _buildBoardContent(WebSocketService ws, Map<String, dynamic> board, int totalBoards) {
    final showMetrics = ws.showMetrics && (ws.configData?['show_metrics'] != false);
    final items = board['items'] as List<dynamic>? ?? [];
    final cols = (board['grid_columns'] as num? ?? 4).toInt();
    final rows = (board['grid_rows'] as num? ?? 3).toInt();

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          // Sleek Ultra-Compact Left Sidebar (Width 54px: ☰ Hamburger Button + Micro Gauges + LED)
          _buildCompactLeftSidebar(ws, showMetrics, totalBoards),
          const SizedBox(width: 8),

          // Right Multi-Span Zero-Scroll Matrix Grid (Key forced for instant PC grid size updates!)
          Expanded(
            child: Center(
              key: ValueKey("grid_${cols}_${rows}_${board['id']}_${items.length}"),
              child: DynamicMatrixGrid(
                cols: cols,
                rows: rows,
                spacing: 8,
                itemCount: items.length,
                getSpanCols: (idx) => (items[idx]['span_cols'] as num? ?? 1).toInt(),
                getSpanRows: (idx) => (items[idx]['span_rows'] as num? ?? 1).toInt(),
                getGridX: (idx) => items[idx]['grid_x'] as int?,
                getGridY: (idx) => items[idx]['grid_y'] as int?,
                 isDraggable: ws.enableDragDrop && !ws.configConflict,
                itemBuilder: (context, idx, spanCols, spanRows) {
                  return _buildNeumorphicTile(ws, items[idx], spanCols, spanRows);
                },
                emptyBuilder: (context) => _buildEmptyNeumorphicSlot(),
                 onDrop: (draggedIdx, targetCol, targetRow) {
                   if (!ws.configConflict) _handleItemDroppedMobile(ws, board, draggedIdx, targetCol, targetRow);
                 },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Ultra-Compact Left Sidebar (Width 54px - Fits ☰ Hamburger Menu Icon perfectly without wasting space)
  Widget _buildCompactLeftSidebar(WebSocketService ws, bool showMetrics, int totalBoards) {
    return Container(
      width: 54,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: darkShadow.withOpacity(0.9), offset: const Offset(3, 3), blurRadius: 6),
          BoxShadow(color: lightShadow.withOpacity(0.6), offset: const Offset(-3, -3), blurRadius: 6),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Sleek Compact Hamburger Menu Icon ☰ (36x36px)
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              _scaffoldKey.currentState?.openDrawer();
            },
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: darkShadow.withOpacity(0.8), offset: const Offset(2, 2), blurRadius: 4),
                  BoxShadow(color: lightShadow.withOpacity(0.5), offset: const Offset(-2, -2), blurRadius: 4),
                ],
              ),
              child: Icon(Icons.menu_rounded, color: accentBlue, size: 20),
            ),
          ),

          // Micro Hardware Metrics Gauges (CPU, GPU, RAM)
          if (showMetrics) ...[
            _buildMicroGauge("C", "${ws.metrics['cpu_temp']}°", const Color(0xFF22C55E)),
            _buildMicroGauge("G", "${ws.metrics['gpu_temp']}°", const Color(0xFFF59E0B)),
            _buildMicroGauge("R", "${ws.metrics['ram_percent']}%", const Color(0xFF3B82F6)),
          ],

          if (ws.configConflict)
            IconButton(
              tooltip: 'Review configuration conflict',
              icon: const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B)),
              onPressed: () => setState(() => _conflictDialogShown = false),
            ),

          // Live Connection LED Status Dot & Page Dots
          Column(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: ws.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  totalBoards,
                  (idx) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    width: idx == _activePageIndex ? 10 : 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: idx == _activePageIndex ? accentBlue : textPrimary.withOpacity(0.24),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMicroGauge(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: textPrimary.withOpacity(0.5))),
        Text(value, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: color)),
      ],
    );
  }

  Timer? _sliderDebounceTimer;

  Widget _buildNeumorphicSliderTile(WebSocketService ws, Map<String, dynamic> item, int spanCols, int spanRows, bool isVolume) {
    final color = isVolume
        ? (ws.isMuted ? const Color(0xFFEF4444) : accentBlue)
        : const Color(0xFFF59E0B);
    final icon = isVolume
        ? (ws.isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded)
        : Icons.wb_sunny_rounded;
    final valStr = isVolume ? "${ws.currentVolume}%" : "${ws.currentBrightness}%";
    final double sliderVal = isVolume
        ? ws.currentVolume.toDouble().clamp(0.0, 100.0)
        : ws.currentBrightness.toDouble().clamp(5.0, 100.0);
    final minVal = isVolume ? 0.0 : 5.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.3), width: 1.5),
              boxShadow: [
                BoxShadow(color: darkShadow.withOpacity(0.9), offset: const Offset(4, 4), blurRadius: 8),
                BoxShadow(color: lightShadow.withOpacity(0.6), offset: const Offset(-4, -4), blurRadius: 8),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  if (isVolume) ws.triggerAction("audio_mute_toggle");
                },
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: ws.isMuted && isVolume ? const Color(0xFFEF4444).withOpacity(0.2) : bgColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withOpacity(0.4), width: 1),
                    boxShadow: [
                      BoxShadow(color: darkShadow.withOpacity(0.8), offset: const Offset(2, 2), blurRadius: 4),
                      BoxShadow(color: lightShadow.withOpacity(0.5), offset: const Offset(-2, -2), blurRadius: 4),
                    ],
                  ),
                  child: Icon(icon, color: color, size: 16),
                ),
              ),
              const SizedBox(height: 2),
              Text(valStr, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: color)),
              const SizedBox(height: 4),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 9,
                      thumbShape: SliderComponentShape.noThumb,
                      activeTrackColor: color,
                      inactiveTrackColor: Colors.black38,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: minVal,
                      max: 100,
                      divisions: 10,
                      onChanged: (val) {
                        HapticFeedback.selectionClick();
                        final snappedVal = ((val / 10).round() * 10).toInt();

                        _sliderDebounceTimer?.cancel();
                        _sliderDebounceTimer = Timer(const Duration(milliseconds: 150), () {
                          if (isVolume) {
                            ws.triggerAction("audio_volume", value: snappedVal);
                          } else {
                            ws.triggerAction("brightness", value: snappedVal);
                          }
                        });
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Neumorphic Multi-Span Tile (Supports 1x1 Normal, 2x1 Wide, 2x2 Big)
  Widget _buildNeumorphicTile(WebSocketService ws, Map<String, dynamic> item, int spanCols, int spanRows) {
    final type = item['type'] ?? 'button';
    if (type == 'volume_slider') return _buildNeumorphicSliderTile(ws, item, spanCols, spanRows, true);
    if (type == 'brightness_slider') return _buildNeumorphicSliderTile(ws, item, spanCols, spanRows, false);

    final isMultiSpan = spanCols > 1 || spanRows > 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: textPrimary.withOpacity(0.12), width: 1.2),
              boxShadow: [
                BoxShadow(color: darkShadow.withOpacity(0.9), offset: const Offset(4, 4), blurRadius: 8),
                BoxShadow(color: lightShadow.withOpacity(0.7), offset: const Offset(-4, -4), blurRadius: 8),
              ],
            ),
          ),
        ),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.mediumImpact();
              ws.triggerAction(item['action'], payload: item['payload'], itemId: item['id']);
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _buildTileContent(ws, item, isMultiSpan, spanCols),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTileContent(WebSocketService ws, Map<String, dynamic> item, bool isMultiSpan, int spanCols) {
    if (item['action'] == 'clock_widget') {
      return StreamBuilder(
        stream: Stream.periodic(const Duration(seconds: 1)),
        builder: (context, snapshot) {
          final now = DateTime.now();
          final timeStr = "${now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour)}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";
          return LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: SizedBox(
                  width: constraints.maxWidth * 0.9,
                  height: constraints.maxHeight * 0.5,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Text(
                      timeStr,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: accentBlue,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }

    Widget graphic;
    if (item['icon_base64'] != null) {
      try {
        final b64Str = item['icon_base64'].toString();
        final commaIdx = b64Str.indexOf(',');
        final cleanStr = commaIdx != -1 ? b64Str.substring(commaIdx + 1) : b64Str;
        final noWhitespace = cleanStr.replaceAll(RegExp(r'\s+'), '');
        graphic = FractionallySizedBox(
          widthFactor: 0.7,
          heightFactor: 0.7,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.0),
            child: Image.memory(base64Decode(noWhitespace), fit: BoxFit.contain),
          ),
        );
      } catch (e) {
        graphic = Icon(_getIconData(item['icon']), size: isMultiSpan ? 28 : 20, color: accentBlue);
      }
    } else if (item['system_icon_path'] != null) {
       final url = systemIconUri(ws, item['system_icon_path'].toString());
       if (url == null) {
         return Icon(Icons.broken_image, color: accentBlue);
       }
      final isSvg = item['system_icon_path'].toString().toLowerCase().endsWith('.svg');
      
      graphic = FractionallySizedBox(
        widthFactor: 0.7,
        heightFactor: 0.7,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16.0),
          child: isSvg 
               ? SvgPicture.network(url.toString(), fit: BoxFit.contain, placeholderBuilder: (_) => Icon(Icons.downloading, color: accentBlue))
               : Image.network(url.toString(), fit: BoxFit.contain, errorBuilder: (_,__,___) => Icon(Icons.broken_image, color: accentBlue)),
        ),
      );
    } else {
      graphic = Icon(_getIconData(item['icon']), size: isMultiSpan ? 28 : 20, color: accentBlue);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: Center(child: graphic),
        ),
        if (item['title'] != null && item['title'].toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: Text(
              item['title'],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isMultiSpan ? 11 : 9,
                fontWeight: FontWeight.w800,
                color: textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyNeumorphicSlot() {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: textPrimary.withOpacity(0.06), width: 1),
              boxShadow: [
                BoxShadow(color: darkShadow.withOpacity(0.4), offset: const Offset(2, 2), blurRadius: 4),
                BoxShadow(color: lightShadow.withOpacity(0.3), offset: const Offset(-2, -2), blurRadius: 4),
              ],
            ),
          ),
        ),
        Center(
          child: Icon(Icons.add_rounded, color: textPrimary.withOpacity(0.12), size: 16),
        ),
      ],
    );
  }

  Widget _buildConnectingState(WebSocketService ws) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: darkShadow.withOpacity(0.9), offset: const Offset(6, 6), blurRadius: 12),
              BoxShadow(color: lightShadow.withOpacity(0.6), offset: const Offset(-6, -6), blurRadius: 12),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_windows_rounded, size: 48, color: accentBlue),
              const SizedBox(height: 12),
              Text(
                "Connect to Linux PC",
                style: TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 18),
              ),
              const SizedBox(height: 4),
               Text(
                 ws.authRequired && !ws.authenticated
                     ? 'Pair with ${ws.activeServerName} (${_httpEndpoint(ws) ?? 'invalid address'})'
                     : 'Connecting to ${ws.activeServerName} (${_httpEndpoint(ws) ?? 'invalid address'})...',
                style: TextStyle(color: textPrimary.withOpacity(0.6), fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
               if (!ws.authRequired || ws.status == 'authenticating')
                 CircularProgressIndicator(color: accentBlue, strokeWidth: 3),
               if (ws.authRequired && !ws.authenticated) ...[
                 const SizedBox(height: 12),
                 Text('Enter the one-time pairing code shown on your PC.',
                     style: TextStyle(color: textPrimary), textAlign: TextAlign.center),
                 const SizedBox(height: 12),
                 TextField(
                   key: const Key('pairingCode'),
                   controller: _pairingCodeController,
                   obscureText: true,
                   autocorrect: false,
                   enableSuggestions: false,
                   style: TextStyle(color: textPrimary),
                   decoration: const InputDecoration(labelText: 'One-time pairing code', border: OutlineInputBorder()),
                 ),
                 const SizedBox(height: 8),
                 ElevatedButton(
                   onPressed: () {
                     final code = _pairingCodeController.text.trim();
                     if (code.isEmpty) return;
                     _pairingCodeController.clear();
                     ws.pairWithCode(code);
                   },
                   child: const Text('Pair with code'),
                 ),
                 TextButton(
                   onPressed: () => setState(() => _showEmbeddedToken = !_showEmbeddedToken),
                   child: const Text('Use embedded server token instead'),
                 ),
                 if (_showEmbeddedToken) ...[
                   TextField(
                     key: const Key('embeddedToken'),
                     controller: _embeddedTokenController,
                     obscureText: true,
                     autocorrect: false,
                     enableSuggestions: false,
                     style: TextStyle(color: textPrimary),
                     decoration: const InputDecoration(labelText: 'Embedded server token', border: OutlineInputBorder()),
                   ),
                   ElevatedButton(
                     onPressed: () {
                       final token = _embeddedTokenController.text.trim();
                       if (token.isEmpty) return;
                       _embeddedTokenController.clear();
                       ws.pairWithToken(token);
                     },
                     child: const Text('Pair with embedded server token'),
                   ),
                 ],
               ],
               if (_connectionError(ws.authError) case final error?) ...[
                 const SizedBox(height: 8),
                 Text(error, key: const Key('pairingError'), style: const TextStyle(color: Color(0xFFEF4444)), textAlign: TextAlign.center),
               ],
               if (ws.configError != null && !ws.configConflict)
                 const Text('Could not update the configuration.', style: TextStyle(color: Color(0xFFEF4444))),
               if (ws.configConflict)
                 TextButton(
                   onPressed: () => setState(() => _conflictDialogShown = false),
                   child: const Text('Review configuration conflict'),
                 ),
              const SizedBox(height: 20),

              // Saved PCs Header & List
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Saved PCs", style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                  IconButton(
                    icon: Icon(Icons.add_circle_rounded, color: accentBlue, size: 22),
                    onPressed: () => _openAddServerDialog(context, ws),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              ...ws.savedServers.asMap().entries.map((entry) {
                final idx = entry.key;
                final server = entry.value;
                 final isSelected = server['ip'] == ws.serverIp && server['port'] == ws.serverPort;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? accentBlue.withOpacity(0.15) : bgColor,
                    borderRadius: BorderRadius.circular(14),
                    border: isSelected ? Border.all(color: accentBlue, width: 1.5) : null,
                    boxShadow: [
                      BoxShadow(color: darkShadow.withOpacity(0.5), offset: const Offset(2, 2), blurRadius: 4),
                      BoxShadow(color: lightShadow.withOpacity(0.4), offset: const Offset(-2, -2), blurRadius: 4),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      leading: Icon(
                        Icons.computer_rounded,
                        color: isSelected ? accentBlue : textPrimary.withOpacity(0.6),
                      ),
                      title: Text(
                        server['name'] ?? 'PC',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: isSelected ? accentBlue : textPrimary,
                        ),
                      ),
                      subtitle: Text(
                         "${server['secure'] == true ? 'https' : 'http'}://${server['ip']}:${server['port']}",
                        style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5)),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: accentBlue, borderRadius: BorderRadius.circular(10)),
                              child: const Text("Active", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          IconButton(
                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: textPrimary.withOpacity(0.4)),
                            onPressed: () => ws.removeServer(idx),
                          ),
                        ],
                      ),
                       onTap: () {
                         final host = server['ip']?.toString() ?? '';
                         if (server['secure'] != true && !_isNumericLoopback(host)) {
                           ws.addServer(server['name']?.toString() ?? '', host,
                               server['port'] as int? ?? 8484, '', secure: true);
                         } else {
                           ws.selectServer(server);
                         }
                       },
                    ),
                  ),
                );
              }),

              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentBlue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text("Add New PC IP", style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _openAddServerDialog(context, ws),
              ),
            ],
          ),
        ),
      ),
    );
  }

   bool _isNumericLoopback(String host) {
     final address = InternetAddress.tryParse(host);
     return address != null && address.isLoopback;
   }

   bool _validHost(String host) {
     if (host.isEmpty || host.length > 253 || host != host.trim() ||
         host.contains(RegExp(r'[/@?#\s\[\]]'))) {
       return false;
     }
     if (host.contains(':')) {
       return InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6;
     }
     final labels = host.split('.');
     if (labels.length == 4 && labels.every((label) => RegExp(r'^\d+$').hasMatch(label))) {
       return labels.every((label) => label.length <= 3 &&
           (label.length == 1 || !label.startsWith('0')) && int.parse(label) <= 255);
     }
     if (RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
     return labels.every((label) => label.isNotEmpty && label.length <= 63 &&
         RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$').hasMatch(label));
   }

   void _openAddServerDialog(BuildContext context, WebSocketService ws) {
     final nameCtrl = TextEditingController();
     final ipCtrl = TextEditingController();
     final portCtrl = TextEditingController(text: "8484");
     var secure = true;
     String? validationError;

     showDialog(
       context: context,
       builder: (context) {
         return StatefulBuilder(builder: (context, updateDialog) {
         return AlertDialog(
          backgroundColor: bgColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("Add PC Connection", style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
           content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: textPrimary),
                decoration: InputDecoration(
                  labelText: "PC Nickname (e.g. Work Laptop)",
                  labelStyle: TextStyle(color: textPrimary.withOpacity(0.6)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipCtrl,
                style: TextStyle(color: textPrimary),
                decoration: InputDecoration(
                   labelText: "Host or IP address",
                  labelStyle: TextStyle(color: textPrimary.withOpacity(0.6)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
               TextField(
                 controller: portCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: textPrimary),
                decoration: InputDecoration(
                  labelText: "Port",
                  labelStyle: TextStyle(color: textPrimary.withOpacity(0.6)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
               ),
               SwitchListTile(
                 title: const Text('Secure connection (WSS / HTTPS)'),
                 subtitle: const Text('Requires a certificate trusted by this device. No certificate bypass.'),
                 value: secure,
                 onChanged: (value) => updateDialog(() => secure = value),
               ),
               if (validationError != null)
                 Text(validationError!, key: const Key('serverValidationError'),
                     style: const TextStyle(color: Color(0xFFEF4444))),
             ],
           )),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel", style: TextStyle(color: textPrimary.withOpacity(0.6))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentBlue, foregroundColor: Colors.white),
              onPressed: () {
                final name = nameCtrl.text.trim();
                final ip = ipCtrl.text.trim();
                 final port = int.tryParse(portCtrl.text.trim());

                 if (!_validHost(ip)) {
                   updateDialog(() => validationError = 'Enter a valid host or numeric IP address.');
                 } else if (port == null || port < 1 || port > 65535) {
                   updateDialog(() => validationError = 'Enter a port between 1 and 65535.');
                 } else if (!secure && !_isNumericLoopback(ip)) {
                   updateDialog(() => validationError = 'Plaintext is allowed only for numeric loopback addresses.');
                 } else {
                   ws.addServer(name, ip, port, '', secure: secure);
                   Navigator.pop(context);
                 }
              },
              child: const Text("Save & Connect"),
            ),
          ],
         );
         });
       },
     );
  }

  // Safe Neumorphic Drawer (Wrapped in SingleChildScrollView to prevent RenderFlex Overflow)
  Widget _buildNeumorphicDrawer(BuildContext context, WebSocketService ws) {
    return Drawer(
      backgroundColor: bgColor,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // App Title Header
              DrawerHeader(
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border(bottom: BorderSide(color: lightShadow, width: 1)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("KDE DECK", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: textPrimary, letterSpacing: 2)),
                    Text("Connected to: ${ws.activeServerName}", style: TextStyle(fontSize: 12, color: accentBlue, fontWeight: FontWeight.bold)),
                     Text('${_httpEndpoint(ws) ?? 'Invalid address'}', style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5))),
                  ],
                ),
              ),
              Divider(color: textPrimary.withOpacity(0.12), height: 32),

              // Theme Toggle
              SwitchListTile(
                title: Text("Dark Theme", style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                subtitle: Text("Switch between Dark and Light mode", style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5))),
                value: _isDarkMode,
                activeColor: accentBlue,
                onChanged: (val) {
                  setState(() => _isDarkMode = val);
                },
              ),
              Divider(color: textPrimary.withOpacity(0.12), height: 16),

              // Hardware Metrics Toggle
              SwitchListTile(
                title: Text("Hardware Gauges (CPU/GPU/RAM)", style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                subtitle: Text("Hide gauge & stop PC background polling", style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5))),
                value: ws.showMetrics,
                activeColor: accentBlue,
                onChanged: (val) {
                  ws.toggleMetricsEnabled(val);
                },
              ),
              Divider(color: textPrimary.withOpacity(0.12), height: 16),

              // Battery Saver Toggle
              SwitchListTile(
                title: Text("Battery Saver Mode", style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                subtitle: Text("Extends battery life on low-end phones", style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5))),
                value: ws.isBatterySaverMode,
                activeColor: const Color(0xFF22C55E),
                onChanged: (val) {
                  ws.toggleBatterySaver(val);
                },
              ),
              Divider(color: textPrimary.withOpacity(0.12), height: 16),

              // Advanced: Enable Drag Drop
              SwitchListTile(
                title: Text("Enable Drag & Drop (Advanced)", style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                subtitle: Text("WARNING: Can accidentally break grid layout when tapping.", style: TextStyle(fontSize: 11, color: const Color(0xFFEF4444))),
                value: ws.enableDragDrop,
                activeColor: const Color(0xFFEF4444),
                onChanged: (val) {
                  ws.toggleDragDrop(val);
                },
              ),
               Divider(color: textPrimary.withValues(alpha: 0.12), height: 24),

               ListTile(
                 leading: Icon(Icons.phonelink_lock_rounded, color: accentBlue),
                 title: Text('Re-pair / forget credential', style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
                  subtitle: Text('Remove the saved credential for this PC and pair again',
                      style: TextStyle(fontSize: 11, color: textPrimary.withValues(alpha: 0.5))),
                 onTap: () {
                   Navigator.pop(context);
                   ws.clearCredential();
                 },
               ),

              // Switch / Manage PCs
              ListTile(
                leading: Icon(Icons.devices_other_rounded, color: accentBlue),
                title: Text("Saved PCs & Switch Connection", style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                subtitle: Text("Change active target PC or add a new one", style: TextStyle(fontSize: 11, color: textPrimary.withOpacity(0.5))),
                onTap: () {
                  Navigator.pop(context);
                  _openAddServerDialog(context, ws);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getIconData(String? iconName) {
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
      case 'settings': return Icons.settings_rounded;
      case 'layers': return Icons.layers_rounded;
      default: return Icons.widgets_rounded;
    }
  }
}
