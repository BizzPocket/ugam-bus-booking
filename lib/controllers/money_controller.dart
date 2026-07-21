import 'dart:async';
import 'dart:developer' as dev;

import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';

import '../models/collection.dart';
import '../models/expense.dart';
import '../models/income_entry.dart';
import '../models/bus_handover.dart';
import '../models/money_summary.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';
import 'tour_controller.dart';

/// Loads & persists the money tables (`collections`, `expenses`,
/// `bus_handovers`, `incomes`) for a single tour via [SyncService], and
/// exposes aggregation summaries built from the locally held rows.
///
/// CRUD follows the same shape as [TourController]: mutate local state
/// optimistically so the UI feels instant, await the server write, and on
/// failure pull fresh state from the server + surface the error.
///
/// RLS note: these three tables are NOT owner-scoped (no `owner_id`
/// column). Their policies validate via the tour-owner join, so we just
/// send the row's `toMap()` (which already carries `tour_id`/`bus_id`).
class MoneyController extends GetxController {
  final collections = <Collection>[].obs;
  final expenses = <Expense>[].obs;
  final handovers = <BusHandover>[].obs;
  final incomes = <IncomeEntry>[].obs;
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

  /// Which tour the lists currently hold data for. Used to scope cache
  /// keys and to know what to refetch on refresh.
  String? _loadedTourId;

  /// The tour id whose money rows (`collections`/`expenses`/`handovers`/
  /// `incomes`) are currently held. Summaries (`tourSummary`, …) only
  /// describe THIS tour, so callers that read settlement state for a
  /// specific tour must check this matches first.
  String? get loadedTourId => _loadedTourId;

  SyncService get _sync => Get.find<SyncService>();

  String _collectionsKey(String tourId) => 'collections_$tourId';
  String _expensesKey(String tourId) => 'expenses_$tourId';
  String _handoversKey(String tourId) => 'handovers_$tourId';
  String _incomesKey(String tourId) => 'incomes_$tourId';

  // ── Load / refresh ────────────────────────────────────────

