import 'package:flutter_test/flutter_test.dart';
import 'package:kdedeck_mobile/main.dart';

void main() {
  testWidgets('KdeDeck App Smoke Test', (WidgetTester tester) async {
    await tester.pumpWidget(const KdeDeckApp());
    expect(find.byType(KdeDeckApp), findsOneWidget);
  });
}
