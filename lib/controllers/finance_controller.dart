import 'dart:developer' as dev;

import 'package:get/get.dart';

import '../models/ledger_bus_rollup.dart';
import '../models/money_summary.dart';
import '../models/tour_finance.dart';
import '../models/tour_status.dart';
import '../models/trip_pnl.dart';
import '../services/ledger_money_source.dart';
import '../services/sync_service.dart';
import 'tour_controller.dart';

/// Cross-tour Profit & Loss data source.
///
/// Where [MoneyController] holds the money rows for a SINGLE tour, this loads
/// ledger bus rollups for EVERY tour the agent owns, so the finance report can
/// show profit/loss across the whole history of trips. Tour metadata comes from
/// [TourController]; money totals come from `finance_bus_summary`.
class FinanceController extends GetxController {
  FinanceController({LedgerMoneySource? ledgerSource})
      : _ledgerSource = ledgerSource ?? LedgerMoneySource();

  final LedgerMoneySource _ledgerSource;

  final isLoading = false.obs;
  final loadFailed = false.obs;
  final loadedOnce = false.obs;

  /// How many bus rollups the last successful load returned. Reactive so
  /// [ledgerEmpty] recomputes inside an `Obx` without a manual refresh.
  final _rollupCount = 0.obs;

  /// True when a load SUCCEEDED and returned nothing at all, while the agent
  /// has at least one bus on at least one tour.
  ///
  /// That combination is provably a broken ledger rather than an empty
  /// business: a bus always carries an owner rent (`buses.bus_price`), which
  /// posts as an `expense.rent` line the moment 062's trigger or 058's backfill
  /// runs. So buses with no ledger rows anywhere means the write-through
  /// migrations were never applied — and this report, which reads ONLY
  /// `finance_bus_summary`, would otherwise render a confident "from 1 tour"
  /// badge over ₹0 with [loadFailed] false, because nothing threw.
  ///
  /// Deliberately NOT [loadFailed]: a read failure has its own retry surface,
  /// and this state survives a retry — retrying an empty view returns empty.
  /// The screen shows an explanatory banner instead.
  bool get ledgerEmpty =>
      loadedOnce.value &&
      !loadFailed.value &&
      _rollupCount.value == 0 &&
      _tours.tours.any((t) => t.buses.isNotEmpty);

  /// Each tour's [TripPnl], keyed by tour id — built from the same ledger lines
  /// and the same per-bus rules [MoneyController.tourSummary] uses.
  final Map<String, TripPnl> _pnlByTour = {};

  /// Bus count per tour for tours whose roster is NOT in memory (cold start
  /// skips completed tours' relations — see `coldStartHydrationScope`). Seeded
  /// from the ledger rollups' distinct bus ids, then corrected by a light
  /// `id, tour_id` read. Reactive so the rows repaint when the read lands.
  final _busCountByTour = <String, int>{}.obs;

  Future<void>? _loadInFlight;
  int _loadGeneration = 0;

  TourController get _tours => Get.find<TourController>();

  Future<void> ensureLoaded() async {
    if (loadedOnce.value) return;
    if (_loadInFlight != null) return _loadInFlight!;
    await load();
  }

  Future<void> reload() => load();

  void markStale() {
    if (!loadedOnce.value && !isLoading.value) return;
    _stale = true;
  }

  bool _stale = false;

  Future<void> refreshIfStale() async {
    if (!loadedOnce.value) return ensureLoaded();
    if (!_stale || isLoading.value) {
      if (_stale && _loadInFlight != null) return _loadInFlight!;
      return;
    }
    await load();
  }

