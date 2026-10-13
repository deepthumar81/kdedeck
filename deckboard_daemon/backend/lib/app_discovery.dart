import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

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

/// A bounded, validated snapshot. Serve [bytes] directly; do not reopen [path].
class ApprovedIcon {
  ApprovedIcon(this.canonicalPath, this.extension, List<int> bytes)
    : bytes = List.unmodifiable(bytes);

  final String canonicalPath;
  final String extension;
  final List<int> bytes;

  /// Compatibility alias for callers that use the resolved path generically.
  String get path => canonicalPath;
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
  static const maxIconBytes = 4 * 1024 * 1024;
  static const _maxNamedIconEntries = 4096;
  static const _maxNamedIconDepth = 32;
  final List<String> approvedRoots;

  /// Accepts only explicit supported paths (absolute or relative to an
  /// approved root), and returns the exact approved content for HTTP serving.
  /// A bare filename with a supported extension is an explicit file path.
  Future<ApprovedIcon?> readApprovedIcon(
    String absoluteOrRelativeFilePath,
  ) async {
    final value = absoluteOrRelativeFilePath.trim();
    if (!_validInput(value) ||
        !supportedExtensions.contains(_extension(value))) {
      return null;
    }
    final roots = _canonicalRoots();
    final absolute = p.isAbsolute(value);
    for (final root in roots) {
      final candidate = absolute ? value : p.join(root, value);
      RandomAccessFile? handle;
      try {
        final canonical = await File(candidate).resolveSymbolicLinks();
        if (!_isWithin(canonical, root) ||
            !supportedExtensions.contains(_extension(canonical)) ||
            _extension(candidate) != _extension(canonical)) {
          continue;
        }
        final file = File(canonical);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size > maxIconBytes) {
          continue;
        }
        handle = await file.open();
        if (await handle.length() > maxIconBytes) {
          continue;
        }
        final bytes = await _readBounded(handle, maxIconBytes + 1);
        if (bytes.isEmpty || bytes.length > maxIconBytes) {
          continue;
        }
        final validated = _validatedBytes(bytes, _extension(canonical));
        if (validated == null || !_stillApproved(candidate, canonical, root)) {
          continue;
        }
        return ApprovedIcon(canonical, _extension(canonical), validated);
      } catch (_) {
        // Unreadable, disappearing, or invalid entries are not approved.
      } finally {
        try {
          await handle?.close();
        } catch (_) {
          // No path is served on a failed read.
        }
      }
    }
    return null;
  }

  /// Returns the canonical path of a supported image, or null if disallowed.
  String? resolve(String icon) {
    final value = icon.trim();
    if (!_validInput(value)) {
      return null;
    }
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

  static bool _validInput(String value) =>
      value.isNotEmpty &&
      value.length <= _maxIconInputLength &&
      !_containsUnsafeCharacters(value) &&
      !_containsTraversal(value);

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
      final pending = <({Directory directory, int depth})>[
        (directory: Directory(root), depth: 0),
      ];
      var inspected = 0;

      while (pending.isNotEmpty && inspected < _maxNamedIconEntries) {
        final current = pending.removeLast();
        List<FileSystemEntity> entities;
        try {
          entities = Directory(current.directory.path).listSync(
            followLinks: false,
          )..sort((a, b) => b.path.compareTo(a.path));
        } catch (_) {
          // Ignore unreadable directories rather than failing discovery.
          continue;
        }

        for (final entity in entities) {
          if (++inspected > _maxNamedIconEntries) break;
          if (entity is Directory) {
            if (current.depth < _maxNamedIconDepth) {
              pending.add((directory: entity, depth: current.depth + 1));
            }
            continue;
          }
          if (entity is! File ||
              p.basenameWithoutExtension(entity.path) != name ||
              !supportedExtensions.contains(_extension(entity.path))) {
            continue;
          }
          final resolved = _approvedFile(entity.path, root, absolute: true);
          if (resolved != null) return resolved;
        }
      }
    }
    return null;
  }

  String? _approvedFile(String input, String root, {required bool absolute}) {
    final candidate = absolute ? input : p.join(root, input);
    if (!supportedExtensions.contains(_extension(candidate))) return null;
    try {
      final canonical = File(candidate).resolveSymbolicLinksSync();
      if (!_isWithin(canonical, root)) {
        return null;
      }
      if (_extension(candidate) != _extension(canonical)) return null;
      final file = File(canonical);
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > maxIconBytes ||
          !supportedExtensions.contains(_extension(canonical)) ||
          !_hasSupportedContent(file, _extension(canonical)) ||
          !_stillApproved(candidate, canonical, root)) {
        return null;
      }
      return canonical;
    } catch (_) {
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

  static bool _containsUnsafeCharacters(String value) =>
      value.codeUnits.any((unit) => unit == 0 || unit <= 0x1f || unit == 0x7f);

  bool _stillApproved(String candidate, String canonical, String root) {
    try {
      return File(candidate).resolveSymbolicLinksSync() == canonical &&
          _isWithin(canonical, root) &&
          File(canonical).statSync().type == FileSystemEntityType.file &&
          _approvedRootStillCanonical(root);
    } catch (_) {
      return false;
    }
  }

  bool _approvedRootStillCanonical(String root) {
    for (final approvedRoot in approvedRoots) {
      try {
        if (Directory(approvedRoot).resolveSymbolicLinksSync() == root) {
          return true;
        }
      } catch (_) {
        // A replaced or inaccessible root is not approved.
      }
    }
    return false;
  }

  static bool _hasSupportedContent(File file, String extension) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      if (handle.lengthSync() > maxIconBytes) {
        return false;
      }
      final bytes = <int>[];
      while (bytes.length < maxIconBytes + 1) {
        final chunk = handle.readSync(maxIconBytes + 1 - bytes.length);
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
      }
      return bytes.isNotEmpty &&
          bytes.length <= maxIconBytes &&
          _validatedBytes(bytes, extension) != null;
    } catch (_) {
      return false;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {
        // The content check already fails closed if the file cannot be read.
      }
    }
  }

  static List<int>? _validatedBytes(List<int> bytes, String extension) {
    if (bytes.isEmpty || bytes.length > maxIconBytes) return null;
    if (extension == 'png') return _hasPngSignature(bytes) ? bytes : null;
    if (extension == 'xpm') return _hasXpmMarker(bytes) ? bytes : null;
    if (extension != 'svg') return null;
    try {
      final text = utf8.decode(bytes);
      final document = XmlDocument.parse(text);
      if (document.children.any((node) => node is XmlDoctype)) {
        return null;
      }
      final root = document.rootElement;
      if (root.name.local != 'svg' ||
          (root.name.namespaceUri != null &&
              root.name.namespaceUri != _svgNamespace)) {
        return null;
      }
      for (final element in [
        root,
        ...root.descendants.whereType<XmlElement>(),
      ]) {
        if (element.name.namespaceUri != null &&
                element.name.namespaceUri != _svgNamespace ||
            _unsafeElements.contains(element.name.local.toLowerCase())) {
          return null;
        }
        for (final attribute in element.attributes) {
          final name = attribute.name.local.toLowerCase();
          final value = attribute.value.trim();
          if (name == 'xmlns' || attribute.name.prefix == 'xmlns') continue;
          if (name.startsWith('on') ||
              name == 'src' ||
              name == 'base' ||
              _unsafeAnimationAttributes.contains(name) ||
              (attribute.name.namespaceUri != null &&
                  attribute.name.namespaceUri != _svgNamespace &&
                  attribute.name.namespaceUri != _xlinkNamespace &&
                  attribute.name.namespaceUri != _xmlnsNamespace) ||
              (name == 'href' && !_fragment.hasMatch(value)) ||
              (name == 'style' && !_safeStyle(value)) ||
              (!_safeUrls(value) && name != 'style')) {
            return null;
          }
        }
      }
      final output = utf8.encode(document.toXmlString());
      return output.length <= maxIconBytes ? output : null;
    } catch (_) {
      return null;
    }
  }

  static const _svgNamespace = 'http://www.w3.org/2000/svg';
  static const _xlinkNamespace = 'http://www.w3.org/1999/xlink';
  static const _xmlnsNamespace = 'http://www.w3.org/2000/xmlns/';
  static const _unsafeElements = {
    'script',
    'foreignobject',
    'style',
    'image',
    'audio',
    'video',
    'iframe',
    'object',
    'embed',
    'animate',
    'animatemotion',
    'animatetransform',
    'set',
    'discard',
    'handler',
    'listener',
  };
  static const _unsafeAnimationAttributes = {
    'begin',
    'dur',
    'repeatcount',
    'repeatdur',
    'restart',
    'end',
    'values',
    'keytimes',
    'keysplines',
    'attributename',
    'from',
    'to',
    'by',
    'additive',
    'accumulate',
    'animation',
    'animation-name',
    'transition',
  };
  static final _fragment = RegExp(r'^#[A-Za-z_][A-Za-z0-9_.:-]*$');
  static final _url = RegExp(r'url\s*\(', caseSensitive: false);
  static final _fragmentUrl = RegExp(
    r'''url\s*\(\s*["']?\s*#[A-Za-z_][A-Za-z0-9_.:-]*\s*["']?\s*\)''',
    caseSensitive: false,
  );

  static bool _safeUrls(String value) {
    final withoutFragments = value.replaceAll(_fragmentUrl, '');
    return !_url.hasMatch(withoutFragments) &&
        !RegExp(
          r'[@\\]|(?:javascript|data|file|https?):|//',
          caseSensitive: false,
        ).hasMatch(withoutFragments);
  }

  static bool _safeStyle(String value) {
    if (RegExp(r'[@\\{}<>]|/\*|\*/', caseSensitive: false).hasMatch(value) ||
        !_safeUrls(value)) {
      return false;
    }
    for (final declaration in value.split(';')) {
      if (declaration.trim().isEmpty) continue;
      final separator = declaration.indexOf(':');
      if (separator < 1 ||
          !_styleProperties.contains(
            declaration.substring(0, separator).trim().toLowerCase(),
          ) ||
          !RegExp(r'^[\w\s.,#%()+\-"\x27]*$')
              .hasMatch(declaration.substring(separator + 1))) {
        return false;
      }
    }
    return true;
  }

  static const _styleProperties = {
    'fill',
    'fill-opacity',
    'fill-rule',
    'stroke',
    'stroke-width',
    'stroke-opacity',
    'stroke-linecap',
    'stroke-linejoin',
    'stroke-dasharray',
    'opacity',
    'color',
    'display',
    'visibility',
    'stop-color',
    'stop-opacity',
    'clip-path',
    'mask',
    'filter',
    'font-family',
    'font-size',
    'font-weight',
    'text-anchor',
  };

  static bool _hasPngSignature(List<int> bytes) {
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    return bytes.length >= signature.length && _startsWith(bytes, signature);
  }

  static bool _hasXpmMarker(List<int> bytes) {
    final header = ascii.decode(bytes.take(64).toList(), allowInvalid: true);
    return header.trimLeft().startsWith('/* XPM */') &&
        RegExp(r'\bstatic\s+(?:const\s+)?char\b').hasMatch(header) &&
        bytes.length > 9;
  }

  static Future<List<int>> _readBounded(
    RandomAccessFile handle,
    int limit,
  ) async {
    final bytes = <int>[];
    while (bytes.length < limit) {
      final chunk = await handle.read(limit - bytes.length);
      if (chunk.isEmpty) break;
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static bool _startsWith(List<int> value, List<int> prefix) {
    for (var index = 0; index < prefix.length; index++) {
      if (value[index] != prefix[index]) return false;
    }
    return true;
  }

  static String _extension(String value) {
    final extension = p.extension(value);
    return extension.isEmpty ? '' : extension.substring(1).toLowerCase();
  }

  static const _maxIconInputLength = 4096;

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
