import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';

import '../models/collection.dart';
import '../models/expense.dart';
import '../models/income_entry.dart';
import '../models/bus_handover.dart';
import '../models/ledger_bus_rollup.dart';
import '../models/money_summary.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/payment_claim.dart';
import '../models/tour.dart';
import '../services/collection_reconciler.dart';
import '../services/ledger_money_source.dart';
import '../services/supabase_service.dart';
import '../services/sync_read_projections.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/collection_seat_resolver.dart';
import '../utils/seat_money_state.dart';
import 'finance_controller.dart';
import 'tour_controller.dart';

/// Loads & persists the money tables (`collections`, `expenses`,
/// `bus_handovers`, `incomes`) for a single tour via [SyncService], and
/// exposes aggregation summaries from the finance ledger when available
/// (legacy row lists remain the write/edit surface).
///
/// CRUD follows the same shape as [TourController]: mutate local state
/// optimistically so the UI feels instant, await the server write, and on
/// failure pull fresh state from the server + surface the error.
///
/// RLS note: these three tables are NOT owner-scoped (no `owner_id`
/// column). Their policies validate via the tour-owner join, so we just
/// send the row's `toMap()` (which already carries `tour_id`/`bus_id`).
class MoneyController extends GetxController {
  MoneyController({LedgerMoneySource? ledgerSource})
      : _ledgerSource = ledgerSource ?? LedgerMoneySource();

  final LedgerMoneySource _ledgerSource;

  final collections = <Collection>[].obs;
  final expenses = <Expense>[].obs;
  final handovers = <BusHandover>[].obs;
  final incomes = <IncomeEntry>[].obs;
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

  // ── Load / refresh ────────────────────────────────────────

  Future<void> loadForTour(String tourId) async {
    if (tourId.isEmpty) return;
    // Same-tour concurrent callers share one in-flight request (hero + money
    // tab + collection screen all fire loadForTour on open).
    if (_loadInFlight != null && _loadInFlightTourId == tourId) {
      return _loadInFlight!;
    }
    final future = _loadForTourBody(tourId);
    _loadInFlight = future;
    _loadInFlightTourId = tourId;
    try {
      await future;
    } finally {
      if (_loadInFlightTourId == tourId) {
        _loadInFlight = null;
        _loadInFlightTourId = null;
      }
    }
  }

  Future<void> _loadForTourBody(String tourId) async {
    final gen = ++_loadGeneration;
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
      paymentClaims.clear();
      pendingSeatHolds.clear();
      loadedOnce.value = false;
      _clearLedgerCache();
    }
    _loadedTourId = tourId;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final results = await Future.wait([
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
      if (gen != _loadGeneration || _loadedTourId != tourId) return;

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

        // Claims + holds + ledger are independent — run in parallel instead of
        // three sequential round-trips on 2G.
        final secondary = await Future.wait([
          _loadPaymentClaims(tourId),
          _loadPendingSeatHolds(tourId),
          _loadLedgerForTour(tourId),
        ]);
        if (gen != _loadGeneration || _loadedTourId != tourId) return;
        final ledgerOk = secondary[2] as bool;
        if (!ledgerOk) loadFailed.value = true;
      }
      if (gen != _loadGeneration || _loadedTourId != tourId) return;
      loadFailed.value = failed || loadFailed.value;
    } catch (e, st) {
      if (gen != _loadGeneration || _loadedTourId != tourId) return;
      // Leave whatever we already hold in place — a transient fetch
      // failure shouldn't blank the money screen.
      dev.log(
        'loadForTour failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      loadFailed.value = true;
    } finally {
      if (gen == _loadGeneration) isLoading.value = false;
    }
  }

  void _clearLedgerCache() {
    _ledgerReady = false;
    _ledgerByBus.clear();
  }

