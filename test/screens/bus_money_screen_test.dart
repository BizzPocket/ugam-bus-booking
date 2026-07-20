import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/income_entry.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/bus_money_screen.dart';

/// No-op load so the screen's post-frame init never touches SyncService; the
/// test seeds the money obs lists directly and the inherited aggregation
/// helpers (summaryForBus) read them.
class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {}
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Vantara',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus()],
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: BusMoneyScreen(tour: _tour(), bus: _bus()),
    );

void main() {
  tearDown(Get.reset);

  // EasyLocalization is not initialised in tests, so tr() renders raw keys —
  // we assert those. Grow the surface so the whole cockpit lays out.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('income stat is hidden when there is no extra income',
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

    // No income seeded → the Income stat label key must not render.
    expect(find.text('bus_money.stat_income'), findsNothing);
    // Collected + expenses stats still render.
    expect(find.text('bus_money.stat_collected'), findsOneWidget);
    expect(find.text('bus_money.stat_expenses'), findsOneWidget);
  });

  testWidgets('income stat appears once there is income', (tester) async {
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
    money.incomes.assignAll([
      IncomeEntry(
        tourId: 't1',
        busId: 'b1',
        category: IncomeCategory.other,
        label: 'Cabin',
        amount: 500,
      ),
    ]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('bus_money.stat_income'), findsOneWidget);
  });
}
