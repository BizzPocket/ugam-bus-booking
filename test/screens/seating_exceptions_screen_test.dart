import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/seating_exceptions_screen.dart';

/// Test double for [TourController] that needs no live Supabase / GetX
/// service graph. [onInit] is overridden to a no-op so registering it does
/// NOT kick off the real `_loadTours` + realtime subscription.
///
/// NOTE: the screen was redesigned to derive its exception list LIVE from the
/// engine (`seatingDecisionExceptions(tour)` → `SeatingEngine.propose`) rather
/// than reading a cached plan. So a test no longer seeds a `SeatingPlan`; it
/// seeds a real [Tour] (buses + passengers) whose live proposal genuinely
/// produces the exceptions under test.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }
}

SeatCell _seat(int row, int col, SeatType type, SeatPosition? pos, String id) =>
    SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

/// A tiny hand-rolled bus so we control exactly which seats are free. Rows
/// derive from the highest used row index.
Bus _bus(String id, List<SeatCell> cells) {
  var maxRow = 0;
  for (final c in cells) {
    if (c.row > maxRow) maxRow = c.row;
  }
  return Bus(
    id: id,
    name: id,
    busType: 'Sleeper',
    layout: BusLayout(rows: maxRow + 1, cols: SeatGridCols.count, grid: cells),
  );
}

Passenger _passenger(
  String id,
  String name, {
  List<RequestLine> lines = const [],
  String? groupId,
  PriorityStatus priority = PriorityStatus.none,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+910000000000',
      requestLines: lines,
      groupId: groupId,
      priorityStatus: priority,
    );

RequestLine _line(SeatType t, {SeatPosition? pos, int qty = 1}) =>
    RequestLine(seatType: t, position: pos, qty: qty);

/// A tour whose LIVE engine proposal yields exactly three exception
/// categories and no waitlist:
///   * priorityNoLowerBerth  (Ramesh Patel — only an upper sofa is free, so the
///     approved-priority rider is seated but not on a lower berth) → "Priority"
///   * seatTypeUnavailable   (Mohan Shah wants a Double Sofa, none free)
///     → "Seat type"
///   * groupWontFit          (group "patel" needs 4 berths, none fit) → "Groups"
Tour _exceptionsTour() {
  final bus = _bus('b1', [
    // The ONLY sofa is an upper single → priority rider seats here (no lower).
    _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_SU1'),
    _seat(0, 1, SeatType.seater, null, 'b1_ST1'),
  ]);
  return Tour(
    id: 't1',
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [bus],
    passengers: [
      _passenger(
        'p1',
        'Ramesh Patel',
        priority: PriorityStatus.approved,
        lines: [_line(SeatType.singleSofa)],
      ),
      _passenger(
        'p3',
        'Mohan Shah',
        lines: [_line(SeatType.doubleSofa)],
      ),
      _passenger('g1', 'Geeta A', groupId: 'patel',
          lines: [_line(SeatType.doubleSofa)]),
      _passenger('g2', 'Geeta B', groupId: 'patel',
          lines: [_line(SeatType.doubleSofa)]),
    ],
    // The roster's groupId is a PassengerGroup.id, so the group must exist on
    // the tour for the card to name it. The screen resolves id -> label and
    // renders NOTHING when the lookup misses (mirroring requests_screen), so
    // omitting this row silently drops the group tag instead of leaking the
    // raw id — which is exactly the bug the resolver was added to fix.
    groups: [
      PassengerGroup(id: 'patel', tourId: 't1', label: 'Patel Family'),
    ],
  );
}

/// A tour where every passenger fits → the live proposal has zero exceptions,
/// driving the calm "All clear" empty state.
Tour _allClearTour() {
  final bus = _bus('b1', [
    _seat(0, 0, SeatType.doubleSofa, SeatPosition.lower, 'b1_DL1'),
  ]);
  return Tour(
    id: 't1',
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [bus],
    passengers: [
      _passenger('p1', 'Ramesh Patel', lines: [_line(SeatType.doubleSofa)]),
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
    ctrl.tours.assignAll([_allClearTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // tr() falls back to the key when EasyLocalization isn't initialized in
    // the test harness, so we assert the translation keys (not the English).
    expect(find.text('seating_exceptions.title'), findsOneWidget);
  });

  testWidgets(
      'groups exceptions by category, rendering headers, messages, and '
      'resolved passenger names', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_exceptionsTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Section headers (uppercased category-label keys) for the three live
    // categories the proposal produced.
    expect(find.text('SEATING_EXCEPTIONS.CAT_PRIORITY'), findsOneWidget);
    expect(find.text('SEATING_EXCEPTIONS.CAT_GROUPS'), findsOneWidget);
    expect(find.text('SEATING_EXCEPTIONS.CAT_SEAT_TYPE'), findsOneWidget);
    // No overflow/waitlist exception arose → no Waitlist section.
    expect(find.text('SEATING_EXCEPTIONS.CAT_WAITLIST'), findsNothing);

    // The priority card swaps the engine message for explicit alert copy
    // (title + message keys), so we assert those keys, not the raw message.
    expect(find.text('priority.no_lower_title'), findsOneWidget);
    expect(find.text('priority.no_lower_msg'), findsOneWidget);

    // The seat-type and group cards render the engine's own message text. The
    // seat-type label is itself an un-translated key fragment in tests.
    expect(
      find.textContaining('No matching enums.seat_type.double_sofa'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not fit on any single bus'),
      findsOneWidget,
    );

    // Resolved passenger names (from the tour roster) appear as card titles for
    // the passenger-scoped exceptions.
    expect(find.text('Ramesh Patel'), findsOneWidget);
    expect(find.text('Mohan Shah'), findsOneWidget);

    // The group-scoped exception surfaces its group tag. The visible string is
    // the un-translated key (translations aren't loaded in tests, so tr() can't
    // interpolate the label), but the chip only renders at all once the screen
    // has resolved groupId -> PassengerGroup.
    expect(find.text('seating_exceptions.group_label'), findsOneWidget);

    // NOT asserted (deliberately): that the raw PassengerGroup.id is absent
    // from the whole card. The CHIP no longer leaks it, but the engine's own
    // message still interpolates the id — here "Group patel (4 berths across 2
    // bookings) does not fit on any single bus." In production that id is a v4
    // UUID, so the card body still reads "Group 3f2a1c9e-…". Closing that means
    // editing the seating engine's message construction, which this UI pass is
    // scoped out of; tracked as a follow-up. Tighten this to
    // `expect(find.textContaining('patel'), findsNothing)` once the engine
    // resolves the label itself.
  });

  testWidgets('shows the calm "All clear" panel when there are no exceptions',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_allClearTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('seating_exceptions.all_clear_title'), findsOneWidget);
    expect(find.text('seating_exceptions.all_clear_body'), findsOneWidget);

    // No section headers in the empty state.
    expect(find.text('SEATING_EXCEPTIONS.CAT_PRIORITY'), findsNothing);
    expect(find.text('SEATING_EXCEPTIONS.CAT_GROUPS'), findsNothing);
  });
}
