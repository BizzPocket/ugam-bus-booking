import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for the motivating bug: a SINGLE sofa was rendering two people
/// side-by-side as if double-booked. A single sofa is ONE berth — it can only
/// be held by one person, or REUSED across disjoint legs (one GO + one RET),
/// which must read as the stacked leg-share tile, never the side-by-side
/// shared split (that split is only physically meaningful for a 2-berth
/// double). Localization is not initialised under `flutter test`, so `tr(...)`
/// returns the raw key; we assert only on occupant DISPLAY NAMES, which are
/// never localized and (with no UserController registered) fall back to `name`.

Passenger _p(String id, String name, TripType trip) => Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+910000000000',
      tripType: trip,
    );

SeatCell _single() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.singleSofa,
      position: SeatPosition.upper,
      seatId: 'SU1',
    );

SeatCell _double() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.doubleSofa,
      position: SeatPosition.lower,
      seatId: 'DL1',
    );

Future<void> _pump(WidgetTester tester, SeatCell cell, List<Passenger> occ) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SeatChartTile(
            cell: cell,
            occupants: occ,
            groupColors: const GroupColorResolver(<String, int>{}),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'single sofa GO+RET reuse renders BOTH names (leg-share, not double-booked)',
    (tester) async {
      await _pump(tester, _single(), [
        _p('go', 'Asha', TripType.outboundOnly),
        _p('ret', 'Bina', TripType.returnOnly),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
    },
  );

  testWidgets(
    'single sofa never shows two SAME-leg people side-by-side (only the first)',
    (tester) async {
      // Two round-trip holders on a one-berth seat is over-capacity data the
      // engine can never produce; the tile must still refuse to draw a
      // side-by-side split on a single and show just one occupant.
      await _pump(tester, _single(), [
        _p('a', 'Chetan', TripType.roundTrip),
        _p('b', 'Dipak', TripType.roundTrip),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Chetan'), findsOneWidget);
      expect(find.text('Dipak'), findsNothing);
    },
  );

  testWidgets(
    'single sofa with a stale third holder still resolves the GO/RET pair',
    (tester) async {
      await _pump(tester, _single(), [
        _p('go', 'Asha', TripType.outboundOnly),
        _p('ret', 'Bina', TripType.returnOnly),
        _p('stale', 'Eshwar', TripType.roundTrip),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      // The over-capacity third berth is dropped from view, not drawn as a
      // third name crammed onto a one-berth seat.
      expect(find.text('Eshwar'), findsNothing);
    },
  );

  testWidgets(
    'double sofa still renders two distinct same-leg occupants side-by-side',
    (tester) async {
      await _pump(tester, _double(), [
        _p('a', 'Falgun', TripType.roundTrip),
        _p('b', 'Gita', TripType.roundTrip),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Falgun'), findsOneWidget);
      expect(find.text('Gita'), findsOneWidget);
    },
  );
}
