import 'package:flutter_test/flutter_test.dart';

import 'package:portrai_flutter_app/main.dart';

void main() {
  testWidgets('PortrAI app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PortraiApp());

    expect(find.text('PortrAI'), findsOneWidget);
  });
}
