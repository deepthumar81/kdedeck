import 'dart:io';
import 'dart:convert';

import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kdedeck-tls-provision-');
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'provisions SAN certificate, private key, and fingerprint manifest',
    () async {
      final result = await _run([
        '--hostname',
        'localhost',
        '--hostname',
        '127.0.0.1',
        '--output-dir',
        temp.path,
        '--days',
        '30',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);

      final certificate = File('${temp.path}/server.crt');
      final key = File('${temp.path}/server.key');
      final manifest = File('${temp.path}/server.sha256');
      final trustArtifact = File('${temp.path}/server.kdedeck-trust.json');
      expect(await certificate.exists(), isTrue);
      expect(await key.exists(), isTrue);
      expect(await manifest.exists(), isTrue);
      expect(await trustArtifact.exists(), isTrue);
      expect(await key.length(), greaterThan(0));
      expect(await manifest.readAsString(), startsWith('SHA256:'));
      final artifact = jsonDecode(await trustArtifact.readAsString()) as Map;
      expect(artifact['format'], 'kdedeck-trust');
      expect(artifact['version'], 1);
      expect(artifact['certificate_pem'], contains('BEGIN CERTIFICATE'));
      expect(
        artifact['sha256'],
        await manifest.readAsString().then((s) => s.trim()),
      );
      expect(artifact.containsKey('private_key'), isFalse);

      final inspection = await Process.run('openssl', [
        'x509',
        '-in',
        certificate.path,
        '-noout',
        '-text',
      ]);
      expect(inspection.exitCode, 0);
      expect(inspection.stdout, contains('DNS:localhost'));
      expect(inspection.stdout, contains('IP Address:127.0.0.1'));
      if (!Platform.isWindows) {
        expect(_mode(key.path), '600');
        expect(_mode(certificate.path), '644');
        expect(_mode(manifest.path), '644');
        expect(_mode(trustArtifact.path), '644');
      }
    },
  );

  test(
    'refuses accidental overwrite and requires force for rotation',
    () async {
      final args = ['--hostname', 'localhost', '--output-dir', temp.path];
      expect((await _run(args)).exitCode, 0);
      final first = await File('${temp.path}/server.sha256').readAsString();
      final refused = await _run(args);
      expect(refused.exitCode, 2);
      expect(refused.stderr, contains('already exist'));
      expect(await File('${temp.path}/server.sha256').readAsString(), first);

      final rotated = await _run([...args, '--force']);
      expect(rotated.exitCode, 0, reason: rotated.stderr);
      expect(
        await File('${temp.path}/server.sha256').readAsString(),
        isNot(first),
      );
    },
  );
}

Future<ProcessResult> _run(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/tls_provision.dart', ...arguments],
  workingDirectory: Directory.current.path,
  environment: {'PATH': Platform.environment['PATH'] ?? ''},
);

String _mode(String path) =>
    Process.runSync('stat', ['-c', '%a', path]).stdout.toString().trim();
