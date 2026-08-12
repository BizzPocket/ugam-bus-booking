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
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/widgets/dashboard/trip_hero.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unlike the other money-screen tests, this one boots EasyLocalization for
/// real: the hero reads `context.locale`, which throws without the widget in
/// the tree. Assertions therefore read the English copy rather than raw keys —
/// which also proves the new keys actually exist in `assets/translations`.

const _billedMinor = 5500000; // ₹55,000 per bus

Bus _bus(String id, String name, double rent) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      busPrice: rent,
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

/// The hero only flips to its inline P&L once the tour is LOCKED and its
/// departure date has passed, so the fixture has to satisfy both.
Tour _tour({double bus2Rent = 0}) => Tour(
      id: 't1',
      title: 'Shravan Sud Bij',
      fromCity: 'Surat',
      toCity: 'Bheda',
      departureDate: DateTime(2026, 8, 1),
      pricePerSeat: 1500,
      status: TourStatus.locked,
      buses: [
        _bus('b1', 'shivkamal-1', 50000),
        _bus('b2', 'shivkamal-2', bus2Rent),
      ],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'A',
          phone: '999',
          assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'L1')],
        ),
      ],
    );

Map<String, dynamic> _rollup(String busId, int rentMinor) => {
      'tour_id': 't1',
      'bus_id': busId,
      'outstanding_handover_minor': 0,
      'billed_minor': _billedMinor,
      'income_minor': 0,
      'ground_expenses_minor': 0,
      'rent_minor': rentMinor,
      'owner_unpaid_minor': rentMinor,
      'collected_minor': 0,
      'handed_over_minor': 0,
      'to_collect_minor': _billedMinor,
      'to_return_minor': 0,
    };

Future<void> _pump(WidgetTester tester, {required Tour tour}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  Get.put<SyncService>(_EmptySync());
  final tours = _InertTours();
  Get.put<TourController>(tours);
  tours.tours.assignAll([tour]);

  final ledger = LedgerMoneySource();
  ledger.debugFetchBusRows = (_) async => [
        _rollup('b1', 5000000),
        _rollup('b2', (tour.buses[1].busPrice * 100).round()),
      ];
  ledger.debugFetchRiderRows = (_) async => [];
  final money = MoneyController(ledgerSource: ledger);
  Get.put<MoneyController>(money);
  // Seed the summary up front; the hero's own load is deferred 1.6s behind a
  // post-frame callback, which a widget test should not have to wait on.
  await money.loadForTour('t1');

  // EasyLocalization reads its JSON off the asset bundle with REAL async I/O,
  // which only makes progress inside runAsync — without this the app subtree
  // never builds and the whole tree comes back empty.
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

  testWidgets('inline P&L names a projected net rather than a profit',
      (tester) async {
    await _pump(tester, tour: _tour(bus2Rent: 48000));

    expect(find.text('Projected net'), findsOneWidget);
    expect(find.text('Net profit'), findsNothing);
  });

  testWidgets('inline P&L warns when a bus has no rent recorded',
      (tester) async {
    await _pump(tester, tour: _tour()); // bus 2 rent left at 0

    expect(
      find.text('1 bus has no rent recorded, so this is overstated'),
      findsOneWidget,
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
