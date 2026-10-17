// ONE TRIP, TWO FIGURES, EVERY SURFACE.
//
// The owner's report: "one card says we are in profit, I tap it and the next
// screen says loss, or a different profit number than the card." Two causes:
//
//  1. Two DEFINITIONS under one word. The dashboard hero, the money-board card
//     and the Trip P&L headlined the BILLED net; Settings and the Finance
//     report headlined the CASH net. Now every admin surface shows both, named
//     the same — "Trip profit" (billed) and "Cash so far" — from [TripPnl].
//  2. Two PIPELINES that disagreed on the same basis. [MoneyController] left
//     online (UPI) money out of its cash net while [FinanceController] added
//     it; and Finance costed an archived trip's non-pakku bus as pakku because
//     the roster was not in memory.
//
// This pins the fixture trip to identical (tripProfit, cashSoFar) on: the
// dashboard trip hero, the money-board P&L card and the Trip P&L total (all
// `MoneyController.tourSummary()`), the trip's Finance row, the Finance period
// totals and the Settings lifetime card — and renders the hero to prove both
// numbers actually reach the screen.
//
// Fixture (rupees):
//   b1  pakku-bhadu, rent 40,000. Diesel 3,200 + driver 5,000 sit INSIDE the
//       rent; food 1,500 on top → costs 41,500. Billed 60,000. Riders paid
//       2,000 cash, 2,000 by UPI online, 1,000 cash (partial). Cabin income 800.
//   b2  rent EXCLUDES fuel, rent 30,000. Diesel 4,000 + driver 2,000 + toll 700
//       all on top → costs 36,700. Billed 45,000. Riders paid 20,000 + 5,000.
//   +   a waitlisted rider's 1,500 UPI advance — no seat, no collection row,
//       only on the ledger's bank.gateway (finance_tour_summary).
//
//   billed 105,000 · cash 28,000 · online 3,500 · income 800 · costs 78,200
//   Trip profit = 105,000 + 800 − 78,200            =  27,600
//   Cash so far = 28,000 + 3,500 + 800 − 78,200     = −45,900
//   (076 view not deployed → online = Σ amount_online = 2,000 → −47,400)

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/finance_controller.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_finance.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_pnl.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/widgets/dashboard/trip_hero.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _t = 't1';

Bus _bus(String id, double rent, {required bool pakku}) => Bus(
      id: id,
      name: id,
      tourId: _t,
      busType: 'Seater',
      busPrice: rent,
      rentIncludesFuel: pakku,
      layout: BusLayout.generate(busType: BusType.seater, totalSeats: 10),
    );

/// Locked + departed, so the dashboard hero is in its inline-P&L mode.
Tour _tour({bool rosterLoaded = true}) => Tour(
      id: _t,
      title: 'Bhadarva Bij',
      fromCity: 'Surat',
      toCity: 'Bheda',
      departureDate: DateTime(2026, 9, 12),
      pricePerSeat: 2000,
      status: TourStatus.locked,
      buses: rosterLoaded
          ? [_bus('b1', 40000, pakku: true), _bus('b2', 30000, pakku: false)]
          : const [],
    );

Map<String, dynamic> _col(String id, String bus, String pax, double received,
        {double online = 0}) =>
    {
      'id': id,
      'tour_id': _t,
      'bus_id': bus,
      'passenger_id': pax,
      'seat_id': 'S$id',
      'amount_due': 2000,
      'amount_received': received,
      'amount_online': online,
      'amount_refunded': 0,
    };

Map<String, dynamic> _exp(String id, String bus, String cat, double amount) => {
      'id': id,
      'tour_id': _t,
      'bus_id': bus,
      'category': cat,
      'label': cat,
      'amount': amount,
    };

final _collections = [
  _col('c1', 'b1', 'p1', 2000),
  _col('c2', 'b1', 'p2', 2000, online: 2000), // paid by UPI
  _col('c3', 'b1', 'p3', 1000), // partial
  _col('c4', 'b2', 'p4', 20000),
  _col('c5', 'b2', 'p5', 5000),
];

final _expenses = [
  _exp('e1', 'b1', 'fuel', 3200),
  _exp('e2', 'b1', 'driver', 5000),
  _exp('e3', 'b1', 'food', 1500),
  _exp('e4', 'b2', 'fuel', 4000),
  _exp('e5', 'b2', 'driver', 2000),
  _exp('e6', 'b2', 'toll', 700),
];

final _incomes = [
  {
    'id': 'i1',
    'tour_id': _t,
    'bus_id': 'b1',
    'category': 'cabin',
    'label': 'Cabin',
    'amount': 800,
  },
];

/// finance_bus_summary, consistent with the rows above. `collected_minor` is
/// cash.handler ONLY — the 2,000 UPI slice is not in it.
Map<String, dynamic> _rollup(
  String bus, {
  required int billed,
  required int collected,
  required int ground,
  required int rent,
  int income = 0,
}) =>
    {
      'tour_id': _t,
      'bus_id': bus,
      'outstanding_handover_minor': (collected + income - ground) * 100,
      'billed_minor': billed * 100,
      'income_minor': income * 100,
      'ground_expenses_minor': ground * 100,
      'rent_minor': rent * 100,
      'owner_unpaid_minor': rent * 100,
      'collected_minor': collected * 100,
      'handed_over_minor': 0,
      'to_collect_minor': 0,
      'to_return_minor': 0,
    };

final _rollups = [
  _rollup('b1',
      billed: 60000, collected: 3000, ground: 9700, rent: 40000, income: 800),
  _rollup('b2', billed: 45000, collected: 25000, ground: 6700, rent: 30000),
];

/// finance_tour_summary: 2,000 from c2 + the waitlisted rider's 1,500.
final _tourRows = [
  {'tour_id': _t, 'online_minor': 350000},
];

