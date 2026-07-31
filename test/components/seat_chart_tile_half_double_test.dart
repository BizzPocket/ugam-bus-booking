import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// How a Double Sofa shows what is still free. The tile is a LEG grid — the GO
/// riders on the top row, the RET riders on the bottom — so free capacity reads
/// off an entirely EMPTY leg row. A spare berth *within* a row that already has
/// a rider is deliberately not carved out beside them: doing that shrank a
/// rider who holds a whole leg down to a quarter of the sofa, which is the bug
/// the chart video reported.
///
/// `markHalfDouble` is the berth-accurate flag the seat-assignment chart
/// passes; the empty leg row is drawn with [Icons.event_seat_outlined].

Passenger _p(String id, String name, TripType trip) => Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+910000000000',
      tripType: trip,
    );

SeatCell _double() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.doubleSofa,
      position: SeatPosition.lower,
      seatId: 'DL1',
    );

Future<void> _pumpHalf(WidgetTester tester, List<Passenger> occ) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SeatChartTile(
            cell: _double(),
            occupants: occ,
            groupColors: const GroupColorResolver(<String, int>{}),
            markHalfDouble: true,
          ),
        ),
      ),
    ),
  );
}

Finder _emptyBerth() => find.byIcon(Icons.event_seat_outlined);

void main() {
  testWidgets(
    'double with GO+RET leg-share gives each rider a WHOLE leg row',
    (tester) async {
      // Video case: a GO-only rider holds the sofa, a RET-only single is shared
      // in. Each rides a different leg, so each owns a full-width row — Asha the
      // GO row, Bina the RET row. The old tile squeezed the pair into the left
      // column to carve an empty berth out of the right, quartering them both.
      await _pumpHalf(tester, [
        _p('go', 'Asha', TripType.outboundOnly),
        _p('ret', 'Bina', TripType.returnOnly),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      // Both leg rows are taken, so there is no empty row to draw.
      expect(_emptyBerth(), findsNothing);
    },
  );

  testWidgets(
    'double held WHOLE by one round-trip rider shows NO empty half (full)',
    (tester) async {
      // A whole double = the same passenger on both berths (two raw entries).
      final a = _p('a', 'Falgun', TripType.roundTrip);
      await _pumpHalf(tester, [a, a]);
      expect(tester.takeException(), isNull);
      expect(find.text('Falgun'), findsOneWidget);
      expect(_emptyBerth(), findsNothing);
    },
  );

  testWidgets(
    'double with a single GO-only rider shows an empty half',
    (tester) async {
      await _pumpHalf(tester, [_p('go', 'Asha', TripType.outboundOnly)]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(_emptyBerth(), findsOneWidget);
    },
  );

  testWidgets(
    'double FULL on the GO leg (two GO singles) still shows the free RET row',
    (tester) async {
      // Video case: two GO-only singles merged into an empty double. They fill
      // the outbound leg (g=2) and touch the return leg not at all (r=0), so
      // both riders belong on the TOP row and the whole RETURN leg is still
      // bookable. The old tile stacked them over the entire sofa, so two GO
      // singles made a half-empty double read as fully booked.
      await _pumpHalf(tester, [
        _p('a', 'Asha', TripType.outboundOnly),
        _p('b', 'Bina', TripType.outboundOnly),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      expect(_emptyBerth(), findsOneWidget); // the free RETURN leg row
    },
  );

  testWidgets(
    'WHOLE ONE-LEG double (one rider, both GO berths) shows a free empty half',
    (tester) async {
      // Same rider on BOTH berths but GO only → both RET berths are free.
      final t = _p('t', 'Test', TripType.outboundOnly);
      await _pumpHalf(tester, [t, t]);
      expect(tester.takeException(), isNull);
      expect(find.text('Test'), findsOneWidget);
      // The free return capacity must be visible, not read as fully booked.
      expect(_emptyBerth(), findsOneWidget);
    },
  );

  testWidgets(
    'double with 4 leg-disjoint riders (2 GO + 2 RET) shows ALL FOUR names',
    (tester) async {
      await _pumpHalf(tester, [
        _p('g1', 'Asha', TripType.outboundOnly),
        _p('g2', 'Bina', TripType.outboundOnly),
        _p('r1', 'Chetan', TripType.returnOnly),
        _p('r2', 'Dev', TripType.returnOnly),
      ]);
      expect(tester.takeException(), isNull);
      // The old tile drew only 2 + "+2"; all four must now be visible.
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      expect(find.text('Chetan'), findsOneWidget);
      expect(find.text('Dev'), findsOneWidget);
      // Nothing over-booked → no "+N" badge.
      expect(find.text('+1'), findsNothing);
      expect(find.text('+2'), findsNothing);
    },
  );

  testWidgets(
    'double over-booked on GO (3 GO riders) flags the 3rd as +1, never hidden',
    (tester) async {
      await _pumpHalf(tester, [
        _p('g1', 'Asha', TripType.outboundOnly),
        _p('g2', 'Bina', TripType.outboundOnly),
        _p('g3', 'Chetan', TripType.outboundOnly),
      ]);
      expect(tester.takeException(), isNull);
      // GO row seats 2; the 3rd over-booked GO rider is surfaced as a badge.
      expect(find.text('+1'), findsOneWidget);
    },
  );
}
