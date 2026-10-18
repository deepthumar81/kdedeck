import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backend/mdns_service_advertiser.dart';
import 'package:test/test.dart';

void main() {
  test('uses the Android NSD service type', () {
    expect(MdnsServiceAdvertiser.serviceType, '_kde-deck._tcp');
    expect(MdnsServiceAdvertiser.serviceTypeFqdn, '_kde-deck._tcp.local');
  });

  test('announcement contains only bounded public DNS-SD metadata', () {
    final packet = MdnsServicePacket.encodeAnnouncement(
      port: 8484,
      addresses: [InternetAddress('192.168.50.12')],
    );
    final records = _records(packet);

    expect(
      records.map((record) => record.name),
      contains('KDE Deck._kde-deck._tcp.local'),
    );
    expect(
      records.map((record) => record.name),
      contains('_kde-deck._tcp.local'),
    );
    expect(records.map((record) => record.name), contains('kdedeck.local'));
    expect(
      records.any(
        (record) =>
            record.type == 1 && _sameBytes(record.rdata, [192, 168, 50, 12]),
      ),
      isTrue,
    );
    expect(records.any((record) => record.type == 33), isTrue);
    expect(
      _txtValues(records),
      containsAll(['protocol=1', 'tls=1', 'path=/ws']),
    );

    final text = utf8.decode(packet, allowMalformed: true);
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('token')));
    expect(text, isNot(contains('pairing')));
    expect(text, isNot(contains('device')));
  });

  test('query matcher recognizes service and ignores unrelated queries', () {
    expect(
      MdnsServicePacket.isQueryForService(
        _query('_kde-deck._tcp.local', type: 12),
      ),
      isTrue,
    );
    expect(
      MdnsServicePacket.isQueryForService(_query('_http._tcp.local', type: 12)),
      isFalse,
    );
    expect(
      MdnsServicePacket.isQueryForService(
        _query('_kde-deck._tcp.local', type: 12, response: true),
      ),
      isFalse,
    );
  });

  test(
    'lifecycle announces, answers discovery, and sends goodbye records',
    () async {
      final transport = _FakeTransport();
      final advertiser = MdnsServiceAdvertiser(
        transportFactory: () async => transport,
        addressProvider: () async => [InternetAddress('10.0.0.25')],
        announcementInterval: const Duration(hours: 1),
      );

      await advertiser.start(port: 8484);
      expect(advertiser.isRunning, isTrue);
      expect(transport.sent, hasLength(1));
      transport.queries.add(_query('_kde-deck._tcp.local', type: 12));
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent, hasLength(2));

      await advertiser.stop();
      expect(advertiser.isRunning, isFalse);
      expect(transport.closed, isTrue);
      expect(transport.sent, hasLength(3));
      expect(
        _records(transport.sent.last).every((record) => record.ttl == 0),
        isTrue,
      );
    },
  );

  test('no usable LAN address keeps the advertiser silent', () async {
    final transport = _FakeTransport();
    final advertiser = MdnsServiceAdvertiser(
      transportFactory: () async => transport,
      addressProvider: () async => [
        InternetAddress.loopbackIPv4,
        InternetAddress('169.254.12.3'),
      ],
    );

    await advertiser.start(port: 8484);
    expect(advertiser.isRunning, isFalse);
    expect(transport.sent, isEmpty);
    expect(transport.closed, isFalse);
  });
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _FakeTransport implements MdnsDatagramTransport {
  final StreamController<List<int>> _queriesController =
      StreamController<List<int>>();
  final List<List<int>> sent = <List<int>>[];
  bool closed = false;

  StreamSink<List<int>> get queries => _queriesController.sink;

  @override
  Stream<List<int>> get packets => _queriesController.stream;

  @override
  void send(List<int> packet) => sent.add(packet);

  @override
  Future<void> close() async {
    closed = true;
    await _queriesController.close();
  }
}

final class _Record {
  const _Record(this.name, this.type, this.ttl, this.rdata);

  final String name;
  final int type;
  final int ttl;
  final List<int> rdata;
}

List<_Record> _records(List<int> packet) {
  final count = (packet[6] << 8) | packet[7];
  var offset = 12;
  final records = <_Record>[];
  for (var index = 0; index < count; index++) {
    final name = _name(packet, offset);
    offset = name.$2;
    final type = (packet[offset] << 8) | packet[offset + 1];
    final ttl =
        (packet[offset + 4] << 24) |
        (packet[offset + 5] << 16) |
        (packet[offset + 6] << 8) |
        packet[offset + 7];
    final length = (packet[offset + 8] << 8) | packet[offset + 9];
    final start = offset + 10;
    records.add(
      _Record(name.$1, type, ttl, packet.sublist(start, start + length)),
    );
    offset = start + length;
  }
  return records;
}

List<String> _txtValues(List<_Record> records) {
  final values = <String>[];
  for (final record in records.where((record) => record.type == 16)) {
    var offset = 0;
    while (offset < record.rdata.length) {
      final length = record.rdata[offset++];
      values.add(utf8.decode(record.rdata.sublist(offset, offset + length)));
      offset += length;
    }
  }
  return values;
}

(String, int) _name(List<int> packet, int offset) {
  final labels = <String>[];
  while (packet[offset] != 0) {
    final length = packet[offset++];
    labels.add(utf8.decode(packet.sublist(offset, offset + length)));
    offset += length;
  }
  return (labels.join('.'), offset + 1);
}

List<int> _query(String name, {required int type, bool response = false}) {
  final bytes = <int>[0, 0, response ? 0x84 : 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final label in name.split('.')) {
    final encoded = utf8.encode(label);
    bytes.add(encoded.length);
    bytes.addAll(encoded);
  }
  bytes.add(0);
  bytes.add(type >> 8);
  bytes.add(type & 0xff);
  bytes.add(0);
  bytes.add(1);
  return bytes;
}
