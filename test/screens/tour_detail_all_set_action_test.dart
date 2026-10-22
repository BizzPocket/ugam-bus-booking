import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/tour_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The terminal "You're all set" next-action card is labelled "View timeline"
/// and its dispatcher said "jump to activity" — but it called onSwitchTab(3),
/// which is the MONEY tab (0 Overview, 1 Passengers, 2 Buses, 3 Money,
/// 4 Activity). Tapping it opened the wrong tab.
/// Test double for [TourController] that needs no live Supabase / GetX service
/// graph — same shape as the sibling tour-detail tests.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty — skip the real network load + realtime wiring.
  }

  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {
    // Intentionally empty — the fixture tour is already "hydrated".
  }
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Bus 1',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

SeatAssignment _seat(String id) =>
    SeatAssignment(busId: 'b1', seatId: id, leg: TripType.roundTrip);

/// A rider holding [seats], last notified about [notifiedSig].
Passenger _rider(
  String id, {
  List<SeatAssignment> seats = const [],
  String? notifiedSig,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: 'Rider $id',
      phone: '+919900000000',
      requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
      assignedSeats: seats,
      seatsNotifiedSig: notifiedSig,
      tripType: TripType.roundTrip,
    );

Tour _tour({
  required TourStatus status,
  required List<Passenger> passengers,
}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 9, 1),
      pricePerSeat: 1200,
      status: status,
      handlerId: 'h1',
      buses: [_bus()],
      passengers: passengers,
    );

Widget _harness() => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => GetMaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: const TourDetailScreen(tourId: 't1'),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  testWidgets('"View timeline" on a finished tour opens the Activity tab',
      (tester) async {
    tester.view.physicalSize = const Size(600, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rider = _rider('p1', seats: [_seat('DL3')]);
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      _tour(
        status: TourStatus.completed,
        passengers: [rider.copyWith(seatsNotifiedSig: rider.seatSignature)],
      ),
    ]);
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    final card = find.text(tr('tour_detail.action_done_subtitle_completed'));
    expect(card, findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.text(tr('tour_detail.activity_filter_all')), findsOneWidget,
        reason: 'the timeline (Activity, tab 4) must be what opens');
  });
}
