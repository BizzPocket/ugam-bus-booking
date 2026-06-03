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

  testWidgets('renders one row per bus + the tour-totals capsule',
      (tester) async {
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

    // Bus 1 needs action: outstanding 800 handover due.
    expect(find.text('Handover ₹800 due'), findsOneWidget);
    // Bus 2 is settled.
    expect(find.text('Settled'), findsOneWidget);

    // Tour totals capsule: collected 1500, expenses 200, net 1300.
    expect(find.text('TOUR TOTALS'), findsOneWidget);
    expect(find.text('₹1500'), findsWidgets); // total collected
    expect(find.text('₹1300'), findsWidgets); // net
    // Outstanding handover across the tour = net 1300 - handed 500 = 800.
    expect(find.text('₹800'), findsWidgets);
  });

  testWidgets('classifier marks a bus with no activity as neutral',
      (tester) async {
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);
    // No collections/expenses/handovers seeded → both buses are neutral.

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('No activity'), findsNWidgets(2));
    expect(find.text('All settled'), findsOneWidget); // totals capsule, 0 out
  });
}
