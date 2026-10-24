part of '../money_controller.dart';

/// Shared state every [MoneyController] concern builds on.
///
/// [MoneyController] is ONE class assembled from a linear chain of private
/// mixins (one file per concern under `money_controller/`), each declared
/// `on` the one before it, so a concern may call anything defined earlier.
abstract class _MoneyControllerBase extends GetxController {
  _MoneyControllerBase() {
    // Every mutation of a money list invalidates the memoized summaries. GetX
    // notifies listeners synchronously (GetStream), so the very next summary
    // read after `collections.add(...)` already sees the bumped revision.
    // Subscribed here, not in onInit, so a controller that is constructed but
    // never `Get.put` (tests, benches) is just as safe.
    collections.listen((_) => _invalidateSummaries());
    expenses.listen((_) => _invalidateSummaries());
    handovers.listen((_) => _invalidateSummaries());
    incomes.listen((_) => _invalidateSummaries());
  }

  /// Ledger read seam, injected through [MoneyController]'s constructor.
  LedgerMoneySource get _ledgerSource;

  final collections = <Collection>[].obs;
  final expenses = <Expense>[].obs;
  final handovers = <BusHandover>[].obs;
  final incomes = <IncomeEntry>[].obs;

  // ── Summary memo ──────────────────────────────────────────
  //
  // [summaryForBus] / [tourSummary] are pure functions of: the four money
  // lists, the ledger rollups (+ online figure), which tour is loaded, and the
  // loaded [Tour] object (buses, fares, passengers, seats). The money board and
  // Trip P&L read them 2–3× per frame, so they are memoized.
  //
  // Invalidation — stale money is worse than slow money, so the key is
  // deliberately redundant:
  //  * [_summaryRevision] is bumped by a listener on every money-list change
  //    and by every ledger write ([_invalidateSummaries]);
  //  * the loaded [Tour] is compared by IDENTITY — [Tour] and everything it
  //    holds is immutable and TourController replaces the object on every
  //    tour/bus/passenger/seat change, so a new object means new inputs;
  //  * the loaded tour id, ledger-ready flag, ledger online figure and the four
  //    list lengths are compared too, as a belt-and-braces guard.
  int _summaryRevision = 0;
  int _memoRevision = -1;
  Tour? _memoTour;
  String? _memoTourId;
  bool _memoLedgerReady = false;
  double? _memoLedgerOnline;
  (int, int, int, int)? _memoLengths;
  final Map<String, BusMoneySummary> _busSummaryMemo = {};
  TourMoneySummary? _tourSummaryMemo;

  /// Drops every memoized summary. Called on any money-list change and on any
  /// write to the ledger rollups.
  void _invalidateSummaries() {
    _summaryRevision++;
    _busSummaryMemo.clear();
    _tourSummaryMemo = null;
  }

  /// Makes the memo describe the CURRENT inputs, clearing it when any part of
  /// the key moved. Call before reading or writing the memo.
  void _syncSummaryMemo() {
    final tour = _loadedTour();
    final lengths = (
      collections.length,
      expenses.length,
      handovers.length,
      incomes.length,
    );
    if (_memoRevision == _summaryRevision &&
        identical(_memoTour, tour) &&
        _memoTourId == _loadedTourId &&
        _memoLedgerReady == _ledgerReady &&
        _memoLedgerOnline == _ledgerOnline &&
        _memoLengths == lengths) {
      return;
    }
    _busSummaryMemo.clear();
    _tourSummaryMemo = null;
    _memoRevision = _summaryRevision;
    _memoTour = tour;
    _memoTourId = _loadedTourId;
    _memoLedgerReady = _ledgerReady;
    _memoLedgerOnline = _ledgerOnline;
    _memoLengths = lengths;
  }
  final paymentClaims = <PaymentClaim>[].obs;

  /// Pending chart soft-holds (advance checkout). Cleared on each tour load.
  final pendingSeatHolds = <Map<String, dynamic>>[].obs;
  final isLoading = false.obs;

  /// True when the last [loadForTour] could not reach the server (offline or a
  /// timed-out/failed read). Mirrors [TourController.hasError] /
  /// [FinanceController.loadFailed]: the screens read this to show a retry state
  /// instead of silently rendering an all-zero money board (a failed load is NOT
  /// the same as "this tour has no money"). Reset to false at the start of every
  /// load and only re-raised when one of the reads reports `failed`.
  final loadFailed = false.obs;

