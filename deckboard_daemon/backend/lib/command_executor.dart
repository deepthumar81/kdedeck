import 'dart:io';

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
  const ProcessCommandExecutor();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return Process.run(executable, arguments, environment: environment);
  }
}
