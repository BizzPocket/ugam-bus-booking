import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/chart_summary_bar.dart';

/// The bar carries the facts a customer must not discover late.
///
/// A single "no room" flag could only say "nothing fits" — the wrong sentence
/// for the ordinary mixed party whose outbound leg is seated and whose return
/// leg is not. The shortfall map lets the bar name the leg.
///
/// Translations are deliberately NOT loaded, matching the other screen tests:
/// `tr()` returns the raw key, so asserting on the key proves which branch the
/// headline switch chose — which is the logic under test.
void main() {
  Widget harness(Widget child) => MaterialApp(
        localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
        home: Scaffold(body: child),
      );

  testWidgets('it names the leg that could not be seated', (tester) async {
    await tester.pumpWidget(harness(const ChartSummaryBar(
      people: 4,
      pickedBerths: 2,
      lowerBerths: 2,
      total: 3300,
      shortfall: {TripType.returnOnly: 2},
    )));
    await tester.pumpAndSettle();

    expect(find.text('chart_summary.short_return'), findsOneWidget);
  });

  testWidgets('each leg gets its own sentence', (tester) async {
    for (final (leg, key) in const [
      (TripType.roundTrip, 'chart_summary.short_round'),
      (TripType.outboundOnly, 'chart_summary.short_go'),
      (TripType.returnOnly, 'chart_summary.short_return'),
    ]) {
      await tester.pumpWidget(harness(ChartSummaryBar(
        people: 4,
        pickedBerths: 2,
        lowerBerths: 2,
        total: 3300,
        shortfall: {leg: 2},
      )));
      await tester.pumpAndSettle();

      expect(find.text(key), findsOneWidget, reason: 'for $leg');
    }
  });

  testWidgets('no shortfall reads as ready', (tester) async {
    await tester.pumpWidget(harness(const ChartSummaryBar(
      people: 2,
      pickedBerths: 2,
      lowerBerths: 1,
      total: 2800,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
  });

  testWidgets('a seated go leg and a short return leg is NOT ready',
      (tester) async {
    await tester.pumpWidget(harness(const ChartSummaryBar(
      people: 4,
      pickedBerths: 4,
      lowerBerths: 2,
      total: 5200,
      shortfall: {TripType.returnOnly: 2},
    )));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.check_circle_outline_rounded),
      findsNothing,
      reason: 'four berths were picked, but they are all on the way there — '
          'a green tick here would tell the family they are sorted both ways',
    );
  });
}
