import 'dart:io';

import 'package:backend/command_executor.dart';
import 'package:backend/system_actions_service.dart';
import 'package:test/test.dart';

final class _Invocation {
  _Invocation(this.executable, this.arguments, this.environment);

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

final class _RecordingExecutor implements CommandExecutor {
  final List<_Invocation> invocations = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    invocations.add(
      _Invocation(executable, List<String>.from(arguments), environment),
    );
    return ProcessResult(0, 0, '', '');
  }
}

void main() {
  group('SystemActionsService URL launches', () {
    late _RecordingExecutor executor;

    setUp(() {
      executor = _RecordingExecutor();
    });

    test('passes valid HTTP(S) URLs as one argv value', () async {
      if (!Platform.isLinux) return;

      for (final url in [
        'http://example.test/path',
        'https://example.test/path?q=one%20two',
        'HTTPS://example.test/uppercase-scheme',
      ]) {
        await SystemActionsService.executeLaunch(url, executor: executor);
      }

      expect(executor.invocations, hasLength(3));
      expect(
        executor.invocations.map((invocation) => invocation.executable),
        everyElement('xdg-open'),
      );
      expect(executor.invocations[0].arguments, ['http://example.test/path']);
      expect(executor.invocations[1].arguments, [
        'https://example.test/path?q=one%20two',
      ]);
      expect(executor.invocations[2].arguments, [
        'HTTPS://example.test/uppercase-scheme',
      ]);
      expect(executor.invocations[0].environment, {'DISPLAY': ':0'});
    });

    test('keeps shell metacharacters in a URL as data', () async {
      if (!Platform.isLinux) return;

      const url = 'https://example.test/path?x=one;echo-pwned|cat\$(id)';
      await SystemActionsService.executeLaunch(url, executor: executor);

      expect(executor.invocations, hasLength(1));
      expect(executor.invocations.single.executable, 'xdg-open');
      expect(executor.invocations.single.arguments, [url]);
    });

    test('rejects non-HTTP(S) schemes and malformed HTTP(S) URLs', () async {
      for (final value in [
        'javascript:alert(1)',
        'file:///tmp/example',
        'data:text/plain,hello',
        'ftp://example.test/file',
        '//example.test/path',
        'http://',
        'https:///missing-host',
      ]) {
        await SystemActionsService.executeLaunch(value, executor: executor);
      }

      expect(executor.invocations, isEmpty);
    });

    test(
      'rejects control characters in otherwise valid-looking URLs',
      () async {
        for (final value in [
          'https://example.test/path\nnext',
          'https://example.test/path\rnext',
          'https://example.test/path\tvalue',
        ]) {
          await SystemActionsService.executeLaunch(value, executor: executor);
        }

        expect(executor.invocations, isEmpty);
      },
    );
  });

  group('SystemActionsService application launches', () {
    late _RecordingExecutor executor;

    setUp(() {
      executor = _RecordingExecutor();
    });

    test('passes application payloads as an executable and argv', () async {
      if (!Platform.isLinux) return;

      await SystemActionsService.executeLaunch(
        '/usr/bin/example --title "A quoted title" --mode=test',
        executor: executor,
      );

      expect(executor.invocations, hasLength(1));
      expect(executor.invocations.single.executable, '/usr/bin/example');
      expect(executor.invocations.single.arguments, [
        '--title',
        'A quoted title',
        '--mode=test',
      ]);
      expect(executor.invocations.single.environment, {'DISPLAY': ':0'});
    });

    test('launches Flatpak and Snap payloads without a shell', () async {
      if (!Platform.isLinux) return;

      await SystemActionsService.executeLaunch(
        'flatpak run --branch=stable com.example.App',
        executor: executor,
      );
      await SystemActionsService.executeLaunch(
        'snap run example-app',
        executor: executor,
      );

      expect(
        executor.invocations.map(
          (invocation) => [invocation.executable, ...invocation.arguments],
        ),
        [
          ['flatpak', 'run', '--branch=stable', 'com.example.App'],
          ['snap', 'run', 'example-app'],
        ],
      );
    });

    test(
      'rejects shell injection and malformed application payloads',
      () async {
        for (final payload in [
          'example; touch /tmp/pwned',
          'example && echo pwned',
          r'example $(id)',
          'example\nnext',
          'example "unterminated',
        ]) {
          await SystemActionsService.executeLaunch(payload, executor: executor);
        }

        expect(executor.invocations, isEmpty);
      },
    );
  });

  group('SystemActionsService KDE actions', () {
    test('uses only the fixed KDE action allowlist', () async {
      if (!Platform.isLinux) return;

      final expected = <String, List<String>>{
        'sleep': ['systemctl', 'suspend'],
        'shutdown': ['systemctl', 'poweroff'],
        'lock': ['qdbus', 'org.kde.ksmserver', '/ScreenSaver', 'Lock'],
        'logout': [
          'qdbus',
          'org.kde.ksmserver',
          '/KSMServer',
          'logout',
          '0',
          '0',
          '0',
        ],
      };

      for (final entry in expected.entries) {
        final executor = _RecordingExecutor();
        await SystemActionsService.executeKdeAction(
          entry.key,
          executor: executor,
        );

        expect(executor.invocations, hasLength(1), reason: entry.key);
        expect([
          executor.invocations.single.executable,
          ...executor.invocations.single.arguments,
        ], entry.value);
      }

      final rejected = _RecordingExecutor();
      await SystemActionsService.executeKdeAction(
        'sh; echo should-not-run',
        executor: rejected,
      );
      await SystemActionsService.executeKdeAction(
        'qdbus org.kde.ksmserver /ScreenSaver Lock',
        executor: rejected,
      );
      expect(rejected.invocations, isEmpty);
    });
  });
}
