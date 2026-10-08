import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_discovery.dart';

/// Locally administered launch definitions. Clients supply only an opaque ID;
/// discovery and network requests never add approvals or provide launch argv.
final class ApprovedApplicationRegistry {
  ApprovedApplicationRegistry(Map<String, LaunchCommand> entries)
    : _entries = Map.unmodifiable(_validatedCopy(entries));

  factory ApprovedApplicationRegistry.fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final raw = (environment ?? Platform.environment)['KDEDECK_APPROVED_APPS'];
    if (raw == null || raw.isEmpty) {
      return ApprovedApplicationRegistry(const {});
    }
    if (raw.length > maxEnvironmentLength) {
      return ApprovedApplicationRegistry(const {});
    }
    try {
      return ApprovedApplicationRegistry(_RegistryJsonParser(raw).parse());
    } on FormatException {
      return ApprovedApplicationRegistry(const {});
    } on ArgumentError {
      return ApprovedApplicationRegistry(const {});
    }
  }

  /// Bounds apply to both the environment and direct constructor.
  static const maxEnvironmentLength = 16384;
  static const maxEntries = 64;
  static const maxArguments = 32;
  static const maxArgumentLength = 1024;
  static const maxExecutableLength = 4096;

  final Map<String, LaunchCommand> _entries;

  static final _identityPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );
  static final _interpreterPattern = RegExp(
    r'^(?:python|pypy|node|nodejs|ruby|perl|php|lua|java|deno|bun)(?:\d+(?:\.\d+)*)?(?:\.exe)?$',
  );
  static const _blockedExecutables = {
    'ash',
    'bash',
    'busybox',
    'csh',
    'dash',
    'doas',
    'env',
    'fish',
    'ksh',
    'sh',
    'sudo',
    'tcsh',
    'zsh',
    'xargs',
    'cmd',
    'cmd.exe',
    'powershell',
    'powershell.exe',
    'pwsh',
    'pwsh.exe',
    'flatpak-spawn',
    'bwrap',
    'chroot',
    'firejail',
    'pkexec',
    'proot',
    'runuser',
    'setsid',
    'su',
    'systemd-run',
    'timeout',
    'unshare',
    'nsenter',
    'stdbuf',
    'taskset',
    'ionice',
    'chrt',
    'script',
    'expect',
    'nice',
    'nohup',
    'npm',
    'npx',
    'yarn',
    'pnpm',
    'corepack',
    'dotnet',
    'mono',
    'tclsh',
    'wish',
  };

  static bool isValidIdentity(String identity) =>
      _identityPattern.hasMatch(identity) &&
      !_blockedExecutables.contains(identity.toLowerCase()) &&
      !_interpreterPattern.hasMatch(identity.toLowerCase());

  static Map<String, LaunchCommand> _validatedCopy(
    Map<String, LaunchCommand> entries,
  ) {
    if (entries.length > maxEntries) throw ArgumentError('Invalid registry');
    final copy = <String, LaunchCommand>{};
    for (final entry in entries.entries) {
      final identity = entry.key;
      final command = entry.value;
      if (!isValidIdentity(identity) || !_validCommand(command)) {
        throw ArgumentError('Invalid registry');
      }
      // LaunchCommand copies its argv; copying here also protects against
      // caller-provided subclasses or later changes to the source map.
      copy[identity] = LaunchCommand(command.executable, command.arguments);
    }
    return copy;
  }

  static bool _validCommand(LaunchCommand command) {
    final executable = command.executable;
    if (executable.isEmpty ||
        executable.length > maxExecutableLength ||
        !p.posix.isAbsolute(executable) ||
        p.posix.normalize(executable) != executable ||
        executable.contains('\\') ||
        _hasControl(executable) ||
        command.arguments.length > maxArguments) {
      return false;
    }
    for (final argument in command.arguments) {
      if (argument.length > maxArgumentLength || _hasControl(argument)) {
        return false;
      }
    }
    final basename = p.posix.basename(executable).toLowerCase();
    if (_blockedExecutables.contains(basename) ||
        _interpreterPattern.hasMatch(basename)) {
      return false;
    }
    if (basename == 'flatpak' || basename == 'snap') {
      final argv = command.arguments;
      // No launcher switches, overrides, extra argv or command substitutions.
      return argv.length == 2 && argv[0] == 'run' && isValidIdentity(argv[1]);
    }
    return true;
  }

  static bool _hasControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  LaunchCommand? resolve(String identity) => _entries[identity];

  bool contains(String identity) => _entries.containsKey(identity);

  Iterable<String> get identities => _entries.keys;
}

/// Narrow JSON grammar: {"id":{"executable":"/path","arguments":["arg"]}}.
/// Parsing keys explicitly avoids jsonDecode's last-value-wins duplicate keys.
final class _RegistryJsonParser {
  _RegistryJsonParser(this.source);

  final String source;
  int offset = 0;

  Map<String, LaunchCommand> parse() {
    final entries = <String, LaunchCommand>{};
    _expect('{');
    if (!_take('}')) {
      do {
        final identity = _string();
        if (entries.containsKey(identity) ||
            entries.length >= ApprovedApplicationRegistry.maxEntries) {
          throw const FormatException('Invalid registry');
        }
        _expect(':');
        entries[identity] = _command();
      } while (_take(','));
      _expect('}');
    }
    _space();
    if (offset != source.length) {
      throw const FormatException('Invalid registry');
    }
    return entries;
  }

  LaunchCommand _command() {
    String? executable;
    List<String>? arguments;
    final fields = <String>{};
    _expect('{');
    if (!_take('}')) {
      do {
        final field = _string();
        if (!fields.add(field)) throw const FormatException('Invalid registry');
        _expect(':');
        switch (field) {
          case 'executable':
            executable = _string();
          case 'arguments':
            arguments = _arguments();
          default:
            throw const FormatException('Invalid registry');
        }
      } while (_take(','));
      _expect('}');
    }
    if (executable == null || arguments == null) {
      throw const FormatException('Invalid registry');
    }
    return LaunchCommand(executable, arguments);
  }

  List<String> _arguments() {
    final arguments = <String>[];
    _expect('[');
    if (!_take(']')) {
      do {
        if (arguments.length >= ApprovedApplicationRegistry.maxArguments) {
          throw const FormatException('Invalid registry');
        }
        arguments.add(_string());
      } while (_take(','));
      _expect(']');
    }
    return arguments;
  }

  String _string() {
    _space();
    final start = offset;
    if (offset >= source.length || source[offset++] != '"') {
      throw const FormatException('Invalid registry');
    }
    var escaped = false;
    while (offset < source.length) {
      final unit = source.codeUnitAt(offset++);
      if (unit == 0x22 && !escaped) {
        return jsonDecode(source.substring(start, offset)) as String;
      }
      if (unit == 0x5c && !escaped) {
        escaped = true;
      } else {
        escaped = false;
      }
    }
    throw const FormatException('Invalid registry');
  }

  void _space() {
    while (offset < source.length &&
        (source.codeUnitAt(offset) == 0x20 ||
            source.codeUnitAt(offset) == 0x09 ||
            source.codeUnitAt(offset) == 0x0a ||
            source.codeUnitAt(offset) == 0x0d)) {
      offset++;
    }
  }

  bool _take(String character) {
    _space();
    if (offset >= source.length || source[offset] != character) return false;
    offset++;
    return true;
  }

  void _expect(String character) {
    if (!_take(character)) throw const FormatException('Invalid registry');
  }
}
