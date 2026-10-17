import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Versioned, bounded data needed by a client to select and pin a daemon.
///
/// This object deliberately contains no private key, session token, or device
/// identifier. The challenge is single-use and is consumed by the daemon when
/// it is presented in an enrollment authentication frame.
final class EnrollmentPayload {
  EnrollmentPayload({
    required this.version,
    required this.host,
    required this.port,
    required this.certificateSha256,
    required this.challenge,
    required this.expiresAt,
    DateTime? issuedAt,
  }) : issuedAt = (issuedAt ?? DateTime.now().toUtc()).toUtc();

  static const int currentVersion = 1;
  static const int maxHostBytes = 253;
  static const int maxChallengeBytes = 128;
  static const Duration maxLifetime = Duration(minutes: 5);

  final int version;
  final String host;
  final int port;
  final String certificateSha256;
  final String challenge;
  final DateTime issuedAt;
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
    'version': version,
    'host': host,
    'port': port,
    'certificate_sha256': certificateSha256,
    'challenge': challenge,
    'issued_at': issuedAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  /// Parses only the exact bounded wire shape. Unknown fields are rejected so
  /// clients cannot accidentally accept an unaudited future variant.
  static EnrollmentPayload parse(Object? value, {DateTime Function()? clock}) {
    if (value is! Map) throw const FormatException('Malformed enrollment');
    const expected = <String>{
      'version',
      'host',
      'port',
      'certificate_sha256',
      'challenge',
      'issued_at',
      'expires_at',
    };
    final keys = value.keys.whereType<String>().toSet();
    if (keys.length != value.length ||
        !keys.containsAll(expected) ||
        keys.length != expected.length) {
      throw const FormatException('Malformed enrollment');
    }
    final version = value['version'];
    final host = value['host'];
    final port = value['port'];
    final certificate = value['certificate_sha256'];
    final challenge = value['challenge'];
    final issued = value['issued_at'];
    final expires = value['expires_at'];
    if (version is! int ||
        version != currentVersion ||
        host is! String ||
        port is! int ||
        certificate is! String ||
        challenge is! String ||
        issued is! String ||
        expires is! String) {
      throw const FormatException('Malformed enrollment');
    }
    final hostBytes = utf8.encode(host);
    if (host.isEmpty ||
        hostBytes.length > maxHostBytes ||
        host.contains('/') ||
        host.contains('\\') ||
        host.contains(':') ||
        host.contains(' ') ||
        host.contains('\u0000') ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(certificate) ||
        utf8.encode(issued).length > 64 ||
        utf8.encode(expires).length > 64 ||
        challenge.isEmpty ||
        utf8.encode(challenge).length > maxChallengeBytes ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(challenge)) {
      throw const FormatException('Malformed enrollment');
    }
    DateTime issuedAt;
    DateTime expiresAt;
    try {
      issuedAt = DateTime.parse(issued).toUtc();
      expiresAt = DateTime.parse(expires).toUtc();
    } catch (_) {
      throw const FormatException('Malformed enrollment');
    }
    final now = (clock ?? (() => DateTime.now().toUtc()))().toUtc();
    if (!expiresAt.isAfter(now) ||
        expiresAt.isBefore(issuedAt) ||
        expiresAt.difference(issuedAt) > maxLifetime ||
        issuedAt.isAfter(now.add(const Duration(seconds: 30)))) {
      throw const FormatException('Expired enrollment');
    }
    return EnrollmentPayload(
      version: version,
      host: host,
      port: port,
      certificateSha256: certificate,
      challenge: challenge,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
  }
}

/// Single-use challenge state for enrollment discovery.
final class EnrollmentChallengeStore {
  EnrollmentChallengeStore({
    DateTime Function()? clock,
    Random? random,
    this.maxOutstanding = 16,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _random = random ?? Random.secure() {
    if (maxOutstanding <= 0) throw ArgumentError.value(maxOutstanding);
  }

  static const int _challengeBytes = 32;
  final DateTime Function() _clock;
  final Random _random;
  final int maxOutstanding;
  final Map<String, EnrollmentPayload> _pending = {};

  EnrollmentPayload issue({
    required String host,
    required int port,
    required String certificateSha256,
    Duration lifetime = const Duration(minutes: 2),
  }) {
    _removeExpired();
    if (lifetime <= Duration.zero || lifetime > EnrollmentPayload.maxLifetime) {
      throw ArgumentError.value(lifetime, 'lifetime');
    }
    if (_pending.length >= maxOutstanding) {
      throw StateError('Enrollment capacity reached');
    }
    final challenge = base64Url
        .encode(
          List<int>.generate(_challengeBytes, (_) => _random.nextInt(256)),
        )
        .replaceAll('=', '');
    final now = _clock().toUtc();
    final payload = EnrollmentPayload(
      version: EnrollmentPayload.currentVersion,
      host: host,
      port: port,
      certificateSha256: certificateSha256,
      challenge: challenge,
      issuedAt: now,
      expiresAt: now.add(lifetime),
    );
    _pending[challenge] = payload;
    return payload;
  }

  /// Consumes a challenge only when every public binding matches the issued
  /// record. This makes edits to host, port, certificate identity, or expiry
  /// fail closed, and makes replay fail after the first successful use.
  bool consume(EnrollmentPayload candidate) {
    _removeExpired();
    final issued = _pending[candidate.challenge];
    if (issued == null ||
        candidate.version != issued.version ||
        candidate.host != issued.host ||
        candidate.port != issued.port ||
        candidate.certificateSha256 != issued.certificateSha256 ||
        candidate.issuedAt != issued.issuedAt ||
        candidate.expiresAt != issued.expiresAt ||
        !_constantTimeEquals(candidate.challenge, issued.challenge)) {
      return false;
    }
    _pending.remove(candidate.challenge);
    return true;
  }

  void _removeExpired() {
    final now = _clock().toUtc();
    _pending.removeWhere((_, payload) => !payload.expiresAt.isAfter(now));
  }

  static bool _constantTimeEquals(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    var difference = a.length ^ b.length;
    final length = max(a.length, b.length);
    for (var i = 0; i < length; i++) {
      difference |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
    }
    return difference == 0;
  }
}

/// SHA-256 identity of the DER certificate represented by a PEM file.
String certificateSha256FromPem(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) throw const FormatException('Malformed certificate');
  final der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  return sha256.convert(der).toString();
}
