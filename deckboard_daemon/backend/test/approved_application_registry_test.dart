import 'package:backend/app_discovery.dart';
import 'package:backend/approved_application_registry.dart';
import 'package:test/test.dart';

void main() {
  test('reads the bounded JSON environment format', () {
    final registry = ApprovedApplicationRegistry.fromEnvironment({
      'KDEDECK_APPROVED_APPS':
          '{"example":{"executable":"/usr/bin/example",'
          '"arguments":["--title","fixed"]}}',
    });

    expect(registry.identities, ['example']);
    expect(registry.resolve('example')!.executable, '/usr/bin/example');
    expect(registry.resolve('example')!.arguments, ['--title', 'fixed']);
  });

  test(
    'fails closed for malformed, invalid, duplicate, or oversized input',
    () {
      const prefix =
          '{"good":{"executable":"/usr/bin/example","arguments":[]},';
      for (final raw in [
        '{"good":{"executable":"/usr/bin/example","arguments":[]}',
        '$prefix"bad":{"executable":"relative","arguments":[]}}',
        '{"same":{"executable":"/usr/bin/example","arguments":[]},'
            '"same":{"executable":"/usr/bin/example","arguments":[]}}',
        '{"good":{"executable":"/usr/bin/example","arguments":[]},'
            '"bad":{"executable":"/usr/bin/example","arguments":[1]}}',
      ]) {
        expect(
          ApprovedApplicationRegistry.fromEnvironment({
            'KDEDECK_APPROVED_APPS': raw,
          }).identities,
          isEmpty,
          reason: raw,
        );
      }

      final oversized =
          'x' * (ApprovedApplicationRegistry.maxEnvironmentLength + 1);
      expect(
        ApprovedApplicationRegistry.fromEnvironment({
          'KDEDECK_APPROVED_APPS': oversized,
        }).identities,
        isEmpty,
      );
    },
  );

  test('rejects duplicate nested fields and duplicate identities', () {
    for (final raw in [
      '{"app":{"executable":"/usr/bin/example",'
          '"executable":"/usr/bin/example","arguments":[]}}',
      '{"app":{"executable":"/usr/bin/example",'
          '"arguments":[],"arguments":[]}}',
    ]) {
      expect(
        ApprovedApplicationRegistry.fromEnvironment({
          'KDEDECK_APPROVED_APPS': raw,
        }).identities,
        isEmpty,
      );
    }
  });

  test('bounds entry count and argv in both construction paths', () {
    final entries = {
      for (var i = 0; i <= ApprovedApplicationRegistry.maxEntries; i++)
        'app$i': LaunchCommand('/usr/bin/example', const []),
    };
    expect(
      () => ApprovedApplicationRegistry(entries),
      throwsA(isA<ArgumentError>()),
    );
    final raw =
        '{${entries.keys.map((id) => '"$id":{"executable":"/usr/bin/example","arguments":[]}').join(',')}}';
    expect(
      ApprovedApplicationRegistry.fromEnvironment({
        'KDEDECK_APPROVED_APPS': raw,
      }).identities,
      isEmpty,
    );
    final tooManyArgs = List.filled(
      ApprovedApplicationRegistry.maxArguments + 1,
      'fixed',
    );
    expect(
      ApprovedApplicationRegistry.fromEnvironment({
        'KDEDECK_APPROVED_APPS':
            '{"app":{"executable":"/usr/bin/example",'
            '"arguments":${_jsonStrings(tooManyArgs)}}}',
      }).identities,
      isEmpty,
    );
  });

  test('validates direct definitions and defensively copies them', () {
    final sourceArguments = <String>['--fixed'];
    final source = <String, LaunchCommand>{
      'example': LaunchCommand('/usr/bin/example', sourceArguments),
    };
    final registry = ApprovedApplicationRegistry(source);
    sourceArguments.add('--changed');
    source['other'] = LaunchCommand('/usr/bin/example', const []);

    expect(registry.identities, ['example']);
    expect(registry.resolve('example')!.arguments, ['--fixed']);

    for (final command in [
      LaunchCommand('example', const []),
      LaunchCommand('/usr/bin/python3.12', const []),
      LaunchCommand('/usr/bin/node20', const []),
      LaunchCommand('/usr/bin/sh', const []),
      LaunchCommand('/usr/bin/example', List.filled(33, 'x')),
      LaunchCommand('/usr/bin/example', ['x' * 1025]),
    ]) {
      expect(
        () => ApprovedApplicationRegistry({'example': command}),
        throwsA(isA<ArgumentError>()),
      );
    }
    expect(
      () => ApprovedApplicationRegistry({
        'bad/id': LaunchCommand('/usr/bin/example', const []),
      }),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('allows fixed executable argv and only fixed snap/flatpak forms', () {
    final registry = ApprovedApplicationRegistry.fromEnvironment({
      'KDEDECK_APPROVED_APPS':
          '{'
          '"example":{"executable":"/usr/bin/example",'
          '"arguments":["--mode=test"]},'
          '"flat":{"executable":"/usr/bin/flatpak",'
          '"arguments":["run","com.example.App"]},'
          '"snap":{"executable":"/usr/bin/snap",'
          '"arguments":["run","example-app"]}}',
    });
    expect(registry.contains('example'), isTrue);
    expect(registry.contains('flat'), isTrue);
    expect(registry.contains('snap'), isTrue);

    for (final command in [
      LaunchCommand('/usr/bin/flatpak', const ['run', '--command=sh', 'app']),
      LaunchCommand('/usr/bin/flatpak', const ['run', 'app', '--devel']),
      LaunchCommand('/usr/bin/snap', const ['run', '--shell', 'app']),
      LaunchCommand('/usr/bin/snap', const ['install', 'app']),
    ]) {
      expect(
        () => ApprovedApplicationRegistry({'app': command}),
        throwsA(isA<ArgumentError>()),
      );
    }
  });

  test(
    'identity validation rejects paths, URLs, whitespace, and interpreters',
    () {
      for (final identity in [
        '/usr/bin/example',
        'https://example.test',
        'example app',
        'python3.12',
        'node20',
      ]) {
        expect(ApprovedApplicationRegistry.isValidIdentity(identity), isFalse);
      }
      expect(
        ApprovedApplicationRegistry.isValidIdentity('snap:example'),
        isTrue,
      );
    },
  );
}

String _jsonStrings(List<String> strings) =>
    '[${strings.map((value) => '"$value"').join(',')}]';
