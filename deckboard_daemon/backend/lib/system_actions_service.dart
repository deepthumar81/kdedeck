import 'dart:io';
import 'dart:convert';

class SystemActionsService {
  static String? _cachedDisplayOutput;
  static Map<String, String>? _iconCache;

  static void _scanDirForIcons(Directory dir, Map<String, String> map) {
    try {
      final entities = dir.listSync(followLinks: true);
      for (var entity in entities) {
        if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (ext == 'png' || ext == 'svg' || ext == 'xpm') {
            final filename = entity.path.split('/').last;
            final name = filename.substring(0, filename.lastIndexOf('.'));
            map[name] = entity.path;
          }
        } else if (entity is Directory) {
          _scanDirForIcons(entity, map);
        }
      }
    } catch (_) {}
  }

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
      if (payload == 'volume_up') {
        if (Platform.isLinux) {
          await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '+5%']);
          await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', '5%+']);
        }
        return;
      }
      if (payload == 'volume_down') {
        if (Platform.isLinux) {
          await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '-5%']);
          await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', '5%-']);
        }
        return;
      }
      if (payload == 'mute') {
        await toggleMute();
        return;
      }

      if (Platform.isLinux) {
        final dbusRes = await Process.run('dbus-send', ['--print-reply', '--dest=org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus.ListNames']);
        if (dbusRes.exitCode == 0) {
          final out = dbusRes.stdout as String;
          final lines = out.split('\n');
          final mprisNames = lines.where((l) => l.contains('org.mpris.MediaPlayer2.')).map((l) {
            final parts = l.split('"');
            return parts.length > 1 ? parts[1] : '';
          }).where((n) => n.isNotEmpty).toList();
          
          String method = '';
          if (payload == 'play-pause' || payload == 'play_pause') method = 'PlayPause';
          else if (payload == 'next') method = 'Next';
          else if (payload == 'previous') method = 'Previous';
          else if (payload == 'stop') method = 'Stop';
          else if (payload == 'play') method = 'Play';
          else if (payload == 'pause') method = 'Pause';

          if (method.isNotEmpty) {
            for (var mpris in mprisNames) {
              await Process.run('dbus-send', ['--print-reply', '--dest=$mpris', '/org/mpris/MediaPlayer2', 'org.mpris.MediaPlayer2.Player.$method']);
            }
          }
        }
      } else if (Platform.isWindows) {
        // TODO: Implement Windows media keys
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS media keys
      }
    } catch (e) {
      print("❌ [SystemActionsService] Media error: $e");
    }
  }

  static Future<void> executeKdeAction(String payload) async {
    if (payload.isEmpty) return;
    try {
      if (Platform.isLinux) {
        if (payload == 'sleep') {
          await Process.run('systemctl', ['suspend']);
        } else if (payload == 'shutdown') {
          await Process.run('systemctl', ['poweroff']);
        } else if (payload == 'lock') {
          await Process.run('qdbus', ['org.kde.ksmserver', '/ScreenSaver', 'Lock']);
        } else if (payload == 'logout') {
          await Process.run('qdbus', ['org.kde.ksmserver', '/KSMServer', 'logout', '0', '0', '0']);
        } else {
          // Custom qdbus or arbitrary command
          await Process.run('sh', ['-c', payload]);
        }
      }
    } catch (e) {
      print("❌ [SystemActionsService] KDE Action error: $e");
    }
  }

  static Future<List<Map<String, String>>> getInstalledApps() async {
    List<Map<String, String>> apps = [];
    Set<String> allIconNames = {};
    if (Platform.isLinux) {
      // Find Desktop entries
      final paths = [
        '/usr/share/applications',
        '${Platform.environment['HOME']}/.local/share/applications',
        '/var/lib/flatpak/exports/share/applications'
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
                  if (icon != null && icon.isNotEmpty) allIconNames.add(icon);
                }
              } catch (_) {}
            }
          }
        }
      }
      
      // Flatpaks are already handled by parsing /var/lib/flatpak/exports/share/applications
      
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
    
    // Resolve icons natively
    if (Platform.isLinux && allIconNames.isNotEmpty) {
      if (_iconCache == null) {
        final sw = Stopwatch()..start();
        _iconCache = {};
        final paths = [
          '/usr/share/icons',
          '/usr/share/pixmaps',
          '${Platform.environment['HOME']}/.local/share/icons',
          '/var/lib/flatpak/exports/share/icons'
        ];
        for (var path in paths) {
          final dir = Directory(path);
          if (dir.existsSync()) {
            _scanDirForIcons(dir, _iconCache!);
          }
        }
        print("✅ [SystemActionsService] Indexed ${_iconCache!.length} icons in ${sw.elapsedMilliseconds}ms");
      }

      for (var app in apps) {
        final iconName = app['icon'];
        if (iconName != null) {
          if (iconName.startsWith('/')) {
            app['system_icon_path'] = iconName;
          } else if (_iconCache!.containsKey(iconName)) {
            app['system_icon_path'] = _iconCache![iconName]!;
          } else {
            // Also try matching case-insensitive partial substring
            final iconNameLower = iconName.toLowerCase();
            final match = _iconCache!.keys.firstWhere((k) {
              final kLower = k.toLowerCase();
              return kLower == iconNameLower || kLower.contains(iconNameLower) || (iconNameLower.contains(kLower) && kLower.length > 3);
            }, orElse: () => '');
            if (match.isNotEmpty) app['system_icon_path'] = _iconCache![match]!;
          }
        }
      }
    }
    
    return apps;
  }
}
