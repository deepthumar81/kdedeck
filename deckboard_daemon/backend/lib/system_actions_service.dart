import 'dart:io';

class SystemActionsService {
  static String? _cachedDisplayOutput;

  static Future<String> _getDisplayOutput() async {
    if (_cachedDisplayOutput != null) return _cachedDisplayOutput!;
    try {
      if (Platform.isLinux) {
        final res = await Process.run('xrandr', ['--query'], environment: {'DISPLAY': ':0'});
        if (res.exitCode == 0) {
          for (var line in (res.stdout as String).split('\n')) {
            if (line.contains(' connected')) {
              _cachedDisplayOutput = line.split(' ').first;
              return _cachedDisplayOutput!;
            }
          }
        }
      }
    } catch (_) {}
    return 'eDP-1';
  }

  static Future<void> executeLaunch(String payload) async {
    if (payload.isEmpty) return;
    try {
      if (payload.startsWith('http://') || payload.startsWith('https://')) {
        if (Platform.isLinux) await Process.run('xdg-open', [payload], environment: {'DISPLAY': ':0'});
        else if (Platform.isWindows) await Process.run('cmd', ['/c', 'start', payload]);
        else if (Platform.isMacOS) await Process.run('open', [payload]);
      } else {
        if (Platform.isLinux) await Process.run('sh', ['-c', payload], environment: {'DISPLAY': ':0'});
        else if (Platform.isWindows) await Process.run('cmd', ['/c', payload]); // TODO: Refine Windows launch
        else if (Platform.isMacOS) await Process.run('sh', ['-c', payload]); // TODO: Refine macOS launch
      }
    } catch (e) {
      print("❌ [SystemActionsService] Launch error: $e");
    }
  }

  static Future<bool> setVolume(int volume) async {
    final vol = volume.clamp(0, 100);
    try {
      if (Platform.isLinux) {
        final res = await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '$vol%']);
        if (res.exitCode == 0) return true;
        final res2 = await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', '$vol%']);
        return res2.exitCode == 0;
      } else if (Platform.isWindows) {
        // TODO: Implement Windows volume
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS volume
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> toggleMute() async {
    try {
      if (Platform.isLinux) {
        final res = await Process.run('pactl', ['set-sink-mute', '@DEFAULT_SINK@', 'toggle']);
        if (res.exitCode == 0) return true;
        final res2 = await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', 'toggle']);
        return res2.exitCode == 0;
      } else if (Platform.isWindows) {
        // TODO: Implement Windows mute
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS mute
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> setBrightness(int brightness) async {
    final b = brightness.clamp(5, 100);
    try {
      if (Platform.isLinux) {
        try {
          final sysDir = Directory('/sys/class/backlight');
          if (sysDir.existsSync()) {
            final entries = sysDir.listSync();
            if (entries.isNotEmpty) {
              final maxFile = File('${entries.first.path}/max_brightness');
              final brightFile = File('${entries.first.path}/brightness');
              if (maxFile.existsSync() && brightFile.existsSync()) {
                final maxB = int.tryParse(maxFile.readAsStringSync().trim()) ?? 100;
                final targetVal = ((b / 100) * maxB).round();
                brightFile.writeAsStringSync('$targetVal');
                return true;
              }
            }
          }
        } catch (_) {}

        try {
          final res = await Process.run('brightnessctl', ['set', '$b%']);
          if (res.exitCode == 0) return true;
        } catch (_) {}

        try {
          final display = await _getDisplayOutput();
          final brightVal = (b / 100.0).toStringAsFixed(2);
          final res = await Process.run('xrandr', ['--output', display, '--brightness', brightVal], environment: {'DISPLAY': ':0'});
          return res.exitCode == 0;
        } catch (_) {}
      } else if (Platform.isWindows) {
        // TODO: Implement Windows brightness
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS brightness
      }
    } catch (_) {}
    return false;
  }

  static Future<void> executeMpris(String payload) async {
    if (payload.isEmpty) return;
    try {
      if (Platform.isLinux) {
        await Process.run('playerctl', [payload]);
      } else if (Platform.isWindows) {
        // TODO: Implement Windows media keys
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS media keys
      }
    } catch (e) {
      print("❌ [SystemActionsService] Media error: $e");
    }
  }

  static Future<List<Map<String, String>>> getInstalledApps() async {
    List<Map<String, String>> apps = [];
    if (Platform.isLinux) {
      // Find Desktop entries
      final paths = [
        '/usr/share/applications',
        '${Platform.environment['HOME']}/.local/share/applications'
      ];
      
      for (var path in paths) {
        final dir = Directory(path);
        if (dir.existsSync()) {
          for (var entity in dir.listSync(recursive: true)) {
            if (entity is File && entity.path.endsWith('.desktop')) {
              try {
                final lines = entity.readAsLinesSync();
                String? name, exec, icon;
                bool inDesktopEntry = false;
                for (var line in lines) {
                  if (line == '[Desktop Entry]') inDesktopEntry = true;
                  else if (line.startsWith('[')) inDesktopEntry = false;
                  
                  if (!inDesktopEntry) continue;
                  
                  if (line.startsWith('Name=')) name ??= line.substring(5);
                  if (line.startsWith('Exec=')) {
                    exec ??= line.substring(5).split('%')[0].trim();
                  }
                  if (line.startsWith('Icon=')) icon ??= line.substring(5);
                }
                if (name != null && exec != null) {
                  apps.add({'name': name, 'payload': exec, 'icon': icon ?? 'apps'});
                }
              } catch (_) {}
            }
          }
        }
      }
      
      // Flatpaks
      try {
        final res = await Process.run('flatpak', ['list', '--app', '--columns=name,application']);
        if (res.exitCode == 0) {
          final lines = (res.stdout as String).split('\n');
          for (var line in lines) {
            final parts = line.split('\t');
            if (parts.length >= 2) {
              apps.add({'name': parts[0].trim(), 'payload': 'flatpak run ${parts[1].trim()}', 'icon': 'apps'});
            }
          }
        }
      } catch (_) {}
      
      // Snaps
      try {
        final res = await Process.run('snap', ['list']);
        if (res.exitCode == 0) {
          final lines = (res.stdout as String).split('\n');
          for (int i = 1; i < lines.length; i++) {
            final parts = lines[i].split(RegExp(r'\s+'));
            if (parts.length >= 1 && parts[0].isNotEmpty) {
              apps.add({'name': parts[0], 'payload': 'snap run ${parts[0]}', 'icon': 'apps'});
            }
          }
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      // TODO: Windows start menu apps
    } else if (Platform.isMacOS) {
      // TODO: macOS /Applications apps
    }
    
    // Sort and remove exact duplicates by payload
    apps.sort((a, b) => a['name']!.compareTo(b['name']!));
    final seen = <String>{};
    apps.retainWhere((app) => seen.add(app['payload']!));
    
    return apps;
  }
}
