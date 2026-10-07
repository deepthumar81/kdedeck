import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/main.dart';
import 'package:kdedeck_mobile/services/websocket_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('KdeDeck App Smoke Test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => WebSocketService(),
        child: const KdeDeckApp(),
      ),
    );
    expect(find.byType(KdeDeckApp), findsOneWidget);
  });
}
