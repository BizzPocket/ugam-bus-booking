import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_overview_screen.dart';
import 'package:occubusbooking/services/seating_engine.dart';

/// Test double for [TourController] that needs no live Supabase / GetX
/// service graph. [onInit] is overridden to a no-op so registering it does
/// NOT kick off the real `_loadTours` + realtime subscription, and
/// [fillTour] is stubbed to record the invocation (and optionally surface
/// canned exceptions) instead of writing to the network.
class _FakeTourController extends TourController {
  /// Number of times [fillTour] was called — lets the test assert the pill
  /// is wired to the glue.
  int fillCalls = 0;

  /// Exceptions the stubbed plan reports back. Drives the "needs decision"
  /// chip after a fill.
  final List<SeatingException> stubExceptions;

  _FakeTourController({this.stubExceptions = const []});

  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring
    // (the parent's onInit calls _loadTours + Get.find<RealtimeService>()).
  }

  @override
  Future<SeatingPlan> fillTour(String tourId) async {
    fillCalls++;
    final plan = SeatingPlan(
      assignmentsByPassenger: const {},
      exceptions: stubExceptions,
      reasons: const [],
    );
    lastPlanByTour[tourId] = plan;
    lastPlanByTour.refresh();
    return plan;
  }
}

Bus _bus(String id, String name, {required int seats}) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

Passenger _passenger(String id, String tourId, {int seats = 1}) => Passenger(
      id: id,
      tourId: tourId,
      name: id,
      phone: '+910000000000',
      requestLines: [
        RequestLine(seatType: SeatType.doubleSofa, qty: seats),
      ],
    );

Tour _fakeTour() {
  const tourId = 't1';
  return Tour(
    id: tourId,
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [
      _bus('b1', 'Bus 1', seats: 30),
      _bus('b2', 'Bus 2', seats: 30),
    ],
    passengers: [
      _passenger('p1', tourId),
      _passenger('p2', tourId),
      _passenger('p3', tourId),
    ],
  );
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourOverviewScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('renders bus cards + the Fill bus pill', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Header shows the tour title.
    expect(find.text('Dwarka Yatra'), findsOneWidget);

    // Both bus cards render (name + type).
    expect(find.text('Bus 1'), findsOneWidget);
    expect(find.text('Bus 2'), findsOneWidget);
    expect(find.text('Sleeper'), findsNWidgets(2));

    // Fill-bus pill renders (no seats placed yet → "Fill bus" label).
    expect(find.text('Fill bus'), findsOneWidget);
  });

  testWidgets('tapping the Fill bus pill invokes the glue', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(ctrl.fillCalls, 0);
    await tester.tap(find.text('Fill bus'));
    await tester.pump(); // start the async fill
    await tester.pump(); // settle the post-fill setState

    expect(ctrl.fillCalls, 1);
  });

  testWidgets('shows the "need your decision" chip when the plan has exceptions',
      (tester) async {
    final ctrl = _FakeTourController(stubExceptions: const [
      SeatingException(
        type: SeatingExceptionType.seatTypeUnavailable,
        passengerId: 'p3',
        message: 'No matching Double Sofa free for p3.',
      ),
    ]);
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // No chip before a plan is generated.
    expect(find.textContaining('need your decision'), findsNothing);

    await tester.tap(find.text('Fill bus'));
    await tester.pump();
    await tester.pump();

    // After the fill, the cached plan's single exception surfaces.
    expect(find.text('1 need your decision'), findsOneWidget);
  });
}
