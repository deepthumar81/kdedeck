import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/services/websocket_service.dart';
import 'package:kdedeck_mobile/ui/neumorphic_deck.dart';
import 'package:provider/provider.dart';

class FakeConnection extends WebSocketService {
  FakeConnection()
      : super(
          autoConnect: false,
          manageWakelock: false,
          connector: (_) => throw StateError('A widget test must not connect'),
        );

  String? code;
  String? token;
  bool forgot = false;
  bool reloaded = false;
  Map<String, dynamic>? added;
  Map<String, dynamic>? selected;

  void change({bool? connected, bool? authorized, bool? pairing}) {
    if (connected != null) isConnected = connected;
    if (authorized != null) authenticated = authorized;
    if (pairing != null) authRequired = pairing;
    notifyListeners();
  }

  @override
  Future<void> pairWithCode(String value) async => code = value;

  @override
  Future<void> pairWithToken(String value) async => token = value;

  @override
  Future<void> clearCredential() async {
    forgot = true;
    change(connected: false, authorized: false, pairing: true);
  }

  @override
  Future<void> addServer(String name, String ip, int port, String ignoredPin,
      {bool? secure}) async {
    added = {'name': name, 'ip': ip, 'port': port, 'secure': secure};
  }

  @override
  Future<void> selectServer(Map<String, dynamic> server) async {
    selected = server;
  }

  @override
  void reloadServerConfig() {
    reloaded = true;
    configConflict = false;
    configData = null;
    remoteConfigData = null;
    change(connected: false, authorized: false);
  }
}

