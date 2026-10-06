import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) exitCode = 64;
  switch (args.first) {
    case 'normal':
      stdout.write('probe stdout');
      stderr.write('probe stderr');
      break;
    case 'nonzero':
      stdout.write('nonzero stdout');
      stderr.write('nonzero stderr');
      exitCode = int.parse(args[1]);
      break;
    case 'argv-env':
      stdout.write(
        jsonEncode({
          'argv': args.sublist(1),
          'env': Platform.environment['KDEDECK_PROBE_VALUE'],
        }),
      );
      break;
    case 'hang':
      await _hang(args[1], ignoreTerm: args.length > 2);
      break;
    case 'flood':
      await _flood(int.parse(args[1]));
      break;
    case 'hold-pipe':
      await _holdPipe(args[1]);
      break;
    case 'hold-child':
      stdout.write('descendant output');
      await stdout.flush();
      await _keepAlive();
      break;
    case 'is-alive':
      exitCode = Platform.isLinux && File('/proc/${args[1]}').existsSync()
          ? 0
          : 1;
      break;
    default:
      exitCode = 64;
  }
}

Future<void> _hang(String pidFile, {required bool ignoreTerm}) async {
  await File(pidFile).writeAsString('$pid');
  if (ignoreTerm && !Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) {});
  }
  await _keepAlive();
}

Future<void> _flood(int size) async {
  final chunk = List<int>.filled(4096, 65);
  var remaining = size;
  while (remaining > 0) {
    final count = remaining < chunk.length ? remaining : chunk.length;
    stdout.add(chunk.sublist(0, count));
    stderr.add(chunk.sublist(0, count));
    remaining -= count;
  }
  await Future.wait([stdout.flush(), stderr.flush()]);
  await _keepAlive();
}

Future<void> _keepAlive() => Future<void>.delayed(const Duration(days: 1));

Future<void> _holdPipe(String pidFile) async {
  final child = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    'hold-child',
  ], mode: ProcessStartMode.detachedWithStdio);
  await File(pidFile).writeAsString('${child.pid}');
  await _keepAlive();
}
