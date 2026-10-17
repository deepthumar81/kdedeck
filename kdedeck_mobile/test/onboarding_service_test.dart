import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/services/onboarding_service.dart';

const _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, dynamic> _payload({
  String host = 'pc.local',
  String? expires,
}) =>
    {
      'version': 1,
      'host': host,
      'port': 8484,
      'certificate_sha256': _fingerprint,
      'challenge': 'ABCD_1234',
      'issued_at': DateTime.now().toUtc().toIso8601String(),
      'expires_at': expires ??
          DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 2))
              .toIso8601String(),
    };

void main() {
  test('parses a daemon enrollment payload without manual PEM entry', () {
    final invite = EnrollmentInvite.parse(jsonEncode(_payload()));
    expect(invite.name, 'KDE Deck PC');
    expect(invite.host, 'pc.local');
    expect(invite.port, 8484);
    expect(invite.challenge, 'ABCD_1234');
    expect(invite.certificateSha256, _fingerprint);
  });

  test('rejects unsupported, malformed, and expired enrollment', () {
    expect(
        () => EnrollmentInvite.parse(jsonEncode({..._payload(), 'version': 2})),
        throwsFormatException);
    expect(() => EnrollmentInvite.parse(jsonEncode(_payload(host: '127.1'))),
        throwsFormatException);
    expect(
        () => EnrollmentInvite.parse(jsonEncode(_payload(
            expires: DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 1))
                .toIso8601String()))),
        throwsFormatException);
    expect(
        () => EnrollmentInvite.parse(
            jsonEncode({..._payload(), 'certificate_sha256': 'bad'})),
        throwsFormatException);
  });

  test('discovery seam returns hosts and allows cancellation/timeout',
      () async {
    final discovery = _FakeDiscovery([
      const DiscoveredHost(
          name: 'Living Room PC', host: '192.168.1.20', port: 8484),
    ]);
    expect(await discovery.discover(), hasLength(1));
    expect((await discovery.discover()).single.host, '192.168.1.20');

    final slow = _FakeDiscovery(const [], delay: const Duration(seconds: 1));
    expect(
      slow.discover(timeout: const Duration(milliseconds: 5)),
      throwsA(isA<TimeoutException>()),
    );
  });
}

class _FakeDiscovery implements HostDiscovery {
  _FakeDiscovery(this.hosts, {this.delay = Duration.zero});
  final List<DiscoveredHost> hosts;
  final Duration delay;

  @override
  Future<List<DiscoveredHost>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (delay > timeout) {
      await Future<void>.delayed(timeout);
      throw TimeoutException('discovery timed out');
    }
    await Future<void>.delayed(delay);
    return hosts;
  }
}
