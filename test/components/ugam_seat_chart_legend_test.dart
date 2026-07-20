import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_seat_chart_legend.dart';
import 'package:occubusbooking/design/tokens.dart';

/// Covers the tidy grouped-grid rewrite of the shared seat-chart legend. This
/// is a high-blast-radius component (every seat chart — charts, handler,
/// manual assignment, bus-status — renders it), so the contract we lock in is:
/// all nine keys render, and the grid never overflows even on a narrow phone.
///
/// Localization is not initialised under `flutter test`, so `tr(...)` returns
/// the raw key; we assert on those keys, which is enough to prove every entry
/// is laid out.

const _keys = <String>[
  'seat_legend.free',
  'seat_legend.booked',
  'seat_legend.priority',
  'seat_legend.paid',
  'seat_legend.owing',
  'seat_legend.half',
  'seat_legend.go',
  'seat_legend.ret',
  'seat_legend.held',
];

Future<void> _pump(WidgetTester tester, {double width = 360}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: UgamSeatChartLegend(c: UgamColors.dark),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders all nine legend keys', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    for (final k in _keys) {
      expect(find.text(k), findsOneWidget, reason: 'missing legend key $k');
    }
  });

  testWidgets('does not overflow on a narrow phone width', (tester) async {
    // The 3-column grid must degrade gracefully: labels wrap (Flexible) rather
    // than throwing a RenderFlex overflow when the column is tight.
    await _pump(tester, width: 300);
    expect(tester.takeException(), isNull);
    for (final k in _keys) {
      expect(find.text(k), findsOneWidget, reason: 'missing legend key $k');
    }
  });
}
