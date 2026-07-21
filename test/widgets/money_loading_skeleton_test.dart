import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/widgets/money_loading_skeleton.dart';
import 'package:occubusbooking/design/components/ugam_skeleton.dart';

void main() {
  testWidgets('renders shimmer blocks with no overflow', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MoneyLoadingSkeleton()),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(UgamSkeleton), findsWidgets);
  });
}