  /// Returns false when the ledger views could not be read.
  Future<bool> _loadLedgerForTour(String tourId) async {
    try {
      final rollups = await _ledgerSource.fetchBusRollups(tourId);
      if (_loadedTourId != tourId) return false;
      _ledgerByBus
        ..clear()
        ..addEntries([
          for (final r in rollups)
            if (r.busId != null && r.busId!.isNotEmpty) MapEntry(r.busId!, r),
        ]);
      _ledgerReady = true;
      return true;
    } catch (e, st) {
      if (_loadedTourId != tourId) return false;
      dev.log(
        'ledger load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      _clearLedgerCache();
      return false;
    }
  }

  Future<void> _loadPaymentClaims(String tourId) async {
    try {
      final raw = await SupabaseService.instance.client
          .from('payment_claims')
          .select(SyncReadProjections.paymentClaimsSelect)
          .eq('tour_id', tourId)
          .order('claimed_at', ascending: false);
      if (_loadedTourId != tourId) return;
      paymentClaims.assignAll([
        for (final r in (raw as List))
          PaymentClaim.fromMap(Map<String, dynamic>.from(r as Map)),
      ]);
    } catch (e, st) {
      if (_loadedTourId != tourId) return;
      // Claims table may be undeployed — keep empty, don't fail the board.
      dev.log(
        'payment_claims load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      paymentClaims.clear();
    }
  }

  Future<void> _loadPendingSeatHolds(String tourId) async {
    try {
      final raw = await SupabaseService.instance.client.rpc(
        'tour_pending_seat_holds',
        params: {'p_tour_id': tourId},
      );
      if (_loadedTourId != tourId) return;
      if (raw is! List) {
        pendingSeatHolds.clear();
        return;
      }
      pendingSeatHolds.assignAll([
        for (final r in raw)
          if (r is Map) Map<String, dynamic>.from(r),
      ]);
    } catch (e, st) {
      if (_loadedTourId != tourId) return;
      dev.log(
        'pending seat holds load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      pendingSeatHolds.clear();
    }
  }

  /// Admin: lock held seats without waiting for UPI confirm (pay on bus).
  Future<void> payLaterFinalizeHold(String holdId) async {
    await SupabaseService.instance.client.rpc(
      'chart_finalize_hold',
      params: {'p_hold_id': holdId},
    );
    final tourId = _loadedTourId;
    if (tourId != null) {
      await refreshForTour(tourId);
      if (Get.isRegistered<TourController>()) {
        await Get.find<TourController>().refreshTours();
      }
    }
  }

  List<PaymentClaim> get pendingClaims =>
      paymentClaims.where((c) => c.isPending).toList();

  /// The rider's UNVERIFIED claim, if any — "I paid you, here's the reference".
  /// Surfaced on the collect sheet so the agent can confirm or reject it; it is
  /// deliberately NOT money until they do.
  ///
  /// There is intentionally no `confirmedAdvanceForPassenger` / `dueAfterAdvances`
  /// counterpart. Confirming a claim writes a real `collections` row
  /// (`confirm_payment_claim`, migration 060/069), so a confirmed advance is
  /// already inside `netCollectedOf` and every balance derived from it. A helper
  /// that subtracted it a SECOND time would reproduce, client-side, exactly the
  /// double-count that migration 069 removes from the ledger — so the pair was
  /// deleted rather than left lying around unused.
  PaymentClaim? pendingClaimForPassenger(String passengerId) =>
      paymentClaims.firstWhereOrNull(
        (c) => c.passengerId == passengerId && c.isPending,
      );

  Future<void> confirmPaymentClaim(String claimId, {String? note}) async {
    await SupabaseService.instance.client.rpc(
      'confirm_payment_claim',
      params: {
        'p_claim_id': claimId,
        'p_note': ?note,
      },
    );
    final tourId = _loadedTourId;
    if (tourId != null) {
      await refreshForTour(tourId);
    }
    _invalidateFinance();
  }

  /// Record a payment the ORGANISER collected from a waitlisted rider, and
  /// post it to the ledger.
  ///
  /// Goes claim -> confirm rather than writing a collection row, for a concrete
  /// reason: `collections` is keyed (passenger, bus, seat) and a waitlisted
  /// rider has no seat yet, so there is nothing to key a row to. The claim rail
  /// is passenger-scoped and already posts bank.gateway -> ar.rider through
  /// `confirm_payment_claim`, which is exactly the entry this money needs.
  ///
  /// Returns null on success, or a reason the caller can show. The commonest
  /// failure is a rider the ORGANISER added by hand: they have no
  /// booking_requests row, and `claim_upi_advance` is keyed by one. That is
  /// reported rather than swallowed — silently confirming a rider whose money
  /// never reached the ledger is how a tour's books stop adding up.
  Future<String?> recordWaitlistPayment({
    required String tourId,
    required String passengerId,
    required int amountPaise,
    String? reference,
  }) async {
    if (amountPaise <= 0) return 'amount';
    final client = SupabaseService.instance.client;
    try {
      final rows = await client
          .from('booking_requests')
          .select('id')
          .eq('passenger_id', passengerId)
          .limit(1);
      final list = rows as List;
      if (list.isEmpty) return 'no_request';
      final requestId = (list.first as Map)['id']?.toString();
      if (requestId == null || requestId.isEmpty) return 'no_request';

      final claimId = await client.rpc(
        'claim_upi_advance',
        params: {
          'p_request_id': requestId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      if (claimId == null) return 'claim_failed';

      await client.rpc(
        'confirm_payment_claim',
        params: {
          'p_claim_id': claimId.toString(),
          'p_note': 'waitlist collection',
        },
      );
      await refreshForTour(tourId);
      _invalidateFinance();
      return null;
    } catch (e, st) {
      dev.log(
        'recordWaitlistPayment failed for $passengerId: $e\n$st',
        name: 'MoneyController',
      );
      return 'failed';
    }
  }

  Future<void> rejectPaymentClaim(String claimId, {String? note}) async {
    await SupabaseService.instance.client.rpc(
      'reject_payment_claim',
      params: {
        'p_claim_id': claimId,
        'p_note': ?note,
      },
    );
    final tourId = _loadedTourId;
    if (tourId != null) await _loadPaymentClaims(tourId);
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
    if (_settlementInFlight != null) return _settlementInFlight!;
    final future = _loadSettlementSnapshotsBody(tourIds);
    _settlementInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_settlementInFlight, future)) {
        _settlementInFlight = null;
      }
    }
  }

  Future<void> _loadSettlementSnapshotsBody(Iterable<String> tourIds) async {
    final tourCtrl =
        Get.isRegistered<TourController>() ? Get.find<TourController>() : null;
    var changed = false;
    final pending = tourIds
        .where((id) => id != _loadedTourId && !settlementByTour.containsKey(id))
        .toList();

    // Parallel batches of 3 — sequential N tours on 2G stacks latency; unbounded
    // parallelism floods a weak radio. Three keeps the air moving without
    // saturating the sync retry budget.
    const batchSize = 3;
    for (var i = 0; i < pending.length; i += batchSize) {
      final chunk = pending.sublist(i, math.min(i + batchSize, pending.length));
      final results = await Future.wait(chunk.map((id) async {
        try {
          final rollups = await _ledgerSource.fetchBusRollups(id);
          return MapEntry(
            id,
            rollups.fold<double>(
              0,
              (sum, r) => sum + r.outstandingHandover,
            ),
          );
        } catch (e, st) {
          dev.log(
            'settlement ledger snapshot failed for $id: $e\n$st',
            name: 'MoneyController',
          );
        }

        final results = await Future.wait([
          _sync.smartFetch(
            table: 'collections',
            cacheKey: _collectionsKey(id),
            select: SyncReadProjections.collectionsSelect,
            filters: {'tour_id': id},
            orderBy: 'created_at',
          ),
          _sync.smartFetch(
            table: 'expenses',
            cacheKey: _expensesKey(id),
            select: SyncReadProjections.expensesSelect,
            filters: {'tour_id': id},
            orderBy: 'created_at',
          ),
          _sync.smartFetch(
            table: 'bus_handovers',
            cacheKey: _handoversKey(id),
            select: SyncReadProjections.handoversSelect,
            filters: {'tour_id': id},
            orderBy: 'created_at',
          ),
          _sync.smartFetch(
            table: 'incomes',
            cacheKey: _incomesKey(id),
            select: SyncReadProjections.incomesSelect,
            filters: {'tour_id': id},
            orderBy: 'created_at',
          ),
        ]);
        if (results.any((r) => r.failed)) return null;
        final tour = tourCtrl?.getTour(id);
        final busRentsTotal =
            tour == null ? 0.0 : tour.buses.fold<double>(0, (s, b) => s + b.busPrice);
        final totalRevenueBilled = tour == null
            ? 0.0
            : tour.buses.fold<double>(
                0,
                (s, b) =>
                    s + tour.passengers.fold<double>(0, (ps, p) => ps + b.amountDueFor(p)),
              );
        final summary = TourMoneySummary.compute(
          collections: results[0].rows.map(Collection.fromMap).toList(),
          expenses: results[1].rows.map(Expense.fromMap).toList(),
          handovers: results[2].rows.map(BusHandover.fromMap).toList(),
          incomes: results[3].rows.map(IncomeEntry.fromMap).toList(),
          busRentsTotal: busRentsTotal,
          totalRevenueBilled: totalRevenueBilled,
        );
        return MapEntry(id, summary.totalOutstandingHandover);
      }));

      for (final entry in results) {
        if (entry == null) continue;
        settlementByTour[entry.key] = entry.value;
        changed = true;
      }
    }
    if (changed) settlementByTour.refresh();
  }

  // ── Collections ───────────────────────────────────────────

  /// The EXISTING collection row a tap on [seatId] must write into.
  ///
  /// Resolves through [collectionRowForSeat], not the strict
  /// (passenger, bus, seat) triple. Matching on the triple meant a rider who
  /// paid on one seat and later moved to another MISSED their own row, so the
  /// collect sheet opened blank and the save wrote a SECOND row — which 062's
  /// collections_ledger_sync posted to the ledger again, and both money engines
  /// fold per row. The admin board then showed double the cash in hand. Same
  /// hole, same fix, as the handler chart's `_collectionFor`.
  Collection? collectionFor(Passenger passenger, String busId, String seatId) =>
      collectionRowForSeat(
        passenger: passenger,
        busId: busId,
        seatId: seatId,
        collections: collections,
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
      _invalidateFinance();
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
      _invalidateFinance();
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_collection', namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }

  /// Re-attach this tour's collection rows to the seats their payers actually
  /// hold after a seat move, and report what that does to each payer's balance.
  ///
  /// A cross-bus move re-prices the passenger at the DESTINATION bus's bands
  /// while the cash they already handed over stays exactly as recorded, so each
  /// returned [SeatMoveMoneyDelta] says how much more to collect — or hand back
  /// when the new bus is cheaper. See [CollectionReconciler] for why the rows
  /// need re-homing at all.
  ///
  /// Never throws. The seat move this follows is already persisted and visible
  /// on the chart, so a money-write failure surfaces as an error toast plus a
  /// refetch rather than unwinding a placement the agent can see.
  ///
  /// [crossedBus] gates the on-demand read. A cross-bus move is rare and is the
  /// whole point of this method, so it is worth a round trip when the money
  /// tables are not loaded. A same-bus move only re-stamps a stale `seat_id`,
  /// which is not worth a fetch on every drag — it reconciles for free when the
  /// tour's rows happen to be loaded, and otherwise waits for the next write
  /// that touches this passenger's seats. Nothing reconciles on a
  /// collection-screen visit; this method has exactly one caller
  /// ([TourController] after a seat write), so a skipped pass stays skipped
  /// until the seats move again.
  Future<List<SeatMoveMoneyDelta>> reconcileAfterSeatMove({
    required Tour tour,
    required Iterable<String> passengerIds,
    required bool crossedBus,
  }) async {
    final ids = passengerIds.toSet();
    if (ids.isEmpty) return const [];

    final isLoadedTour = _loadedTourId == tour.id;
    if (!isLoadedTour && !crossedBus) return const [];

    final List<Collection> rows;
    if (isLoadedTour) {
      rows = collections.toList();
    } else {
      // The assign workspace never loads the money tables, so read this tour's
      // rows on demand rather than planning against an empty list — that would
      // silently skip the carry-over for exactly the screen where moves happen.
      final res = await _sync.smartFetch(
        table: 'collections',
        cacheKey: _collectionsKey(tour.id),
        select: SyncReadProjections.collectionsSelect,
        filters: {'tour_id': tour.id},
        orderBy: 'created_at',
      );
      if (res.failed) {
        // Offline, or the read failed. We now know NOTHING about this tour's
        // collections, so returning an empty plan is not "nothing to do" — it
        // is "we did not look". Staying silent here is what let a paid rider
        // cross buses and quietly keep the full destination fare outstanding
        // with their cash stranded on the old bus. Say so; the reconcile is
        // idempotent, so the next seat write (online) puts it right.
        AppSnackBar.warning(tr('money.reconcile_unavailable'));
        return const [];
      }
      rows = res.rows.map(Collection.fromMap).toList();
    }

    final plan = CollectionReconciler.plan(
      tour: tour,
      passengerIds: ids,
      collections: rows,
    );
    if (plan.isEmpty) return const [];

    try {
      for (final c in plan.updates) {
        await _sync.smartUpdate(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
        if (isLoadedTour) {
          final idx = collections.indexWhere((e) => e.id == c.id);
          if (idx >= 0) collections[idx] = c;
        }
      }
      if (isLoadedTour) collections.refresh();
    } catch (e) {
      await refreshForTour(tour.id);
      AppSnackBar.error(
        tr('errors.save_collection', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      return const [];
    }

    return plan.deltas;
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
      _invalidateFinance();
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
      _invalidateFinance();
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_expense', namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }

  // ── Incomes ───────────────────────────────────────────────
  // Extra cash taken in outside seat fares (cabin / gallery / other). The
  // HANDLER logs these on the ground through their own RPCs; these are the
  // ADMIN's equivalents, so a wrong or missing entry can be corrected from the
  // bus money screen instead of being permanently stuck at whatever the handler
  // typed. Same optimistic-then-confirm shape as [upsertExpense].

  Future<void> upsertIncome(IncomeEntry i) async {
    final idx = incomes.indexWhere((x) => x.id == i.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      incomes[idx] = i;
    } else {
      incomes.add(i);
    }
    incomes.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'incomes',
          entityId: i.id,
          data: i.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'incomes',
          entityId: i.id,
          data: i.toMap(),
        );
      }
      _invalidateFinance();
    } catch (e) {
      await refreshForTour(i.tourId);
      AppSnackBar.error(
        tr('errors.save_income', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  Future<void> deleteIncome(String id) async {
    final removed = incomes.firstWhereOrNull((i) => i.id == id);
    incomes.removeWhere((i) => i.id == id);
    try {
      await _sync.smartDelete(table: 'incomes', entityId: id);
      _invalidateFinance();
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr('errors.delete_income', namedArgs: {'e': '$e'}),
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

  /// How many of the tour's buses have no owner rent recorded — see
  /// [TourMoneySummary.busesMissingRent] for why it matters. Reads the tour's
  /// own bus list (not the ledger roll-ups) so both aggregation paths agree,
  /// and so a bus the ledger has no rows for yet is still checked.
  ///
  /// An unresolvable fleet yields an empty map and therefore 0 — "unknown",
  /// never a false accusation, matching [_busRents]'s own guard.
  int _busesMissingRent() =>
      _busRents().values.where((rent) => rent <= 0).length;

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

  /// This bus's still-owed / still-owed-back, priced seat by seat against the
  /// LIVE fare — the same [busSeatAr] walk the collection roster,
  /// [BusMoneySummary.compute] and the handler all use.
  ///
  /// The ledger cannot answer this. `ar.rider` lines are passenger-scoped and
  /// carry no `bus_id` (063's header says so explicitly), so the old code
  /// reconstructed a per-bus figure by apportioning each rider's TOUR-WIDE
  /// `finance_rider_balance` across their buses by billed share. Two things went
  /// wrong with that. A fraction of one rider's balance landed on a bus whose own
  /// seat was square — the "₹449 to return" with nobody in the To-return filter.
  /// And the posted fare it divides up goes stale whenever a bus is re-priced,
  /// because nothing re-posted it (migration 092 fixes that half).
  ///
  /// Cash, billed revenue, expenses and handovers still come from the ledger
  /// rollup: those are posted facts, not derivations, and the ledger is the
  /// better source for them.
  ///
  /// Falls back to the rollup's own figures when the bus cannot be priced —
  /// a bus the tour no longer lists has no [Bus] to read a fare from.
  ({double toCollect, double toReturn})? _seatArForBus(String busId) {
    final bus = _busById()[busId];
    if (bus == null) return null;
    return busSeatAr(
      busId: busId,
      passengers: _tourPassengers(),
      collections: collections,
      dueForSeat: bus.amountDueForSeat,
    );
  }

  BusMoneySummary summaryForBus(String busId) {
    if (_ledgerReady) {
      final rollup = _ledgerByBus[busId];
      if (rollup != null) {
        final ar =
            _seatArForBus(busId) ??
            (toCollect: rollup.toCollect, toReturn: rollup.toReturn);
        return BusMoneySummary(
          busId: busId,
          collected: rollup.collected,
          revenueBilled: rollup.billed,
          expensesTotal: rollup.expensesTotal,
          handedOver: rollup.handedOver,
          toReturnTotal: ar.toReturn,
          toCollectTotal: ar.toCollect,
          income: rollup.income,
          busRent: rollup.rent,
        );
      }
      // Ledger loaded but holding no lines for this bus — fall through to the
      // legacy recompute below.
      //
      // An empty answer is NOT proof the bus has no money. The write-through
      // triggers (062) may not be deployed, or the backfill (058) never run, in
      // which case the ledger is simply blank while the legacy tables — already
      // fetched, sitting in the obs lists right here — hold the real cash. This
      // used to return hard zeros, which is what rendered a ₹0 Profit & Loss
      // for a tour with money on it, and worse than an obviously-broken board:
      // rent still came through from the in-memory tour, so the trip read as a
      // clean rent-sized LOSS rather than as a failure.
      //
      // When the bus genuinely has nothing, the legacy compute returns the same
      // zeros (plus rent and billed revenue), so falling back is never worse
      // than the figure it replaces.
    }
    return BusMoneySummary.compute(
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
  }

  TourMoneySummary tourSummary() {
    if (_ledgerReady) {
      final busById = _busById();
      final knownIds = busById.keys.toSet();
      // Buses the LEDGER carries money for that the tour no longer lists. Their
      // cash is real and must stay inside the trip total — dropping it (which
      // is what iterating `busById.keys` alone did) makes money silently vanish
      // from the books with nothing on screen to explain the gap. They are
      // summed in below AND broken out as `orphan*` so the arithmetic still
      // reconciles, exactly as the legacy path does.
      //
      // Only meaningful when we actually resolved a fleet: an empty `busById`
      // means the tour/controller wasn't available, NOT that the tour has no
      // buses, so every ledger bus would look orphaned.
      final orphanIds = knownIds.isEmpty
          ? const <String>[]
          : [
              for (final id in _ledgerByBus.keys)
                if (!knownIds.contains(id)) id,
            ];
      final ids = knownIds.isEmpty
          ? _ledgerByBus.keys.toList()
          : [...knownIds, ...orphanIds];
      final buses = summariesForBuses(ids);
      var toCollect = 0.0;
      var toReturn = 0.0;
      for (final s in buses) {
        toCollect += s.toCollectTotal;
        toReturn += s.toReturnTotal;
      }
      // A rider seated on NO bus is deliberately not added here. To-collect is
      // now priced from the seats someone actually holds ([busSeatAr]), and an
      // unseated rider holds none — so they are billed nothing and owe nothing.
      // Cash they already paid does not vanish: it stays in `collected` and is
      // called out separately as [TourMoneySummary.totalDetachedCash] below.
      // The old ledger-AR reading counted them, which is how a rider who had
      // been unseated kept generating a refund the roster could not explain.

      var orphanCollected = 0.0;
      var orphanExpenses = 0.0;
      var orphanIncome = 0.0;
      for (final id in orphanIds) {
        final r = _ledgerByBus[id]!;
        orphanCollected += r.collected;
        orphanExpenses += r.expensesTotal;
        orphanIncome += r.income;
      }

      return TourMoneySummary(
        totalCollected: buses.fold(0.0, (s, b) => s + b.collected),
        totalRevenueBilled: buses.fold(0.0, (s, b) => s + b.revenueBilled),
        totalExpenses: buses.fold(0.0, (s, b) => s + b.expensesTotal),
        totalHandedOver: buses.fold(0.0, (s, b) => s + b.handedOver),
        totalToReturn: toReturn,
        totalToCollect: toCollect,
        totalIncome: buses.fold(0.0, (s, b) => s + b.income),
        totalBusRent: buses.fold(0.0, (s, b) => s + b.busRent),
        busesMissingRent: _busesMissingRent(),
        orphanCollected: orphanCollected,
        orphanExpenses: orphanExpenses,
        orphanIncome: orphanIncome,
        totalDetachedCash: _detachedCash(
          collections,
          (p) => p.assignedSeats.isNotEmpty,
        ),
      );
    }

    // Roll to-collect up from the per-bus summaries so the tour total counts
    // seated-but-uncollected riders exactly the same way each bus row does —
    // admin, handler and tour totals then all agree. Fall back to the recorded
    // shortfalls (null override) when no tour/buses are resolvable.
    final busById = _busById();
    // One pass over the per-bus summaries feeds BOTH overrides — computing them
    // separately would walk every bus twice, and leaving either out lets the
    // trip total drift from the rows printed beneath it.
    final perBus = busById.isEmpty
        ? null
        : summariesForBuses(busById.keys).toList();
    return TourMoneySummary.compute(
      collections: collections.toList(),
      expenses: expenses.toList(),
      handovers: handovers.toList(),
      incomes: incomes.toList(),
      // Only claim to know the fleet when we actually resolved one. An empty
      // busById here means the tour/controller wasn't resolvable, NOT that the
      // tour has no buses — passing an empty set then would flag every single
      // row as orphaned.
      knownBusIds: busById.isEmpty ? null : busById.keys.toSet(),
      busRentsTotal: _busRents().values.fold(0.0, (sum, r) => sum + r),
      busesMissingRent: _busesMissingRent(),
      totalRevenueBilled: _billedRevenues().values.fold(
        0.0,
        (sum, r) => sum + r,
      ),
      toCollectTotal: perBus?.fold<double>(
        0,
        (sum, s) => sum + s.toCollectTotal,
      ),
      toReturnTotal: perBus?.fold<double>(
        0,
        (sum, s) => sum + s.toReturnTotal,
      ),
      // Trip level: only a rider seated on NO bus at all is stranded here — one
      // merely moved between buses is still on the trip and still counted once.
      detachedCashTotal: _detachedCash(
        collections,
        (p) => p.assignedSeats.isNotEmpty,
      ),
    );
  }

  /// Cash from payers that [isStillSeated] rejects — the shared engine behind
  /// [BusMoneySummary.detachedCash] at the handler and tour levels, where the
  /// "still seated" test spans several buses and so can't be answered per bus.
  ///
  /// Returns 0 when the tour's roster isn't resolvable: with nobody to check
  /// against, every row would look detached, and a false "₹X is stranded" alarm
  /// is worse than staying quiet.
  double _detachedCash(
    Iterable<Collection> rows,
    bool Function(Passenger p) isStillSeated,
  ) {
    final passengers = _tourPassengers();
    if (passengers.isEmpty) return 0;
    final seated = <String>{
      for (final p in passengers)
        if (isStillSeated(p)) p.id,
    };
    return rows
        .where((c) => !seated.contains(c.passengerId))
        .fold(0.0, (sum, c) => sum + c.netCollected);
  }

  /// Read-only summaries for every bus id in [busIds], in the order given.
  /// Pure aggregation over the currently held rows — no fetch. Used by the
  /// tour money board to render one row per bus without each row recomputing
  /// the same `where` scans against the shared lists.
  List<BusMoneySummary> summariesForBuses(Iterable<String> busIds) => [
        for (final id in busIds) summaryForBus(id),
      ];

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
      for (final h in ordered)
        HandlerMoneySummary.fromBuses(
          h,
          grouped[h]!,
          // Scoped to THIS handler's fleet: a rider moved between two buses
          // the same handler runs never left their care, so they are not
          // stranded cash here even though each bus sees them as detached.
          detachedCash: _detachedCash(
            collections.where(
              (c) => grouped[h]!.any((s) => s.busId == c.busId),
            ),
            (p) => p.assignedSeats.any(
              (a) => grouped[h]!.any((s) => s.busId == a.busId),
            ),
          ),
        ),
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
    // Cash taken in doesn't cover the trip's costs (the owner's rent included —
    // the ADMIN pays that out of the handover), so the bus is running at a loss.
    // Reads off the cash net, NOT the handover: the handover figure is
    // rent-free by design, so it would never surface this.
    final cannotCoverRent = s.netCollected < -eps;
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
