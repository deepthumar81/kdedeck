import 'dart:io';
import 'package:flutter/foundation.dart';

/// Service responsible for executing native Linux system commands.
class LinuxActionsService {
  static String? _cachedDisplayOutput;

  /// Detects the active connected display output using `xrandr`.
  static Future<String> _getDisplayOutput() async {
    if (_cachedDisplayOutput != null) return _cachedDisplayOutput!;
    try {
      final res = await Process.run('xrandr', ['--query'], environment: {'DISPLAY': ':0'});
      if (res.exitCode == 0) {
        for (var line in (res.stdout as String).split('\n')) {
          if (line.contains(' connected')) {
            _cachedDisplayOutput = line.split(' ').first;
            return _cachedDisplayOutput!;
          }
        }
      }
    } catch (_) {}
    return 'eDP-1';
  }

  /// Launch application executable or open URL
  static Future<void> executeLaunch(String payload) async {
    if (!Platform.isLinux || payload.isEmpty) return;
    try {
      if (payload.startsWith('http://') || payload.startsWith('https://')) {
        await Process.run('xdg-open', [payload], environment: {'DISPLAY': ':0'});
      } else {
        await Process.run('sh', ['-c', payload], environment: {'DISPLAY': ':0'});
      }
    } catch (e) {
      debugPrint("❌ [LinuxActionsService] Launch error: $e");
    }
  }

  /// Set System Sink Volume (0 - 100%)
  static Future<bool> setVolume(int volume) async {
    if (!Platform.isLinux) return false;
    final vol = volume.clamp(0, 100);
    try {
      final res = await Process.run('pactl', ['set-sink-volume', '@DEFAULT_SINK@', '$vol%']);
      if (res.exitCode == 0) return true;
    } catch (_) {}

    try {
      final res = await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', '$vol%']);
      return res.exitCode == 0;
    } catch (_) {}
    return false;
  }

  /// Toggle System Sink Audio Mute
  static Future<bool> toggleMute() async {
    if (!Platform.isLinux) return false;
    try {
      final res = await Process.run('pactl', ['set-sink-mute', '@DEFAULT_SINK@', 'toggle']);
      if (res.exitCode == 0) return true;
    } catch (_) {}

    try {
      final res = await Process.run('amixer', ['-D', 'pulse', 'sset', 'Master', 'toggle']);
      return res.exitCode == 0;
    } catch (_) {}
    return false;
  }

  /// Set System Brightness (5 - 100%)
  static Future<bool> setBrightness(int brightness) async {
    if (!Platform.isLinux) return false;
    final b = brightness.clamp(5, 100);

    // Approach 1: Try writing to /sys/class/backlight sysfs directly
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

    // Approach 2: Try brightnessctl
    try {
      final res = await Process.run('brightnessctl', ['set', '$b%']);
      if (res.exitCode == 0) return true;
    } catch (_) {}

    // Approach 3: Fallback to xrandr --brightness
    try {
      final display = await _getDisplayOutput();
      final brightVal = (b / 100.0).toStringAsFixed(2);
      final res = await Process.run('xrandr', ['--output', display, '--brightness', brightVal], environment: {'DISPLAY': ':0'});
      return res.exitCode == 0;
    } catch (e) {
      debugPrint("❌ [LinuxActionsService] Brightness xrandr fallback failed: $e");
    }

    return false;
  }

  /// MPRIS Media Control (play-pause, next, previous)
  static Future<void> executeMpris(String payload) async {
    if (!Platform.isLinux || payload.isEmpty) return;
    try {
      await Process.run('playerctl', [payload]);
    } catch (e) {
      debugPrint("❌ [LinuxActionsService] MPRIS error: $e");
    }
  }
}
