import 'dart:io';

import 'app_discovery.dart';
import 'command_executor.dart';

final class _KdeCommand {
  const _KdeCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class SystemActionsService {
  /// The default executor can be replaced by an application-wide test fake.
  /// Prefer the per-call [executor] parameter when tests run concurrently.
  static CommandExecutor commandExecutor = const ProcessCommandExecutor();
  static String? _cachedDisplayOutput;
  static Map<String, String>? _iconCache;

  /// Linux roots used both when indexing application icons and when serving
  /// an icon back to the client. Keep this list narrow: the HTTP endpoint
  /// must never turn an arbitrary filesystem path into a readable file.
  static List<String> get linuxIconRoots => [
    '/usr/share/icons',
    '/usr/share/pixmaps',
    '${Platform.environment['HOME']}/.local/share/icons',
    '/var/lib/flatpak/exports/share/icons',
  ];

  static const Map<String, _KdeCommand> _kdeActions = {
    'sleep': _KdeCommand('systemctl', ['suspend']),
    'shutdown': _KdeCommand('systemctl', ['poweroff']),
    'lock': _KdeCommand('qdbus', ['org.kde.ksmserver', '/ScreenSaver', 'Lock']),
    'logout': _KdeCommand('qdbus', [
      'org.kde.ksmserver',
      '/KSMServer',
      'logout',
      '0',
      '0',
      '0',
    ]),
  };

  static Uri? _validatedHttpUrl(String value) {
    if (value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      return null;
    }

    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return uri;
  }

  static bool _looksLikeUrl(String value) {
    return value.startsWith('//') ||
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(value);
  }

  static void resetCommandExecutor() {
    commandExecutor = const ProcessCommandExecutor();
  }

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

  static Future<String> _getDisplayOutput(CommandExecutor executor) async {
    if (_cachedDisplayOutput != null) return _cachedDisplayOutput!;
    try {
      if (Platform.isLinux) {
        final res = await executor.run(
          'xrandr',
          ['--query'],
          environment: {'DISPLAY': ':0'},
        );
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

  static Future<void> executeLaunch(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (_looksLikeUrl(payload)) {
        final url = _validatedHttpUrl(payload);
        // Anything that looks like a URI must be a valid HTTP(S) URL. Do not
        // reinterpret rejected schemes or malformed URLs as shell commands.
        if (url == null) return;
        if (Platform.isLinux) {
          await commandExecutor.run(
            'xdg-open',
            [payload],
            environment: {'DISPLAY': ':0'},
          );
        } else if (Platform.isWindows) {
          // explorer.exe opens HTTP(S) URLs without passing the value through
          // cmd.exe, where URL metacharacters would become shell syntax.
          await commandExecutor.run('explorer.exe', [payload]);
        } else if (Platform.isMacOS) {
          await commandExecutor.run('open', [payload]);
        }
        return;
      }

      final launch = DesktopEntryParser.parseExec(payload);
      if (launch == null) return;

      if (Platform.isLinux) {
        await commandExecutor.run(
          launch.executable,
          launch.arguments,
          environment: {'DISPLAY': ':0'},
        );
      } else if (Platform.isWindows || Platform.isMacOS) {
        // Keep the platform branches explicit while using the same argv-safe
        // path. Do not reintroduce cmd.exe or a shell as a fallback.
        await commandExecutor.run(launch.executable, launch.arguments);
      }
    } catch (e) {
      print("❌ [SystemActionsService] Launch error: $e");
    }
  }

  static Future<bool> setVolume(int volume, {CommandExecutor? executor}) async {
    final vol = volume.clamp(0, 100);
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (Platform.isLinux) {
        final res = await commandExecutor.run('pactl', [
          'set-sink-volume',
          '@DEFAULT_SINK@',
          '$vol%',
        ]);
        if (res.exitCode == 0) return true;
        final res2 = await commandExecutor.run('amixer', [
          '-D',
          'pulse',
          'sset',
          'Master',
          '$vol%',
        ]);
        return res2.exitCode == 0;
      } else if (Platform.isWindows) {
        // TODO: Implement Windows volume
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS volume
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> toggleMute({CommandExecutor? executor}) async {
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (Platform.isLinux) {
        final res = await commandExecutor.run('pactl', [
          'set-sink-mute',
          '@DEFAULT_SINK@',
          'toggle',
        ]);
        if (res.exitCode == 0) return true;
        final res2 = await commandExecutor.run('amixer', [
          '-D',
          'pulse',
          'sset',
          'Master',
          'toggle',
        ]);
        return res2.exitCode == 0;
      } else if (Platform.isWindows) {
        // TODO: Implement Windows mute
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS mute
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> setBrightness(
    int brightness, {
    CommandExecutor? executor,
  }) async {
    final b = brightness.clamp(5, 100);
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
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
                final maxB =
                    int.tryParse(maxFile.readAsStringSync().trim()) ?? 100;
                final targetVal = ((b / 100) * maxB).round();
                brightFile.writeAsStringSync('$targetVal');
                return true;
              }
            }
          }
        } catch (_) {}

        try {
          final res = await commandExecutor.run('brightnessctl', [
            'set',
            '$b%',
          ]);
          if (res.exitCode == 0) return true;
        } catch (_) {}

        try {
          final display = await _getDisplayOutput(commandExecutor);
          final brightVal = (b / 100.0).toStringAsFixed(2);
          final res = await commandExecutor.run(
            'xrandr',
            ['--output', display, '--brightness', brightVal],
            environment: {'DISPLAY': ':0'},
          );
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

  static Future<void> executeMpris(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (payload == 'volume_up') {
        if (Platform.isLinux) {
          await commandExecutor.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '+5%',
          ]);
          await commandExecutor.run('amixer', [
            '-D',
            'pulse',
            'sset',
            'Master',
            '5%+',
          ]);
        }
        return;
      }
      if (payload == 'volume_down') {
        if (Platform.isLinux) {
          await commandExecutor.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '-5%',
          ]);
          await commandExecutor.run('amixer', [
            '-D',
            'pulse',
            'sset',
            'Master',
            '5%-',
          ]);
        }
        return;
      }
      if (payload == 'mute') {
        await toggleMute(executor: commandExecutor);
        return;
      }

      if (Platform.isLinux) {
        final dbusRes = await commandExecutor.run('dbus-send', [
          '--print-reply',
          '--dest=org.freedesktop.DBus',
          '/org/freedesktop/DBus',
          'org.freedesktop.DBus.ListNames',
        ]);
        if (dbusRes.exitCode == 0) {
          final out = dbusRes.stdout as String;
          final lines = out.split('\n');
          final mprisNames = lines
              .where((l) => l.contains('org.mpris.MediaPlayer2.'))
              .map((l) {
                final parts = l.split('"');
                return parts.length > 1 ? parts[1] : '';
              })
              .where((n) => n.isNotEmpty)
              .toList();

          String method = '';
          if (payload == 'play-pause' || payload == 'play_pause') {
            method = 'PlayPause';
          } else if (payload == 'next') {
            method = 'Next';
          } else if (payload == 'previous') {
            method = 'Previous';
          } else if (payload == 'stop') {
            method = 'Stop';
          } else if (payload == 'play') {
            method = 'Play';
          } else if (payload == 'pause') {
            method = 'Pause';
          }

          if (method.isNotEmpty) {
            for (var mpris in mprisNames) {
              await commandExecutor.run('dbus-send', [
                '--print-reply',
                '--dest=$mpris',
                '/org/mpris/MediaPlayer2',
                'org.mpris.MediaPlayer2.Player.$method',
              ]);
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

  static Future<void> executeKdeAction(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (Platform.isLinux) {
        final action = _kdeActions[payload];
        if (action != null) {
          await commandExecutor.run(action.executable, action.arguments);
        }
      }
    } catch (e) {
      print("❌ [SystemActionsService] KDE Action error: $e");
    }
  }

  static Future<List<Map<String, dynamic>>> getInstalledApps({
    CommandExecutor? executor,
  }) async {
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    final apps = <Map<String, dynamic>>[];
    Set<String> allIconNames = {};
    if (Platform.isLinux) {
      // Find Desktop entries
      final paths = [
        '/usr/share/applications',
        '${Platform.environment['HOME']}/.local/share/applications',
        '/var/lib/flatpak/exports/share/applications',
      ];

      for (var path in paths) {
        final dir = Directory(path);
        if (dir.existsSync()) {
          for (var entity in dir.listSync(recursive: true)) {
            if (entity is File && entity.path.endsWith('.desktop')) {
              try {
                final entry = DesktopEntryParser.parse(
                  entity.readAsStringSync(),
                  sourcePath: entity.path,
                );
                if (entry == null) continue;

                // Preserve the existing launch payload contract. The
                // parser retains the desktop Exec template so callers can
                // choose how to expand field codes; this backend has
                // historically removed them before returning the payload.
                final payload = entry.exec.split('%').first.trim();
                final app = <String, dynamic>{
                  'name': entry.name,
                  'payload': payload,
                  'icon': entry.icon ?? 'apps',
                };
                final launch = DesktopEntryParser.parseExec(entry.exec);
                if (launch != null) {
                  app['executable'] = launch.executable;
                  app['arguments'] = launch.arguments;
                }
                apps.add(app);
                if (entry.icon != null && entry.icon!.isNotEmpty) {
                  allIconNames.add(entry.icon!);
                }
              } catch (_) {}
            }
          }
        }
      }

      // Flatpaks are already handled by parsing /var/lib/flatpak/exports/share/applications

      // Snaps
      try {
        final res = await commandExecutor.run('snap', ['list']);
        if (res.exitCode == 0) {
          final lines = (res.stdout as String).split('\n');
          for (int i = 1; i < lines.length; i++) {
            final parts = lines[i].split(RegExp(r'\s+'));
            if (parts.isNotEmpty && parts[0].isNotEmpty) {
              apps.add({
                'name': parts[0],
                'payload': 'snap run ${parts[0]}',
                'icon': 'apps',
                'executable': 'snap',
                'arguments': ['run', parts[0]],
              });
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
        final paths = linuxIconRoots;
        for (var path in paths) {
          final dir = Directory(path);
          if (dir.existsSync()) {
            _scanDirForIcons(dir, _iconCache!);
          }
        }
        print(
          "✅ [SystemActionsService] Indexed ${_iconCache!.length} icons in ${sw.elapsedMilliseconds}ms",
        );
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
              return kLower == iconNameLower ||
                  kLower.contains(iconNameLower) ||
                  (iconNameLower.contains(kLower) && kLower.length > 3);
            }, orElse: () => '');
            if (match.isNotEmpty) app['system_icon_path'] = _iconCache![match]!;
          }
        }
      }
    }

    return apps;
  }
}
