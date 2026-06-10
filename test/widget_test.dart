import 'package:flutter_test/flutter_test.dart';
import 'package:recorder/app.dart'; // ignore: depend_on_referenced_packages

void main() {
  testWidgets('App renders recording page', (WidgetTester tester) async {
    await tester.pumpWidget(const RecorderApp());
    expect(find.text('Grabar'), findsWidgets);
  });
}
