import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/design/components/ugam_free_by_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
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

SeatCell _cell(int row, int col, SeatType t, SeatPosition? pos, String id) =>
    SeatCell(row: row, col: col, seatType: t, position: pos, seatId: id);

Bus _busCells(String id, String name, List<SeatCell> cells) {
  var maxRow = 0;
  for (final cell in cells) {
    if (cell.row > maxRow) maxRow = cell.row;
  }
  return Bus(
    id: id,
    name: name,
    busType: 'Sleeper',
    layout: BusLayout(rows: maxRow + 1, cols: SeatGridCols.count, grid: cells),
  );
}

Tour _tourWith(List<Bus> buses, List<Passenger> ps) => Tour(
      id: 't1',
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 100,
      buses: buses,
      passengers: ps,
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourOverviewScreen(tourId: 't1'),
    );

/// Bus rows compose "<name>  ·  <type>" inside a single [RichText] span, so the
/// name/type are not findable as standalone [Text] widgets. These helpers walk
/// the rendered RichText trees and match against the flattened plain text.
String _flatten(InlineSpan span) => span.toPlainText();

bool _richTextContaining(WidgetTester tester, String needle) =>
    tester.widgetList<RichText>(find.byType(RichText)).any(
          (rt) => _flatten(rt.text).contains(needle),
        );

int _richTextSpanCount(WidgetTester tester, String needle) =>
    tester.widgetList<RichText>(find.byType(RichText)).where(
          (rt) => _flatten(rt.text).contains(needle),
        ).length;

void main() {
  tearDown(Get.reset);

  testWidgets('renders bus cards + the Fill bus pill', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // The redesigned screen is BODY-ONLY: the SeatsScreen shell owns the
    // head bar, so this widget no longer renders the tour title header.
    expect(find.text('Dwarka Yatra'), findsNothing);

    // Bus names render inside the slim bus rows. Each row composes
    // "<name>  ·  <type>" in a single RichText span, so the name + type are
    // NOT separate Text widgets — match the combined run via RichText.
    expect(_richTextContaining(tester, 'Bus 1'), isTrue);
    expect(_richTextContaining(tester, 'Bus 2'), isTrue);
    // Bus type "Sleeper" appears as a span inside each of the two bus rows.
    expect(_richTextSpanCount(tester, 'Sleeper'), 2);

    // The summary's "seats placed" eyebrow renders (raw key — easy_localization
    // is not initialized in tests, so tr() returns the key string).
    expect(find.text('tour_overview.seats_placed'), findsOneWidget);

    // Standalone CTA renders the auto-fill button. Its label is the raw key
    // (no seats placed yet → the "fill_bus" key, not "regenerate_plan").
    expect(find.text('tour_overview.fill_bus'), findsOneWidget);
  });

  testWidgets('tapping the Fill bus pill invokes the glue', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(ctrl.fillCalls, 0);
    // The CTA label is the raw key (easy_localization not initialized).
    await tester.tap(find.text('tour_overview.fill_bus'));
    await tester.pump(); // start the async fill
    await tester.pump(); // settle the post-fill setState

    expect(ctrl.fillCalls, 1);
  });

  testWidgets(
      'a bus with unassigned demand is NOT shown full (matches the empty grid)',
      (tester) async {
    // The reported bug: enough DEMAND exists to fill the bus, but nobody is
    // actually seated yet. The old overview ran the engine plan and painted the
    // bus "ભરાઈ ગઈ / full"; the grid (real assignedSeats) was empty. The fixed
    // overview reads actual assignments, so an empty bus reads free, never full.
    const tourId = 't1';
    final tour = Tour(
      id: tourId,
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      // One small bus (4 berths). Demand OVER-fills it, so the engine plan would
      // have read it full — but no passenger has an assignedSeat.
      buses: [_bus('b1', 'Bus 1', seats: 4)],
      passengers: [
        _passenger('p1', tourId), // 1 double sofa = 2 berths
        _passenger('p2', tourId),
        _passenger('p3', tourId),
      ],
    );
    for (final p in tour.passengers) {
      expect(p.assignedSeats, isEmpty, reason: 'precondition: nothing is placed');
    }

    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([tour]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // l10n is not initialized in tests, so the meter renders raw keys:
    // 'capacity.full' when a leg is full, 'capacity.free_n' otherwise. The bus
    // must read FREE (grid is empty), never FULL.
    expect(find.text('capacity.full'), findsNothing,
        reason: 'nothing is assigned — no leg can be full');
    expect(find.text('capacity.free_n'), findsWidgets,
        reason: 'the empty bus shows free capacity, matching the grid');
  });

  testWidgets('a bus with mixed free types renders one pill per free type',
      (tester) async {
    // Empty bus with a single + a double, nobody assigned → both types free
    // round-trip → two pills, and no one-way caption.
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _tourWith([
        _busCells('b1', 'Bus 1', [
          _cell(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _cell(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
        ])
      ], const [])
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(UgamTypeFreePill), findsNWidgets(2),
        reason: 'one pill for the free single, one for the free double');
    expect(find.byType(UgamLegCaption), findsNothing,
        reason: 'all seats free both legs — no one-way surplus');
  });

  testWidgets('a genuinely full bus renders no type pills', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _tourWith([
        _busCells('b1', 'Bus 1', [
          _cell(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        ])
      ], [
        Passenger(
          id: 'A',
          tourId: 't1',
          name: 'A',
          phone: '+910000000000',
          requestLines: const [
            RequestLine(seatType: SeatType.singleSofa, qty: 1),
          ],
          assignedSeats: const [
            SeatAssignment(busId: 'b1', seatId: 'SU1', leg: TripType.roundTrip),
          ],
        ),
      ])
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(UgamTypeFreePill), findsNothing);
  });

  testWidgets('a return-only opening surfaces a pill + the leg caption',
      (tester) async {
    // One single seat taken GOING only → it returns empty. The meter reads
    // round-trip-full, but the type line must still surface the return-only
    // seat (the "available for one leg" case) with the go/return colour key.
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _tourWith([
        _busCells('b1', 'Bus 1', [
          _cell(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        ])
      ], [
        Passenger(
          id: 'A',
          tourId: 't1',
          name: 'A',
          phone: '+910000000000',
          requestLines: const [
            RequestLine(
                seatType: SeatType.singleSofa,
                qty: 1,
                leg: TripType.outboundOnly),
          ],
          assignedSeats: const [
            SeatAssignment(
                busId: 'b1', seatId: 'SU1', leg: TripType.outboundOnly),
          ],
          tripType: TripType.outboundOnly,
        ),
      ])
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(UgamTypeFreePill), findsOneWidget,
        reason: 'the return-only single is still a bookable seat');
    expect(find.byType(UgamLegCaption), findsOneWidget,
        reason: 'a one-way-only opening shows the go/return colour key');
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

    // No chip before a plan is generated (raw key — l10n not initialized).
    expect(find.text('tour_overview.need_decision'), findsNothing);

    await tester.tap(find.text('tour_overview.fill_bus'));
    await tester.pump();
    await tester.pump();

    // After the fill, the cached plan's single exception surfaces the
    // decision chip. easy_localization isn't initialized so the chip renders
    // the raw key string (namedArgs aren't interpolated into a missing key).
    expect(find.text('tour_overview.need_decision'), findsOneWidget);
  });
}
