import 'dart:convert';
import 'dart:io';

import 'package:backend/command_executor.dart';
import 'package:test/test.dart';

void main() {
  final probe = File('test/support/command_executor_probe.dart').absolute.path;

  test('legacy executor captures normal output and stderr', () async {
    final result = await const ProcessCommandExecutor().run(
      Platform.resolvedExecutable,
      [probe, 'normal'],
    );

    expect(result.exitCode, 0);
    expect(result.stdout, 'probe stdout');
    expect(result.stderr, 'probe stderr');
  }, timeout: Timeout(Duration(seconds: 5)));

  test(
    'bounded executor preserves nonzero exit and argv/environment',
    () async {
      final executor = ProcessCommandExecutor.bounded();
      final nonzero = await executor.run(Platform.resolvedExecutable, [
        probe,
        'nonzero',
        '17',
      ]);
      final values = await executor.run(
        Platform.resolvedExecutable,
        [probe, 'argv-env', 'one', 'two words'],
        environment: {'KDEDECK_PROBE_VALUE': 'present'},
      );

      expect(nonzero.exitCode, 17);
      expect(nonzero.stdout, 'nonzero stdout');
      expect(nonzero.stderr, 'nonzero stderr');
      expect(jsonDecode(values.stdout), {
        'argv': ['one', 'two words'],
        'env': 'present',
      });
    },
    timeout: Timeout(Duration(seconds: 5)),
  );

  test('bounded options must be positive', () {
    expect(
      () => ProcessCommandExecutor.bounded(timeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => ProcessCommandExecutor.bounded(
        terminationGrace: Duration(microseconds: -1),
      ),
      throwsArgumentError,
    );
    expect(
      () => ProcessCommandExecutor.bounded(maxOutputBytes: 0),
      throwsArgumentError,
    );
  });

  test(
    'timeout kills the direct child, including a TERM-ignoring child',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final directory = await Directory.systemTemp.createTemp(
        'kdedeck-command-',
      );
      addTearDown(() => directory.delete(recursive: true));
      for (final mode in ['normal', 'ignore']) {
        final pidFile = '${directory.path}/$mode.pid';
        final args = [probe, 'hang', pidFile];
        if (mode == 'ignore') args.add('ignore-term');
        final error = await _failure(
          ProcessCommandExecutor.bounded(
            timeout: const Duration(milliseconds: 500),
            terminationGrace: const Duration(milliseconds: 100),
          ).run(Platform.resolvedExecutable, args),
        );

        expect(error.reason, CommandFailure.timeout);
        final childPid = int.parse(await _waitForFile(pidFile));
        await _waitUntilGone(childPid);
      }
    },
    timeout: Timeout(Duration(seconds: 5)),
  );

  test('output limit bounds combined stdout and stderr bytes', () async {
    final error = await _failure(
      ProcessCommandExecutor.bounded(
        timeout: const Duration(seconds: 2),
        maxOutputBytes: 4096,
      ).run(Platform.resolvedExecutable, [probe, 'flood', '100000']),
    );

    expect(error.reason, CommandFailure.outputLimit);
  }, timeout: Timeout(Duration(seconds: 5)));

  test('start failures are sanitized and the executor is reusable', () async {
    const missing = '/definitely/not-an-executable';
    final executor = ProcessCommandExecutor.bounded(
      timeout: const Duration(seconds: 1),
    );
    final error = await _failure(executor.run(missing, ['secret-argument']));

    expect(error.reason, CommandFailure.start);
    expect(error.toString(), isNot(contains(missing)));
    expect(error.toString(), isNot(contains('secret-argument')));

    final result = await executor.run(Platform.resolvedExecutable, [
      probe,
      'normal',
    ]);
    expect(result.exitCode, 0);
  }, timeout: Timeout(Duration(seconds: 5)));

  test('deadline settles when a descendant holds the output pipe', () async {
    if (!Platform.isLinux) return;
    final directory = await Directory.systemTemp.createTemp('kdedeck-pipe-');
    addTearDown(() => directory.delete(recursive: true));
    final pidFile = '${directory.path}/descendant.pid';
    final stopwatch = Stopwatch()..start();
    final error = await _failure(
      ProcessCommandExecutor.bounded(
        timeout: const Duration(milliseconds: 500),
        terminationGrace: const Duration(milliseconds: 100),
      ).run(Platform.resolvedExecutable, [probe, 'hold-pipe', pidFile]),
    );
    stopwatch.stop();

    expect(error.reason, CommandFailure.timeout);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    final descendantPid = int.parse(await _waitForFile(pidFile));
    Process.killPid(descendantPid, ProcessSignal.sigkill);
    await _waitUntilGone(descendantPid);
  }, timeout: Timeout(Duration(seconds: 5)));
}

Future<CommandExecutionException> _failure(Future<ProcessResult> future) async {
  try {
    await future;
  } on CommandExecutionException catch (error) {
    return error;
  }
  throw StateError('Expected CommandExecutionException');
}

Future<String> _waitForFile(String path) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    final file = File(path);
    if (file.existsSync()) return file.readAsString();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Probe did not create its pid file');
}

Future<void> _waitUntilGone(int childPid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (!File('/proc/$childPid').existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('direct child $childPid is still alive');
}
