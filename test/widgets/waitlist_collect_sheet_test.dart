import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/waitlist_collect_sheet.dart';

/// "Mark paid & confirm" on the waitlist collect sheet.
///
/// *** THE BUG ***
/// `setConfirmed` rethrows after its own failure toast, and the sheet had no
/// try/finally — so one failed confirm left `_busy` stuck true and BOTH
/// buttons dead. Worse, the obvious retry would have posted the waitlist
/// payment to the ledger a second time.

class _FakeTourController extends TourController {
  int confirmCalls = 0;
  bool failNextConfirm = true;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> setConfirmed(
      String tourId, String passengerId, bool confirmed) async {
    confirmCalls++;
    if (failNextConfirm) {
      failNextConfirm = false;
      throw Exception('network down');
    }
  }
}

class _FakeMoneyController extends MoneyController {
  int recordCalls = 0;

  @override
  Future<String?> recordWaitlistPayment({
    required String tourId,
    required String passengerId,
    required int amountPaise,
    String? reference,
  }) async {
    recordCalls++;
    return null;
  }
}

Bus _bandedBus() => Bus(
      id: 'b1',
      name: 'Bus 1',
      pricePerSeat: 1200,
      singleSofaPrice: 1200,
      priceBands: const [
        PriceBand(label: 'Front', fromRow: 0, toRow: 1, price: 1600),
      ],
      layout: BusLayout(
        rows: 2,
        cols: 5,
        grid: [
          for (var r = 0; r < 2; r++)
            SeatCell(
                row: r, col: 4, seatType: SeatType.singleSofa, seatId: 'SL$r'),
        ],
      ),
    );

final _rider = Passenger(
  id: 'p1',
  tourId: 't1',
  name: 'Waiting Rider',
  phone: '+919900000000',
  requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
  tripType: TripType.outboundOnly,
  isWaitlisted: true,
);

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 9, 1),
      pricePerSeat: 1200,
      buses: [_bandedBus()],
      passengers: [_rider],
    );

void main() {
  tearDown(Get.reset);

  testWidgets(
      'a failed confirm frees the buttons, and the retry does not re-post '
      'the payment', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tours = Get.put<TourController>(_FakeTourController())
        as _FakeTourController;
    final money = Get.put<MoneyController>(_FakeMoneyController())
        as _FakeMoneyController;
    final tour = _tour();

    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showWaitlistCollectSheet(context, tour: tour, rider: _rider),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Pick the band — that is what sets the price.
    await tester.tap(find
        .byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('wlband-'))
        .first);
    await tester.pump();

    Future<void> pressMarkPaid() async {
      await tester.tap(find.text('waitlist_collect.mark_paid'));
      await tester.pumpAndSettle();
      // No partner on this tour → the "confirm unpaired?" dialog.
      final confirm = find.text('waitlist_collect.unpaired_confirm');
      if (confirm.evaluate().isNotEmpty) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
      }
    }

    await pressMarkPaid();

    expect(tours.confirmCalls, 1);
    expect(money.recordCalls, 1);
    // Still open, and the button is live again.
    final button = tester.widget<UgamButton>(find.ancestor(
      of: find.text('waitlist_collect.mark_paid'),
      matching: find.byType(UgamButton),
    ));
    expect(button.onPressed, isNotNull,
        reason: '_busy must reset after a failed confirm');

    await pressMarkPaid();

    expect(tours.confirmCalls, 2);
    expect(money.recordCalls, 1,
        reason: 'the payment already reached the ledger; a confirm retry must '
            'not post it twice');
    expect(find.text('waitlist_collect.mark_paid'), findsNothing,
        reason: 'a successful confirm closes the sheet');

    // Drain snackbar timers.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });
}