void main() {
  late FakeConnection service;

  setUp(() => service = FakeConnection());
  tearDown(() => service.dispose());

  Future<void> render(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<WebSocketService>.value(
      value: service,
      child: const MaterialApp(home: NeumorphicDeckScreen()),
    ));
    await tester.pump();
  }

  Future<void> animateDialog(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('stale deck is hidden offline or while authorization is pending',
      (tester) async {
    service.configData = {
      'boards': [
        {'id': 'stale', 'grid_columns': 1, 'grid_rows': 1, 'items': <dynamic>[]}
      ],
    };
    await render(tester);
    expect(find.text('Connect to Linux PC'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);

    service.change(connected: true, authorized: false, pairing: true);
    await tester.pump();
    expect(find.byKey(const Key('pairingCode')), findsOneWidget);
    expect(find.byType(PageView), findsNothing);

    service.change(authorized: true, pairing: false);
    await tester.pump();
    expect(find.byType(PageView), findsOneWidget);
    service.change(connected: false, authorized: false);
    await tester.pump();
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('invalid stored endpoint renders recovery instead of throwing',
      (tester) async {
    service.serverIp = 'bad/endpoint';
    service.authError = 'invalid_endpoint';
    await render(tester);
    expect(find.text('Check the PC address and port.'), findsOneWidget);
    expect(find.text('Add New PC IP'), findsOneWidget);
    expect(systemIconUri(service, 'unavailable.svg'), isNull);
  });

  test('system icon endpoint follows the selected WebSocket transport', () {
    service.serverIp = 'pc.example';
    service.secureConnection = true;
    final secure = systemIconUri(service, '/icons/my image.svg')!;
    expect(secure.scheme, 'https');
    expect(secure.host, 'pc.example');
    expect(secure.path, '/system_icons');
    expect(secure.queryParameters['path'], '/icons/my image.svg');

    service.serverIp = '127.0.0.1';
    service.secureConnection = false;
    expect(systemIconUri(service, 'icon.png')!.scheme, 'http');
  });

  testWidgets('one-time code and embedded token take separate obscured paths',
      (tester) async {
    service.change(pairing: true);
    await render(tester);
    final codeField =
        tester.widget<TextField>(find.byKey(const Key('pairingCode')));
    expect(codeField.obscureText, true);
    await tester.enterText(find.byKey(const Key('pairingCode')), ' ABC-123 ');
    await tester.tap(find.text('Pair with code'));
    await tester.pump();
    expect(service.code, 'ABC-123');
    expect(service.token, isNull);
    expect(codeField.controller!.text, isEmpty);

    await tester.tap(find.text('Use embedded server token instead'));
    await tester.pump();
    final tokenField =
        tester.widget<TextField>(find.byKey(const Key('embeddedToken')));
    expect(tokenField.obscureText, true);
    await tester.enterText(
        find.byKey(const Key('embeddedToken')), ' local-secret ');
    await tester.tap(find.text('Pair with embedded server token'));
    await tester.pump();
    expect(service.token, 'local-secret');
    expect(tokenField.controller!.text, isEmpty);

    service.authError = 'server exception: secret=local-secret';
    service.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('pairingError')), findsOneWidget);
    expect(find.textContaining('local-secret'), findsNothing);

    service.authError = 'expired';
    service.notifyListeners();
    await tester.pump();
    expect(find.text('Pairing code expired. Request a new code on your PC.'),
        findsOneWidget);
  });

  testWidgets(
      'new PCs default to WSS; invalid host, port and LAN plaintext are blocked',
      (tester) async {
    await render(tester);
    await tester.tap(find.text('Add New PC IP'));
    await animateDialog(tester);
    expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, true);
    await tester.tap(find.text('Save & Connect'));
    await tester.pump();
    expect(service.added, isNull);
    expect(
        find.text('Enter a valid host or numeric IP address.'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Host or IP address'), '127.1');
    await tester.tap(find.text('Save & Connect'));
    await tester.pump();
    expect(service.added, isNull);

    await tester.enterText(
        find.widgetWithText(TextField, 'Host or IP address'), 'pc.example');
    await tester.enterText(find.widgetWithText(TextField, 'Port'), '0');
    await tester.tap(find.text('Save & Connect'));
    await tester.pump();
    expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Port'), '8484');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.text('Save & Connect'));
    await tester.pump();
    expect(service.added, isNull);
    expect(
        find.text('Plaintext is allowed only for numeric loopback addresses.'),
        findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Host or IP address'), '127.0.0.1');
    await tester.tap(find.text('Save & Connect'));
    await animateDialog(tester);
    expect(service.added,
        {'name': '', 'ip': '127.0.0.1', 'port': 8484, 'secure': false});

    await tester.tap(find.text('Add New PC IP'));
    await animateDialog(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Host or IP address'), '192.168.1.10');
    await tester.tap(find.text('Save & Connect'));
    await animateDialog(tester);
    expect(service.added!['secure'], true);
  });

  testWidgets(
      'saved PC selection upgrades legacy LAN; drawer offers credential reset',
      (tester) async {
    service.savedServers = [
      {'name': 'old LAN', 'ip': '192.168.1.20', 'port': 8484, 'secure': false},
      {'name': 'TLS PC', 'ip': 'pc.example', 'port': 9443, 'secure': true},
    ];
    await render(tester);
    await tester.tap(find.text('old LAN'));
    expect(service.added!['secure'], true);
    expect(service.selected, isNull);
    await tester.tap(find.text('TLS PC'));
    expect(service.selected!['secure'], true);

    service.configData = {
      'boards': [
        {'id': 'live', 'grid_columns': 1, 'grid_rows': 1, 'items': <dynamic>[]}
      ]
    };
    service.secureConnection = true;
    service.change(connected: true, authorized: true);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await animateDialog(tester);
    expect(find.text('https://192.168.29.128:8484'), findsOneWidget);
    await tester.ensureVisible(find.text('Re-pair / forget credential'));
    await tester.pump();
    await tester.tap(find.text('Re-pair / forget credential'));
    await animateDialog(tester);
    expect(service.forgot, true);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('conflict keeps local draft until explicit discard and reload',
      (tester) async {
    final local = {
      'boards': <dynamic>[
        {'id': 'local', 'grid_columns': 1, 'grid_rows': 1, 'items': <dynamic>[]}
      ]
    };
    final remote = {
      'boards': <dynamic>[
        {
          'id': 'remote',
          'grid_columns': 1,
          'grid_rows': 1,
          'items': <dynamic>[]
        }
      ]
    };
    service.configData = local;
    service.remoteConfigData = remote;
    service.configConflict = true;
    service.change(connected: true, authorized: true);
    await render(tester);
    await animateDialog(tester);
    expect(find.text('Configuration conflict'), findsOneWidget);
    expect(service.configData, same(local));
    await tester.tap(find.text('Keep local draft'));
    await animateDialog(tester);
    expect(service.reloaded, false);
    expect(service.configData, same(local));

    await tester.tap(find.byTooltip('Review configuration conflict'));
    await animateDialog(tester);
    await tester.tap(find.text('Discard draft & reload'));
    await animateDialog(tester);
    expect(service.reloaded, true);
    expect(service.configData, isNull);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('Connect to Linux PC'), findsOneWidget);
  });
}
