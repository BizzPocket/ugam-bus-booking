import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/trip_pnl_screen.dart';
import 'package:occubusbooking/widgets/money_loading_skeleton.dart';

/// Test double for [TourController] — skips the real network load + realtime
/// wiring so the screen can read `tours` without a live Supabase graph.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: no _loadTours / RealtimeService lookup.
  }
}

/// Test double for [MoneyController] — overrides [loadForTour] (called from
/// the screen's post-frame init) to a no-op so it never touches SyncService.
/// [refreshForTour] is likewise overridden (rather than left to the real
/// implementation, which calls `Get.find<SyncService>()`) so pull-to-refresh
/// wiring can be asserted without standing up a fake SyncService.
class _FakeMoneyController extends MoneyController {
  bool refreshedCalled = false;
  String? refreshedTourId;

  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async {
    refreshedCalled = true;
    refreshedTourId = tourId;
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
      buses: [_bus('b1', 'Bus 1')],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TripPnlScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  // EasyLocalization is not initialised in tests, so tr() renders raw keys.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('shows the loading skeleton on first load, not an all-₹0 P&L',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);
    // isLoading true + loadedOnce still false (its default) is the exact
    // first-fetch state the gate targets — before any row has ever landed.
    money.isLoading.value = true;

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(MoneyLoadingSkeleton), findsOneWidget);
    // The real P&L content must not render underneath the skeleton.
    expect(find.text('Bus 1'), findsNothing);
  });

  testWidgets('renders the trip total once loaded', (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);
    money.collections.assignAll([
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p1',
        seatId: 'A1',
        amountDue: 1000,
        amountReceived: 1000,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Bus 1'), findsOneWidget);
  });

  testWidgets('pull-to-refresh calls refreshForTour for this tour',
      (tester) async {
    useTallSurface(tester);
    final tours = _FakeTourController();
    final money = _FakeMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    final indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await indicator.onRefresh();

    expect(money.refreshedCalled, isTrue);
    expect(money.refreshedTourId, 't1');
  });
}
