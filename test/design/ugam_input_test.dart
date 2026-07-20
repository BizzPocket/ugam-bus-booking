import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_input.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: child),
      );

  testWidgets('obscureToggle starts obscured and reveals on tap', (tester) async {
    await tester.pumpWidget(host(
      const UgamInput(obscure: true, obscureToggle: true),
    ));

    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });

  testWidgets('no toggle icon when obscureToggle is false', (tester) async {
    await tester.pumpWidget(host(const UgamInput(obscure: true)));
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
  });

  testWidgets('autofillHints pass through to the field', (tester) async {
    await tester.pumpWidget(host(
      const UgamInput(autofillHints: [AutofillHints.password]),
    ));
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.password),
    );
  });
}
