import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'dynamic_matrix_grid.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';

class DesktopConfiguratorScreen extends StatefulWidget {
  const DesktopConfiguratorScreen({super.key});

  @override
  State<DesktopConfiguratorScreen> createState() => _DesktopConfiguratorScreenState();
}

class _DesktopConfiguratorScreenState extends State<DesktopConfiguratorScreen> {
  int _activeBoardIdx = 0;
  Map<String, dynamic>? _draftConfig;
  bool _isDraftDirty = false;
  bool _isDarkMode = true;

  Color get bgCol => _isDarkMode ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0);
  Color get cardCol => _isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
  Color get lightShadow => _isDarkMode ? const Color(0xFF2B3952) : const Color(0xFFFFFFFF);
  Color get darkShadow => _isDarkMode ? const Color(0xFF060A14) : const Color(0xFFCBD5E1);

  Color get textPrimary => _isDarkMode ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
  Color get textSecondary => _isDarkMode ? const Color(0xFF94A3B8) : const Color(0xFF475569);
  Color get accentCol => _isDarkMode ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
  Color get saveGreen => const Color(0xFF16A34A);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ws = Provider.of<WebSocketService>(context, listen: false);
    if (_draftConfig == null && ws.configData != null) {
      _draftConfig = jsonDecode(jsonEncode(ws.configData));
    }
  }

  void _markDirty() {
    setState(() {
      _isDraftDirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = Provider.of<WebSocketService>(context, listen: false);
    if (_draftConfig == null && ws.configData != null) {
      _draftConfig = jsonDecode(jsonEncode(ws.configData));
    }

    final boards = _draftConfig?['boards'] as List<dynamic>? ?? [];

    return Scaffold(
      backgroundColor: bgCol,
      body: SafeArea(
        child: Column(
          children: [
            // Top PC Header
            _buildHeader(ws),

            // Main PC Workspace
            Expanded(
              child: Row(
                children: [
                  // Left Sidebar
                  _buildSidebar(boards),

                  // Center Workspace Matrix + Static Sliders Preview
                  Expanded(
                    child: _buildMatrixWorkspace(ws, boards),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(WebSocketService ws) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: cardCol,
        border: Border(bottom: BorderSide(color: textSecondary.withOpacity(0.2))),
        boxShadow: [
          BoxShadow(color: darkShadow.withOpacity(0.3), offset: const Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.dashboard_rounded, color: accentCol, size: 24),
              const SizedBox(width: 12),
              Text(
                "KDE DECK CONFIGURATOR",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: textPrimary, letterSpacing: 1.2),
              ),
            ],
          ),

          Row(
            children: [
              // Global Theme Switcher
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: bgCol, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  children: [
                    Icon(_isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded, size: 16, color: accentCol),
                    const SizedBox(width: 6),
                    Text(_isDarkMode ? "Dark Theme" : "Light Theme", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textPrimary)),
                    const SizedBox(width: 6),
                    Switch(
                      value: !_isDarkMode,
                      activeColor: accentCol,
                      onChanged: (val) {
                        setState(() => _isDarkMode = !val);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Server Link Indicator
              Consumer<WebSocketService>(
                builder: (context, wsData, child) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: wsData.isConnected ? const Color(0x2B22C55E) : const Color(0x2BEF4444),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      wsData.isConnected ? "Link: http://${wsData.serverIp}:${wsData.serverPort}" : "Offline",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: wsData.isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
                    ),
                  );
                },
              ),
              const SizedBox(width: 16),

              // Save & Apply Button
              ElevatedButton.icon(
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: Text(_isDraftDirty ? "Save & Apply Changes *" : "Save & Apply"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isDraftDirty ? saveGreen : accentCol,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  if (_draftConfig != null) {
                    ws.sendSaveConfig(_draftConfig!);
                    setState(() => _isDraftDirty = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text("✅ Saved & Synced to Phone Live!"),
                        backgroundColor: saveGreen,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(List<dynamic> boards) {
    final activeBoard = boards.isNotEmpty && _activeBoardIdx < boards.length ? boards[_activeBoardIdx] : null;
    final cols = activeBoard?['grid_columns'] ?? 4;
    final rows = activeBoard?['grid_rows'] ?? 3;

    return Container(
      width: 260,
      color: cardCol,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("DECKS & BOARDS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textSecondary)),
              IconButton(
                icon: Icon(Icons.add_circle_outline_rounded, color: accentCol, size: 20),
                tooltip: "Create New Deck Board",
                onPressed: _addNewBoard,
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Board List
          Expanded(
            child: ListView.builder(
              itemCount: boards.length,
              itemBuilder: (context, idx) {
                final isSelected = idx == _activeBoardIdx;
                final board = boards[idx];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: isSelected ? accentCol : bgCol.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _activeBoardIdx = idx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.layers_rounded, size: 16, color: isSelected ? Colors.white : textPrimary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                board['title'] ?? 'Board',
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  color: isSelected ? Colors.white : textPrimary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (isSelected)
                              IconButton(
                                icon: const Icon(Icons.edit_rounded, size: 14, color: Colors.white70),
                                onPressed: () => _renameBoard(idx),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          Divider(color: textSecondary.withOpacity(0.2), height: 24),

          // Grid Matrix Dimensions Sizer
          Text("GRID MATRIX SIZE", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textSecondary)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: [3, 4, 5, 6, 7, 8].contains(cols) ? cols : null,
                  dropdownColor: cardCol,
                  style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    labelText: "Cols",
                    labelStyle: TextStyle(color: textSecondary),
                    filled: true,
                    fillColor: bgCol,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  ),
                  items: [3, 4, 5, 6, 7, 8].map((c) => DropdownMenuItem(value: c, child: Text("$c", style: TextStyle(color: textPrimary)))).toList(),
                  onChanged: (val) {
                    if (val != null && activeBoard != null) {
                      activeBoard['grid_columns'] = val;
                      _markDirty();
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<int>(
                  value: [3, 4, 5, 6, 7, 8].contains(rows) ? rows : null,
                  dropdownColor: cardCol,
                  style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    labelText: "Rows",
                    labelStyle: TextStyle(color: textSecondary),
                    filled: true,
                    fillColor: bgCol,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  ),
                  items: [3, 4, 5, 6, 7, 8].map((r) => DropdownMenuItem(value: r, child: Text("$r", style: TextStyle(color: textPrimary)))).toList(),
                  onChanged: (val) {
                    if (val != null && activeBoard != null) {
                      activeBoard['grid_rows'] = val;
                      _markDirty();
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMatrixWorkspace(WebSocketService ws, List<dynamic> boards) {
    if (boards.isEmpty || _activeBoardIdx >= boards.length) {
      return Center(child: Text("No boards found. Click + to create one.", style: TextStyle(color: textPrimary)));
    }

    final board = boards[_activeBoardIdx];
    final items = board['items'] as List<dynamic>? ?? [];
    final cols = board['grid_columns'] ?? 4;
    final rows = board['grid_rows'] ?? 3;
    final totalSlots = cols * rows;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Main Multi-Span Grid Matrix
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Deck: ${board['title']} ($cols × $rows Grid Matrix)",
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textPrimary),
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text("Add Button Item"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentCol,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _openItemEditorDialog(null),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Multi-Span Grid Matrix View
                Expanded(
                  child: Center(
                    key: ValueKey("pc_grid_${cols}_${rows}_${board['id']}_${items.length}"),
                    child: DynamicMatrixGrid(
                      cols: cols,
                      rows: rows,
                      spacing: 10,
                      itemCount: items.length,
                      getSpanCols: (idx) => (items[idx]['span_cols'] as num? ?? 1).toInt(),
                      getSpanRows: (idx) => (items[idx]['span_rows'] as num? ?? 1).toInt(),
                      itemBuilder: (context, idx, spanCols, spanRows) {
                        return _buildNeumorphicButtonTile(items[idx], idx, spanCols, spanRows);
                      },
                      emptyBuilder: (context) => _buildNeumorphicEmptyTile(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderPreviewCard(Map<String, dynamic> item, int itemIdx, int spanCols, int spanRows, String label, IconData icon, Color color) {
    return RepaintBoundary(
      child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cardCol,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: darkShadow.withOpacity(0.6), offset: const Offset(4, 4), blurRadius: 8),
          BoxShadow(color: lightShadow.withOpacity(0.5), offset: const Offset(-4, -4), blurRadius: 8),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openItemEditorDialog(itemIdx),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: 8,
                  decoration: BoxDecoration(color: bgCol, borderRadius: BorderRadius.circular(10)),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: spanRows * 15.0, // Mockup height
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildNeumorphicButtonTile(Map<String, dynamic> item, int itemIdx, int spanCols, int spanRows) {
    final type = item['type'] ?? 'button';
    if (type == 'volume_slider') return _buildSliderPreviewCard(item, itemIdx, spanCols, spanRows, "VOL", Icons.volume_up_rounded, accentCol);
    if (type == 'brightness_slider') return _buildSliderPreviewCard(item, itemIdx, spanCols, spanRows, "BRIGHT", Icons.wb_sunny_rounded, const Color(0xFFF59E0B));

    final isMultiSpan = spanCols > 1 || spanRows > 1;

    return RepaintBoundary(
      child: Container(
      decoration: BoxDecoration(
        color: cardCol,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: darkShadow.withOpacity(0.7), offset: const Offset(4, 4), blurRadius: 8),
          BoxShadow(color: lightShadow.withOpacity(0.6), offset: const Offset(-4, -4), blurRadius: 8),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openItemEditorDialog(itemIdx),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_getIconData(item['icon']), size: isMultiSpan ? 32 : 24, color: accentCol),
                const SizedBox(height: 6),
                Text(
                  item['title'] ?? 'Button',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: textPrimary),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (isMultiSpan)
                  Text(
                    "${spanCols}x${spanRows} Tile",
                    style: TextStyle(fontSize: 9, color: accentCol, fontWeight: FontWeight.w900),
                  ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildNeumorphicEmptyTile() {
    return RepaintBoundary(
      child: Container(
      decoration: BoxDecoration(
        color: cardCol,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: darkShadow.withOpacity(0.4), offset: const Offset(3, 3), blurRadius: 6),
          BoxShadow(color: lightShadow.withOpacity(0.4), offset: const Offset(-3, -3), blurRadius: 6),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openItemEditorDialog(null),
          child: Center(
            child: Icon(Icons.add_rounded, color: textSecondary.withOpacity(0.4), size: 24),
          ),
        ),
      ),
      ),
    );
  }

  void _openItemEditorDialog(int? itemIdx) {
    final boards = _draftConfig?['boards'] as List<dynamic>? ?? [];
    if (boards.isEmpty || _activeBoardIdx >= boards.length) return;

    final items = boards[_activeBoardIdx]['items'] as List<dynamic>;
    final isNew = itemIdx == null;
    final item = isNew
        ? {
            "type": "button",
            "id": "item_${int.parse(DateTime.now().millisecondsSinceEpoch.toString().substring(5))}",
            "title": "New App",
            "action": "launch_app",
            "payload": "firefox",
            "icon": "terminal",
            "span_cols": 1,
            "span_rows": 1,
          }
        : items[itemIdx];

    String selectedType = item['type'] ?? 'button';
    final titleCtrl = TextEditingController(text: item['title']);
    final payloadCtrl = TextEditingController(text: item['payload']);
    final iconCtrl = TextEditingController(text: item['icon']);
    String selectedAction = item['action'] ?? 'launch_app';
    int selectedSpanCols = item['span_cols'] ?? 1;
    int selectedSpanRows = item['span_rows'] ?? 1;

    final actionOptions = [
      "launch_app", "open_url", "audio_volume", "brightness", "audio_mute_toggle", "mpris_action", "kde_action"
    ];
    if (!actionOptions.contains(selectedAction)) selectedAction = "launch_app";

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: cardCol,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text(isNew ? "Add Item" : "Configure Item", style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Item Type Picker
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                      dropdownColor: cardCol,
                      decoration: InputDecoration(
                        labelText: "Item Type",
                        labelStyle: TextStyle(color: textSecondary),
                        filled: true,
                        fillColor: bgCol,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                      items: [
                        DropdownMenuItem(value: "button", child: Text("Standard Button", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "volume_slider", child: Text("Volume Slider", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "brightness_slider", child: Text("Brightness Slider", style: TextStyle(color: textPrimary))),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() {
                            selectedType = val;
                            if (val == "volume_slider") {
                              selectedAction = "audio_volume";
                              selectedSpanCols = 1;
                              selectedSpanRows = 4;
                            } else if (val == "brightness_slider") {
                              selectedAction = "brightness";
                              selectedSpanCols = 1;
                              selectedSpanRows = 4;
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),

                    if (selectedType == 'button') ...[
                      TextField(
                        controller: titleCtrl,
                        style: TextStyle(color: textPrimary),
                        decoration: InputDecoration(
                          labelText: "Button Label",
                          labelStyle: TextStyle(color: textSecondary),
                          filled: true,
                          fillColor: bgCol,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Tile Size Span Picker
                    DropdownButtonFormField<String>(
                      value: "${selectedSpanCols}x${selectedSpanRows}",
                      style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                      dropdownColor: cardCol,
                      decoration: InputDecoration(
                        labelText: "Tile Size Span",
                        labelStyle: TextStyle(color: textSecondary),
                        filled: true,
                        fillColor: bgCol,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                      items: [
                        DropdownMenuItem(value: "1x1", child: Text("Normal Square Tile (1x1)", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "2x1", child: Text("Wide Tile (2x1)", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "2x2", child: Text("Big Square Tile (2x2)", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "1x3", child: Text("Vertical Slider (1x3)", style: TextStyle(color: textPrimary))),
                        DropdownMenuItem(value: "1x4", child: Text("Tall Vertical Slider (1x4)", style: TextStyle(color: textPrimary))),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          final parts = val.split('x');
                          setDialogState(() {
                            selectedSpanCols = int.parse(parts[0]);
                            selectedSpanRows = int.parse(parts[1]);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),

                    if (selectedType == 'button')
                      DropdownButtonFormField<String>(
                        value: selectedAction,
                        style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
                        dropdownColor: cardCol,
                        decoration: InputDecoration(
                          labelText: "Action Type",
                          labelStyle: TextStyle(color: textSecondary),
                          filled: true,
                          fillColor: bgCol,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                        items: [
                          DropdownMenuItem(value: "launch_app", child: Text("Launch Application", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "open_url", child: Text("Open Website URL", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "audio_volume", child: Text("Audio Volume Control", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "brightness", child: Text("Brightness Control", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "audio_mute_toggle", child: Text("Toggle Audio Mute", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "mpris_action", child: Text("Media Control (Play/Next)", style: TextStyle(color: textPrimary))),
                          DropdownMenuItem(value: "kde_action", child: Text("KDE Shortcut (Lock/NightLight)", style: TextStyle(color: textPrimary))),
                        ],
                        onChanged: (val) {
                          if (val != null) setDialogState(() => selectedAction = val);
                        },
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: payloadCtrl,
                      style: TextStyle(color: textPrimary),
                      decoration: InputDecoration(
                        labelText: "Payload (App Executable / URL)",
                        labelStyle: TextStyle(color: textSecondary),
                        filled: true,
                        fillColor: bgCol,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: iconCtrl,
                      style: TextStyle(color: textPrimary),
                      decoration: InputDecoration(
                        labelText: "Icon Name",
                        labelStyle: TextStyle(color: textSecondary),
                        filled: true,
                        fillColor: bgCol,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (!isNew)
                  TextButton(
                    onPressed: () {
                      items.removeAt(itemIdx);
                      _markDirty();
                      Navigator.pop(context);
                    },
                    child: const Text("Delete Button", style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text("Cancel", style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: saveGreen, foregroundColor: Colors.white),
                  onPressed: () {
                    item['title'] = titleCtrl.text;
                    item['action'] = selectedAction;
                    item['payload'] = payloadCtrl.text;
                    item['icon'] = iconCtrl.text;
                    item['span_cols'] = selectedSpanCols;
                    item['span_rows'] = selectedSpanRows;

                    if (isNew) {
                      items.add(item);
                    } else {
                      items[itemIdx] = item;
                    }
                    _markDirty();
                    Navigator.pop(context);
                  },
                  child: const Text("Save Button"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _addNewBoard() {
    final titleController = TextEditingController(text: "Board ${(_draftConfig?['boards'] as List).length + 1}");
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardCol,
          title: Text("Create New Deck Board", style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: titleController,
            style: TextStyle(color: textPrimary),
            decoration: InputDecoration(
              labelText: "Board Title",
              labelStyle: TextStyle(color: textSecondary),
              filled: true,
              fillColor: bgCol,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancel", style: TextStyle(color: textSecondary))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentCol, foregroundColor: Colors.white),
              onPressed: () {
                final boards = _draftConfig?['boards'] as List<dynamic>? ?? [];
                boards.add({
                  "id": "board_${int.parse(DateTime.now().millisecondsSinceEpoch.toString().substring(5))}",
                  "title": titleController.text,
                  "icon": "layers",
                  "items": []
                });
                _activeBoardIdx = boards.length - 1;
                _markDirty();
                Navigator.pop(context);
              },
              child: const Text("Create Board"),
            ),
          ],
        );
      },
    );
  }

  void _renameBoard(int idx) {
    final boards = _draftConfig?['boards'] as List<dynamic>? ?? [];
    final titleController = TextEditingController(text: boards[idx]['title']);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: cardCol,
          title: Text("Rename Board", style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: titleController,
            style: TextStyle(color: textPrimary),
            decoration: InputDecoration(
              labelText: "Board Title",
              labelStyle: TextStyle(color: textSecondary),
              filled: true,
              fillColor: bgCol,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                boards.removeAt(idx);
                if (_activeBoardIdx >= boards.length) _activeBoardIdx = 0;
                _markDirty();
                Navigator.pop(context);
              },
              child: const Text("Delete Deck", style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: saveGreen, foregroundColor: Colors.white),
              onPressed: () {
                boards[idx]['title'] = titleController.text;
                _markDirty();
                Navigator.pop(context);
              },
              child: const Text("Save Title"),
            ),
          ],
        );
      },
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
