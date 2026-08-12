// The handover ledger on `bus_money_screen`, under the Gujarati guard.
//
// The row gained a second thing on its caption line: WHO recorded the
// settlement, beside the date. That line is the one place on this screen where
// two independent translated strings share a horizontal run, so it is exactly
// the "Row with an unbounded natural-width trailing child" shape this guard
// exists to catch — and `bus_money.handover_by_handler` is ~30% longer in
// Gujarati than the English it was drafted in.
//
// Run: flutter test test/overflow/bus_money_handover_row_overflow_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/bus_money_screen.dart';

import 'overflow_guard.dart';

/// No network: the screen's post-frame load and its pull-to-refresh both
/// reach for SyncService in production.
class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async {}
}

Bus _bus() => Bus(
      id: 'b1',
      tourId: 't1',
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

void main() {
  setUpAll(loadGuardTranslations);
  tearDown(resetGuardState);

  testWidgets('BusMoneyScreen — handover rows from BOTH sources',
      (tester) async {
    // Both branches of the new label render at once (rule 4): a settlement the
    // handler filed on the bus and one the office typed in. Lakh-scale figures
    // so the amount line is at its real width while the caption line below it
    // carries the longer of the two provenance strings.
    final money = _FakeMoneyController();
    money.collections.assignAll([
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p1',
        seatId: 'A1',
        amountDue: 245000,
        amountReceived: 245000,
      ),
    ]);
    money.handovers.assignAll([
      BusHandover(
        id: 'h-1',
        tourId: 't1',
        busId: 'b1',
        expectedAmount: 245000,
        handedOverAmount: 124500,
        source: 'handler',
      ),
      BusHandover(
        id: 'h-2',
        tourId: 't1',
        busId: 'b1',
        expectedAmount: 120500,
        handedOverAmount: 120500,
        source: 'admin',
      ),
    ]);
    money.loadedOnce.value = true;
    Get.put<MoneyController>(money);

    await expectNoOverflow(
      tester,
      subject: 'BusMoneyScreen handover ledger (handler + admin rows)',
      build: () => BusMoneyScreen(tour: _tour(), bus: _bus()),
      // 8 pumps instead of 16 — the screen is a heavy subject and nothing in
      // this row is tone-dependent.
      matrix: lightOnlyMatrix,
    );
  });
}
