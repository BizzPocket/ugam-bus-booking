import 'dart:async';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/requests_screen.dart';
import 'package:occubusbooking/utils/in_flight.dart';

/// The agent taps Accept on a request; on 2G nothing visibly happens for
/// seconds, so they tap again. Each tap used to run the whole confirm — and the
/// confirmation WhatsApp after it — a second time.
class _SlowTourController extends TourController {
  int confirmCalls = 0;
  final gate = Completer<void>();

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> setConfirmed(
    String tourId,
    String passengerId,
    bool confirmed,
  ) async {
    confirmCalls++;
    // Held open: the write is still on the wire when the second tap lands.
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
          name: 'b1',
          busType: 'Sleeper',
          layout:
              BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
        ),
      ],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'Anjali QA',
          phone: '+919000000005',
          requestLines: [RequestLine(seatType: SeatType.seater, qty: 1)],
        ),
      ],
    );

void main() {
  setUpAll(() {
    Localization.load(const Locale('en'), ignorePluralRules: true);
  });

  tearDown(() {
    InFlight.reset();
    Get.reset();
  });

  testWidgets('a double-tapped Accept confirms ONCE', (tester) async {
    final ctrl = _SlowTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tour()]);
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const GetMaterialApp(home: RequestsScreen()));
    await tester.pump();

    await tester.tap(find.text('requests.action.accept'));
    await tester.pump();
    await tester.tap(find.text('requests.action.accept'));
    await tester.pump();
    await tester.tap(find.text('requests.action.accept'));
    await tester.pump();

    expect(ctrl.confirmCalls, 1,
        reason: 'a second confirm means a second WhatsApp to the rider');
  });
}
