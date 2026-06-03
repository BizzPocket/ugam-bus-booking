import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/seating_exceptions_screen.dart';
import 'package:occubusbooking/services/seating_engine.dart';

/// Test double for [TourController] that needs no live Supabase / GetX
/// service graph. [onInit] is overridden to a no-op so registering it does
/// NOT kick off the real `_loadTours` + realtime subscription. A canned
/// [SeatingPlan] can be seeded straight into [lastPlanByTour] so the
/// exception screen reads it reactively, exactly as it would after a real
/// [fillTour].
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }

  void seedPlan(String tourId, List<SeatingException> exceptions) {
    lastPlanByTour[tourId] = SeatingPlan(
      assignmentsByPassenger: const {},
      exceptions: exceptions,
      reasons: const [],
    );
    lastPlanByTour.refresh();
  }
}

Passenger _passenger(String id, String tourId, String name) => Passenger(
      id: id,
      tourId: tourId,
      name: name,
      phone: '+910000000000',
      requestLines: [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1),
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
    buses: const [],
    passengers: [
      _passenger('p1', tourId, 'Ramesh Patel'),
      _passenger('p2', tourId, 'Sita Joshi'),
      _passenger('p3', tourId, 'Mohan Shah'),
    ],
  );
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const SeatingExceptionsScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('header renders the "Needs your decision" title',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Needs your decision'), findsOneWidget);
  });

  testWidgets(
      'groups exceptions by category, rendering headers, messages, and '
      'resolved passenger names', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);
    ctrl.seedPlan('t1', const [
      // → "Priority"
      SeatingException(
        type: SeatingExceptionType.priorityNoFrontSeat,
        passengerId: 'p1',
        message: 'Approved-priority Ramesh Patel was seated, but no front '
            'sofa seat was available.',
      ),
      // → "Seat type"
      SeatingException(
        type: SeatingExceptionType.seatTypeUnavailable,
        passengerId: 'p3',
        message: 'No matching Double Sofa seat free for Mohan Shah.',
      ),
      // → "Groups"
      SeatingException(
        type: SeatingExceptionType.groupWontFit,
        groupId: 'patel',
        message: 'Group patel (6 berths across 3 bookings) does not fit on '
            'any single bus.',
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Section headers (uppercased) with their counts.
    expect(find.text('PRIORITY'), findsOneWidget);
    expect(find.text('GROUPS'), findsOneWidget);
    expect(find.text('SEAT TYPE'), findsOneWidget);
    // No waitlist exception was seeded → no Waitlist section.
    expect(find.text('WAITLIST'), findsNothing);

    // Per-exception messages render.
    expect(
      find.textContaining('no front sofa seat was available'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No matching Double Sofa seat free'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not fit on any single bus'),
      findsOneWidget,
    );

    // Resolved passenger names (from the tour roster) appear as card titles.
    expect(find.text('Ramesh Patel'), findsOneWidget);
    expect(find.text('Mohan Shah'), findsOneWidget);

    // The group-scoped exception surfaces its group label.
    expect(find.text('Group patel'), findsOneWidget);
  });

  testWidgets('shows the calm "All clear" panel when there are no exceptions',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);
    // No plan seeded → exceptionsForTour returns empty.

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('All clear'), findsOneWidget);
    expect(
      find.textContaining('No seating decisions need your attention'),
      findsOneWidget,
    );

    // No section headers in the empty state.
    expect(find.text('PRIORITY'), findsNothing);
    expect(find.text('GROUPS'), findsNothing);
  });
}
