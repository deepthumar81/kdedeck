import 'dart:convert';

import 'package:backend/enrollment_protocol.dart';
import 'package:test/test.dart';

void main() {
  final fingerprint = 'a' * 64;
  late _FakeClock clock;

  setUp(() {
    clock = _FakeClock(DateTime.utc(2026, 1, 1));
  });

  test('round-trips a bounded versioned payload', () {
    final store = EnrollmentChallengeStore(clock: clock.now);
    final issued = store.issue(
      host: '192.168.1.20',
      port: 8484,
      certificateSha256: fingerprint,
    );

    final parsed = EnrollmentPayload.parse(
      jsonDecode(issued.encode()),
      clock: clock.now,
    );
    expect(parsed.version, EnrollmentPayload.currentVersion);
    expect(parsed.scheme, 'https');
    expect(parsed.host, '192.168.1.20');
    expect(store.consume(parsed), isTrue);
  });

  test('rejects expired payloads', () {
    final store = EnrollmentChallengeStore(clock: clock.now);
    final issued = store.issue(
      host: 'host.example',
      port: 443,
      certificateSha256: fingerprint,
      lifetime: const Duration(seconds: 1),
    );
    clock.advance(const Duration(seconds: 2));
    expect(
      () => EnrollmentPayload.parse(
        jsonDecode(issued.encode()),
        clock: clock.now,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(store.consume(issued), isFalse);
  });

  test('rejects malformed and unsupported enrollment data', () {
    expect(
      () => EnrollmentPayload.parse({'version': 1}),
      throwsA(isA<FormatException>()),
    );
    final valid = {
      'version': EnrollmentPayload.currentVersion,
      'scheme': 'https',
      'host': 'host.example',
      'port': 8484,
      'certificate_sha256': fingerprint,
      'challenge': 'abc_DEF-123',
      'issued_at': clock.now().toIso8601String(),
      'expires_at': clock
          .now()
          .add(const Duration(minutes: 1))
          .toIso8601String(),
      'unexpected': true,
    };
    expect(
      () => EnrollmentPayload.parse(valid, clock: clock.now),
      throwsA(isA<FormatException>()),
    );
    final wrongScheme = Map<String, dynamic>.of(valid)
      ..remove('unexpected')
      ..['scheme'] = 'http';
    expect(
      () => EnrollmentPayload.parse(wrongScheme, clock: clock.now),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects replayed and tampered challenge data', () {
    final store = EnrollmentChallengeStore(clock: clock.now);
    final issued = store.issue(
      host: 'host.example',
      port: 8484,
      certificateSha256: fingerprint,
    );
    final tampered = EnrollmentPayload(
      version: issued.version,
      host: issued.host,
      port: issued.port + 1,
      certificateSha256: issued.certificateSha256,
      challenge: issued.challenge,
      issuedAt: issued.issuedAt,
      expiresAt: issued.expiresAt,
    );
    expect(store.consume(tampered), isFalse);
    expect(store.consume(issued), isTrue);
    expect(store.consume(issued), isFalse);
  });
}

final class _FakeClock {
  _FakeClock(this.current);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) => current = current.add(duration);
}
