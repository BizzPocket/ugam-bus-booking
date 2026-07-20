import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for the reported bug: when a rider SHARES a double sofa with
/// someone (side-by-side split) — or holds only one berth of a double (the
/// half-taken tile) — the mobile number was dropped from the tile, so the
/// agent could not read the shared occupant's phone. Every other tile shows
/// name-over-number; the split halves must too. `displayPhone` keeps the
/// last-10 digits, so '+919876543210' renders as '9876543210'.

Passenger _p(String id, String name, TripType trip, String phone) => Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: phone,
      tripType: trip,
    );

SeatCell _double() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.doubleSofa,
      position: SeatPosition.lower,
      seatId: 'DL5',
    );

Future<void> _pump(
  WidgetTester tester,
  List<Passenger> occ, {
  bool markHalfDouble = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SeatChartTile(
            cell: _double(),
            occupants: occ,
            groupColors: const GroupColorResolver(<String, int>{}),
            markHalfDouble: markHalfDouble,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'shared double sofa shows BOTH occupants\' mobile numbers',
    (tester) async {
      await _pump(tester, [
        _p('a', 'Falgun', TripType.roundTrip, '+919876543210'),
        _p('b', 'Gita', TripType.roundTrip, '+918123456789'),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('Falgun'), findsOneWidget);
      expect(find.text('Gita'), findsOneWidget);
      // The mobile numbers must be visible on each half — not dropped.
      expect(find.text('9876543210'), findsOneWidget);
      expect(find.text('8123456789'), findsOneWidget);
    },
  );

  testWidgets(
    'half-taken double sofa (one rider + empty berth) shows the mobile number',
    (tester) async {
      await _pump(
        tester,
        [_p('go', 'Asha', TripType.outboundOnly, '+919876543210')],
        markHalfDouble: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.byIcon(Icons.event_seat_outlined), findsOneWidget);
      // The lone occupant's number must show even though the tile is split.
      expect(find.text('9876543210'), findsOneWidget);
    },
  );
}
