import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool isConnected = false;
  bool pinRequired = false;
  bool isBatterySaverMode = false;

  String serverIp = "192.168.29.128";
  int serverPort = 8484;
  String pin = "8484";

  Map<String, dynamic>? configData;
  int currentVolume = 50;
  int currentBrightness = 70;
  Map<String, dynamic> metrics = {
    "cpu_temp": 45,
    "cpu_load": 15,
    "gpu_temp": 50,
    "gpu_load": 20,
    "ram_used_gb": 8.0,
    "ram_total_gb": 16.0,
    "ram_percent": 50,
  };

  Timer? _reconnectTimer;

  WebSocketService() {
    _loadSettingsAndConnect();
  }

  Future<void> _loadSettingsAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    serverIp = prefs.getString('server_ip') ?? "192.168.29.128";
    serverPort = prefs.getInt('server_port') ?? 8484;
    pin = prefs.getString('server_pin') ?? "8484";
    isBatterySaverMode = prefs.getBool('battery_saver') ?? false;

    connect();
  }

  void connect() {
    _channel?.sink.close();
    final wsUrl = Uri.parse("ws://$serverIp:$serverPort/ws");

    try {
      _channel = WebSocketChannel.connect(wsUrl);
      isConnected = true;
      notifyListeners();

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (err) {
          _handleDisconnect();
        },
        onDone: () {
          _handleDisconnect();
        },
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    isConnected = false;
    notifyListeners();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!isConnected) connect();
    });
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final type = data['type'];

      if (type == 'init_state' || type == 'config_updated') {
        configData = data['config'];
        pinRequired = data['pin_required'] ?? false;

        if (data['state'] != null) {
          final state = data['state'];
          currentVolume = state['volume'] ?? currentVolume;
          currentBrightness = state['brightness'] ?? currentBrightness;
          if (state['metrics'] != null) metrics = Map<String, dynamic>.from(state['metrics']);
        }
        notifyListeners();
      } else if (type == 'state_update') {
        final key = data['key'];
        final val = data['value'];
        if (key == 'volume') currentVolume = val;
        if (key == 'brightness') currentBrightness = val;
        notifyListeners();
      } else if (type == 'state_poll') {
        if (data['state'] != null) {
          final state = data['state'];
          currentVolume = state['volume'] ?? currentVolume;
          currentBrightness = state['brightness'] ?? currentBrightness;
          if (state['metrics'] != null) metrics = Map<String, dynamic>.from(state['metrics']);
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint("WS parse error: $e");
    }
  }

  void triggerAction(String action, {String? payload, dynamic value, String? itemId}) {
    if (_channel != null && isConnected) {
      final msg = jsonEncode({
        "type": "trigger_action",
        "action": action,
        "payload": payload,
        "value": value,
        "item_id": itemId,
      });
      _channel!.sink.add(msg);
    }
  }

  void toggleBatterySaver(bool val) async {
    isBatterySaverMode = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('battery_saver', val);
  }

  Future<void> updateServerConnection(String ip, int port, String newPin) async {
    serverIp = ip;
    serverPort = port;
    pin = newPin;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', ip);
    await prefs.setInt('server_port', port);
    await prefs.setString('server_pin', newPin);

    connect();
  }
}
