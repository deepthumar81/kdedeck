import re

with open('lib/dart_server_service.dart', 'r') as f:
    content = f.read()

# Replace debugPrint with print
content = content.replace('debugPrint(', 'print(')

# Remove flutter dependencies
content = re.sub(r"import 'package:flutter/foundation\.dart';\n", "", content)
content = re.sub(r"import 'package:shared_preferences/shared_preferences\.dart';\n", "", content)

# Change ChangeNotifier
content = content.replace('class DartServerService extends ChangeNotifier {', 'class DartServerService {')
content = content.replace('notifyListeners();\n', '')
content = content.replace('notifyListeners();', '')

# Replace SharedPreferences with File
new_load_config = """  Future<void> _loadConfig() async {
    try {
      final file = File('deckboard_config.json');
      if (await file.exists()) {
        final str = await file.readAsString();
        configData = jsonDecode(str);
      } else {
        configData = _getDefaultConfig();
      }
    } catch (e) {
      print("Error loading config: $e");
      configData = _getDefaultConfig();
    }
  }"""
content = re.sub(r"  Future<void> _loadConfig\(\) async \{.*?\n  \}", new_load_config, content, flags=re.DOTALL)

new_save_config = """  Future<void> _saveConfigLocal() async {
    if (configData == null) return;
    try {
      final file = File('deckboard_config.json');
      await file.writeAsString(jsonEncode(configData));
    } catch (e) {
      print("Error saving config: $e");
    }
  }"""
content = re.sub(r"  Future<void> _saveConfigLocal\(\) async \{.*?\n  \}", new_save_config, content, flags=re.DOTALL)

with open('lib/dart_server_service.dart', 'w') as f:
    f.write(content)
