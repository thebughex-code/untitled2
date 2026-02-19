import 'package:flutter_test/flutter_test.dart';

import 'package:untitled2/main.dart';

void main() {
  testWidgets('App builds without errors', (WidgetTester tester) async {
    await tester.pumpWidget(const ReelsApp());
    expect(find.text('Reels'), findsOneWidget);
  });
}
