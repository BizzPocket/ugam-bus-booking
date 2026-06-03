import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/seat_detail_screen.dart';

/// Test double for [TourController] that needs no live Supabase / GetX
/// service graph. [onInit] is a no-op so registering it does NOT kick off
/// the real `_loadTours` + realtime subscription, and [cancelOneSeat] is
/// stubbed to RECORD the call (instead of writing to the network) so the
/// "Free seat" action can be asserted.
class _FakeTourController extends TourController {
  /// Records every (passengerId, busId, seatId) the screen asked to free.
  final List<String> freedSeats = [];

  /// Records every (busId, seatId, value) the screen asked to flag forward.
  final List<String> forwardCalls = [];

  /// Records every (busId, seatId, value) the screen asked to flag reserved.
  final List<String> reservedCalls = [];

  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }

  @override
  Future<void> cancelOneSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String seatId,
  }) async {
    freedSeats.add('$passengerId:$busId:$seatId');
  }

  @override
  Future<void> setSeatForward(
      String tourId, String busId, String seatId, bool forward) async {
    forwardCalls.add('$busId:$seatId:$forward');
  }

  @override
  Future<void> setSeatReserved(
      String tourId, String busId, String seatId, bool reserved) async {
    reservedCalls.add('$busId:$seatId:$reserved');
  }
}

/// Build a deterministic tiny layout with exactly the cells the test needs:
///   SU1 — booked single (single-upper, row 0)
///   SU2 — free single   (single-upper, row 1)
///   SU3 — reserved/held  (single-upper, row 2)
///   DU1 — booked single with a groupId (double-upper, row 0)
///   DL1 — booked single, priority-approved (double-lower, row 0)
BusLayout _layout() {
  return const BusLayout(
    rows: 3,
    cols: SeatGridCols.count,
    grid: [
      SeatCell(
        row: 0,
        col: SeatGridCols.singleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU1',
      ),
      SeatCell(
        row: 1,
        col: SeatGridCols.singleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU2',
      ),
      SeatCell(
        row: 2,
        col: SeatGridCols.singleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU3',
        reserved: true,
      ),
      SeatCell(
        row: 0,
        col: SeatGridCols.doubleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'DU1',
      ),
      SeatCell(
        row: 0,
        col: SeatGridCols.doubleLower,
        seatType: SeatType.singleSofa,
        position: SeatPosition.lower,
        seatId: 'DL1',
      ),
      // A Double Sofa, used by the whole-double and shared-double tests.
      SeatCell(
        row: 1,
        col: SeatGridCols.doubleUpper,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.upper,
        seatId: 'DU2',
      ),
    ],
  );
}

Bus _bus() => Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper', layout: _layout());

Passenger _booked(
  String id,
  String name,
  String seatId, {
  String? groupId,
  PriorityStatus priority = PriorityStatus.none,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+919876500000',
      groupId: groupId,
      priorityStatus: priority,
      requestLines: const [
        RequestLine(seatType: SeatType.singleSofa, qty: 1),
      ],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
    );

/// A passenger holding a WHOLE Double Sofa: ONE passenger with TWO
/// [SeatAssignment] entries on the SAME seatId (as written by
/// [TourController.consolidateOntoDouble]).
Passenger _wholeDouble(String id, String name, String seatId) => Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+919876500000',
      priorityStatus: PriorityStatus.none,
      requestLines: const [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1),
      ],
      assignedSeats: [
        SeatAssignment(busId: 'b1', seatId: seatId),
        SeatAssignment(busId: 'b1', seatId: seatId),
      ],
    );

