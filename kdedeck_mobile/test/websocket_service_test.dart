import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/services/credential_store.dart';
import 'package:kdedeck_mobile/services/websocket_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MemoryCredentials implements CredentialStore {
  final values = <String, String>{};
  final reads = <String>[];
  Completer<String?>? blockedRead;
  Completer<void>? blockedWrite;
  Completer<void>? blockedDelete;

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (blockedRead != null) return blockedRead!.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String token) async {
    if (blockedWrite != null) await blockedWrite!.future;
    values[key] = token;
  }

  @override
  Future<void> delete(String key) async {
    if (blockedDelete != null) await blockedDelete!.future;
    values.remove(key);
  }
}

class FakeSink implements WebSocketSink {
  final sent = <Map<String, dynamic>>[];
  final _done = Completer<void>();
  bool closeThrows = false;

  @override
  void add(dynamic data) => sent.add(jsonDecode(data as String));

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (closeThrows) throw StateError('socket closed');
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>.broadcast(sync: true);
  final outbound = FakeSink();
  final Completer<void> readyGate;

  FakeChannel() : readyGate = (Completer<void>()..complete());
  FakeChannel.pending() : readyGate = Completer<void>();

  void receive(Map<String, dynamic> message) =>
      incoming.add(jsonEncode(message));

  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => outbound;
  @override
  Future<void> get ready => readyGate.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryCredentials credentials;
  late List<FakeChannel> sockets;
  late List<Uri> urls;
  late WebSocketService service;

  WebSocketService makeService({
    bool autoConnect = false,
    SocketConnector? connector,
    Duration timeout = const Duration(milliseconds: 40),
  }) {
    return WebSocketService(
      credentialStore: credentials,
      autoConnect: autoConnect,
      manageWakelock: false,
      readyTimeout: timeout,
      connector: connector ??
          (uri) {
            urls.add(uri);
            final socket = FakeChannel();
            sockets.add(socket);
            return socket;
          },
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    credentials = MemoryCredentials();
    sockets = [];
    urls = [];
    service = makeService();
    service.serverIp = '127.0.0.1';
    service.secureConnection = false;
  });

  tearDown(() => service.dispose());

