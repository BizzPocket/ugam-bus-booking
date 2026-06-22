import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/components/ugam_tab_pills.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_seat_snapshot.dart';
import 'package:occubusbooking/screens/past_tour_seat_history_screen.dart';

/// Test double for [TourController] mirroring the screen-test idiom (see
/// tour_groups_screen_test.dart / seats_screen_test.dart): [onInit] is a no-op
/// so registering it does NOT start the real `_loadTours` + realtime
/// subscription, and [loadSeatSnapshots] returns CONTROLLED data instead of
/// touching Supabase. The live `Bus` layouts the screen pairs each snapshot bus
/// to are seeded via `tours` (read back by the real `getTour`).
class _FakeTourController extends TourController {
  /// Snapshots [loadSeatSnapshots] hands back, keyed by tourId.
  final Map<String, List<TourSeatSnapshot>> snapshotsByTour;

  _FakeTourController({this.snapshotsByTour = const {}});

  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }

  @override
  Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async {
    return snapshotsByTour[tourId] ?? const [];
  }
}

/// A 30-seat sleeper bus with a real, fully-generated [BusLayout] so the grid
/// has actual seat cells / ids to render against the snapshot map.
Bus _bus(String id, String name) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Passenger _passenger(
  String id,
  String tourId, {
  List<SeatAssignment> assigned = const [],
}) =>
    Passenger(
      id: id,
      tourId: tourId,
      name: id,
      phone: '+910000000000',
      requestLines: const [RequestLine(seatType: SeatType.doubleSofa, qty: 1)],
      assignedSeats: assigned,
    );

Tour _fakeTour({List<Passenger> passengers = const []}) {
  const tourId = 't1';
  return Tour(
    id: tourId,
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 1, 1),
    pricePerSeat: 1200,
    buses: [_bus('b1', 'Bus 1')],
    passengers: passengers,
  );
}

/// First real seat id on bus `b1`'s generated layout — used as the seat the
/// snapshot occupant sits on so the grid actually paints that occupant.
String _firstSeatId() =>
    BusLayout.generate(busType: BusType.sleeper, totalSeats: 30)
        .allSeatIds
        .first;

TourSeatSnapshot _snapshot(
  SnapshotLeg leg, {
  required String seatId,
  required String occupantName,
}) =>
    TourSeatSnapshot(
      tourId: 't1',
      leg: leg,
      buses: [
        SnapshotBus(
          busId: 'b1',
          seats: [SnapshotSeat(seatId: seatId, name: occupantName)],
        ),
      ],
      capturedAt: DateTime(2026, 1, 2),
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const PastTourSeatHistoryScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('both legs captured → GO/RETURN toggle + outbound occupant render',
      (tester) async {
    final seatId = _firstSeatId();
    final ctrl = _FakeTourController(snapshotsByTour: {
      't1': [
        _snapshot(SnapshotLeg.outbound,
            seatId: seatId, occupantName: 'Asha Outbound'),
        _snapshot(SnapshotLeg.return_,
            seatId: seatId, occupantName: 'Bharat Return'),
      ],
    });
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle(); // settle the initState loadSeatSnapshots()

    // Both legs present → the GO/RETURN segmented toggle is shown.
    expect(find.byType(UgamTabPills), findsOneWidget);
    // Its two leg labels render (raw keys — easy_localization not initialized).
    expect(find.text('seat_history.leg_go'), findsOneWidget);
    expect(find.text('seat_history.leg_return'), findsOneWidget);

    // Default leg is outbound (GO) → the outbound occupant is on the chart, not
    // the return one.
    expect(find.text('Asha Outbound'), findsOneWidget);
    expect(find.text('Bharat Return'), findsNothing);
  });

  testWidgets('only one leg captured → no toggle; occupant renders',
      (tester) async {
    final seatId = _firstSeatId();
    final ctrl = _FakeTourController(snapshotsByTour: {
      't1': [
        _snapshot(SnapshotLeg.outbound,
            seatId: seatId, occupantName: 'Solo Rider'),
      ],
    });
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // A single leg → no GO/RETURN toggle at all.
    expect(find.byType(UgamTabPills), findsNothing);
    expect(find.text('seat_history.leg_go'), findsNothing);

    // The single snapshot's occupant still renders.
    expect(find.text('Solo Rider'), findsOneWidget);
  });

  testWidgets(
      'no snapshots + live passengers → fallback note + live occupants render',
      (tester) async {
    final seatId = _firstSeatId();
    // No snapshots for this tour → screen falls back to the live chart. Seed a
    // live passenger holding that seat so seatOccupantsForBus resolves them.
    final ctrl = _FakeTourController(snapshotsByTour: const {});
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _fakeTour(passengers: [
        _passenger('Live Occupant', 't1', assigned: [
          SeatAssignment(busId: 'b1', seatId: seatId),
        ]),
      ]),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // No snapshot → the fallback banner note shows (raw key).
    expect(find.text('seat_history.fallback_note'), findsOneWidget);
    // And the live occupant is painted on the read-only chart.
    expect(find.text('Live Occupant'), findsOneWidget);
    // No toggle in the fallback path.
    expect(find.byType(UgamTabPills), findsNothing);
  });
}
