import 'package:flutter_test/flutter_test.dart';

import 'package:gospel_vox/main.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const GospelVoxApp());
    await tester.pumpAndSettle();
  });
}
