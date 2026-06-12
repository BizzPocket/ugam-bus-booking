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
import 'package:occubusbooking/screens/seats_screen.dart';

/// Test double: skip the real network load + realtime wiring so registering
/// the controller doesn't need Supabase/GetX services.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, String name, {required int seats}) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

Passenger _passenger(String id, String tourId) => Passenger(
      id: id,
      tourId: tourId,
      name: id,
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: SeatType.doubleSofa, qty: 1)],
    );

Tour _fakeTour() {
  const tourId = 't1';
  return Tour(
    id: tourId,
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [_bus('b1', 'Bus 1', seats: 30), _bus('b2', 'Bus 2', seats: 30)],
    passengers: [
      _passenger('p1', tourId),
      _passenger('p2', tourId),
      _passenger('p3', tourId),
    ],
  );
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const SeatsScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('renders the 3-mode segmented control + tour title in the header',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Dwarka Yatra'), findsOneWidget);
    // tr() falls back to the key without EasyLocalization init in tests.
    expect(find.text('seats.mode_autofill'), findsOneWidget);
    expect(find.text('seats.mode_assign'), findsOneWidget);
    expect(find.text('seats.mode_rearrange'), findsOneWidget);
  });

  testWidgets('defaults to Auto-fill mode (the Fill-bus cockpit is visible)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Auto-fill body on screen → its "Fill bus" CTA is visible.
    expect(find.text('Fill bus'), findsOneWidget);
  });

  testWidgets('switching modes swaps the visible body (Assign hides the cockpit)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Start on Auto-fill.
    expect(find.text('Fill bus'), findsOneWidget);

    // Switch to Assign → the cockpit's Fill-bus CTA is now offstage.
    await tester.tap(find.text('seats.mode_assign'));
    await tester.pump();
    expect(find.text('Fill bus'), findsNothing);

    // Switch back to Auto-fill → the cockpit returns.
    await tester.tap(find.text('seats.mode_autofill'));
    await tester.pump();
    expect(find.text('Fill bus'), findsOneWidget);
  });
}
