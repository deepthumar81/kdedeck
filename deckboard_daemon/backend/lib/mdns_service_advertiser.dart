import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The small transport seam keeps DNS-SD packet generation testable without
/// requiring a multicast-capable network in CI.
abstract interface class MdnsDatagramTransport {
  Stream<List<int>> get packets;

  void send(List<int> packet);

  Future<void> close();
}

abstract interface class MdnsAdvertiser {
  Future<void> start({required int port});

  Future<void> stop();
}

/// A bounded DNS-SD/mDNS advertisement for the standalone KDE Deck daemon.
///
/// This intentionally uses only dart:io. The service has a stable, generic
/// name and host name: no machine name, device id, certificate, credential,
/// pairing code, or bearer token is put on the multicast network.
final class MdnsServiceAdvertiser implements MdnsAdvertiser {
  MdnsServiceAdvertiser({
    Future<MdnsDatagramTransport> Function()? transportFactory,
    Future<List<InternetAddress>> Function()? addressProvider,
    Duration announcementInterval = const Duration(seconds: 1),
    Duration addressRetryInterval = const Duration(seconds: 5),
  }) : _transportFactory = transportFactory ?? _openTransport,
       _addressProvider = addressProvider ?? _localIpv4Addresses,
       _announcementInterval = _validateAnnouncementInterval(
         announcementInterval,
       ),
       _addressRetryInterval = _validateAnnouncementInterval(
         addressRetryInterval,
       );

  /// The DNS-SD service type used by Android NSD clients.
  static const String serviceType = '_kde-deck._tcp';
  static const String serviceTypeFqdn = '$serviceType.local';
  static const String serviceInstance = 'KDE Deck.$serviceTypeFqdn';
  static const String hostName = 'kdedeck.local';
  static final InternetAddress multicastAddress = InternetAddress(
    '224.0.0.251',
  );
  static const int multicastPort = 5353;
  static const int recordTtlSeconds = 120;
  static const int maxAddressRecords = 16;
  static const List<String> txtEntries = <String>[
    'protocol=1',
    'tls=1',
    'path=/ws',
  ];

  static Duration _validateAnnouncementInterval(Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(
        value,
        'announcementInterval',
        'must be greater than zero',
      );
    }
    return value;
  }

  final Future<MdnsDatagramTransport> Function() _transportFactory;
  final Future<List<InternetAddress>> Function() _addressProvider;
  final Duration _announcementInterval;
  final Duration _addressRetryInterval;
  MdnsDatagramTransport? _transport;
  StreamSubscription<List<int>>? _packetSubscription;
  Timer? _announcementTimer;
  Timer? _addressRetryTimer;
  bool _startInFlight = false;
  int _requestedPort = 0;
  int _port = 0;
  List<InternetAddress> _addresses = const <InternetAddress>[];

  bool get isRunning => _transport != null;

  @override
  Future<void> start({required int port}) async {
    if (isRunning || _startInFlight) return;
    if (port <= 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be a TCP port');
    }

    _requestedPort = port;
    _startInFlight = true;
    try {
      final addresses = _boundedAddresses(await _addressProvider());
      // A service without an address record is not useful to NSD clients. It
      // is also safer to remain silent on hosts with no usable LAN interface.
      // Keep a bounded retry alive so a daemon started before the network
      // interface is ready becomes discoverable without a restart.
      if (addresses.isEmpty) {
        _scheduleAddressRetry();
        return;
      }

      final transport = await _transportFactory();
      if (_requestedPort != port) {
        await transport.close();
        return;
      }
      _cancelAddressRetry();
      _port = port;
      _addresses = addresses;
      _transport = transport;
      try {
        _packetSubscription = transport.packets.listen(_handlePacket);
        _sendAnnouncement(recordTtlSeconds);
        _announcementTimer = Timer.periodic(_announcementInterval, (_) {
          if (isRunning) _sendAnnouncement(recordTtlSeconds);
        });
      } catch (_) {
        _transport = null;
        _announcementTimer?.cancel();
        _announcementTimer = null;
        await _packetSubscription?.cancel();
        _packetSubscription = null;
        await transport.close();
        _port = 0;
        _addresses = const <InternetAddress>[];
        rethrow;
      }
    } finally {
      _startInFlight = false;
    }
  }

  void _scheduleAddressRetry() {
    _addressRetryTimer ??= Timer.periodic(_addressRetryInterval, (_) {
      if (_requestedPort <= 0 || isRunning) {
        _cancelAddressRetry();
        return;
      }
      unawaited(start(port: _requestedPort));
    });
  }

  void _cancelAddressRetry() {
    _addressRetryTimer?.cancel();
    _addressRetryTimer = null;
  }

  @override
  Future<void> stop() async {
    _cancelAddressRetry();
    _requestedPort = 0;
    final transport = _transport;
    if (transport == null) return;

    // Fence incoming packets and the delayed second announcement before
    // sending goodbye records. This makes stop deterministic and prevents a
    // restart from receiving packets belonging to the old service instance.
    _transport = null;
    _announcementTimer?.cancel();
    _announcementTimer = null;
    await _packetSubscription?.cancel();
    _packetSubscription = null;
    try {
      transport.send(
        MdnsServicePacket.encodeAnnouncement(
          port: _port,
          addresses: _addresses,
          ttlSeconds: 0,
        ),
      );
    } finally {
      await transport.close();
      _port = 0;
      _addresses = const <InternetAddress>[];
    }
  }

  void _sendAnnouncement(int ttlSeconds) {
    final transport = _transport;
    if (transport == null) return;
    transport.send(
      MdnsServicePacket.encodeAnnouncement(
        port: _port,
        addresses: _addresses,
        ttlSeconds: ttlSeconds,
      ),
    );
  }

  void _handlePacket(List<int> packet) {
    if (!MdnsServicePacket.isQueryForService(packet)) return;
    _sendAnnouncement(recordTtlSeconds);
  }
}

