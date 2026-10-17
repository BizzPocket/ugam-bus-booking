import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/widgets/handler/handler_money_hero.dart';

/// The Money tab's hero folds its breakdown behind a chevron, so its headline
/// and secondary line are all a handler reads at a glance. On a fresh bus that
/// used to be "Handed over ₹0 / ₹0 collected so far" — nothing about the
/// ₹56,800 the bus was still owed (live, SHIVKAMAL 2026-09-05).
///
/// EasyLocalization is not initialised, so `tr(key)` returns the raw key and
/// the assertions are written against keys.
void main() {
  Widget app(Widget child) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(body: child),
  );

  testWidgets('fares still owed lead the secondary line', (tester) async {
    await tester.pumpWidget(
      app(
        const HandlerMoneyHero(
          collected: 0,
          toReturn: 0,
          toCollect: 41600,
          spent: 0,
          income: 0,
          inHand: 0,
          outstanding: 0,
          settled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Collected (₹0) equals the headline (₹0), so only the owed clause shows.
    expect(
      find.text('handler_chart.in_hand_secondary_owing_only'),
      findsOneWidget,
    );
    expect(find.text('handler_chart.in_hand_secondary'), findsNothing);
  });

  testWidgets('collected is named only when it differs from the headline', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const HandlerMoneyHero(
          collected: 26800,
          toReturn: 0,
          toCollect: 24500,
          spent: 1200,
          income: 0,
          inHand: 25600,
          outstanding: 25600,
          settled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('handler_chart.in_hand_secondary_owing'), findsOneWidget);
    expect(
      find.text('handler_chart.in_hand_secondary_owing_only'),
      findsNothing,
    );
  });

  testWidgets('the same figure is never printed twice in the hero', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const HandlerMoneyHero(
          collected: 26800,
          toReturn: 0,
          toCollect: 24500,
          spent: 0,
          income: 0,
          inHand: 26800,
          outstanding: 26800,
          settled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('handler_chart.in_hand_secondary_owing_only'),
      findsOneWidget,
    );
    expect(find.text('handler_chart.in_hand_secondary_owing'), findsNothing);
  });

  testWidgets('nothing left to collect: all-collected, not the same sum twice', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const HandlerMoneyHero(
          collected: 41600,
          toReturn: 0,
          toCollect: 0,
          spent: 0,
          income: 0,
          inHand: 41600,
          outstanding: 41600,
          settled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('handler_phase.detail_all_collected'), findsOneWidget);
    expect(find.text('handler_chart.in_hand_secondary'), findsNothing);
    expect(find.text('handler_chart.in_hand_secondary_owing'), findsNothing);
  });

  testWidgets('an untouched bus reads "in hand", never "handed over"', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const HandlerMoneyHero(
          collected: 0,
          toReturn: 0,
          toCollect: 41600,
          spent: 0,
          income: 0,
          inHand: 0,
          outstanding: 0,
          settled: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // UgamHeroStat renders its label upper-cased.
    expect(find.text('HANDLER_CHART.STAT_IN_HAND'), findsOneWidget);
    expect(find.text('HANDLER_CHART.STAT_SETTLED'), findsNothing);
  });
}
