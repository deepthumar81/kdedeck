import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Executes a program with an explicit executable and argument vector.
///
/// Keeping this behind an interface lets callers test command construction
/// without starting processes or involving a shell.
abstract interface class CommandExecutor {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  });
}

/// The production command executor used by the standalone backend.
final class ProcessCommandExecutor implements CommandExecutor {
  const ProcessCommandExecutor()
    : _timeout = null,
      _terminationGrace = null,
      _maxOutputBytes = null;

  /// Opt-in limits for commands whose output and lifetime must be bounded.
  factory ProcessCommandExecutor.bounded({
    Duration timeout = const Duration(seconds: 15),
    Duration terminationGrace = const Duration(milliseconds: 250),
    int maxOutputBytes = 1048576,
  }) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
    }
    if (terminationGrace <= Duration.zero) {
      throw ArgumentError.value(
        terminationGrace,
        'terminationGrace',
        'Must be positive',
      );
    }
    if (maxOutputBytes <= 0) {
      throw ArgumentError.value(
        maxOutputBytes,
        'maxOutputBytes',
        'Must be positive',
      );
    }
    return ProcessCommandExecutor._bounded(
      timeout,
      terminationGrace,
      maxOutputBytes,
    );
  }

  const ProcessCommandExecutor._bounded(
    this._timeout,
    this._terminationGrace,
    this._maxOutputBytes,
  );

  final Duration? _timeout;
  final Duration? _terminationGrace;
  final int? _maxOutputBytes;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final timeout = _timeout;
    if (timeout == null) {
      return Process.run(executable, arguments, environment: environment);
    }

    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        environment: environment,
        runInShell: false,
      );
    } catch (_) {
      throw const CommandExecutionException(CommandFailure.start);
    }

    // Start the deadline as soon as the direct child has been acquired. Waiting
    // for exit alone is insufficient: inherited pipe handles can outlive it.
    final failure = Completer<void>();
    CommandFailure? reason;
    StreamSubscription<List<int>>? stdoutSubscription;
    StreamSubscription<List<int>>? stderrSubscription;
    final stdout = BytesBuilder(copy: false);
    final stderr = BytesBuilder(copy: false);
    var totalBytes = 0;
    var exited = false;
    var exitCode = 0;

    void fail(CommandFailure value) {
      if (reason != null) return;
      reason = value;
      stdoutSubscription?.pause();
      stderrSubscription?.pause();
      failure.complete();
    }

    final deadline = Timer(timeout, () => fail(CommandFailure.timeout));

    void collect(List<int> data, BytesBuilder target) {
      if (reason != null) return;
      if (data.length > _maxOutputBytes! - totalBytes) {
        fail(CommandFailure.outputLimit);
        return;
      }
      totalBytes += data.length;
      target.add(data);
    }

    // Every completion future has an error handler before the first await.
    // A failed pipe/close is a controlled failure rather than an unhandled
    // asynchronous error or a wait for a never-ending drain.
    final exitDone = process.exitCode.then<void>((code) {
      exitCode = code;
      exited = true;
    }, onError: (Object _, StackTrace _) => fail(CommandFailure.io));
    try {
      final stdoutDone = Completer<void>();
      stdoutSubscription = process.stdout.listen(
        (data) => collect(data, stdout),
        onError: (Object _, StackTrace _) {
          fail(CommandFailure.io);
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
        onDone: () {
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
        cancelOnError: true,
      );
      final stderrDone = Completer<void>();
      stderrSubscription = process.stderr.listen(
        (data) => collect(data, stderr),
        onError: (Object _, StackTrace _) {
          fail(CommandFailure.io);
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
        onDone: () {
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
        cancelOnError: true,
      );
      final stdinDone = process.stdin.close().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) => fail(CommandFailure.io),
      );
      final allDone = Future.wait<void>([
        exitDone,
        stdoutDone.future,
        stderrDone.future,
        stdinDone,
      ]);
      await Future.any<void>([allDone, failure.future]);
      if (reason != null) {
        throw CommandExecutionException(reason!);
      }
      return ProcessResult(
        process.pid,
        exitCode,
        utf8.decode(stdout.takeBytes(), allowMalformed: true),
        utf8.decode(stderr.takeBytes(), allowMalformed: true),
      );
    } catch (_) {
      // Never include OS exceptions, command data, or captured output in the
      // public error. Kill only the direct child; this is not a process tree.
      if (!exited) {
        try {
          process.kill(
            Platform.isWindows ? ProcessSignal.sigkill : ProcessSignal.sigterm,
          );
        } catch (_) {}
        await _waitFor(exitDone, _terminationGrace!);
        if (!exited && !Platform.isWindows) {
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
          await _waitFor(exitDone, _terminationGrace);
        }
      }
      throw CommandExecutionException(reason ?? CommandFailure.io);
    } finally {
      deadline.cancel();
      // Cancellation does not depend on pipe closure. Observe cancellation
      // errors but never delay settlement on descendant-held pipe handles.
      if (stdoutSubscription != null) {
        unawaited(stdoutSubscription.cancel().catchError((Object _) {}));
      }
      if (stderrSubscription != null) {
        unawaited(stderrSubscription.cancel().catchError((Object _) {}));
      }
    }
  }
}

/// Safe reason codes, deliberately without command, argument or OS payloads.
enum CommandFailure { start, timeout, outputLimit, io }

final class CommandExecutionException implements Exception {
  const CommandExecutionException(this.reason);

  final CommandFailure reason;

  @override
  String toString() => 'CommandExecutionException: ${reason.name}';
}

Future<void> _waitFor(Future<void> completion, Duration duration) async {
  final elapsed = Completer<void>();
  final timer = Timer(duration, elapsed.complete);
  try {
    await Future.any<void>([completion, elapsed.future]);
  } finally {
    timer.cancel();
  }
}