/// Pure DNS-SD packet helpers used by [MdnsServiceAdvertiser] and its tests.
final class MdnsServicePacket {
  const MdnsServicePacket._();

  static List<int> encodeAnnouncement({
    required int port,
    required Iterable<InternetAddress> addresses,
    int ttlSeconds = MdnsServiceAdvertiser.recordTtlSeconds,
  }) {
    if (port <= 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be a TCP port');
    }
    if (ttlSeconds < 0 || ttlSeconds > 0xffffffff) {
      throw ArgumentError.value(ttlSeconds, 'ttlSeconds', 'must be uint32');
    }

    final ipv4 = _boundedAddresses(addresses);
    final records = <_DnsRecord>[
      _DnsRecord.ptr(
        MdnsServiceAdvertiser.serviceTypeFqdn,
        MdnsServiceAdvertiser.serviceInstance,
        ttlSeconds,
      ),
      _DnsRecord.srv(
        MdnsServiceAdvertiser.serviceInstance,
        MdnsServiceAdvertiser.hostName,
        port,
        ttlSeconds,
      ),
      _DnsRecord.txt(
        MdnsServiceAdvertiser.serviceInstance,
        MdnsServiceAdvertiser.txtEntries,
        ttlSeconds,
      ),
      for (final address in ipv4)
        _DnsRecord.a(MdnsServiceAdvertiser.hostName, address, ttlSeconds),
    ];
    final builder = BytesBuilder(copy: false);
    _writeUint16(builder, 0); // mDNS message id is always zero.
    _writeUint16(builder, 0x8400); // response + authoritative answer.
    _writeUint16(builder, 0); // questions
    _writeUint16(builder, records.length); // answers
    _writeUint16(builder, 0); // authority
    _writeUint16(builder, 0); // additional
    for (final record in records) {
      _writeName(builder, record.name);
      _writeUint16(builder, record.type);
      // PTR is shared; the other DNS-SD records are unique and use cache
      // flush. Goodbye packets retain the flush bit as required by RFC 6762.
      _writeUint16(builder, record.type == 12 ? 1 : 0x8001);
      _writeUint32(builder, record.ttlSeconds);
      final rdata = record.rdata;
      _writeUint16(builder, rdata.length);
      builder.add(rdata);
    }
    return builder.takeBytes();
  }

  /// Returns true for a DNS query that asks for this service or one of its
  /// records. Compressed query names are accepted so Android NSD and other
  /// normal mDNS clients work without relying on packet layout details.
  static bool isQueryForService(List<int> packet) {
    if (packet.length < 12) return false;
    final flags = _readUint16(packet, 2);
    if ((flags & 0x8000) != 0) return false;
    final questions = _readUint16(packet, 4);
    var offset = 12;
    for (var index = 0; index < questions; index++) {
      final name = _readName(packet, offset);
      if (name == null) return false;
      offset = name.nextOffset;
      if (offset + 4 > packet.length) return false;
      final type = _readUint16(packet, offset);
      final recordClass = _readUint16(packet, offset + 2) & 0x7fff;
      offset += 4;
      if (recordClass != 1 && recordClass != 255) continue;
      final normalizedName = name.name.toLowerCase();
      if ((normalizedName ==
                  MdnsServiceAdvertiser.serviceTypeFqdn.toLowerCase() &&
              (type == 12 || type == 255)) ||
          (normalizedName ==
                  MdnsServiceAdvertiser.serviceInstance.toLowerCase() &&
              (type == 16 || type == 33 || type == 255)) ||
          (normalizedName == MdnsServiceAdvertiser.hostName.toLowerCase() &&
              (type == 1 || type == 255))) {
        return true;
      }
    }
    return false;
  }
}

final class _DnsRecord {
  const _DnsRecord(this.name, this.type, this.ttlSeconds, this.rdata);

  factory _DnsRecord.ptr(String name, String target, int ttlSeconds) =>
      _DnsRecord(name, 12, ttlSeconds, _encodeName(target));

  factory _DnsRecord.srv(String name, String target, int port, int ttlSeconds) {
    final builder = BytesBuilder(copy: false);
    _writeUint16(builder, 0); // priority
    _writeUint16(builder, 0); // weight
    _writeUint16(builder, port);
    builder.add(_encodeName(target));
    return _DnsRecord(name, 33, ttlSeconds, builder.takeBytes());
  }

