import 'dart:io';

import 'package:path/path.dart' as p;

import 'approved_application_registry.dart';
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
  static ApprovedApplicationRegistry applicationRegistry =
      ApprovedApplicationRegistry.fromEnvironment();
  static String? _cachedDisplayOutput;
  static Map<String, String>? _iconCache;

  /// Linux roots used both when indexing application icons and when serving
  /// an icon back to the client. Keep this list narrow: the HTTP endpoint
  /// must never turn an arbitrary filesystem path into a readable file.
  static List<String> get linuxIconRoots =>
      linuxIconRootsFor(Platform.environment);

  static const _maxSnapPackages = 512;
  static const _maxIconEntriesPerRoot = 16384;
  static const _maxIconDepth = 32;
  static const _maxIconBytes = 4 * 1024 * 1024;

  /// Builds the same narrow allowlist used by icon discovery and HTTP serving.
  /// [snapRoot] is injectable so package layouts can be tested without /snap.
  static List<String> linuxIconRootsFor(
    Map<String, String> environment, {
    String snapRoot = '/snap',
  }) {
    final roots = <String>[];
    _addIconRoot(roots, '/usr/share/icons', '/usr/share');
    _addIconRoot(roots, '/usr/share/pixmaps', '/usr/share');
    _addIconRoot(
      roots,
      '/var/lib/flatpak/exports/share/icons',
      '/var/lib/flatpak',
    );
    _addIconRoot(roots, '/var/lib/snapd/desktop/icons', '/var/lib/snapd');

    final home = _absoluteDirectory(environment['HOME']);
    if (home != null) {
      _addIconRoot(roots, p.join(home, '.local/share/icons'), home);
      _addIconRoot(roots, p.join(home, '.local/share/pixmaps'), home);
    }
    // XDG_DATA_HOME is a single absolute directory, not the colon-separated
    // XDG_DATA_DIRS. A missing/relative value falls back to HOME/.local/share.
    final dataHome =
        _absoluteDirectory(environment['XDG_DATA_HOME']) ??
        (home == null ? null : p.join(home, '.local/share'));
    if (dataHome != null) {
      _addIconRoot(roots, p.join(dataHome, 'icons'), dataHome);
      _addIconRoot(roots, p.join(dataHome, 'pixmaps'), dataHome);
      _addIconRoot(
        roots,
        p.join(dataHome, 'flatpak/exports/share/icons'),
        dataHome,
      );
    }

    final snap = _absoluteDirectory(snapRoot);
    if (snap != null && Directory(snap).existsSync()) {
      try {
        // listSync has no streaming synchronous counterpart. Bound the number
        // of candidates processed and returned, even on a crowded /snap.
        var inspected = 0;
        for (final entry in Directory(snap).listSync(followLinks: false)) {
          if (++inspected > _maxSnapPackages) break;
          if (entry is! Directory ||
              !RegExp(r'^[a-z][a-z0-9-]{0,39}$')
                  .hasMatch(p.basename(entry.path))) {
            continue;
          }
          final package = entry.path;
          final current = p.join(package, 'current');
          final gui = p.join(current, 'meta/gui');
          try {
            // Only current may point at a revision. Neither the package nor
            // meta/gui can redirect the approved root outside that revision.
            final snapCanonical = Directory(snap).resolveSymbolicLinksSync();
            final packageCanonical = Directory(package)
                .resolveSymbolicLinksSync();
            final currentCanonical = Directory(current)
                .resolveSymbolicLinksSync();
            final guiCanonical = Directory(gui).resolveSymbolicLinksSync();
            if (p.isWithin(snapCanonical, packageCanonical) &&
                p.isWithin(packageCanonical, currentCanonical) &&
                p.isWithin(currentCanonical, guiCanonical) &&
                Directory(guiCanonical).existsSync()) {
              roots.add(gui);
            }
          } on FileSystemException {
            // A missing/broken revision contributes no root.
          }
        }
      } on FileSystemException {
        // Missing/inaccessible snap mount.
      }
    }
    return List.unmodifiable(roots);
  }

  static String? _absoluteDirectory(String? value) {
    if (value == null ||
        value.isEmpty ||
        !p.isAbsolute(value) ||
        p.normalize(value) == '/' ||
        value.contains('\u0000')) {
      return null;
    }
    return p.normalize(value);
  }

  static void _addIconRoot(List<String> roots, String root, String anchor) {
    try {
      // A present icon directory must stay inside its containing installation
      // or user-data directory, even if an intermediate component is a link.
      if (Directory(root).existsSync()) {
        final canonicalAnchor = Directory(anchor).resolveSymbolicLinksSync();
        final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
        if (!p.isWithin(canonicalAnchor, canonicalRoot)) return;
      } else if (FileSystemEntity.typeSync(root, followLinks: false) ==
          FileSystemEntityType.link) {
        return;
      }
      if (!roots.contains(root)) roots.add(root);
    } on FileSystemException {
      // A present but inaccessible/symlink-escaped root is not approved.
    }
  }

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

  /// Indexes only files canonically contained in each supplied icon root.
  /// Directory links inside a root are followed once, without traversal cycles.
  static Future<Map<String, String>> indexLinuxIconsForRoots(
    Iterable<String> roots, {
    int maxEntriesPerRoot = _maxIconEntriesPerRoot,
    int maxDepth = _maxIconDepth,
  }) async {
    if (maxEntriesPerRoot < 1 || maxDepth < 0) {
      throw ArgumentError('Icon scan limits must be positive');
    }
    final icons = <String, String>{};
    for (final path in roots) {
      if (!p.isAbsolute(path)) continue;
      String canonicalRoot;
      try {
        canonicalRoot = await Directory(path).resolveSymbolicLinks();
      } on FileSystemException {
        continue;
      }
      final pending = <({String path, int depth})>[(path: path, depth: 0)];
      final visited = <String>{};
      var inspected = 0;
      while (pending.isNotEmpty && inspected < maxEntriesPerRoot) {
        final next = pending.removeLast();
        String canonicalDir;
        try {
          canonicalDir = await Directory(next.path).resolveSymbolicLinks();
        } on FileSystemException {
          continue;
        }
        if ((canonicalDir != canonicalRoot &&
                !p.isWithin(canonicalRoot, canonicalDir)) ||
            !visited.add(canonicalDir)) {
          continue;
        }
        try {
          await for (final entity in Directory(
            next.path,
          ).list(followLinks: false)) {
            if (++inspected > maxEntriesPerRoot) break;
            final extension = p.extension(entity.path).toLowerCase();
            if (entity is! Directory &&
                entity is! Link &&
                (entity is! File || !_isIconExtension(extension))) {
              continue;
            }
            try {
              final canonical = await entity.resolveSymbolicLinks();
              if (!p.isWithin(canonicalRoot, canonical)) continue;
              final stat = await FileStat.stat(canonical);
              if (stat.type == FileSystemEntityType.directory) {
                if (next.depth < maxDepth) {
                  pending.add((path: entity.path, depth: next.depth + 1));
                }
              } else if (stat.type == FileSystemEntityType.file &&
                  stat.size <= _maxIconBytes &&
                  _isIconExtension(extension) &&
                  _isIconExtension(p.extension(canonical).toLowerCase())) {
                icons[p.basenameWithoutExtension(entity.path)] = entity.path;
              }
            } on FileSystemException {
              // Skip broken links and entries removed during discovery.
            }
          }
        } on FileSystemException {
          // Unreadable directory: continue with other roots.
        }
      }
    }
    return icons;
  }

  static bool _isIconExtension(String extension) =>
      extension == '.png' || extension == '.svg' || extension == '.xpm';

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

  static Future<bool> executeOpenUrl(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return false;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (_looksLikeUrl(payload)) {
        final url = _validatedHttpUrl(payload);
        // Anything that looks like a URI must be a valid HTTP(S) URL. Do not
        // reinterpret rejected schemes or malformed URLs as shell commands.
        if (url == null) return false;
        if (Platform.isLinux) {
          final result = await commandExecutor.run(
            'xdg-open',
            [payload],
            environment: {'DISPLAY': ':0'},
          );
          return result.exitCode == 0;
        } else if (Platform.isWindows) {
          // explorer.exe opens HTTP(S) URLs without passing the value through
          // cmd.exe, where URL metacharacters would become shell syntax.
          final result = await commandExecutor.run('explorer.exe', [payload]);
          return result.exitCode == 0;
        } else if (Platform.isMacOS) {
          final result = await commandExecutor.run('open', [payload]);
          return result.exitCode == 0;
        }
        return false;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  /// Launches only a server-approved identity. The request never supplies an
  /// executable or arguments, so an authenticated client cannot turn this into
  /// an arbitrary process or interpreter invocation.
  static Future<bool> executeLaunch(
    String identity, {
    CommandExecutor? executor,
    ApprovedApplicationRegistry? registry,
  }) async {
    if (!ApprovedApplicationRegistry.isValidIdentity(identity)) return false;
    final launch = (registry ?? applicationRegistry).resolve(identity);
    if (launch == null) return false;

    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      final result = await commandExecutor.run(
        launch.executable,
        launch.arguments,
        environment: Platform.isLinux ? {'DISPLAY': ':0'} : null,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
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

  static Future<bool> executeMpris(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return false;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (payload == 'volume_up') {
        if (Platform.isLinux) {
          final pactl = await commandExecutor.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '+5%',
          ]);
          final amixer = await commandExecutor.run('amixer', [
            '-D',
            'pulse',
            'sset',
            'Master',
            '5%+',
          ]);
          return pactl.exitCode == 0 && amixer.exitCode == 0;
        }
        return false;
      }
      if (payload == 'volume_down') {
        if (Platform.isLinux) {
          final pactl = await commandExecutor.run('pactl', [
            'set-sink-volume',
            '@DEFAULT_SINK@',
            '-5%',
          ]);
          final amixer = await commandExecutor.run('amixer', [
            '-D',
            'pulse',
            'sset',
            'Master',
            '5%-',
          ]);
          return pactl.exitCode == 0 && amixer.exitCode == 0;
        }
        return false;
      }
      if (payload == 'mute') {
        return await toggleMute(executor: commandExecutor);
      }

      final method = switch (payload) {
        'play-pause' || 'play_pause' => 'PlayPause',
        'next' => 'Next',
        'previous' => 'Previous',
        'stop' => 'Stop',
        'play' => 'Play',
        'pause' => 'Pause',
        _ => '',
      };
      if (method.isEmpty) return false;

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

          if (mprisNames.isEmpty) return false;
          for (var mpris in mprisNames) {
            final result = await commandExecutor.run('dbus-send', [
              '--print-reply',
              '--dest=$mpris',
              '/org/mpris/MediaPlayer2',
              'org.mpris.MediaPlayer2.Player.$method',
            ]);
            if (result.exitCode != 0) return false;
          }
          return true;
        }
        return false;
      } else if (Platform.isWindows) {
        // TODO: Implement Windows media keys
      } else if (Platform.isMacOS) {
        // TODO: Implement macOS media keys
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<bool> executeKdeAction(
    String payload, {
    CommandExecutor? executor,
  }) async {
    if (payload.isEmpty) return false;
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    try {
      if (Platform.isLinux) {
        final action = _kdeActions[payload];
        if (action == null) return false;
        final result = await commandExecutor.run(
          action.executable,
          action.arguments,
        );
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<List<Map<String, dynamic>>> getInstalledApps({
    CommandExecutor? executor,
    ApprovedApplicationRegistry? registry,
  }) async {
    final commandExecutor = executor ?? SystemActionsService.commandExecutor;
    final approved = registry ?? applicationRegistry;
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

                final identity = p.basenameWithoutExtension(entity.path);
                if (!approved.contains(identity)) continue;
                final app = <String, dynamic>{
                  'name': entry.name,
                  'payload': identity,
                  'icon': entry.icon ?? 'apps',
                  'approved': true,
                };
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
              final identity = 'snap:${parts[0]}';
              if (!approved.contains(identity)) continue;
              apps.add({
                'name': parts[0],
                'payload': identity,
                'icon': 'apps',
                'approved': true,
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

    // Sort and remove exact duplicates by approved identity.
    apps.sort((a, b) => a['name']!.compareTo(b['name']!));
    final seen = <String>{};
    apps.retainWhere((app) => seen.add(app['payload']!));

    // Resolve icons natively
    if (Platform.isLinux && allIconNames.isNotEmpty) {
      if (_iconCache == null) {
        final sw = Stopwatch()..start();
        _iconCache = await indexLinuxIconsForRoots(linuxIconRoots);
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