  Future<void> loadForTour(String tourId) async {
    // A genuine tour SWITCH must never render the previous tour's rows. Clear
    // the four cached lists up-front, BEFORE the fetch, so tour B can never show
    // tour A's collections + rent even if B's read fails (loadFailed then drives
    // the retry surface). A SAME-tour reload is left untouched — its transient
    // read failures still preserve last-known rows (see below), the intended
    // resilience behaviour.
    final isSwitch = tourId != _loadedTourId;
    // Before the OUTGOING tour's rows are cleared below, snapshot its
    // outstanding handover into [settlementByTour] via the same
    // [tourSummary] → [TourMoneySummary.compute] path [outstandingHandoverFor]
    // uses for the live tour — no extra network call, no divergence. Without
    // this, a tour that WAS the loaded tour has no cached snapshot the moment
    // it stops being loaded (loadSettlementSnapshots explicitly skips
    // _loadedTourId), so its genuine outstanding handover would silently drop
    // out of the dashboard's "needs attention" list until some unrelated
    // event re-ran the snapshot pass. Gated on [loadedOnce] so a tour that was
    // never actually fetched (still holding empty/initial lists) isn't cached
    // as a false "settled" (0) — that must stay "unknown" (null).
    if (isSwitch && _loadedTourId != null && loadedOnce.value) {
      settlementByTour[_loadedTourId!] = tourSummary().totalOutstandingHandover;
    }
    if (isSwitch) {
      collections.clear();
      expenses.clear();
      handovers.clear();
      incomes.clear();
      loadedOnce.value = false;
    }
    _loadedTourId = tourId;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final results = await Future.wait([
        _sync.smartFetch(
          table: 'collections',
          cacheKey: _collectionsKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'expenses',
          cacheKey: _expensesKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'bus_handovers',
          cacheKey: _handoversKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'incomes',
          cacheKey: _incomesKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
      ]);

      // smartFetch never throws — it returns [] with a per-call `failed` flag on
      // any failure or when offline. The four reads run concurrently; this load
      // has failed if ANY of them did. Each flag is that call's OWN outcome (no
      // shared service field), so an unrelated concurrent read can't corrupt it.
      // Only COMMIT the fetched rows when the load genuinely succeeded: a
      // transient timeout must keep whatever we already hold rather than blank
      // the money board to ₹0 (which reads as "this tour has no money" — the bug
      // this guard fixes). The screens observe [loadFailed] to show a retry.
      final failed = results.any((r) => r.failed);
      if (!failed) {
        collections.assignAll(results[0].rows.map(Collection.fromMap).toList());
        expenses.assignAll(results[1].rows.map(Expense.fromMap).toList());
        handovers.assignAll(results[2].rows.map(BusHandover.fromMap).toList());
        incomes.assignAll(results[3].rows.map(IncomeEntry.fromMap).toList());
        loadedOnce.value = true;
      }
      loadFailed.value = failed;
    } catch (e, st) {
      // Leave whatever we already hold in place — a transient fetch
      // failure shouldn't blank the money screen.
      dev.log(
        'loadForTour failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      loadFailed.value = true;
    } finally {
      isLoading.value = false;
    }
  }

  /// Force a fresh fetch by invalidating the three per-tour cache keys
  /// before reloading.
  Future<void> refreshForTour(String tourId) async {
    await _sync.invalidateCache(_collectionsKey(tourId));
    await _sync.invalidateCache(_expensesKey(tourId));
    await _sync.invalidateCache(_handoversKey(tourId));
    await _sync.invalidateCache(_incomesKey(tourId));
    await loadForTour(tourId);
  }

  // ── Settlement snapshots (AL-3) ───────────────────────────

  /// Per-tour outstanding-handover totals for the dashboard's settlement alerts
  /// (AL-3), so tours OTHER than the currently-loaded one still surface. Filled
  /// by [loadSettlementSnapshots]; read via [outstandingHandoverFor].
  final settlementByTour = <String, double>{}.obs;

  /// Outstanding handover for [tourId]: the exact live value when it's the
  /// loaded tour, else the cached snapshot (null when not yet computed — the
  /// caller must treat null as "unknown", not "settled").
  double? outstandingHandoverFor(String tourId) {
    if (tourId == _loadedTourId) return tourSummary().totalOutstandingHandover;
    return settlementByTour[tourId];
  }

  /// Lightweight settlement pass for [tourIds]: fetch each tour's four money
  /// tables and cache its outstanding handover via the SAME
  /// [TourMoneySummary.compute] the board uses. Never touches the live obs
  /// lists; skips the loaded tour (already exact, read live), any tour whose
  /// snapshot is already cached (the dashboard's trigger re-runs whenever the
  /// tours list changes for ANY reason, so this keeps repeat calls a no-op
  /// instead of re-fetching four tables per tour on every unrelated update),
  /// and any failed read (left uncached so a later call can retry it).
  Future<void> loadSettlementSnapshots(Iterable<String> tourIds) async {
    final tourCtrl =
        Get.isRegistered<TourController>() ? Get.find<TourController>() : null;
    var changed = false;
    for (final id in tourIds) {
      if (id == _loadedTourId) continue;
      if (settlementByTour.containsKey(id)) continue;
      final results = await Future.wait([
        _sync.smartFetch(
          table: 'collections',
          cacheKey: _collectionsKey(id),
          filters: {'tour_id': id},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'expenses',
          cacheKey: _expensesKey(id),
          filters: {'tour_id': id},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'bus_handovers',
          cacheKey: _handoversKey(id),
          filters: {'tour_id': id},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'incomes',
          cacheKey: _incomesKey(id),
          filters: {'tour_id': id},
          orderBy: 'created_at',
        ),
      ]);
      if (results.any((r) => r.failed)) continue;
      final tour = tourCtrl?.getTour(id);
      final busRentsTotal =
          tour == null ? 0.0 : tour.buses.fold<double>(0, (s, b) => s + b.busPrice);
      final totalRevenueBilled = tour == null
          ? 0.0
          : tour.buses.fold<double>(
              0,
              (s, b) => s + tour.passengers.fold<double>(0, (ps, p) => ps + b.amountDueFor(p)),
            );
      final summary = TourMoneySummary.compute(
        collections: results[0].rows.map(Collection.fromMap).toList(),
        expenses: results[1].rows.map(Expense.fromMap).toList(),
        handovers: results[2].rows.map(BusHandover.fromMap).toList(),
        incomes: results[3].rows.map(IncomeEntry.fromMap).toList(),
        busRentsTotal: busRentsTotal,
        totalRevenueBilled: totalRevenueBilled,
      );
      settlementByTour[id] = summary.totalOutstandingHandover;
      changed = true;
    }
    if (changed) settlementByTour.refresh();
  }

  // ── Collections ───────────────────────────────────────────

  Collection? collectionFor(String passengerId, String busId, String seatId) =>
      collections.firstWhereOrNull(
        (c) =>
            c.passengerId == passengerId &&
            c.busId == busId &&
            c.seatId == seatId,
      );

  Future<void> upsertCollection(Collection c) async {
    final idx = collections.indexWhere((e) => e.id == c.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      collections[idx] = c;
    } else {
      collections.add(c);
    }
    collections.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
      }
    } catch (e) {
      await refreshForTour(c.tourId);
      AppSnackBar.error(
        tr('errors.save_collection', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  Future<void> deleteCollection(String id) async {
    final removed = collections.firstWhereOrNull((c) => c.id == id);
    collections.removeWhere((c) => c.id == id);
    try {
      await _sync.smartDelete(table: 'collections', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_collection', namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }

  // ── Expenses ──────────────────────────────────────────────

  Future<void> upsertExpense(Expense e) async {
    final idx = expenses.indexWhere((x) => x.id == e.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      expenses[idx] = e;
    } else {
      expenses.add(e);
    }
    expenses.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'expenses',
          entityId: e.id,
          data: e.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'expenses',
          entityId: e.id,
          data: e.toMap(),
        );
      }
    } catch (err) {
      await refreshForTour(e.tourId);
      AppSnackBar.error(
        tr('errors.save_expense', namedArgs: {'e': '$err'}),
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  Future<void> deleteExpense(String id) async {
    final removed = expenses.firstWhereOrNull((e) => e.id == id);
    expenses.removeWhere((e) => e.id == id);
    try {
      await _sync.smartDelete(table: 'expenses', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_expense', namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }

  // ── Handovers ─────────────────────────────────────────────

  /// Records a new handover or, when [h] carries an existing id, updates it —
  /// so a logged handover can be corrected after the fact (mirrors
  /// [upsertExpense]).
  Future<void> recordHandover(BusHandover h) async {
    final idx = handovers.indexWhere((x) => x.id == h.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      handovers[idx] = h;
    } else {
      handovers.add(h);
    }
    handovers.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'bus_handovers',
          entityId: h.id,
          data: h.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'bus_handovers',
          entityId: h.id,
          data: h.toMap(),
        );
      }
    } catch (e) {
      await refreshForTour(h.tourId);
      AppSnackBar.error(
        tr('errors.record_handover', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  Future<void> deleteHandover(String id) async {
    final removed = handovers.firstWhereOrNull((h) => h.id == id);
    handovers.removeWhere((h) => h.id == id);
    try {
      await _sync.smartDelete(table: 'bus_handovers', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_handover', namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }

  // ── Aggregation ───────────────────────────────────────────

  /// Per-bus owner rent (`Bus.busPrice`) for the loaded tour, keyed by bus id.
  /// The rent is auto-counted as a `busOwner` expense in the summaries (single
  /// source of truth — never a DB expense row). Resolves from the loaded tour's
  /// buses via [TourController]; guards for a missing tour / not-registered
  /// controller by treating every rent as 0, so it never throws.
  Map<String, double> _busRents() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const {};
    }
    final buses = Get.find<TourController>().getTour(tourId)?.buses;
    if (buses == null) return const {};
    return {for (final b in buses) b.id: b.busPrice};
  }

  /// Per-bus BILLED revenue — the sum of fares owed by every passenger seated
  /// on the bus (via [Bus.amountDueFor], which is already bus-scoped and trip-
  /// factor aware). This is ACCRUAL revenue: what the trip earns regardless of
  /// how much cash has been collected, so the P&L can show a "true" profit.
  /// Keyed by bus id; guards a missing tour / unregistered controller with 0.
  Map<String, double> _billedRevenues() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const {};
    }
    final tour = Get.find<TourController>().getTour(tourId);
    if (tour == null) return const {};
    return {
      for (final b in tour.buses)
        b.id: tour.passengers.fold(0.0, (sum, p) => sum + b.amountDueFor(p)),
    };
  }

  /// Bus objects for the loaded tour, keyed by bus id — the source of each bus's
  /// per-seat fare ([Bus.amountDueForSeat]) so to-collect can price seated riders
  /// who have no collection row yet. Same guards as [_busRents] (missing tour /
  /// unregistered controller → empty).
  Map<String, Bus> _busById() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const {};
    }
    final buses = Get.find<TourController>().getTour(tourId)?.buses;
    if (buses == null) return const {};
    return {for (final b in buses) b.id: b};
  }

  /// The loaded tour's passengers, or empty when the tour/controller is missing.
  List<Passenger> _tourPassengers() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const [];
    }
    return Get.find<TourController>().getTour(tourId)?.passengers ?? const [];
  }

  BusMoneySummary summaryForBus(String busId) => BusMoneySummary.compute(
    busId: busId,
    collections: collections.toList(),
    expenses: expenses.toList(),
    handovers: handovers.toList(),
    incomes: incomes.toList(),
    busRent: _busRents()[busId] ?? 0,
    revenueBilled: _billedRevenues()[busId] ?? 0,
    passengers: _tourPassengers(),
    dueForSeat: _busById()[busId]?.amountDueForSeat,
  );

  TourMoneySummary tourSummary() {
    // Roll to-collect up from the per-bus summaries so the tour total counts
    // seated-but-uncollected riders exactly the same way each bus row does —
    // admin, handler and tour totals then all agree. Fall back to the recorded
    // shortfalls (null override) when no tour/buses are resolvable.
    final busById = _busById();
    final perBusToCollect = busById.isEmpty
        ? null
        : summariesForBuses(busById.keys).fold(
            0.0,
            (sum, s) => sum + s.toCollectTotal,
          );
    return TourMoneySummary.compute(
      collections: collections.toList(),
      expenses: expenses.toList(),
      handovers: handovers.toList(),
      incomes: incomes.toList(),
      busRentsTotal: _busRents().values.fold(0.0, (sum, r) => sum + r),
      totalRevenueBilled: _billedRevenues().values.fold(
        0.0,
        (sum, r) => sum + r,
      ),
      toCollectTotal: perBusToCollect,
    );
  }

  /// Read-only summaries for every bus id in [busIds], in the order given.
  /// Pure aggregation over the currently held rows — no fetch. Used by the
  /// tour money board to render one row per bus without each row recomputing
  /// the same `where` scans against the shared lists.
  List<BusMoneySummary> summariesForBuses(Iterable<String> busIds) {
    final cols = collections.toList();
    final exps = expenses.toList();
    final hands = handovers.toList();
    final incs = incomes.toList();
    final rents = _busRents();
    final billed = _billedRevenues();
    final busById = _busById();
    final passengers = _tourPassengers();
    return [
      for (final id in busIds)
        BusMoneySummary.compute(
          busId: id,
          collections: cols,
          expenses: exps,
          handovers: hands,
          incomes: incs,
          busRent: rents[id] ?? 0,
          revenueBilled: billed[id] ?? 0,
          passengers: passengers,
          dueForSeat: busById[id]?.amountDueForSeat,
        ),
    ];
  }

  /// Per-handler money rollups for the loaded tour. A handler runs whole buses
  /// ([Bus.handlerPassengerId]), so each handler's P&L is the sum of their
  /// buses' [BusMoneySummary]s. Buses with no handler fall into a single
  /// null-keyed bucket (kept LAST) so unassigned buses are never dropped.
  /// First-seen handler order is preserved for a stable UI.
  List<HandlerMoneySummary> handlerSummaries() {
    final tourId = _loadedTourId;
    if (tourId == null || !Get.isRegistered<TourController>()) {
      return const [];
    }
    final tour = Get.find<TourController>().getTour(tourId);
    if (tour == null) return const [];

    final handlerByBus = {
      for (final b in tour.buses) b.id: b.handlerPassengerId,
    };
    final summaries = summariesForBuses(tour.buses.map((b) => b.id));

    final order = <String?>[];
    final grouped = <String?, List<BusMoneySummary>>{};
    for (final s in summaries) {
      final h = handlerByBus[s.busId];
      if (!grouped.containsKey(h)) {
        grouped[h] = [];
        order.add(h);
      }
      grouped[h]!.add(s);
    }
    // Non-null handlers first (in first-seen order), unassigned bucket last.
    final ordered = [
      ...order.where((h) => h != null),
      ...order.where((h) => h == null),
    ];
    return [
      for (final h in ordered) HandlerMoneySummary.fromBuses(h, grouped[h]!),
    ];
  }

  /// Classifies a bus's money state for the board's attention ring. Pure
  /// read-only derivation from a [BusMoneySummary]:
  ///   * [BusMoneyState.actionNeeded] — handler still owes a handover
  ///     (outstanding > 0) OR a passenger shortfall is still to be collected.
  ///   * [BusMoneyState.settled] — money has moved (collected or handed over)
  ///     and nothing is outstanding / to collect / to return.
  ///   * [BusMoneyState.neutral] — nothing has happened on this bus yet.
  /// A small epsilon absorbs floating-point dust so a fully-square bus never
  /// reads as action-needed.
  BusMoneyState stateForBusSummary(BusMoneySummary s) {
    const eps = 0.005;
    final outstanding = s.outstandingHandover > eps;
    final toCollect = s.toCollectTotal > eps;
    final toReturn = s.toReturnTotal > eps;
    // Real money still owed: billed revenue not yet collected (catches seated
    // riders billed but uncollected, whether or not a shortfall row exists).
    final revenueOutstanding = (s.revenueBilled - s.collected) > eps;
    // Net can't even cover the owner's rent — the handler is short on the
    // settlement, so this is an attention state, never "settled".
    final cannotCoverRent = s.expectedHandover < -eps;
    if (outstanding || toCollect || revenueOutstanding || cannotCoverRent) {
      return BusMoneyState.actionNeeded;
    }

    final hasActivity = s.collected > eps || s.handedOver > eps;
    if (hasActivity && !toReturn) return BusMoneyState.settled;
    return BusMoneyState.neutral;
  }
}

/// Per-bus money board state, driving the attention ring on the tour money
/// board. Kept here (next to the aggregation helpers) so both the screen and
/// its tests share one source of truth.
enum BusMoneyState { actionNeeded, settled, neutral }
