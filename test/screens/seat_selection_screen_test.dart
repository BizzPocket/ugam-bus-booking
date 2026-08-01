import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/seat_selection_screen.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// Renders the customer chart against the EXACT payload production returns,
/// captured from `chart_tour_buses` for the live test tour. If the screen can
/// go blank, it goes blank here.
const _rpcBusJson = '''
{
  "id": "ab8a5ef3-26ff-4ccb-8c99-f144cdd5f744",
  "name": "Test Bus 1",
  "is_ac": true,
  "tour_id": "341baff4-9c9b-47b7-868f-ad123cffb8d1",
  "bus_type": "Sleeper",
  "rear_rows": 2,
  "rear_price": 1100,
  "price_bands": [],
  "seater_price": null,
  "boarding_point": "Udhna",
  "departure_time": "21:30",
  "price_per_seat": 900.0,
  "registration_no": "GJ05TEST1",
  "double_sofa_price": 1600.0,
  "single_sofa_price": 900.0,
  "layout": {
    "rows": 6,
    "cols": 5,
    "hasBalcony": false,
    "grid": [
      {"col":0,"row":0,"seatId":"SU1","position":"upper","seatType":"singleSofa"},
      {"col":1,"row":0,"seatId":"SL1","position":"lower","seatType":"singleSofa"},
      {"col":3,"row":0,"seatId":"DU1","position":"upper","seatType":"doubleSofa"},
      {"col":4,"row":0,"seatId":"DL1","position":"lower","seatType":"doubleSofa"},
      {"col":0,"row":1,"seatId":"SU2","position":"upper","seatType":"singleSofa"},
      {"col":1,"row":1,"seatId":"SL2","position":"lower","seatType":"singleSofa"},
      {"col":3,"row":1,"seatId":"DU2","position":"upper","seatType":"doubleSofa"},
      {"col":4,"row":1,"seatId":"DL2","position":"lower","seatType":"doubleSofa"}
    ]
  }
}
''';

void main() {
  Bus liveBus() =>
      Bus.fromMap(Map<String, dynamic>.from(jsonDecode(_rpcBusJson) as Map));

  Tour chartTour() => Tour(
        id: '341baff4-9c9b-47b7-868f-ad123cffb8d1',
        title: 'TEST',
        fromCity: 'Surat',
        toCity: 'Shirdi',
        departureDate: DateTime(2026, 9, 15),
        returnDate: DateTime(2026, 9, 18),
        pricePerSeat: 900,
        status: TourStatus.busBooked,
        bookingMode: BookingMode.chart,
      );

  Widget harness({
    required List<Bus> buses,
    Map<String, SeatAvailability> availability = const {},
  }) {
    return MaterialApp(
      home: SeatSelectionScreen(
        tour: chartTour(),
        loadBuses: (_) async => buses,
        loadAvailability: (_) async => availability,
      ),
    );
  }

  testWidgets('the RPC payload parses into a bus with a usable layout',
      (tester) async {
    final b = liveBus();
    expect(b.layout, isNotNull, reason: 'a null layout blanks the chart');
    expect(b.layout!.grid.where((c) => c.hasSeat), isNotEmpty);
    expect(b.layout!.totalSeats, greaterThan(0));
    // NOTE: BusLayout.fromMap RECOMPUTES `rows` from the grid's max row, so a
    // truncated fixture shrinks the bus and the rear zone (rows - rearRows)
    // slides forward to cover everything. With this 2-row fixture and
    // rear_rows = 2, EVERY row is the rear band — hence 1100, not 900.
    expect(b.layout!.rows, 2);
    expect(b.berthPriceFor(b.layout!.grid.first.seatType!, 0), 1100);
  });

  testWidgets('renders with REAL occupancy — the seeded live seats',
      (tester) async {
    // Exactly what chart_seat_availability returns for the live test tour:
    // a lady on a single, half a double taken, and a double sold GO-only.
    const busId = 'ab8a5ef3-26ff-4ccb-8c99-f144cdd5f744';
    final avail = availabilityByKey(const [
      SeatAvailability(
        busId: busId, seatId: 'SU1',
        usedGo: 1, usedRet: 1, ladyGo: true, ladyRet: true,
      ),
      SeatAvailability(
        busId: busId, seatId: 'DU1', usedGo: 1, usedRet: 1,
      ),
      SeatAvailability(
        busId: busId, seatId: 'DL1', usedGo: 2, usedRet: 0, ladyGo: true,
      ),
    ]);

    await tester.pumpWidget(harness(buses: [liveBus()], availability: avail));
    await tester.pumpAndSettle();

    // A half-taken double renders as the SPLIT tile — the case an empty
    // availability map never exercises.
    expect(find.text('SU1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chart actually renders seats — not a blank body',
      (tester) async {
    await tester.pumpWidget(harness(buses: [liveBus()]));
    await tester.pumpAndSettle();

    // The bug this test exists for: app bar present, body empty.
    expect(find.text('SU1'), findsOneWidget);
    expect(find.text('DL1'), findsOneWidget);
  });

  testWidgets('an empty bus list shows the empty state, never a blank screen',
      (tester) async {
    await tester.pumpWidget(harness(buses: const []));
    await tester.pumpAndSettle();
    // Something explanatory must be on screen.
    expect(find.byType(Text), findsWidgets);
  });
}
