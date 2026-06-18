import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_money_board_screen.dart';

/// Test double for [TourController] — skips the real network load + realtime
/// wiring so the board can read `tours` without a live Supabase graph.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: no _loadTours / RealtimeService lookup.
  }
}

/// Test double for [MoneyController] — overrides [loadForTour] (called from
/// the screen's post-frame init) to a no-op so it never touches SyncService.
/// Aggregation helpers are inherited unchanged and operate on the seeded
/// `collections` / `expenses` / `handovers` obs lists.
class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {
    // No-op: the test seeds the obs lists directly.
  }
}

Bus _bus(String id, String name) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _fakeTour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [
        _bus('b1', 'Bus 1'),
        _bus('b2', 'Bus 2'),
      ],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourMoneyBoardScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  // The board renders its bus rows in a lazy ListView, so a default phone-size
  // viewport only builds the first bus row before the fold. We grow the test
  // surface so BOTH bus rows are laid out and assertable in one paint.
  //
  // EasyLocalization is not initialised in tests, so every tr() (incl. the
  // status labels, which use namedArgs) renders as its RAW KEY — we assert
  // those keys, not English. Money figures come from Formatters.formatMoneyInr
  // which uses en_IN grouping → "₹1,000", "₹1,500" (with the thousands comma).
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('renders one row per bus + the tour-totals capsule',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);

    // Bus 1: collected 1000, expense 200 → expected handover 800, none handed
    // over yet → action needed (outstanding 800).
    money.collections.assignAll([
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p1',
        seatId: 'A1',
        amountDue: 1000,
        amountReceived: 1000,
      ),
      // Bus 2: collected 500, fully handed over → settled.
      Collection(
        tourId: 't1',
        busId: 'b2',
        passengerId: 'p2',
        seatId: 'B1',
        amountDue: 500,
        amountReceived: 500,
      ),
    ]);
    money.expenses.assignAll([
      Expense(tourId: 't1', busId: 'b1', label: 'Fuel', amount: 200),
    ]);
    money.handovers.assignAll([
      BusHandover(
        tourId: 't1',
        busId: 'b2',
        expectedAmount: 500,
        handedOverAmount: 500,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Header shows the tour title.
    expect(find.text('Dwarka Yatra'), findsOneWidget);

    // Both bus rows render (name + type).
    expect(find.text('Bus 1'), findsOneWidget);
    expect(find.text('Bus 2'), findsOneWidget);
    expect(find.text('Sleeper'), findsNWidgets(2));

    // Bus 1 needs action → its status dot carries the "handover due" label key
    // (namedArgs aren't interpolated without EasyLocalization). The outstanding
    // 800 leads the row as the headline figure.
    expect(find.text('tour_money_board.handover_due'), findsOneWidget);
    // Bus 2 is settled.
    expect(find.text('tour_money_board.settled'), findsOneWidget);

    // Tour-totals capsule: collected 1500, expenses 200, net 1300, with the
    // tour open (Bus 1's 800 still outstanding).
    expect(find.text('tour_money_board.tour_totals'), findsOneWidget);
    expect(find.text('tour_money_board.open'), findsOneWidget);
    expect(find.text('₹1,500'), findsOneWidget); // total collected
    expect(find.text('₹1,300'), findsOneWidget); // net
    // Outstanding handover (Bus 1's 800) appears as the bus headline AND the
    // tour-totals outstanding line.
    expect(find.text('₹800'), findsWidgets);
  });

  testWidgets('classifier marks a bus with no activity as neutral',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);
    // No collections/expenses/handovers seeded → both buses are neutral.

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Both bus rows show the neutral "no activity" status label key.
    expect(find.text('tour_money_board.no_activity'), findsNWidgets(2));
    // Totals capsule reports the tour fully settled (0 outstanding).
    expect(find.text('tour_money_board.all_settled'), findsOneWidget);
  });
}
