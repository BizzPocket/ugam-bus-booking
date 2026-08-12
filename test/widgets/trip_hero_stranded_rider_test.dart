import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
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
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/widgets/dashboard/trip_hero.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dashboard hero's single action line, for the rider whose seat was taken
/// back AFTER they were told about it.
///
/// The line used to be derived from `assignedSeats.isNotEmpty &&
/// seatsChangedSinceNotified`, which is false for a rider holding nothing — so
/// the one person carrying a WhatsApp message that names a seat they no longer
/// have never appeared here.
///
/// Fixing the predicate alone was not enough: withdrawing the seat also puts
/// those berths back into `pendingSeatsToAssign`, and the higher-ranked
/// "N seats unassigned" branch answered first. The withdrawal is now ranked
/// above the seat count it creates.
///
/// EasyLocalization is booted for real (the hero reads `context.locale`), so
/// the assertions resolve through `tr()` and also prove the new keys exist in
/// `assets/translations`.

Bus _bus() => Bus(
      id: 'b1',
      name: 'shivkamal-1',
      busType: 'Sleeper',
      busPrice: 50000,
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

const _dl3 = SeatAssignment(busId: 'b1', seatId: 'DL3');

Passenger _rider({
  List<SeatAssignment> seats = const [],
  String? notifiedSig,
}) =>
    Passenger(
      id: 'p1',
      tourId: 't1',
      name: 'Rider',
      phone: '+919900000000',
      requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
      assignedSeats: seats,
      seatsNotifiedSig: notifiedSig,
      tripType: TripType.roundTrip,
    );

/// The signature the rider was notified with while seated on DL3.
String get _dl3Sig => _rider(seats: const [_dl3]).seatSignature;

/// Departure kept in the FUTURE so the hero stays on its action line rather
/// than flipping to the post-trip inline P&L.
Tour _tour(Passenger p) => Tour(
      id: 't1',
      title: 'Shravan Sud Bij',
      fromCity: 'Surat',
      toCity: 'Bheda',
      departureDate: DateTime.now().add(const Duration(days: 30)),
      pricePerSeat: 1500,
      status: TourStatus.locked,
      handlerId: 'h1',
      buses: [_bus()],
      passengers: [p],
    );

Future<void> _pump(WidgetTester tester, Tour tour) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  Get.put<SyncService>(_EmptySync());
  final tours = _InertTours();
  Get.put<TourController>(tours);
  tours.tours.assignAll([tour]);

  final ledger = LedgerMoneySource();
  ledger.debugFetchBusRows = (_) async => const [];
  ledger.debugFetchRiderRows = (_) async => const [];
  Get.put<MoneyController>(MoneyController(ledgerSource: ledger));

  // EasyLocalization reads its JSON off the asset bundle with REAL async I/O,
  // which only makes progress inside runAsync.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (outer) => MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            localizationsDelegates: outer.localizationDelegates,
            supportedLocales: outer.supportedLocales,
            locale: outer.locale,
            home: Builder(
              builder: (context) => Scaffold(
                body: SingleChildScrollView(
                  child: DashboardTripHero(c: UgamColors.of(context)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
  // Flush the hero's deferred money load so no timer outlives the test.
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  testWidgets('the hero names the rider whose seat was taken back after telling',
      (tester) async {
    // Told about DL3, then unseated entirely.
    await _pump(tester, _tour(_rider(seats: const [], notifiedSig: _dl3Sig)));

    expect(
      find.text(tr('dashboard.attention_seat_removed', namedArgs: {'n': '1'})),
      findsOneWidget,
      reason: 'the stranded rider is the hero\'s most urgent fact — not the '
          '"1 seat unassigned" their own withdrawal produced',
    );
    expect(
      find.text(tr('dashboard.attention_unassigned', namedArgs: {'n': '1'})),
      findsNothing,
      reason: 're-seating them silently would leave the wrong seat number in '
          'their hand, so the seat count must not outrank the call',
    );
  });

  testWidgets('an ordinary post-lock seat MOVE keeps the re-notify line',
      (tester) async {
    await _pump(
      tester,
      _tour(_rider(
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DL4')],
        notifiedSig: _dl3Sig,
      )),
    );

    expect(
      find.text(tr('dashboard.attention_renotify', namedArgs: {'n': '1'})),
      findsOneWidget,
      reason: 'a move has an approved WhatsApp template and keeps its copy',
    );
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  // The hero warms layouts on build; the fixture already carries them.
  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {}
}

class _EmptySync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
      smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async =>
          (rows: const <Map<String, dynamic>>[], failed: false, error: null);
}
