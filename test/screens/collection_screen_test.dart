import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/collection_screen.dart';
import 'package:occubusbooking/widgets/money_loading_skeleton.dart';

/// No-op load so the screen's post-frame init never touches SyncService; the
/// test seeds the money obs lists directly. [refreshForTour] is likewise
/// overridden (rather than left to the real implementation, which calls
/// `Get.find<SyncService>()`) so pull-to-refresh wiring can be asserted
/// without standing up a fake SyncService.
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

Bus _bus() => Bus(
      id: 'b1',
      name: 'Vantara',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Passenger _passenger() => Passenger(
      tourId: 't1',
      name: 'Riya Shah',
      phone: '9876543210',
      assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'A1')],
    );

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus()],
      passengers: [_passenger()],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: CollectionScreen(tour: _tour(), bus: _bus()),
    );

void main() {
  tearDown(Get.reset);

  // EasyLocalization is not initialised in tests, so tr() renders raw keys.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('shows the loading skeleton on first load, not the roster',
      (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
    // isLoading true + loadedOnce still false (its default) is the exact
    // first-fetch state the gate targets — before any row has ever landed.
    money.isLoading.value = true;

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(MoneyLoadingSkeleton), findsOneWidget);
    // The real passenger roster must not render underneath the skeleton.
    expect(find.text('Riya Shah'), findsNothing);
  });

  testWidgets(
      'a same-tour refresh (loadedOnce true) keeps the roster, no skeleton',
      (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
    // Seed real data and mark the tour as already loaded once...
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
    money.loadedOnce.value = true;

    await tester.pumpWidget(_harness());
    await tester.pump();

    // ...then start a background refresh: isLoading flips true again, but
    // loadedOnce is still true, so the `&& !loadedOnce` clause must suppress
    // the skeleton and keep the existing roster on screen.
    money.isLoading.value = true;
    await tester.pump();

    expect(find.byType(MoneyLoadingSkeleton), findsNothing);
    expect(find.text('Riya Shah'), findsOneWidget);
  });

  testWidgets('renders the passenger roster once loaded', (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Riya Shah'), findsOneWidget);
  });

  testWidgets('pull-to-refresh calls refreshForTour for this tour',
      (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
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

    final indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await indicator.onRefresh();

    expect(money.refreshedCalled, isTrue);
    expect(money.refreshedTourId, 't1');
  });
}
