import 'dart:io';

import 'package:path/path.dart' as p;

/// The desktop-entry fields needed by application discovery.
class DesktopEntry {
  const DesktopEntry({
    required this.name,
    required this.exec,
    this.icon,
    this.sourcePath,
  });

  final String name;

  /// The unmodified launch template, including field codes such as %U/%F.
  final String exec;
  final String? icon;
  final String? sourcePath;
}

/// A launch command that can be passed directly to [Process.run] without a
/// shell.
class LaunchCommand {
  LaunchCommand(this.executable, Iterable<String> arguments)
    : arguments = List.unmodifiable(arguments);

  final String executable;
  final List<String> arguments;
}

/// Pure desktop-entry parsing, independent of any platform runtime checks.
///
/// The caller chooses application roots (Debian, Flatpak, Snap, etc.) and
/// handles launch-template expansion. This parser never runs commands.
class DesktopEntryParser {
  const DesktopEntryParser();

  /// Parses a desktop-entry Exec value (or a legacy app payload) into an
  /// executable and argv. This deliberately implements only the small,
  /// safe subset needed by app launches; it is not a shell parser.
  static LaunchCommand? parseExec(String value) {
    if (value.isEmpty || _hasUnsafeLaunchSyntax(value)) return null;
    final stripped = _stripFieldCodes(value);
    if (stripped == null || stripped.isEmpty) return null;

    final tokens = _tokenize(stripped);
    if (tokens == null || tokens.isEmpty || tokens.first.isEmpty) return null;

    final executable = tokens.first;
    final basename = p.basename(executable);
    if ((basename == 'flatpak' || basename == 'snap') &&
        (tokens.length < 3 || tokens[1] != 'run' || tokens[2].isEmpty)) {
      return null;
    }
    return LaunchCommand(executable, tokens.skip(1));
  }

  static DesktopEntry? parse(String contents, {String? sourcePath}) {
    var inEntry = false;
    var foundEntry = false;
    var malformed = false;
    final values = <String, String>{};

    final lines = contents.split('\n');
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index].trim();
      if (index == 0 && line.startsWith('\uFEFF')) {
        line = line.substring(1).trimLeft();
      }
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('[')) {
        if (!line.endsWith(']')) {
          if (inEntry) malformed = true;
          continue;
        }
        inEntry = line.substring(1, line.length - 1).trim() == 'Desktop Entry';
        foundEntry = foundEntry || inEntry;
        continue;
      }

      if (!inEntry) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) {
        malformed = true;
        continue;
      }
      final key = line.substring(0, separator).trim();
      if (!_validKey.hasMatch(key)) {
        malformed = true;
        continue;
      }
      values.putIfAbsent(key, () => line.substring(separator + 1).trim());
    }

    if (!foundEntry || malformed) return null;
    final name = values['Name'];
    final exec = values['Exec'];
    if (name == null || name.isEmpty || exec == null || exec.isEmpty) {
      return null;
    }
    final icon = values['Icon'];
    return DesktopEntry(
      name: name,
      exec: exec,
      icon: icon == null || icon.isEmpty ? null : icon,
      sourcePath: sourcePath,
    );
  }

  /// Mirrors existing payload-based deduplication, retaining the first entry.
  static List<DesktopEntry> deduplicateByExec(Iterable<DesktopEntry> entries) {
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.exec)) entry,
    ];
  }

  static final _validKey = RegExp(r'^[A-Za-z][A-Za-z0-9-]*(?:\[[^=\]]+\])?$');

  static bool _hasUnsafeLaunchSyntax(String value) {
    for (final unit in value.codeUnits) {
      if (unit <= 0x1f || unit == 0x7f) return true;
    }
    // These are shell operators/substitution markers, not argv data. Reject
    // them even inside quotes so a legacy payload cannot smuggle shell syntax
    // through a permissive quote parser.
    return value.contains(';') ||
        value.contains('&') ||
        value.contains('|') ||
        value.contains('<') ||
        value.contains('>') ||
        value.contains('`') ||
        value.contains(r'$');
  }

  static String? _stripFieldCodes(String value) {
    final result = StringBuffer();
    for (var index = 0; index < value.length; index++) {
      final char = value[index];
      if (char != '%') {
        result.write(char);
        continue;
      }
      if (index + 1 >= value.length) return null;
      final code = value[++index];
      if (code == '%') {
        result.write('%');
      } else if ('fFuUdDicCk'.contains(code)) {
        // File/URL/name/icon/desktop-file field codes have no value in a
        // button launch, so safely omit them rather than passing them on.
      } else {
        return null;
      }
    }
    return result.toString();
  }

  static List<String>? _tokenize(String value) {
    final tokens = <String>[];
    final token = StringBuffer();
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var tokenStarted = false;

    void finishToken() {
      if (tokenStarted) {
        tokens.add(token.toString());
        token.clear();
        tokenStarted = false;
      }
    }

    for (var index = 0; index < value.length; index++) {
      final char = value[index];
      if (inSingleQuote) {
        if (char == "'") {
          inSingleQuote = false;
        } else {
          token.write(char);
        }
        tokenStarted = true;
        continue;
      }
      if (inDoubleQuote) {
        if (char == '"') {
          inDoubleQuote = false;
        } else if (char == '\\') {
          if (++index >= value.length) return null;
          token.write(value[index]);
        } else {
          token.write(char);
        }
        tokenStarted = true;
        continue;
      }

      if (char == "'") {
        inSingleQuote = true;
        tokenStarted = true;
      } else if (char == '"') {
        inDoubleQuote = true;
        tokenStarted = true;
      } else if (char == '\\') {
        if (++index >= value.length) return null;
        token.write(value[index]);
        tokenStarted = true;
      } else if (char.trim().isEmpty) {
        finishToken();
      } else {
        token.write(char);
        tokenStarted = true;
      }
    }

    if (inSingleQuote || inDoubleQuote) return null;
    finishToken();
    return tokens;
  }
}