  factory _DnsRecord.txt(
    String name,
    Iterable<String> entries,
    int ttlSeconds,
  ) {
    final builder = BytesBuilder(copy: false);
    for (final entry in entries) {
      final bytes = utf8.encode(entry);
      if (bytes.isEmpty || bytes.length > 255) {
        throw ArgumentError.value(entry, 'txtEntries', 'must be 1-255 bytes');
      }
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    return _DnsRecord(name, 16, ttlSeconds, builder.takeBytes());
  }

  factory _DnsRecord.a(String name, InternetAddress address, int ttlSeconds) {
    if (!_isAdvertisableIpv4(address)) {
      throw ArgumentError.value(address, 'address', 'must be an IPv4 address');
    }
    return _DnsRecord(name, 1, ttlSeconds, address.rawAddress);
  }

  final String name;
  final int type;
  final int ttlSeconds;
  final List<int> rdata;
}

final class _DnsName {
  const _DnsName(this.name, this.nextOffset);

  final String name;
  final int nextOffset;
}

bool _isAdvertisableIpv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
    return false;
  }
  final raw = address.rawAddress;
  return raw.length == 4 && !(raw[0] == 169 && raw[1] == 254);
}

List<InternetAddress> _boundedAddresses(Iterable<InternetAddress> addresses) {
  final unique = <String, InternetAddress>{};
  for (final address in addresses) {
    if (!_isAdvertisableIpv4(address)) continue;
    unique.putIfAbsent(address.address, () => InternetAddress(address.address));
    if (unique.length == MdnsServiceAdvertiser.maxAddressRecords) break;
  }
  return unique.values.toList(growable: false);
}

Future<List<InternetAddress>> _localIpv4Addresses() async {
  final result = <InternetAddress>[];
  try {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    )) {
      result.addAll(interface.addresses.where(_isAdvertisableIpv4));
    }
  } catch (_) {
    // mDNS is optional. A restricted host/network should not stop the daemon.
  }
  return result;
}

Future<MdnsDatagramTransport> _openTransport() async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    MdnsServiceAdvertiser.multicastPort,
    reuseAddress: true,
    reusePort: true,
  );
  socket.multicastHops = 255;
  try {
    socket.joinMulticast(MdnsServiceAdvertiser.multicastAddress);
  } catch (_) {
    socket.close();
    rethrow;
  }
  return _RawMdnsDatagramTransport(socket);
}

final class _RawMdnsDatagramTransport implements MdnsDatagramTransport {
  _RawMdnsDatagramTransport(this._socket) {
    _subscription = _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = _socket.receive()) != null) {
        _packets.add(datagram!.data);
      }
    });
  }

  final RawDatagramSocket _socket;
  final StreamController<List<int>> _packets =
      StreamController<List<int>>.broadcast();
  late final StreamSubscription<RawSocketEvent> _subscription;
  bool _closed = false;

  @override
  Stream<List<int>> get packets => _packets.stream;

  @override
  void send(List<int> packet) {
    if (_closed) return;
    _socket.send(
      packet,
      MdnsServiceAdvertiser.multicastAddress,
      MdnsServiceAdvertiser.multicastPort,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _packets.close();
    _socket.close();
  }
}

List<int> _encodeName(String name) {
  final builder = BytesBuilder(copy: false);
  _writeName(builder, name);
  return builder.takeBytes();
}

void _writeName(BytesBuilder builder, String name) {
  final labels = name.split('.');
  for (final label in labels) {
    final bytes = utf8.encode(label);
    if (bytes.isEmpty || bytes.length > 63) {
      throw ArgumentError.value(name, 'name', 'contains an invalid DNS label');
    }
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
}

void _writeUint16(BytesBuilder builder, int value) {
  builder.addByte((value >> 8) & 0xff);
  builder.addByte(value & 0xff);
}

void _writeUint32(BytesBuilder builder, int value) {
  builder.addByte((value >> 24) & 0xff);
  builder.addByte((value >> 16) & 0xff);
  builder.addByte((value >> 8) & 0xff);
  builder.addByte(value & 0xff);
}

int _readUint16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

_DnsName? _readName(List<int> bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return null;
  final labels = <String>[];
  var cursor = offset;
  var nextOffset = offset;
  var jumped = false;
  final visited = <int>{};
  for (var depth = 0; depth < 64; depth++) {
    if (cursor >= bytes.length || !visited.add(cursor)) return null;
    final length = bytes[cursor++];
    if (length == 0) {
      if (!jumped) nextOffset = cursor;
      return _DnsName(labels.join('.'), nextOffset);
    }
    if ((length & 0xc0) == 0xc0) {
      if (cursor >= bytes.length) return null;
      final pointer = ((length & 0x3f) << 8) | bytes[cursor++];
      if (!jumped) nextOffset = cursor;
      cursor = pointer;
      jumped = true;
      continue;
    }
    if ((length & 0xc0) != 0 || length > 63 || cursor + length > bytes.length) {
      return null;
    }
    labels.add(utf8.decode(bytes.sublist(cursor, cursor + length)));
    cursor += length;
  }
  return null;
}