typedef _Surfaces = ({
  TripPnl hero,
  TripPnl board,
  TripPnl tripPnl,
  TripPnl financeRow,
  TripPnl financeTotals,
  TripPnl settings,
});

Future<_Surfaces> _computeSurfaces({
  required bool viewDeployed,
  bool financeRosterLoaded = true,
}) async {
  Get.put<SyncService>(_StubSync({
    'collections': _collections,
    'expenses': _expenses,
    'incomes': _incomes,
  }));
  final tours = _InertTours();
  Get.put<TourController>(tours);

  Future<List<Map<String, dynamic>>> tourRows() async {
    if (!viewDeployed) throw StateError('relation does not exist');
    return _tourRows;
  }

  // ── Finance (every tour; maybe without the roster in memory) ──
  tours.tours.assignAll([_tour(rosterLoaded: financeRosterLoaded)]);
  final finance = FinanceController(
    ledgerSource: LedgerMoneySource()
      ..debugFetchAllBusRows = (() async => _rollups)
      ..debugFetchTourRows = tourRows
      ..debugFetchOnlineCollectionRows = (() async => [
            for (final c in _collections)
              if ((c['amount_online'] as num) > 0) c,
          ])
      ..debugFetchAbsorbableRows = (() async => [
            for (final e in _expenses)
              if (const {'fuel', 'driver', 'busOwner'}.contains(e['category']))
                e,
          ])
      ..debugFetchBusTermRows = (() async => [
            {'id': 'b1', 'bus_price': 40000, 'rent_includes_fuel': true},
            {'id': 'b2', 'bus_price': 30000, 'rent_includes_fuel': false},
          ]),
  );
  await finance.load();
  final row = finance
      .financesFor(FinancePeriod.allTime)
      .singleWhere((f) => f.tourId == _t);
  final totals = finance.totalsFor(FinancePeriod.allTime);

  // ── The trip's own surfaces (roster always loaded when the trip is open) ──
  tours.tours.assignAll([_tour()]);
  final money = MoneyController(
    ledgerSource: LedgerMoneySource()
      ..debugFetchBusRows = ((_) async => _rollups)
      ..debugFetchRiderRows = ((_) async => const [])
      ..debugFetchTourRows = tourRows,
  );
  Get.put<MoneyController>(money);
  await money.loadForTour(_t);
  final trip = money.tourSummary();

  return (
    // DashboardTripHero._pnlBreakdown, _PnlEntryCard and _TripTotalCard all
    // read `tourSummary()`; each pair below is exactly what that surface
    // prints (totalNetBilled = headline, totalNet = "Cash so far").
    hero: trip.pnl,
    board: trip.pnl,
    tripPnl: trip.pnl,
    financeRow: row.pnl,
    financeTotals: totals.pnl,
    settings: finance.lifetimePnl,
  );
}

void _expectAllEqual(_Surfaces s, {required double profit, required double cash}) {
  final all = <String, TripPnl>{
    'dashboard trip hero': s.hero,
    'money-board P&L card': s.board,
    'Trip P&L total': s.tripPnl,
    'Finance row': s.financeRow,
    'Finance totals': s.financeTotals,
    'Settings lifetime card': s.settings,
  };
  for (final e in all.entries) {
    expect(e.value.tripProfit, closeTo(profit, 0.001),
        reason: '${e.key}: Trip profit');
    expect(e.value.cashSoFar, closeTo(cash, 0.001),
        reason: '${e.key}: Cash so far');
  }
}

void main() {
  tearDown(Get.reset);

  test('TripPnl: one formula — billed vs received, income in both, '
      'handover-free', () {
    const p = TripPnl(
        billed: 105000, cash: 28000, online: 3500, income: 800, costs: 78200);
    expect(p.received, 31500);
    expect(p.tripProfit, 27600);
    expect(p.cashSoFar, -45900);
    expect(TripPnl.sum([p, p]).tripProfit, 55200);
  });

  test('ledger view deployed: every surface shows 27,600 / −45,900', () async {
    final s = await _computeSurfaces(viewDeployed: true);
    _expectAllEqual(s, profit: 27600, cash: -45900);
    // Online UPI counted exactly once: the 2,000 slice is NOT in cash.
    expect(s.tripPnl.cash, 28000);
    expect(s.tripPnl.online, 3500);
    expect(s.financeRow.online, 3500);
    // Pakku rule on b1, everything on top on b2.
    expect(s.tripPnl.costs, 78200);
    expect(s.financeRow.costs, 78200);
  });

  test('076 not deployed: both pipelines fall back to Σ amount_online '
      '(and still agree)', () async {
    final s = await _computeSurfaces(viewDeployed: false);
    _expectAllEqual(s, profit: 27600, cash: -47400);
  });

  test('archived trip (roster not in memory): Finance still costs the '
      'non-pakku bus like the board does', () async {
    final s = await _computeSurfaces(
      viewDeployed: true,
      financeRosterLoaded: false,
    );
    _expectAllEqual(s, profit: 27600, cash: -45900);
  });

  group('rendered', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
    });

    testWidgets('dashboard hero prints Trip profit AND Cash so far',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() => _computeSurfaces(viewDeployed: true));
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
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Trip profit'), findsOneWidget);
      expect(find.text('₹27,600'), findsOneWidget);
      expect(find.text('Cash so far -₹45,900'), findsOneWidget);
    });
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {}
}

class _StubSync extends SyncService {
  _StubSync(this.rows);

  final Map<String, List<Map<String, dynamic>>> rows;

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
          (
            rows: rows[table] ?? const <Map<String, dynamic>>[],
            failed: false,
            error: null,
          );

  @override
  Future<void> invalidateCache(String cacheKey) async {}
}