/// Resolves icons only within caller-approved directories.
///
/// A Linux adapter can supply Debian's /usr/share/icons and
/// /usr/share/pixmaps, Flatpak's exported icons, and Snap icon locations.
/// Other platforms can supply their own roots without Linux-specific checks.
class IconPathValidator {
  IconPathValidator(Iterable<String> approvedRoots)
    : approvedRoots = List.unmodifiable(approvedRoots);

  static const supportedExtensions = {'png', 'svg', 'xpm'};
  final List<String> approvedRoots;

  /// Returns the canonical path of a supported image, or null if disallowed.
  String? resolve(String icon) {
    final value = icon.trim();
    if (value.isEmpty || _containsTraversal(value)) return null;
    final roots = _canonicalRoots();
    if (roots.isEmpty) return null;

    final absolute = p.isAbsolute(value);
    final hasSeparator = value.contains('/') || value.contains('\\');
    final extension = _extension(value);

    // File paths must explicitly name a supported image. Icon names may
    // contain dots (e.g. Flatpak IDs), so do not interpret every dotted name
    // as a filename unless it also contains a directory separator.
    if (absolute || hasSeparator || supportedExtensions.contains(extension)) {
      if (!supportedExtensions.contains(extension)) return null;
      for (final root in roots) {
        final resolved = _approvedFile(value, root, absolute: absolute);
        if (resolved != null) return resolved;
      }
      return null;
    }

    // A bare filename with a clearly unsupported image extension is not an
    // icon theme name. Dotted application IDs remain valid icon theme names.
    if (_unsupportedImageExtensions.contains(extension)) return null;
    for (final root in roots) {
      for (final extension in supportedExtensions) {
        final resolved = _approvedFile(
          p.join(root, '$value.$extension'),
          root,
          absolute: true,
        );
        if (resolved != null) return resolved;
      }
    }
    return _findNamedIcon(value, roots);
  }

  List<String> _canonicalRoots() {
    final roots = <String>[];
    for (final root in approvedRoots) {
      try {
        final canonical = Directory(root).resolveSymbolicLinksSync();
        if (Directory(canonical).existsSync() && !roots.contains(canonical)) {
          roots.add(canonical);
        }
      } on FileSystemException {
        // A missing or inaccessible root contributes no icons.
      }
    }
    return roots;
  }

  String? _findNamedIcon(String name, List<String> roots) {
    for (final root in roots) {
      try {
        final entities = Directory(root).listSync(
          recursive: true,
          followLinks: false,
        )..sort((a, b) => a.path.compareTo(b.path));
        for (final entity in entities) {
          if (entity is! File ||
              p.basenameWithoutExtension(entity.path) != name) {
            continue;
          }
          if (!supportedExtensions.contains(_extension(entity.path))) continue;
          final resolved = _approvedFile(entity.path, root, absolute: true);
          if (resolved != null) return resolved;
        }
      } on FileSystemException {
        // Ignore unreadable roots rather than failing discovery.
      }
    }
    return null;
  }

  String? _approvedFile(String input, String root, {required bool absolute}) {
    final candidate = absolute ? input : p.join(root, input);
    if (!supportedExtensions.contains(_extension(candidate))) return null;
    try {
      final canonical = File(candidate).resolveSymbolicLinksSync();
      if (!_isWithin(canonical, root) || !File(canonical).existsSync()) {
        return null;
      }
      if (!supportedExtensions.contains(_extension(canonical))) return null;
      return canonical;
    } on FileSystemException {
      return null;
    }
  }

  static bool _isWithin(String candidate, String root) {
    final relative = p.relative(candidate, from: root);
    return relative != '..' &&
        !relative.startsWith('..${p.separator}') &&
        !p.isAbsolute(relative);
  }

  static bool _containsTraversal(String value) =>
      value.split(RegExp(r'[\\/]+')).contains('..');

  static String _extension(String value) {
    final extension = p.extension(value);
    return extension.isEmpty ? '' : extension.substring(1).toLowerCase();
  }

  static const _unsupportedImageExtensions = {
    'bmp',
    'gif',
    'ico',
    'jpeg',
    'jpg',
    'webp',
    'tif',
    'tiff',
  };
}
