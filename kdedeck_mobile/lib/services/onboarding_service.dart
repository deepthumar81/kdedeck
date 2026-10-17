import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Exact versioned enrollment payload emitted by the daemon.
///
/// It contains only public endpoint/certificate identity and a short-lived
/// single-use challenge. No private key, bearer token, or certificate bypass is
/// accepted. TLS remains responsible for hostname and validity-period checks.
class EnrollmentInvite {
  EnrollmentInvite({
    required this.version,
    required this.host,
    required this.port,
    required this.certificateSha256,
    required this.challenge,
    required this.issuedAt,
    required this.expiresAt,
  }) {
    if (version != 1 || port < 1 || port > 65535) {
      throw const FormatException('Malformed enrollment');
    }
    _validateHost(host);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(certificateSha256) ||
        challenge.isEmpty ||
        challenge.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(challenge)) {
      throw const FormatException('Malformed enrollment');
    }
    final now = DateTime.now().toUtc();
    if (!expiresAt.isAfter(now) ||
        expiresAt.isBefore(issuedAt) ||
        expiresAt.difference(issuedAt) > const Duration(minutes: 5) ||
        issuedAt.isAfter(now.add(const Duration(seconds: 30)))) {
      throw const FormatException('Expired enrollment');
    }
  }

  final int version;
  final String host;
  final int port;
  final String certificateSha256;
  final String challenge;
  final DateTime issuedAt;
  final DateTime expiresAt;

  String get name => 'KDE Deck PC';

  factory EnrollmentInvite.parse(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Malformed enrollment');
    }
    if (decoded is! Map) throw const FormatException('Malformed enrollment');
    const expected = <String>{
      'version',
      'host',
      'port',
      'certificate_sha256',
      'challenge',
      'issued_at',
      'expires_at',
    };
    final map = Map<String, dynamic>.from(decoded);
    if (map.length != expected.length ||
        !map.keys.toSet().containsAll(expected)) {
      throw const FormatException('Malformed enrollment');
    }
    final issued = DateTime.tryParse(map['issued_at']?.toString() ?? '');
    final expires = DateTime.tryParse(map['expires_at']?.toString() ?? '');
    if (issued == null ||
        expires == null ||
        map['version'] is! int ||
        map['port'] is! int ||
        map['host'] is! String ||
        map['certificate_sha256'] is! String ||
        map['challenge'] is! String) {
      throw const FormatException('Malformed enrollment');
    }
    return EnrollmentInvite(
      version: map['version'] as int,
      host: map['host'] as String,
      port: map['port'] as int,
      certificateSha256: map['certificate_sha256'] as String,
      challenge: map['challenge'] as String,
      issuedAt: issued.toUtc(),
      expiresAt: expires.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'host': host,
        'port': port,
        'certificate_sha256': certificateSha256,
        'challenge': challenge,
        'issued_at': issuedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  static void _validateHost(String host) {
    // The daemon's enrollment protocol intentionally emits DNS names or IPv4
    // literals. IPv6 can remain a future version rather than an ambiguous QR.
    if (host.isEmpty ||
        host.length > 253 ||
        host != host.trim() ||
        host.contains(RegExp(r'[/@?#\s\[\]:\\\u0000]'))) {
      throw const FormatException('Malformed enrollment');
    }
    final labels = host.split('.');
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
      final validIp = labels.length == 4 &&
          labels.every((label) {
            final value = int.tryParse(label);
            return value != null &&
                label.length <= 3 &&
                (label.length == 1 || !label.startsWith('0')) &&
                value <= 255;
          });
      if (!validIp) throw const FormatException('Malformed enrollment');
      return;
    }
    if (!labels.every((label) =>
        label.isNotEmpty &&
        label.length <= 63 &&
        RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$')
            .hasMatch(label))) {
      throw const FormatException('Malformed enrollment');
    }
  }
}

class DiscoveredHost {
  const DiscoveredHost(
      {required this.name, required this.host, required this.port});

  final String name;
  final String host;
  final int port;

  factory DiscoveredHost.fromMap(Map<String, dynamic> data) => DiscoveredHost(
        name: (data['name'] ?? 'KDE Deck PC').toString(),
        host: data['host']?.toString() ?? '',
        port: data['port'] is int
            ? data['port'] as int
            : int.tryParse(data['port']?.toString() ?? '') ?? 0,
      );
}

abstract interface class HostDiscovery {
  Future<List<DiscoveredHost>> discover({Duration timeout});
}

class AndroidHostDiscovery implements HostDiscovery {
  const AndroidHostDiscovery();

  static const _channel =
      MethodChannel('io.github.deepthumar81.kdedeck/onboarding');

  @override
  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!Platform.isAndroid) return const <DiscoveredHost>[];
    final result = await _channel.invokeMethod<List<dynamic>>(
      'discoverKdeDeck',
      {'timeoutMs': timeout.inMilliseconds.clamp(500, 15000)},
    ).timeout(timeout + const Duration(seconds: 1));
    return (result ?? const <dynamic>[]).whereType<Map>().map((entry) {
      return DiscoveredHost.fromMap(Map<String, dynamic>.from(entry));
    }).toList();
  }
}

typedef EnrollmentScanner = Future<String?> Function();

Future<String?> unavailableEnrollmentScanner() async => null;
