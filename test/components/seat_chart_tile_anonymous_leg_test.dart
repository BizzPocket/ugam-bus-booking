import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for the reported bug: on the customer "your seat" (anonymous)
/// chart, a rider who is one-way (single leg, e.g. outbound-only) had their seat
/// painted as a FULL accent chair — the same as a round-trip rider. A one-leg
/// booking occupies only half the seat's journey, so it must render a HALF: one
/// accent half (the travelled leg) over a neutral empty half. The empty half is
/// drawn with [Icons.event_seat_outlined]; a whole seat never shows it.

SeatCell _double() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.doubleSofa,
      position: SeatPosition.upper,
      seatId: 'DU1',
    );

Future<void> _pump(
  WidgetTester tester, {
  required bool mine,
  TripType? mineLeg,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SeatChartTile(
            cell: _double(),
            occupants: const [],
            groupColors: const GroupColorResolver(<String, int>{}),
            anonymous: true,
            mine: mine,
            mineLeg: mineLeg,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'one-way (outbound-only) own seat renders a HALF (accent + empty half)',
    (tester) async {
      await _pump(tester, mine: true, mineLeg: TripType.outboundOnly);
      expect(tester.takeException(), isNull);
      // The free/other half of the split is marked by the outlined seat glyph.
      expect(find.byIcon(Icons.event_seat_outlined), findsOneWidget);
      expect(find.byIcon(Icons.event_seat_rounded), findsOneWidget);
      expect(find.text('DU1'), findsOneWidget);
    },
  );

  testWidgets(
    'return-only own seat also renders a HALF',
    (tester) async {
      await _pump(tester, mine: true, mineLeg: TripType.returnOnly);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.event_seat_outlined), findsOneWidget);
    },
  );

  testWidgets(
    'round-trip own seat stays WHOLE (no empty half)',
    (tester) async {
      await _pump(tester, mine: true, mineLeg: TripType.roundTrip);
      expect(tester.takeException(), isNull);
      // A whole accent chair — never the split empty-half glyph.
      expect(find.byIcon(Icons.event_seat_outlined), findsNothing);
    },
  );

  testWidgets(
    'a one-way leg on a seat that is NOT mine stays whole/neutral',
    (tester) async {
      // mineLeg is ignored unless the seat is the viewer\'s own.
      await _pump(tester, mine: false, mineLeg: TripType.outboundOnly);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.event_seat_outlined), findsNothing);
    },
  );
}
