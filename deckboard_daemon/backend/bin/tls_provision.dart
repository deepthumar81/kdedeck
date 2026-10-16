import 'dart:io';

const _usage = '''Usage:
  dart run bin/tls_provision.dart --hostname <name-or-ip> [options]

Options:
  --hostname <value>       Subject alternative name; repeat for each name/IP.
  --output-dir <path>      Destination directory (default: ~/.config/kdedeck/tls).
  --days <number>          Certificate lifetime in days (default: 365).
  --force                  Replace an existing certificate and key.
  --help                   Show this help.
''';

Future<void> main(List<String> arguments) async {
  try {
    final options = _parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }
    if (options.hostnames.isEmpty) {
      throw const FormatException('at least one --hostname is required');
    }

    final output = Directory(options.outputDirectory);
    await output.create(recursive: true);
    _restrict(output.path, '700');

    final certificate = File('${output.path}/server.crt');
    final key = File('${output.path}/server.key');
    final fingerprint = File('${output.path}/server.sha256');
    if (!options.force &&
        (certificate.existsSync() ||
            key.existsSync() ||
            fingerprint.existsSync())) {
      throw StateError(
        'TLS files already exist; use --force only for intentional rotation',
      );
    }

    final san = options.hostnames.map(_sanEntry).join(',');
    final commonName = options.hostnames.first;
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '${options.days}',
      '-subj',
      '/CN=$commonName',
      '-addext',
      'subjectAltName=$san',
      '-keyout',
      key.path,
      '-out',
      certificate.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('OpenSSL could not create the TLS certificate');
    }
    _restrict(key.path, '600');
    _restrict(certificate.path, '644');

    final digest = await Process.run('openssl', [
      'x509',
      '-in',
      certificate.path,
      '-noout',
      '-fingerprint',
      '-sha256',
    ]);
    if (digest.exitCode != 0) {
      throw StateError('OpenSSL could not read the certificate fingerprint');
    }
    final line = digest.stdout.toString().trim();
    final separator = line.indexOf('=');
    if (separator < 0 || separator == line.length - 1) {
      throw StateError('OpenSSL returned an invalid certificate fingerprint');
    }
    final normalized = line
        .substring(separator + 1)
        .replaceAll(':', '')
        .toUpperCase();
    await fingerprint.writeAsString('SHA256:$normalized\n', flush: true);
    _restrict(fingerprint.path, '644');

    stdout.writeln('Certificate: ${certificate.path}');
    stdout.writeln('Private key: ${key.path}');
    stdout.writeln('Fingerprint: SHA256:$normalized');
    stdout.writeln(
      'Verify this fingerprint through a trusted local channel before trusting the certificate.',
    );
  } catch (error) {
    final message = error is FormatException
        ? error.message
        : error is StateError
        ? error.message
        : 'TLS provisioning failed';
    stderr.writeln(message);
    exitCode = 2;
  }
}

String _sanEntry(String value) =>
    InternetAddress.tryParse(value) == null ? 'DNS:$value' : 'IP:$value';

void _restrict(String target, String mode) {
  if (Platform.isWindows) return;
  final result = Process.runSync('chmod', [mode, target]);
  if (result.exitCode != 0) {
    throw StateError('TLS file permissions unavailable');
  }
}

_Options _parse(List<String> arguments) {
  final hostnames = <String>[];
  var outputDirectory = _defaultOutputDirectory();
  var days = 365;
  var force = false;
  var help = false;

  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    switch (argument) {
      case '--help':
        help = true;
      case '--force':
        force = true;
      case '--hostname':
        if (++index >= arguments.length) {
          throw const FormatException('missing --hostname value');
        }
        final value = arguments[index];
        _validateHostname(value);
        hostnames.add(value);
      case '--output-dir':
        if (++index >= arguments.length) {
          throw const FormatException('missing --output-dir value');
        }
        outputDirectory = arguments[index];
        if (!pathIsAbsolute(outputDirectory)) {
          throw const FormatException('output directory must be absolute');
        }
      case '--days':
        if (++index >= arguments.length) {
          throw const FormatException('missing --days value');
        }
        days = int.tryParse(arguments[index]) ?? 0;
        if (days < 1 || days > 825) {
          throw const FormatException('--days must be between 1 and 825');
        }
      default:
        throw FormatException('unknown argument: $argument');
    }
  }
  return _Options(hostnames, outputDirectory, days, force, help);
}

void _validateHostname(String value) {
  if (value.isEmpty ||
      value.length > 253 ||
      value.contains(RegExp(r'[\x00\s/@?#\[\]]'))) {
    throw const FormatException('invalid hostname or IP address');
  }
  if (InternetAddress.tryParse(value) != null) return;
  final labels = value.split('.');
  if (labels.any(
    (label) =>
        label.isEmpty ||
        label.length > 63 ||
        !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(label),
  )) {
    throw const FormatException('invalid hostname or IP address');
  }
}

String _defaultOutputDirectory() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty || !pathIsAbsolute(home)) {
    return './tls';
  }
  return '$home/.config/kdedeck/tls';
}

bool pathIsAbsolute(String value) =>
    value.startsWith('/') ||
    (Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value));

final class _Options {
  const _Options(
    this.hostnames,
    this.outputDirectory,
    this.days,
    this.force,
    this.help,
  );

  final List<String> hostnames;
  final String outputDirectory;
  final int days;
  final bool force;
  final bool help;
}
