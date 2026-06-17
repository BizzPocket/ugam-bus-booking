import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for the reported bug: a Double Sofa holding only a GO-only +
/// RET-only leg-share pair STILL has one free berth (capacity 2 − max(GO,RET)
/// = 2 − 1 = 1), yet it rendered as a fully-booked leg-share tile. A double
/// that is not physically full must show its free half as an empty,
/// bookable berth — same as a single-on-half-double already does.
///
/// `markHalfDouble` is the berth-accurate flag the seat-assignment chart
/// passes; the empty half is drawn with [Icons.event_seat_outlined].

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
    'double with GO+RET leg-share shows BOTH names AND a free empty half',
    (tester) async {
      await _pumpHalf(tester, [
        _p('go', 'Asha', TripType.outboundOnly),
        _p('ret', 'Bina', TripType.returnOnly),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bina'), findsOneWidget);
      // The remaining berth must read as available, not fully booked.
      expect(_emptyBerth(), findsOneWidget);
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
    'double FULL on the GO leg (two GO singles) shows NO empty half',
    (tester) async {
      // go=2, ret=0 → max=2 → free=0 → fully booked side-by-side.
      await _pumpHalf(tester, [
        _p('a', 'Asha', TripType.outboundOnly),
        _p('b', 'Bina', TripType.outboundOnly),
      ]);
      expect(tester.takeException(), isNull);
      expect(_emptyBerth(), findsNothing);
    },
  );
}
