// test/design/ui_scale_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/ui_scale.dart';

Future<double> _scaleAtWidth(WidgetTester tester, double width) async {
  late double s;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Builder(builder: (context) {
        s = UgamScale.of(context);
        return const SizedBox();
      }),
    ),
  );
  return s;
}

void main() {
  testWidgets('caps at 1.0 at the baseline and on larger screens', (tester) async {
    expect(await _scaleAtWidth(tester, UgamScale.baseline), 1.0);
    expect(await _scaleAtWidth(tester, 800), 1.0);
  });

  testWidgets('floors at 0.85 on the smallest phones', (tester) async {
    expect(await _scaleAtWidth(tester, 300), 0.85);
    expect(await _scaleAtWidth(tester, 200), 0.85);
  });

  testWidgets('scales proportionally between floor and cap', (tester) async {
    // 360 / 390 baseline ≈ 0.9231
    expect(await _scaleAtWidth(tester, 360), closeTo(0.923, 0.001));
  });
}