  test('exact standalone challenge exchanges code for issued bearer', () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    expect(service.authRequired, true);
    expect(sockets.last.outbound.sent, isEmpty);
    await service.pairWithCode('one-time-code');
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    expect(sockets.last.outbound.sent.single, {
      'type': 'authenticate',
      'protocol_version': 1,
      'pairing_code': 'one-time-code',
    });
    expect(credentials.values, isEmpty);
    sockets.last.receive({
      'type': 'auth_success',
      'token': 'issued-bearer',
      'role': 'configAdmin',
    });
    sockets.last.receive({
      'type': 'init_state',
      'config': {'boards': []},
      'revision': 9,
    });
    await settle();
    expect(credentials.values['ws://127.0.0.1:8484'], 'issued-bearer');
    expect(credentials.values.values, isNot(contains('one-time-code')));
    expect(service.authenticated, true);
    expect(service.configRevision, 9);
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    expect(sockets.last.outbound.sent.single, {
      'type': 'authenticate',
      'protocol_version': 1,
      'token': 'issued-bearer',
    });
  });

  test('auth_success alone does not expose deck or permit actions', () async {
    credentials.values['ws://127.0.0.1:8484'] = 'bearer';
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    sockets.last.receive({'type': 'auth_success', 'token': 'bearer'});
    await settle();
    expect(service.authenticated, true);
    expect(service.isConnected, false);
    expect(service.status, 'awaiting_state');
    sockets.last.receive({
      'type': 'config_updated',
      'config': {
        'boards': ['premature']
      }
    });
    sockets.last.receive({'type': 'init_state', 'config': null});
    await settle();
    service.triggerAction('launch_app');
    expect(sockets.last.outbound.sent, hasLength(1)); // authenticate only
    expect(service.configData, null);
    sockets.last.receive({
      'type': 'init_state',
      'config': {'boards': []}
    });
    await settle();
    expect(service.isConnected, true);
    service.triggerAction('launch_app');
    expect(sockets.last.outbound.sent.last['type'], 'trigger_action');
  });

  test('embedded v1 token auth and legacy trusted loopback', () async {
    await service.pairWithToken('embedded-token');
    await settle();
    sockets.last.receive({
      'type': 'auth_required',
      'protocol_version': 1,
      'auth_required': true,
    });
    await settle();
    expect(sockets.last.outbound.sent.single['token'], 'embedded-token');
    sockets.last.receive({'type': 'auth_success', 'protocol_version': 1});
    await settle();
    expect(credentials.values['ws://127.0.0.1:8484'], 'embedded-token');
    service.connect();
    await settle();
    sockets.last.receive({
      'type': 'auth_required',
      'protocol_version': 1,
      'auth_required': false,
    });
    sockets.last.receive({
      'type': 'init_state',
      'config': {'boards': []}
    });
    await settle();
    expect(service.authenticated, true);
  });

  test('LAN plaintext is rejected before connector or credential reads',
      () async {
    service.serverIp = '192.168.1.20';
    service.connect();
    await settle();
    expect(urls, isEmpty);
    expect(credentials.reads, isEmpty);
    expect(service.authError, 'tls_required');
    expect(service.status, 'tls_required');
    await service.pairWithCode('code');
    expect(urls, isEmpty);
    expect(credentials.values, isEmpty);
    service.serverIp = 'localhost';
    service.connect();
    expect(service.authError, 'tls_required');
    service.serverIp = '127.0.0.2';
    service.connect();
    await settle();
    expect(urls.last.scheme, 'ws');
  });

  test('new LAN profiles default to TLS; explicit old insecure profile fails',
      () async {
    await service.addServer('Office', '192.168.1.9', 8484, 'legacy-pin');
    await settle();
    expect(service.secureConnection, true);
    expect(urls.last.scheme, 'wss');
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getString('saved_servers_list'), isNot(contains('legacy-pin')));
    final count = sockets.length;
    await service.selectServer({
      'ip': '192.168.1.9',
      'port': 8484,
      'secure': false,
    });
    expect(sockets, hasLength(count));
    expect(service.authError, 'tls_required');
    await service.selectServer({'ip': '192.168.1.10', 'port': 8484});
    await settle();
    expect(urls.last.scheme, 'wss');
  });

  test('numeric IPv6 loopback allows ws and uses canonical key', () async {
    service.serverIp = '::1';
    service.connect();
    await settle();
    expect(urls.last.scheme, 'ws');
    await service.pairWithToken('ipv6-bearer');
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    sockets.last.receive({'type': 'auth_success'});
    await settle();
    expect(credentials.values['ws://[::1]:8484'], 'ipv6-bearer');
  });

  test('unconfigured transport defaults to ws for numeric loopback', () async {
    service.dispose();
    service = makeService();
    service.serverIp = '127.0.0.1';
    service.connect();
    await settle();
    expect(urls.single.scheme, 'ws');
  });

  test('remote auth_required false cannot authorize state or actions',
      () async {
    await service.selectServer({
      'ip': '192.168.1.20',
      'port': 8484,
      'secure': true,
    });
    await settle();
    expect(urls.last.scheme, 'wss');
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['leak']
      }
    });
    await settle();
    service.triggerAction('launch_app');
    expect(sockets.last.outbound.sent, isEmpty);
    expect(service.configData, null);
    expect(service.authenticated, false);
    expect(service.authRequired, true);
  });

  test('WSS numeric loopback cannot use trusted plaintext shortcut', () async {
    await service.setSecureConnection(true);
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['leak']
      }
    });
    await settle();
    expect(service.authRequired, true);
    expect(service.authenticated, false);
    expect(service.isConnected, false);
    expect(service.configData, null);
  });

  test('explicit protocol mismatch is rejected; absent version is accepted',
      () async {
    credentials.values['ws://127.0.0.1:8484'] = 'old';
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'protocol_version': 2});
    await settle();
    expect(service.authError, 'unsupported_protocol');
    expect(credentials.values, isEmpty);
    expect(sockets.last.outbound.sent, isEmpty);
  });

  test('bare unsupported version and expired session revoke bearer', () async {
    credentials.values['ws://127.0.0.1:8484'] = 'old';
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    sockets.last.receive({'type': 'unsupported_protocol_version'});
    await settle();
    expect(service.authError, 'unsupported_protocol_version');
    expect(credentials.values, isEmpty);
  });

  test('one-time code without a valid issued bearer is rejected', () async {
    await service.pairWithCode('single-use');
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    sockets.last.receive({'type': 'auth_success', 'token': 123});
    await settle();
    expect(service.authError, 'invalid_response');
    expect(credentials.values, isEmpty);
    expect(service.authenticated, false);
  });

  for (final code in [
    'invalid_credentials',
    'rate_limited',
    'unsupported_protocol_version',
    'expired',
    'revoked',
    'authentication_required',
  ]) {
    test('$code clears bearer and marks auth required', () async {
      credentials.values['ws://127.0.0.1:8484'] = 'old';
      service.connect();
      await settle();
      sockets.last.receive({'type': 'auth_required'});
      await settle();
      sockets.last.receive({'type': 'auth_error', 'code': code});
      await settle();
      expect(credentials.values, isEmpty);
      expect(service.authError, code);
      expect(service.authenticated, false);
      expect(service.authRequired, true);
      service.connect();
      await settle();
      sockets.last.receive({'type': 'auth_required'});
      await settle();
      expect(sockets.last.outbound.sent, isEmpty);
    });
  }

  test('permission and capacity errors do not revoke a valid bearer', () async {
    credentials.values['ws://127.0.0.1:8484'] = 'valid';
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    sockets.last.receive({'type': 'auth_success', 'token': 'valid'});
    await settle();
    for (final code in [
      'permission_denied',
      'capacity_exceeded',
      'rate_limited'
    ]) {
      sockets.last.receive({'type': 'action_error', 'code': code});
    }
    await settle();
    expect(service.authenticated, true);
    expect(service.authError, 'rate_limited');
    expect(credentials.values['ws://127.0.0.1:8484'], 'valid');
  });

  test('switch fences delayed credential read, stale frames and closes',
      () async {
    credentials.blockedRead = Completer<String?>();
    service.connect();
    await settle();
    final old = sockets.last;
    old.receive({'type': 'auth_required'});
    await settle();
    final switching = service.selectServer({
      'ip': '192.168.1.20',
      'port': 9001,
      'secure': true,
    });
    await switching;
    await settle();
    old.receive({'type': 'auth_success', 'token': 'stale'});
    credentials.blockedRead!.complete('old-token');
    await settle();
    await old.incoming.close();
    await settle();
    expect(old.outbound.sent, isEmpty);
    expect(credentials.values, isEmpty);
    expect(service.serverIp, '192.168.1.20');
    expect(service.status, 'awaiting_auth');
    expect(urls.last.scheme, 'wss');
  });

  test('delayed old auth_success storage never writes under new endpoint',
      () async {
    credentials.blockedWrite = Completer<void>();
    await service.pairWithCode('short-code');
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    final old = sockets.last;
    old.receive({'type': 'auth_success', 'token': 'old-issued'});
    await settle();
    await service.selectServer({
      'ip': '192.168.1.21',
      'port': 9001,
      'secure': true,
    });
    credentials.blockedWrite!.complete();
    await settle();
    expect(credentials.values['wss://192.168.1.21:9001'], null);
    expect(credentials.values.values, isNot(contains('short-code')));
    expect(service.authenticated, false);
  });

  test('socket close fences delayed auth_success credential write', () async {
    credentials.blockedWrite = Completer<void>();
    await service.pairWithCode('one-time');
    await settle();
    final socket = sockets.last;
    socket.receive({'type': 'auth_required'});
    await settle();
    socket.receive({'type': 'auth_success', 'token': 'issued'});
    await settle();
    await socket.incoming.close();
    expect(service.authenticated, false);
    expect(service.isConnected, false);
    credentials.blockedWrite!.complete();
    await settle();
    service.triggerAction('launch_app');
    expect(socket.outbound.sent, hasLength(1)); // authenticate only
    expect(service.authenticated, false);
    expect(service.isConnected, false);
    expect(service.status, 'auth_required');
  });

  test('credential deletion error is surfaced without an unhandled future',
      () async {
    credentials.values['ws://127.0.0.1:8484'] = 'stored';
    credentials.blockedDelete = Completer<void>();
    service.connect();
    await settle();
    final clearing = service.clearCredential();
    expect(service.isConnected, false);
    credentials.blockedDelete!
        .completeError(StateError('keystore unavailable'));
    await clearing;
    expect(service.authError, 'credential_unavailable');
    expect(service.authRequired, true);
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    expect(sockets.last.outbound.sent, isEmpty);
  });

  test('switch during pairing deletion does not replay code to new endpoint',
      () async {
    credentials.blockedDelete = Completer<void>();
    final pairing = service.pairWithCode('private-code');
    await settle();
    await service.selectServer({
      'ip': '192.168.1.31',
      'port': 9001,
      'secure': true,
    });
    credentials.blockedDelete!.complete();
    await pairing;
    await settle();
    sockets.last.receive({'type': 'auth_required'});
    await settle();
    expect(sockets.last.outbound.sent, isEmpty);
    expect(credentials.values, isEmpty);
  });

  test('failed ready and stale close are handled with bounded timeout',
      () async {
    service.dispose();
    service = makeService(connector: (uri) {
      final socket = FakeChannel.pending();
      sockets.add(socket);
      return socket;
    });
    service.serverIp = '::1';
    service.secureConnection = false;
    service.connect();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(service.authenticated, false);
    expect(service.status, 'disconnected');
    expect(service.authError, 'connection_failed');
    expect(sockets.single.outbound.done, completes);
    sockets.single.readyGate.completeError(StateError('late failure'));
    await settle();
    expect(service.status, 'disconnected');
    expect(service.authError, 'connection_failed');
  });

  test('ready failure and connector failure do not escape as async errors',
      () async {
    service.dispose();
    service = makeService(connector: (uri) {
      final socket = FakeChannel.pending();
      sockets.add(socket);
      return socket;
    });
    service.serverIp = '127.0.0.1';
    service.connect();
    await settle();
    sockets.last.readyGate.completeError(StateError('handshake failed'));
    await settle();
    expect(service.status, 'disconnected');
    service.dispose();
    service =
        makeService(connector: (uri) => throw StateError('connector failed'));
    service.serverIp = '127.0.0.1';
    service.connect();
    await settle();
    expect(service.status, 'disconnected');
  });

  test('invalid endpoint and old insecure profile fail before connector',
      () async {
    for (final host in [
      'https://host',
      'host/path',
      'user@host',
      '127.1',
      '256.1.1.1'
    ]) {
      service.serverIp = host;
      service.connect();
      expect(service.authError, 'invalid_endpoint');
    }
    service.serverIp = '127.0.0.1';
    service.serverPort = 65536;
    service.connect();
    expect(service.authError, 'invalid_endpoint');
    service.dispose();
    SharedPreferences.setMockInitialValues({
      'server_ip': '192.168.1.3',
      'server_secure': false,
      'server_pin': 'legacy',
      'saved_servers_list': jsonEncode([
        {'name': 'old', 'ip': '192.168.1.3', 'port': 8484, 'pin': 'legacy'},
      ]),
    });
    service = makeService(autoConnect: true);
    await settle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_pin'), null);
    expect(prefs.getString('saved_servers_list'), isNot(contains('legacy')));
    // On desktop the app intentionally selects its numeric loopback engine.
    expect(urls.every((uri) => uri.host == '127.0.0.1'), true);
  });

  test('rejected saves release pending slot and keep the local draft',
      () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'revision': 4,
      'config': {'boards': []},
    });
    await settle();
    for (final code in ['invalid_config', 'save_failed']) {
      service.sendSaveConfig({
        'boards': [code]
      });
      sockets.last.receive({'type': 'config_error', 'code': code});
      await settle();
      expect(service.configData, {
        'boards': [code]
      });
      expect(service.configError, code);
      expect(service.configConflict, false);
    }
    expect(sockets.last.outbound.sent.where((m) => m['type'] == 'save_config'),
        hasLength(2));
  });

  test('rejected draft survives later broadcast and reconnect', () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['old']
      }
    });
    await settle();
    service.sendSaveConfig({
      'boards': ['draft']
    });
    sockets.last.receive({'type': 'config_error', 'code': 'invalid_config'});
    sockets.last.receive({
      'type': 'config_updated',
      'config': {
        'boards': ['other']
      }
    });
    await settle();
    expect(service.configConflict, true);
    expect(service.configData, {
      'boards': ['draft']
    });
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['other']
      }
    });
    await settle();
    expect(service.configConflict, true);
    expect(service.configData, {
      'boards': ['draft']
    });
  });

  test('offline edit is not treated as an acknowledged pending save', () async {
    service.sendSaveConfig({
      'boards': ['offline-draft']
    });
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['server']
      }
    });
    await settle();
    expect(service.configConflict, true);
    expect(service.configData, {
      'boards': ['offline-draft']
    });
    expect(sockets.last.outbound.sent, isEmpty);
  });

  test('binary, oversized and queued floods disconnect without parsing',
      () async {
    service.connect();
    await settle();
    sockets.last.incoming.add(<int>[1, 2, 3]);
    expect(service.authError, 'invalid_frame');
    expect(service.isConnected, false);
    service.connect();
    await settle();
    sockets.last.incoming.add('x' * (1024 * 1024 + 1));
    expect(service.authError, 'invalid_frame');
    service.connect();
    await settle();
    // Fewer code units than the limit can still exceed it in UTF-8 bytes.
    sockets.last.incoming.add('é' * (600 * 1024));
    expect(service.authError, 'invalid_frame');
    credentials.blockedRead = Completer<String?>();
    service.connect();
    await settle();
    final socket = sockets.last;
    socket.receive({'type': 'auth_required'});
    await settle();
    for (var i = 0; i < 65; i++) {
      socket.receive({
        'type': 'state_poll',
        'state': {'volume': 10}
      });
    }
    expect(service.authError, 'overloaded');
    expect(service.isConnected, false);
    credentials.blockedRead!.complete('stale');
    await settle();
    expect(socket.outbound.sent, isEmpty);
  });

  test('conflict without current remote snapshot blocks unsafe rebase',
      () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'revision': 4,
      'config': {
        'boards': ['remote']
      },
    });
    await settle();
    service.sendSaveConfig({
      'boards': ['draft']
    });
    sockets.last.receive({
      'type': 'config_error',
      'code': 'config_conflict',
      'revision': 5,
    });
    await settle();
    service.resolveConfigConflict({
      'boards': ['blind-overwrite']
    });
    expect(service.configError, 'reload_required');
    expect(service.configData, {
      'boards': ['draft']
    });
    expect(sockets.last.outbound.sent, hasLength(1));
    service.reloadServerConfig();
    await settle();
    expect(service.configData, null);
    expect(service.configConflict, false);
    expect(sockets, hasLength(2));
  });

  test('matching update advances revision and flushes queued edit', () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {'boards': []},
      'revision': 7,
    });
    await settle();
    service.sendSaveConfig({
      'boards': ['first']
    });
    service.sendSaveConfig({
      'boards': ['second']
    });
    expect(sockets.last.outbound.sent, hasLength(1));
    sockets.last.receive({
      'type': 'config_updated',
      'config': {
        'boards': ['first']
      },
      'revision': 8,
    });
    await settle();
    expect(sockets.last.outbound.sent.last['revision'], 8);
    expect(sockets.last.outbound.sent.last['config'], {
      'boards': ['second']
    });
  });

  test('normalized or unrelated update cannot silently acknowledge a draft',
      () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {'boards': []}
    });
    await settle();
    service.sendSaveConfig({
      'boards': ['local']
    });
    sockets.last.receive({
      'type': 'config_updated',
      'config': {
        'boards': ['normalized']
      },
    });
    await settle();
    expect(service.configConflict, true);
    expect(service.configData, {
      'boards': ['local']
    });
    service.sendSaveConfig({
      'boards': ['unsafely-overwritten']
    });
    expect(sockets.last.outbound.sent, hasLength(1));
  });

  test('explicit rebase requires a fresh remote revision and config', () async {
    service.connect();
    await settle();
    sockets.last.receive({'type': 'auth_required', 'auth_required': false});
    sockets.last.receive({
      'type': 'init_state',
      'config': {
        'boards': ['old']
      },
      'revision': 2,
    });
    await settle();
    service.sendSaveConfig({
      'boards': ['draft']
    });
    sockets.last.receive({
      'type': 'config_error',
      'code': 'config_conflict',
      'config': {
        'boards': ['current']
      },
      'revision': 3,
    });
    await settle();
    service.resolveConfigConflict({
      'boards': ['merged']
    });
    expect(service.configConflict, false);
    expect(sockets.last.outbound.sent.last['revision'], 3);
    expect(sockets.last.outbound.sent.last['config'], {
      'boards': ['merged']
    });
  });
}