  Future<void> load() async {
    if (_loadInFlight != null) return _loadInFlight!;
    final future = _loadBody();
    _loadInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_loadInFlight, future)) {
        _loadInFlight = null;
      }
    }
  }

  Future<void> _loadBody() async {
    final gen = ++_loadGeneration;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final pnl = <String, TripPnl>{};

      final rollups = await _ledgerSource.fetchAllBusRollups();
      if (gen != _loadGeneration) return;
      // Diesel / driver / owner advances per bus — what a pakku-bhadu rent
      // absorbs. Without them Finance summed `ground + rent` (every rupee on
      // top of the rent) and printed a smaller profit than the trip P&L and
      // the money board for the very same trip.
      final absorbable = await _ledgerSource.fetchRentAbsorbableByBus();
      if (gen != _loadGeneration) return;
      // Rent + pakku flag for buses whose roster is NOT in memory (archived
      // trips) — so they are costed exactly as their board will cost them.
      final terms = await _ledgerSource.fetchBusRentTerms();
      if (gen != _loadGeneration) return;
      final busesById = <String, ({double busPrice, bool rentIncludesFuel})>{
        ...terms,
        for (final t in _tours.tours)
          for (final b in t.buses)
            b.id: (busPrice: b.busPrice, rentIncludesFuel: b.rentIncludesFuel),
      };
      for (final r in rollups) {
        final tid = r.tourId;
        if (tid.isEmpty) continue;
        // Billed = the ledger's `revenue.fare` — the SAME figure the trip's own
        // board reads ([MoneyController.summaryForBus] → `rollup.billed`).
        // Finance used to have no billed figure at all, so its headline was
        // the cash net while every per-trip surface headlined the billed one.
        pnl[tid] = (pnl[tid] ?? TripPnl.zero) +
            TripPnl(
              billed: r.billed,
              cash: r.collected,
              income: r.income,
              costs: _busExpenses(r, busesById, absorbable),
            );
      }

      // Online (bank.gateway) money belongs to no bus, so it never appears in
      // a per-bus rollup — finance_bus_summary filters `bus_id is not null`.
      // Without this, a trip whose riders all paid by UPI shows zero revenue
      // against real rent and prints a loss. No double count: 069 puts a rupee
      // on cash.handler OR bank.gateway, never both, and `collected` above is
      // cash.handler only.
      final onlineByTour = await _ledgerSource.fetchOnlineByTourRupees();
      if (gen != _loadGeneration) return;
      onlineByTour.forEach((tid, online) {
        if (online == 0) return;
        pnl[tid] = (pnl[tid] ?? TripPnl.zero).copyWith(
          online: (pnl[tid]?.online ?? 0) + online,
        );
      });

      _pnlByTour
        ..clear()
        ..addAll(pnl);
      // Every bus that carries rent or money has a rollup row, so its distinct
      // bus ids are a correct floor for an archived tour's bus count before the
      // exact count below lands.
      final rollupBuses = <String, Set<String>>{};
      for (final r in rollups) {
        final bid = r.busId;
        if (r.tourId.isEmpty || bid == null || bid.isEmpty) continue;
        (rollupBuses[r.tourId] ??= <String>{}).add(bid);
      }
      _busCountByTour.assignAll({
        for (final e in rollupBuses.entries) e.key: e.value.length,
      });

      _rollupCount.value = rollups.length;
      loadedOnce.value = true;
      _stale = false;
      // Background: never gates the report's first paint.
      // ignore: unawaited_futures
      _loadArchivedBusCounts(gen);
    } catch (e, st) {
      if (gen != _loadGeneration) return;
      dev.log('finance load failed: $e\n$st', name: 'FinanceController');
      loadFailed.value = true;
    } finally {
      if (gen == _loadGeneration) isLoading.value = false;
    }
  }

  /// One bus's cost under the SAME rule [MoneyController.summaryForBus] uses
  /// ([BusExpenseRollup.fromLedger]): on a pakku-bhadu bus diesel, driver and
  /// owner advances sit INSIDE the rent; everything else is on top. Rent and
  /// the pakku flag come from the in-memory bus when the roster is loaded
  /// (exactly as the board reads them), else the bus row's own terms
  /// ([LedgerMoneySource.fetchBusRentTerms]), else — a bus the trip no longer
  /// lists, as on the board — the ledger's rent and the column default (true).
  static double _busExpenses(
    LedgerBusRollup r,
    Map<String, ({double busPrice, bool rentIncludesFuel})> busesById,
    Map<String, ({double fuel, double driver, double ownerAdvance})> absorbable,
  ) {
    final bid = r.busId;
    if (bid == null || bid.isEmpty) return r.expensesTotal;
    final bus = busesById[bid];
    final price = bus?.busPrice ?? 0;
    final a = absorbable[bid];
    return BusExpenseRollup.fromLedger(
      ground: r.groundExpenses,
      busRent: price > 0 ? price : r.rent,
      fuel: a?.fuel ?? 0,
      driver: a?.driver ?? 0,
      ownerAdvance: a?.ownerAdvance ?? 0,
      rentIncludesFuel: bus?.rentIncludesFuel ?? true,
    ).expensesTotal;
  }

  /// Exact bus counts for tours whose roster is not loaded (archived tours),
  /// WITHOUT hydrating their whole roster — the cold-start skip is a deliberate
  /// low-end-device choice, and counting buses must not undo it. Best-effort: a
  /// failure keeps the rollup-derived floor.
  Future<void> _loadArchivedBusCounts(int gen) async {
    if (!Get.isRegistered<SyncService>()) return;
    final ids = [
      for (final t in _tours.tours)
        if (t.buses.isEmpty) t.id,
    ];
    if (ids.isEmpty) return;
    try {
      final counts =
          await Get.find<SyncService>().fetchBusCountsByTour(ids);
      if (gen != _loadGeneration) return;
      for (final id in ids) {
        _busCountByTour[id] = counts[id] ?? 0;
      }
    } catch (e, st) {
      dev.log('archived bus count failed: $e\n$st', name: 'FinanceController');
    }
  }

  /// Per-tour P&L for [period], newest trip first.
  ///
  /// Counts EVERY tour by default — a running trip's figures are real money
  /// that has already moved, and gating the report on the manual "Mark
  /// completed" tap meant an agent mid-season saw a ₹0 card and an empty report
  /// no matter how much they had collected. [TourFinance.isCompleted] carries
  /// the distinction so the UI can still separate realised from running P&L.
  /// Pass [completedOnly] to get the realised-only view.
  List<TourFinance> financesFor(
    FinancePeriod period, {
    bool completedOnly = false,
  }) {
    final now = DateTime.now();
    final out = <TourFinance>[];
    for (final tour in _tours.tours) {
      if (completedOnly && tour.status != TourStatus.completed) continue;
      final tf = TourFinance.from(
        tour,
        _pnlByTour[tour.id] ?? TripPnl.zero,
        busCount: _busCountByTour[tour.id],
      );
      if (!_inPeriod(tf.date, period, now)) continue;
      out.add(tf);
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  FinanceTotals totalsFor(FinancePeriod period, {bool completedOnly = false}) =>
      FinanceTotals.from(financesFor(period, completedOnly: completedOnly));

  /// Every trip ever, both figures — the Settings lifetime card.
  TripPnl get lifetimePnl => totalsFor(FinancePeriod.allTime).pnl;

  /// Completed trips only, both figures.
  TripPnl get lifetimeRealisedPnl =>
      totalsFor(FinancePeriod.allTime, completedOnly: true).pnl;

  bool _inPeriod(DateTime date, FinancePeriod period, DateTime now) =>
      switch (period) {
        FinancePeriod.thisMonth =>
          date.year == now.year && date.month == now.month,
        FinancePeriod.thisYear => date.year == now.year,
        FinancePeriod.allTime => true,
      };
}
