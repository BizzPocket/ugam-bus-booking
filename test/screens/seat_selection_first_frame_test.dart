import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_skeleton.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/seat_selection_screen.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// Why the push into the chart felt janky.
///
/// It is NOT the page transition builder — Flutter already supplies a
/// platform-appropriate one (PredictiveBack on Android, Cupertino on iOS), and
/// overriding Android's would throw away predictive-back gestures. The cost is
/// the FIRST FRAME: the screen rendered a bare centred CircularProgressIndicator
/// and then, mid-transition, replaced it with a full ListView + seat grid. The
/// body's whole structure changed while the route was still animating.
///
/// The fix is that loading and loaded frames share a structure, so nothing
/// reflows underneath the transition. These tests pin that.
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
    "rows": 2,
    "cols": 5,
    "hasBalcony": false,
    "grid": [
      {"col":0,"row":0,"seatId":"SU1","position":"upper","seatType":"singleSofa"},
      {"col":1,"row":0,"seatId":"SL1","position":"lower","seatType":"singleSofa"},
      {"col":3,"row":0,"seatId":"DU1","position":"upper","seatType":"doubleSofa"},
      {"col":4,"row":0,"seatId":"DL1","position":"lower","seatType":"doubleSofa"}
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

  /// Holds the load open so the loading frame can be inspected.
  Widget slowHarness(Completer<List<Bus>> gate) => MaterialApp(
        home: SeatSelectionScreen(
          tour: chartTour(),
          loadBuses: (_) => gate.future,
          loadAvailability: (_) async => const <String, SeatAvailability>{},
        ),
      );

  testWidgets('the loading frame is a skeleton, not a bare spinner',
      (tester) async {
    final gate = Completer<List<Bus>>();
    await tester.pumpWidget(slowHarness(gate));
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'a bare spinner swapped for a full grid mid-transition is the '
          'layout jump that made the push feel janky',
    );
    expect(
      find.byType(ChartSeatSkeleton),
      findsOneWidget,
      reason: 'the loading frame must already occupy the shape the seats '
          'will land in',
    );

    gate.complete([liveBus()]);
    await tester.pumpAndSettle();
  });

  testWidgets('the loaded frame keeps the same scaffold as the loading frame',
      (tester) async {
    final gate = Completer<List<Bus>>();
    await tester.pumpWidget(slowHarness(gate));
    await tester.pump();

    // The deck card is the thing the seats land inside. Its geometry must be
    // decided BEFORE the data arrives, or the body resizes mid-transition.
    final loadingDeck = tester.getRect(find.byType(ChartSeatSkeleton));

    gate.complete([liveBus()]);
    await tester.pumpAndSettle();

    expect(find.byType(ChartSeatSkeleton), findsNothing);
    expect(find.text('SU1'), findsOneWidget);
    expect(
      tester.getRect(find.byType(ChartSeatTile).first).top,
      greaterThanOrEqualTo(loadingDeck.top),
      reason: 'the seats must land inside the space the skeleton reserved, '
          'not push the body down when they arrive',
    );
  });

  testWidgets('every rendered seat tile has the shared fixed footprint',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SeatSelectionScreen(
          tour: chartTour(),
          loadBuses: (_) async => [liveBus()],
          loadAvailability: (_) async => const <String, SeatAvailability>{},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tiles = find.byType(ChartSeatTile);
    expect(tiles, findsWidgets);

    for (var i = 0; i < tester.widgetList(tiles).length; i++) {
      final size = tester.getSize(tiles.at(i));
      expect(
        size.width,
        ChartSeatMetrics.width,
        reason: 'tile $i rendered at a width the grid did not choose',
      );
      expect(size.height, ChartSeatMetrics.height);
    }
  });
}
