import 'dart:io';

import 'package:backend/system_actions_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('kdedeck-linux-icons');
  });

  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  test('builds narrow default, user, XDG, Flatpak, and Snap roots', () async {
    final home = p.join(fixture.path, 'home');
    final dataHome = p.join(fixture.path, 'xdg-data');
    final snap = p.join(fixture.path, 'snap');
    await Directory(p.join(snap, 'good-app', 'revisions', '42', 'meta/gui'))
        .create(recursive: true);
    await Link(p.join(snap, 'good-app', 'current'))
        .create(p.join(snap, 'good-app', 'revisions', '42'));
    await Directory(p.join(snap, 'bad_app', 'current', 'meta/gui'))
        .create(recursive: true);

    final roots = SystemActionsService.linuxIconRootsFor({
      'HOME': home,
      'XDG_DATA_HOME': dataHome,
    }, snapRoot: snap);

    expect(roots, contains('/usr/share/icons'));
    expect(roots, contains('/usr/share/pixmaps'));
    expect(roots, contains('/var/lib/flatpak/exports/share/icons'));
    expect(roots, contains('/var/lib/snapd/desktop/icons'));
    expect(roots, contains(p.join(home, '.local/share/icons')));
    expect(roots, contains(p.join(home, '.local/share/pixmaps')));
    expect(roots, contains(p.join(dataHome, 'icons')));
    expect(roots, contains(p.join(dataHome, 'pixmaps')));
    expect(roots, contains(p.join(dataHome, 'flatpak/exports/share/icons')));
    expect(roots, contains(p.join(snap, 'good-app/current/meta/gui')));
    expect(roots, isNot(contains(p.join(snap, 'bad_app/current/meta/gui'))));
    expect(roots.every(p.isAbsolute), isTrue);
    expect(roots.every((root) => !root.contains('null')), isTrue);
  });

  test('fails closed for missing HOME and unsafe XDG values', () {
    final roots = SystemActionsService.linuxIconRootsFor({
      'XDG_DATA_HOME': 'relative-data',
    }, snapRoot: p.join(fixture.path, 'missing-snap'));

    expect(roots, contains('/usr/share/icons'));
    expect(roots, contains('/usr/share/pixmaps'));
    expect(roots, contains('/var/lib/flatpak/exports/share/icons'));
    expect(roots, contains('/var/lib/snapd/desktop/icons'));
    expect(roots, isNot(contains(contains('relative-data'))));
    expect(roots.every((root) => !root.contains('null')), isTrue);
    expect(roots.every((root) => !root.contains('.local')), isTrue);
  });

  test(
    'indexes bounded in-root icon links without following cycles or escapes',
    () async {
      final root = Directory(p.join(fixture.path, 'icons'));
      final outside = Directory(p.join(fixture.path, 'outside'));
      await root.create(recursive: true);
      await outside.create(recursive: true);
      await File(p.join(root.path, 'real.png')).writeAsBytes([1]);
      await File(p.join(outside.path, 'escape.png')).writeAsBytes([1]);
      await Link(p.join(root.path, 'linked.png'))
          .create(p.join(root.path, 'real.png'));
      await Link(p.join(root.path, 'escape.png'))
          .create(p.join(outside.path, 'escape.png'));
      await Link(p.join(root.path, 'cycle')).create(root.path);

      final icons = await SystemActionsService.indexLinuxIconsForRoots([
        root.path,
      ]);

      expect(icons['real'], p.join(root.path, 'real.png'));
      expect(icons['linked'], p.join(root.path, 'linked.png'));
      expect(icons, isNot(contains('escape')));
    },
  );
}
