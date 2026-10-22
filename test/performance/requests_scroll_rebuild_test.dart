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

/// PERF pin: flicking the Requests list (which retracts / extends the bottom
/// bar on every direction flip) must not rebuild the request cards.

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
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
        for (var i = 0; i < 60; i++)
          Passenger(
            id: 'p$i',
            tourId: 't1',
            name: 'Rider $i',
            phone: '+9190000000${i.toString().padLeft(2, '0')}',
            requestLines: [RequestLine(seatType: SeatType.seater, qty: 1)],
            createdAt: DateTime(2026, 6, 1).add(Duration(minutes: i)),
          ),
      ],
    );

final _cardFinder =
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_RequestCard');

void main() {
  setUpAll(() {
    Localization.load(const Locale('en'), ignorePluralRules: true);
  });
  tearDown(Get.reset);

  testWidgets('scroll-direction flips rebuild zero request cards',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tour()]);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const GetMaterialApp(home: RequestsScreen()));
    await tester.pump();

    // Scroll down (retracts the bar), then flip direction (extends it): the
    // flip is the moment that used to setState the whole screen.
    await tester.drag(find.byType(ListView).last, const Offset(0, -300));
    await tester.pumpAndSettle();
    final before = tester.widgetList(_cardFinder).toList();
    expect(before, isNotEmpty);

    await tester.drag(find.byType(ListView).last, const Offset(0, 150));
    await tester.pump();
    final after = tester.widgetList(_cardFinder).toList();
    // The flip really happened: the bar is extended again.
    expect(
      tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
      Offset.zero,
    );
    var rebuilt = 0;
    for (final w in after) {
      if (!before.any((b) => identical(b, w))) rebuilt++;
    }
    // ignore: avoid_print
    print('PERF requests scroll flip: $rebuilt/${after.length} cards rebuilt');
    expect(rebuilt, 0);
    await tester.pumpAndSettle();
  });
}
