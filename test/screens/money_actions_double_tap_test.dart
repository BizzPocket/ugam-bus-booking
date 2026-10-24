import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/payment_claim.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_money_board_screen.dart';
import 'package:occubusbooking/utils/in_flight.dart';
import 'package:occubusbooking/widgets/tour_detail/tour_money_tab.dart';

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// A rider's UPI advance is waiting on the board. The agent taps Confirm on a
/// slow link and, seeing nothing, taps again — which used to post the advance
/// to the ledger twice.
class _SlowMoneyController extends MoneyController {
  int confirmCalls = 0;
  int rejectCalls = 0;
  final gate = Completer<void>();

  /// When set, this controller reports [loadedTourId] as this tour.
  String? reportLoadedTourId;

  @override
  String? get loadedTourId => reportLoadedTourId ?? super.loadedTourId;

  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> confirmPaymentClaim(String claimId, {String? note}) async {
    confirmCalls++;
    await gate.future;
  }

  @override
  Future<void> rejectPaymentClaim(String claimId, {String? note}) async {
    rejectCalls++;
    await gate.future;
  }
}

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [
        Bus(
          id: 'b1',
          name: 'Bus 1',
          busType: 'Sleeper',
          layout:
              BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
        ),
      ],
    );

void main() {
  tearDown(() {
    InFlight.reset();
    Get.reset();
  });

  testWidgets('a double-tapped UPI Confirm posts the claim ONCE, and Reject '
      'cannot race it', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tours = _FakeTourController();
    final money = _SlowMoneyController();
    Get.put<TourController>(tours);
    Get.put<MoneyController>(money);
    tours.tours.assignAll([_tour()]);
    money.paymentClaims.assignAll([
      PaymentClaim(
        id: 'c1',
        tourId: 't1',
        amountRupees: 500,
        payerName: 'Asha',
        status: PaymentClaimStatus.pending,
        claimedAt: DateTime(2026, 6, 1),
      ),
    ]);

    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourMoneyBoardScreen(tourId: 't1'),
    ));
    await tester.pump();
    // Where the buttons sit BEFORE the first tap: once it lands, Confirm
    // swaps its label for a spinner, and a real finger taps the same spot.
    final confirmAt =
        tester.getCenter(find.text('tour_money_board.upi_confirm'));
    final rejectAt = tester.getCenter(find.text('tour_money_board.upi_reject'));

    await tester.tapAt(confirmAt);
    await tester.pump();
    await tester.tapAt(confirmAt);
    await tester.pump();
    await tester.tapAt(rejectAt);
    await tester.pump();

    expect(money.confirmCalls, 1);
    expect(money.rejectCalls, 0);

    money.gate.complete();
    await tester.pump();
  });

  testWidgets('Money tab: a FAILED first read is Retry, never ₹0 expected',
      (tester) async {
    final money = _SlowMoneyController()..reportLoadedTourId = 't1';
    Get.put<MoneyController>(money);
    money.loadFailed.value = true;

    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => CustomScrollView(
            slivers: [
              TourMoneyTab(tour: _tour(), c: UgamColors.of(context)),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('actions.retry'), findsOneWidget);
    expect(find.text('tour_detail.money_expected'), findsNothing);
    expect(find.textContaining('₹0'), findsNothing);
  });
}

// Keeps the `rendering` import meaningful for debugging layout under test.
// ignore: unused_element
void _debugPaint() => debugPaintSizeEnabled = false;