Tour _fakeTour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus()],
      passengers: [
        _booked('p1', 'Ramesh Patel', 'SU1'),
        _booked('p2', 'Sita Joshi', 'DU1', groupId: 'patel'),
        _booked('p3', 'Mohan Shah', 'DL1', priority: PriorityStatus.approved),
      ],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const SeatDetailScreen(tourId: 't1', busId: 'b1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('renders the bus name header + assigned/total subtitle',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Bus 1'), findsOneWidget);
    // 3 booked of 7 berths total: 5 single berths (SU1-3, DU1, DL1) + the empty
    // DU2 Double Sofa, which counts as 2 berths in [BusLayout.totalSeats].
    expect(find.text('3/7 assigned'), findsOneWidget);
  });

  testWidgets('renders booked initials, the held tile, and free tiles',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Booked initials.
    expect(find.text('RP'), findsOneWidget); // Ramesh Patel
    expect(find.text('SJ'), findsOneWidget); // Sita Joshi (grouped)
    expect(find.text('MS'), findsOneWidget); // Mohan Shah (priority)

    // Reserved seat shows the "Held" label. The legend carries its own
    // "Held" swatch label, so the reserved tile pushes the count to two.
    expect(find.text('Held'), findsNWidgets(2));

    // Free seat shows its seat id.
    expect(find.text('SU2'), findsOneWidget);
  });

  testWidgets('tapping a booked seat opens a sheet with name + Free action',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Tap Ramesh's booked tile (his initials live only on the tile).
    await tester.tap(find.text('RP'));
    await tester.pumpAndSettle();

    // Sheet surfaces the occupant name and the Free seat action.
    expect(find.text('Ramesh Patel'), findsOneWidget);
    expect(find.text('Free seat'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);

    // Free seat calls the controller with this passenger + seat.
    expect(ctrl.freedSeats, isEmpty);
    await tester.tap(find.text('Free seat'));
    await tester.pumpAndSettle();
    expect(ctrl.freedSeats, contains('p1:b1:SU1'));
  });

  testWidgets(
      'WHOLE double (one passenger, two entries on same seatId) renders ONE '
      'tile and taps straight to the occupant sheet (no chooser)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _fakeTour().copyWith(
        passengers: [_wholeDouble('p9', 'Kiran Mehta', 'DU2')],
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // One occupant tile, not a split shared tile: initials appear exactly once.
    expect(find.text('KM'), findsOneWidget);
    // Two raw berths on the only passenger → 2/7 assigned (not 1/7). The layout
    // has 5 single berths + the DU2 double (counts as 2 berths) = 7 total.
    expect(find.text('2/7 assigned'), findsOneWidget);

    // Tapping goes straight to the occupant sheet — NO shared chooser.
    await tester.tap(find.text('KM'));
    await tester.pumpAndSettle();
    expect(find.text('is shared'), findsNothing);
    expect(find.textContaining('is shared'), findsNothing);
    expect(find.text('Kiran Mehta'), findsOneWidget);
    expect(find.text('Free seat'), findsOneWidget);
  });

  testWidgets(
      'SHARED double (two DISTINCT passengers on one seatId) renders a split '
      'tile and the chooser lists both distinct names',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _fakeTour().copyWith(
        passengers: [
          _booked('p10', 'Arjun Rao', 'DU2'),
          _booked('p11', 'Bela Nair', 'DU2'),
        ],
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Split tile shows BOTH distinct initials.
    expect(find.text('AR'), findsOneWidget);
    expect(find.text('BN'), findsOneWidget);
    // Two raw berths (one per distinct passenger) → 2/7 assigned.
    expect(find.text('2/7 assigned'), findsOneWidget);

    // Tapping the split tile opens the shared chooser listing both names.
    await tester.tap(find.text('AR'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is shared'), findsOneWidget);
    expect(find.text('Arjun Rao'), findsOneWidget);
    expect(find.text('Bela Nair'), findsOneWidget);
  });

  testWidgets(
      'Edit seats toggle opens the forward/reserved flag sheet and fires the '
      'controller setters', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Normal mode: the app-bar action reads "Edit seats".
    expect(find.text('Edit seats'), findsOneWidget);

    // Enter edit mode.
    await tester.tap(find.text('Edit seats'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    expect(find.textContaining('Editing seats'), findsOneWidget);

    // Tapping the free seat SU2 now opens the flag sheet (NOT the free info
    // sheet) — it surfaces both switch labels.
    await tester.tap(find.text('SU2'));
    await tester.pumpAndSettle();
    expect(find.text('Forward / premium seat'), findsOneWidget);
    expect(find.text('Hold / reserved'), findsOneWidget);

    // Flipping a switch fires the matching controller setter.
    expect(ctrl.forwardCalls, isEmpty);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(ctrl.forwardCalls, contains('b1:SU2:true'));
  });
}
