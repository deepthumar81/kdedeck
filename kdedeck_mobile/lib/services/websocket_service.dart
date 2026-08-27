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

  String activeServerName = "Linux PC";
  List<Map<String, dynamic>> savedServers = [];
  Timer? _reconnectTimer;

  WebSocketService() {
    _loadSettingsAndConnect();
  }

  Future<void> _loadSettingsAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load saved servers list
    final savedJsonStr = prefs.getString('saved_servers_list');
    if (savedJsonStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(savedJsonStr);
        savedServers = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (_) {}
    }

    if (savedServers.isEmpty) {
      savedServers = [
        {
          "name": "Default PC",
          "ip": "192.168.29.128",
          "port": 8484,
          "pin": "8484",
        }
      ];
    }

    // Default desktop fallback if on desktop
    final bool isDesktop = !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows);
    
    if (isDesktop) {
      serverIp = "127.0.0.1";
      serverPort = 8484;
      activeServerName = "Local Desktop Engine";
    } else {
      serverIp = prefs.getString('server_ip') ?? savedServers.first['ip'];
      serverPort = prefs.getInt('server_port') ?? savedServers.first['port'];
      pin = prefs.getString('server_pin') ?? savedServers.first['pin'];
      activeServerName = prefs.getString('server_name') ?? savedServers.first['name'];
    }

    isBatterySaverMode = prefs.getBool('battery_saver') ?? false;

    connect();
  }

  Future<void> addServer(String name, String ip, int port, String pinCode) async {
    final newServer = {
      "name": name.isNotEmpty ? name : "PC ($ip)",
      "ip": ip,
      "port": port,
      "pin": pinCode,
    };

    savedServers.removeWhere((s) => s['ip'] == ip && s['port'] == port);
    savedServers.add(newServer);

    await _saveServersToPrefs();
    await selectServer(newServer);
  }

  Future<void> removeServer(int index) async {
    if (index >= 0 && index < savedServers.length) {
      savedServers.removeAt(index);
      await _saveServersToPrefs();
      notifyListeners();
    }
  }

  Future<void> selectServer(Map<String, dynamic> server) async {
    serverIp = server['ip'];
    serverPort = server['port'] ?? 8484;
    pin = server['pin'] ?? "8484";
    activeServerName = server['name'] ?? "PC ($serverIp)";

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', serverIp);
    await prefs.setInt('server_port', serverPort);
    await prefs.setString('server_pin', pin);
    await prefs.setString('server_name', activeServerName);

    connect();
  }

  Future<void> _saveServersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_servers_list', jsonEncode(savedServers));
  }

  bool _isConnecting = false;

  void connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      await _channel?.sink.close();
      final wsUrl = Uri.parse("ws://$serverIp:$serverPort/ws");
      _channel = WebSocketChannel.connect(wsUrl);

      await _channel!.ready;
      isConnected = true;
      _isConnecting = false;
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
        cancelOnError: false,
      );
    } catch (e) {
      _isConnecting = false;
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnecting = false;
    if (isConnected) {
      isConnected = false;
      notifyListeners();
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      connect();
    });
  }



  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message);
      final type = data['type'];

      if (type == 'init_state' || type == 'config_updated') {
        configData = data['config'];
        pinRequired = data['pin_required'] ?? false;
        isConnected = true;


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

  void sendSaveConfig(Map<String, dynamic> newConfig) {
    configData = newConfig;
    notifyListeners();

    if (_channel != null && isConnected) {
      final msg = jsonEncode({
        "type": "save_config",
        "config": newConfig,
      });
      _channel!.sink.add(msg);
    }
  }

  bool showMetrics = true;

  void toggleMetricsEnabled(bool val) async {
    showMetrics = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_metrics', val);

    if (_channel != null && isConnected) {
      final msg = jsonEncode({
        "type": "set_metrics_enabled",
        "enabled": val,
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