  /// True once at least one load has genuinely succeeded for the current tour, so
  /// consumers can distinguish "never loaded" from "loaded and empty".
  final loadedOnce = false.obs;

  /// When true, [summaryForBus] / [tourSummary] prefer ledger rollups over
  /// recomputing from legacy row lists.
  ///
  /// Rollups only. `finance_rider_balance` used to be fetched alongside these to
  /// derive per-bus to-collect / to-return; that figure is now priced from live
  /// seat fares ([_seatArForBus]), so the read was pure cost — a fifth
  /// round-trip per tour load, on a radio this app has to survive at 2G.
  bool _ledgerReady = false;
  final Map<String, LedgerBusRollup> _ledgerByBus = {};

  /// The loaded tour's online (UPI) take from the ledger's
  /// `finance_tour_summary`, or null when that view cannot be read — the
  /// summaries then sum the held rows' [Collection.amountOnline]. The SAME
  /// two-step rule [FinanceController] applies
  /// ([LedgerMoneySource.fetchOnlineByTourRupees]).
  double? _ledgerOnline;

  /// Which tour the lists currently hold data for. Used to scope cache
  /// keys and to know what to refetch on refresh.
  String? _loadedTourId;

  /// Bumps on every [loadForTour] so a slow response for tour A cannot
  /// overwrite a newer load for tour B (dashboard hero switch / money tab).
  int _loadGeneration = 0;

  /// Coalesces concurrent [loadForTour] calls for the SAME tour id.
  Future<void>? _loadInFlight;
  String? _loadInFlightTourId;

  /// Coalesces dashboard settlement snapshot passes.
  Future<void>? _settlementInFlight;

  /// The tour id whose money rows (`collections`/`expenses`/`handovers`/
  /// `incomes`) are currently held. Summaries (`tourSummary`, …) only
  /// describe THIS tour, so callers that read settlement state for a
  /// specific tour must check this matches first.
  String? get loadedTourId => _loadedTourId;

  SyncService get _sync => Get.find<SyncService>();

  /// Tells the cross-tour P&L its cached totals are out of date.
  ///
  /// [FinanceController] aggregates ledger bus rollups independently. Without
  /// this hook its `ensureLoaded()` permanently no-ops after the first success,
  /// so the Settings card and Finance report kept showing pre-write figures
  /// while the per-tour money board moved. Only marks stale (no refetch): the
  /// next visit to a finance surface pays for the reload.
  /// Guarded on registration so money still saves in tests/flows where the
  /// finance controller was never put.
  void _invalidateFinance() {
    if (!Get.isRegistered<FinanceController>()) return;
    Get.find<FinanceController>().markStale();
  }

  String _collectionsKey(String tourId) => 'collections_$tourId';
  String _expensesKey(String tourId) => 'expenses_$tourId';
  String _handoversKey(String tourId) => 'handovers_$tourId';
  String _incomesKey(String tourId) => 'incomes_$tourId';

  /// The four per-tour money reads, issued concurrently, in the fixed order
  /// `[collections, expenses, bus_handovers, incomes]` every caller indexes.
  /// smartFetch never throws; each result carries its own `failed` flag.
  Future<List<({List<Map<String, dynamic>> rows, bool failed, String? error})>>
      _fetchMoneyTables(String tourId) => Future.wait([
            _sync.smartFetch(
              table: 'collections',
              cacheKey: _collectionsKey(tourId),
              select: SyncReadProjections.collectionsSelect,
              filters: {'tour_id': tourId},
              orderBy: 'created_at',
            ),
            _sync.smartFetch(
              table: 'expenses',
              cacheKey: _expensesKey(tourId),
              select: SyncReadProjections.expensesSelect,
              filters: {'tour_id': tourId},
              orderBy: 'created_at',
            ),
            _sync.smartFetch(
              table: 'bus_handovers',
              cacheKey: _handoversKey(tourId),
              select: SyncReadProjections.handoversSelect,
              filters: {'tour_id': tourId},
              orderBy: 'created_at',
            ),
            _sync.smartFetch(
              table: 'incomes',
              cacheKey: _incomesKey(tourId),
              select: SyncReadProjections.incomesSelect,
              filters: {'tour_id': tourId},
              orderBy: 'created_at',
            ),
          ]);

  /// The loaded tour as [TourController] holds it, or null when no tour is
  /// loaded, the tour controller is not registered, or it does not know the
  /// tour. Every aggregation guard reads through this.
  Tour? _loadedTour() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) return null;
    return Get.find<TourController>().getTour(tourId);
  }
}
