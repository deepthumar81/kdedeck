import 'dart:io';

import 'package:backend/app_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('DesktopEntryParser', () {
    test('parses quoted argv and strips desktop field codes', () {
      final launch = DesktopEntryParser.parseExec(
        '/usr/bin/example --title "A quoted title" --url https://example.test %U',
      );

      expect(launch, isNotNull);
      expect(launch!.executable, '/usr/bin/example');
      expect(launch.arguments, [
        '--title',
        'A quoted title',
        '--url',
        'https://example.test',
      ]);
    });

    test('accepts explicit Flatpak and Snap launch forms', () {
      final flatpak = DesktopEntryParser.parseExec(
        '/usr/bin/flatpak run --branch=stable com.example.App %F',
      );
      final snap = DesktopEntryParser.parseExec('snap run example-app');

      expect(flatpak, isNotNull);
      expect(flatpak!.executable, '/usr/bin/flatpak');
      expect(flatpak.arguments, ['run', '--branch=stable', 'com.example.App']);
      expect(snap, isNotNull);
      expect(snap!.executable, 'snap');
      expect(snap.arguments, ['run', 'example-app']);
    });

    test('rejects shell syntax, control characters, and malformed quoting', () {
      for (final payload in [
        'example; touch /tmp/pwned',
        r'example --arg $(id)',
        'example | cat',
        'example\nother',
        'example "unterminated',
        'example trailing\\',
        '%U',
        'snap list',
      ]) {
        expect(DesktopEntryParser.parseExec(payload), isNull, reason: payload);
      }
    });

    test('parses Debian, Flatpak, and Snap launch templates unchanged', () {
      final debian = DesktopEntryParser.parse('''
[Desktop Entry]
Type=Application
Name=Debian App
Exec=debian-app --new-window %U
Icon=debian-app
''');
      final flatpak = DesktopEntryParser.parse('''
[Desktop Entry]
Name=Flatpak App
Exec=/usr/bin/flatpak run --branch=stable com.example.App %F
Icon=com.example.App
''');
      final snap = DesktopEntryParser.parse('''
[Desktop Entry]
Name=Snap App
Exec=snap run example-app %U
Icon=example-app
''');

      expect(debian, isNotNull);
      expect(debian!.name, 'Debian App');
      expect(debian.exec, 'debian-app --new-window %U');
      expect(
        flatpak!.exec,
        '/usr/bin/flatpak run --branch=stable com.example.App %F',
      );
      expect(snap!.exec, 'snap run example-app %U');
    });

    test('rejects malformed entries', () {
      expect(
        DesktopEntryParser.parse('[Desktop Entry]\nName=Missing exec'),
        isNull,
      );
      expect(
        DesktopEntryParser.parse('[Desktop Entry]\nName=Broken\nnot a key'),
        isNull,
      );
      expect(DesktopEntryParser.parse('Name=No section\nExec=app'), isNull);
    });

    test('keeps the first value when keys are duplicated', () {
      final entry = DesktopEntryParser.parse('''
[Desktop Entry]
Name=First Name
Name=Second Name
Exec=first-command %U
Exec=second-command %F
Icon=first-icon
Icon=second-icon
''');

      expect(entry, isNotNull);
      expect(entry!.name, 'First Name');
      expect(entry.exec, 'first-command %U');
      expect(entry.icon, 'first-icon');
    });

    test('deduplicates exact launch templates while preserving order', () {
      final entries = [
        const DesktopEntry(name: 'One', exec: 'app %U'),
        const DesktopEntry(name: 'Duplicate', exec: 'app %U'),
        const DesktopEntry(name: 'Different field code', exec: 'app %F'),
      ];

      final unique = DesktopEntryParser.deduplicateByExec(entries);
      expect(unique.map((entry) => entry.name), [
        'One',
        'Different field code',
      ]);
    });
  });

  group('IconPathValidator', () {
    late Directory fixture;
    late Directory debianIcons;
    late Directory flatpakIcons;
    late Directory snapIcons;
    late Directory outside;
    late IconPathValidator validator;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('deckboard-app-discovery-');
      debianIcons = Directory(
        '${fixture.path}/usr/share/icons/hicolor/48x48/apps',
      )..createSync(recursive: true);
      flatpakIcons = Directory(
        '${fixture.path}/var/lib/flatpak/exports/share/icons/hicolor/64x64/apps',
      )..createSync(recursive: true);
      snapIcons = Directory('${fixture.path}/snap/example/current/meta/gui')
        ..createSync(recursive: true);
      outside = Directory('${fixture.path}/outside')..createSync();

      File('${debianIcons.path}/debian-app.png')
          .writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      File('${flatpakIcons.path}/com.example.App.svg')
          .writeAsStringSync('<svg xmlns="http://www.w3.org/2000/svg"/>');
      File('${snapIcons.path}/example-app.xpm').writeAsStringSync(
        '/* XPM */\nstatic char * icon[] = {"1 1 1 1", "a c #000000", "a"};',
      );
      File('${outside.path}/outside.png').writeAsBytesSync([1, 2, 3]);

      validator = IconPathValidator([
        '${fixture.path}/usr/share/icons',
        '${fixture.path}/var/lib/flatpak/exports/share/icons',
        '${fixture.path}/snap/example/current/meta/gui',
      ]);
    });

    tearDown(() {
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });

    test(
      'resolves valid PNG, SVG, and XPM icon names below approved roots',
      () {
        expect(validator.resolve('debian-app'), endsWith('/debian-app.png'));
        expect(
          validator.resolve('com.example.App'),
          endsWith('/com.example.App.svg'),
        );
        expect(validator.resolve('example-app'), endsWith('/example-app.xpm'));
      },
    );

    test('rejects traversal and absolute paths outside approved roots', () {
      expect(validator.resolve('../outside/outside.png'), isNull);
      expect(validator.resolve('${outside.path}/outside.png'), isNull);
      expect(validator.resolve('debian-app.jpg'), isNull);
    });

    test('rejects symlink escapes', () {
      final link = File('${debianIcons.path}/escape.png');
      try {
        Link(link.path).createSync('${outside.path}/outside.png');
      } on FileSystemException {
        // Some non-Linux test hosts disallow symlink creation. The helper is
        // still covered by the path and root checks above on those hosts.
        return;
      }
      expect(validator.resolve('hicolor/48x48/apps/escape.png'), isNull);
      expect(validator.resolve('escape.png'), isNull);
    });

    test('rejects unsupported extensions even when the file exists', () {
      final unsupported = File('${debianIcons.path}/unsupported.jpg')
        ..writeAsBytesSync([1, 2, 3]);

      expect(validator.resolve(unsupported.path), isNull);
      expect(validator.resolve('unsupported.jpg'), isNull);
    });
  });
}
