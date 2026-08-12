import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent;
import '../models/booking_mode.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/priority_status.dart';
import '../models/bus_details.dart';
import '../models/payment_status.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour_seat_snapshot.dart';
import '../models/trip_type.dart';
import '../services/group_cascade.dart';
import '../services/realtime_service.dart';
import '../services/seating_engine.dart';
import '../services/seating_plan_applier.dart';
import '../services/sync_retry_policy.dart' as retry;
import '../services/sync_service.dart';
import '../services/whatsapp_outbound.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_normalize.dart';
import '../utils/seat_leg_resolver.dart';
import '../utils/seat_occupants.dart';
import '../models/bus_type.dart';
import '../utils/bus_layout_recovery.dart';
import '../utils/tour_capacity.dart';
import '../widgets/seat_move_money_notice.dart';
import 'auth_controller.dart';
import 'customer_memory_controller.dart';
import 'money_controller.dart';

/// What a seat move actually did — the honest answer a caller needs before it
/// tells the operator "moved" and puts the relocate banner away.
///
/// A cross-bus move of a GROUPED rider is rerouted into a whole-group cascade
/// ([TourController.moveGroupToBus]), which can legitimately refuse (the
/// destination cannot hold the party) and, when it succeeds, re-seats everyone
/// at ENGINE-chosen berths rather than the seat the operator tapped. Both of
/// those are invisible in a `Future<void>`, and on a locked tour an invisible
/// failure means the family is never re-notified and turns up at the wrong bus.
enum SeatMoveOutcome {
  /// The passenger is now on the exact seat that was asked for.
  moved,

  /// The mover's whole group was re-seated together on the destination bus at
  /// engine-chosen berths. The move DID happen — but not onto the requested
  /// seat, so the caller must say so rather than report a plain "moved".
  groupReseated,

  /// Nothing moved. The passenger is still exactly where they were, and the
  /// reason has already been surfaced to the operator.
  failed,

  /// The operator backed out of a confirmation. Nothing moved and nothing is
  /// wrong, so no error is shown — but it is NOT a success either.
  cancelled,
}

class TourController extends GetxController {
  final tours = <Tour>[].obs;
  final isLoading = false.obs;
  /// Monotonic load generation — a stale in-flight fetch must not paint
  /// [hasError] over a newer success (cold-start auth reload + online ever
  /// can overlap the first attempt).
  int _loadGeneration = 0;
  final hasError = false.obs;
  final errorMessage = ''.obs;

  /// Last seating plan produced by [fillTour], keyed by tourId. The seat
  /// Overview screen reads this to render the "N need your decision" chip
  /// without re-running the engine on every rebuild. Reactive so a fresh
  /// fillTour repaints any observer. Cleared entry is fine — absence just
  /// means "no plan generated yet this session".
  final lastPlanByTour = <String, SeatingPlan>{}.obs;

  /// Exceptions from the most recent [fillTour] for [tourId] (empty when no
  /// plan has been generated this session).
  List<SeatingException> exceptionsForTour(String tourId) =>
      lastPlanByTour[tourId]?.exceptions ?? const <SeatingException>[];

  /// Memoization cache for [capacityFor]: the last [computeTourCapacity] result
  /// per tourId, paired with the cheap content signature it was computed for.
  /// Plain (non-reactive) map — capacity is a pure function of `tours`, so any
  /// observer already rebuilds via `tours.refresh()`; this only avoids re-running
  /// the engine on each of those rebuilds. Survives until the tour's signature
  /// changes (recompute) or the controller is disposed.
  final _capacityCache = <String, ({int sig, TourCapacity capacity})>{};

  /// Memoized [computeTourCapacity] for [t].
  ///
  /// [computeTourCapacity] runs the full [SeatingEngine.propose] — expensive, and
  /// the dashboard calls it once per tour on every `tours.refresh()` (each seat
  /// tap, each realtime event). This caches the result keyed by [t.id] + a cheap
  /// [_capacitySignature] that flips whenever anything the engine reads changes
  /// (buses, passengers, seats, status). A cache hit returns the prior snapshot
  /// untouched; a miss (first call, or any signature change) recomputes and
  /// stores. Same semantics as calling [computeTourCapacity] directly — only the
  /// redundant recomputes are removed.
  ///
  /// Correctness-first: the signature folds every field [computeTourCapacity]
  /// reads, so when in doubt it recomputes rather than serve a stale snapshot.
  /// Pass the SAME [Tour] instance the UI holds (e.g. from [getTour] / the
  /// `tours` list) so the signature reflects the live state being rendered.
  TourCapacity capacityFor(Tour t) {
    final sig = _capacitySignature(t);
    final hit = _capacityCache[t.id];
    if (hit != null && hit.sig == sig) return hit.capacity;
    final capacity = computeTourCapacity(t);
    _capacityCache[t.id] = (sig: sig, capacity: capacity);
    return capacity;
  }

  /// Memoization cache for [actualCapacityFor], mirroring [_capacityCache].
  final _actualCapacityCache =
      <String, ({int sig, ActualCapacity capacity})>{};

  /// Memoized [computeActualCapacity] for [t].
  ///
  /// Cheaper than [capacityFor] — it never runs the engine — but far from free:
  /// it walks every bus grid and every passenger's seats, and the surfaces that
  /// want it (the tour-overview meter, each bus row, the seat-assignment leg
  /// meter) sit inside `Obx` blocks that rebuild on every seat tap and every
  /// realtime event. Sharing [_capacitySignature] is safe because that
  /// fingerprint already folds a strict SUPERSET of what
  /// [computeActualCapacity] reads: bus grids, legacy seat counts, and each
  /// passenger's assigned seats and legs.
  ActualCapacity actualCapacityFor(Tour t) {
    final sig = _capacitySignature(t);
    final hit = _actualCapacityCache[t.id];
    if (hit != null && hit.sig == sig) return hit.capacity;
    final capacity = computeActualCapacity(t);
    _actualCapacityCache[t.id] = (sig: sig, capacity: capacity);
    return capacity;
  }

  /// True once every bus on [tourId] has had its `layout` jsonb resolved —
  /// fetched, or confirmed absent on the server.
  ///
  /// Cold start ships buses WITHOUT their grids, so `bus.layout == null` is
  /// ambiguous on its own: it means EITHER "still loading" or "this bus genuinely
  /// has no seat map". Surfaces that would otherwise render a hard, wrong
  /// conclusion from that null — an empty seat chart, or a capacity-shortfall
  /// banner claiming riders will not fit when the engine simply has no grid to
  /// place them on — gate on this instead.
  bool layoutsLoadedFor(String tourId) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    return tour.buses.every((b) => _layoutFetchedBusIds.contains(b.id));
  }

  /// Cheap structural fingerprint of every input [computeTourCapacity] reads —
  /// computed WITHOUT running the engine, so it's safe to evaluate on each
  /// rebuild. Folds the tour status plus, per bus, its id and seat-grid
  /// (seatId + seatType) and, per passenger, the fields that move the plan:
  /// assigned seats, request-line seat-types + legs (drives leg-aware free), the
  /// waitlist / journeyDone flags the engine + decision filter gate on, and the
  /// priorityStatus the engine gates lower-berth / ordering placement on.
  /// Order-stable (we fold list order, which the engine preserves). A collision
  /// would have to match all of these while changing the plan — astronomically
  /// unlikely, and a stale read self-heals on the next genuine change.
  int _capacitySignature(Tour t) {
    var h = t.status.index;
    for (final b in t.buses) {
      // totalSeatsLegacy is folded because capacity now FALLS BACK to it for a
      // bus with no usable grid (see [busBerths]). Without it, a bus whose
      // layout jsonb arrives mid-session — grid empty, then 37 seats — could
      // keep serving the memoized snapshot taken while it read as empty.
      h = Object.hash(h, b.id, b.totalSeatsLegacy);
      for (final cell in b.layout?.grid ?? const []) {
        // cell.reserved is folded because computeTourCapacity subtracts held
        // berths and skips reserved cells — without it, toggling a seat to
        // reserved/held left the memoized capacity (dashboard hero meter + the
        // "needs decision" badge) stale until some unrelated change bumped the
        // signature. position is already encoded in seatId (DL vs DU).
        h = Object.hash(h, cell.seatId, cell.seatType, cell.reserved);
      }
    }
    for (final p in t.passengers) {
      // priorityStatus is folded in because the engine gates placement on
      // isPriorityApproved (lower-berth reservation, seating order) — a
      // priority-only change moves the plan, so it must invalidate the cache or
      // the "N need your decision" badge goes stale. priorityReason is NOT
      // folded: the engine never reads it, so a reason edit shouldn't recompute.
      h = Object.hash(h, p.id, p.isWaitlisted, p.journeyDone, p.priorityStatus);
      for (final a in p.assignedSeats) {
        // a.leg is folded because capacity counts per seat via a.leg ?? the
        // coarse leg; a leg change (e.g. a request-leg edit re-stamp) with the
        // same seatId must invalidate the memoized capacity.
        h = Object.hash(h, a.busId, a.seatId, a.leg);
      }
      for (final l in p.requestLines) {
        h = Object.hash(h, l.seatType, l.leg, l.qty);
      }
    }
    return h;
  }

  /// Frozen per-leg seat charts, keyed by tourId. Populated lazily by
  /// [loadSeatSnapshots] (when a past-tour seat view opens) and written through
  /// by [_captureSeatSnapshot] so a freshly-captured leg is visible without a
  /// round-trip. Never rides along with the tours-list fetch.
  final RxMap<String, List<TourSeatSnapshot>> _seatSnapshots =
      <String, List<TourSeatSnapshot>>{}.obs;

  SyncService get _sync => Get.find<SyncService>();
  AuthController get _auth => Get.find<AuthController>();
  RealtimeService get _realtime => Get.find<RealtimeService>();

  /// Sends the customer-facing WhatsApp "booking confirmed" greeting for ONE
  /// passenger and reports whether Meta accepted it. Held as a field (rather
  /// than a direct `WhatsAppOutbound()` call) so tests can stub the network;
  /// production uses the real Cloud API sender. Invoked by
  /// [_confirmAndNotifyOnSeat] when a seat is placed on a rider who was never
  /// confirmed through the Requests screen.
  Future<bool> Function(Tour tour, Passenger passenger) confirmedSender =
      _sendConfirmedGreeting;

  static Future<bool> _sendConfirmedGreeting(Tour tour, Passenger p) async {
    final res = await WhatsAppOutbound().sendConfirmed(tour: tour, passenger: p);
    return res.anySent;
  }

  StreamSubscription<DataChangedEvent>? _realtimeSub;

  /// Tours whose passengers/buses/groups are actually loaded.
  ///
  /// Cold start hydrates RUNNING tours only — an archived tour's roster is
  /// fetched the moment it is opened ([ensureTourHydrated]). Without this set
  /// an un-hydrated archived tour is indistinguishable from an empty one, and
  /// the UI would render "0 passengers" for a tour that has fifty.
  final _hydratedTourIds = <String>{};

  /// Bus ids for which we have already attempted a layout fetch (including
  /// buses whose layout is legitimately null). Prevents refetch loops on 2G.
  final _layoutFetchedBusIds = <String>{};

  /// In-flight hydrations, so two widgets opening the same tour at once
  /// share one request instead of racing two down a 2G link.
  final _hydrationsInFlight = <String, Future<void>>{};
  final _layoutFetchesInFlight = <String, Future<void>>{};
  Timer? _refreshDebounce;

  /// Microtask flag for coalescing burst notifications. Without this, a
  /// single seat tap (which can fan out to 1-3 server-side row changes,
  /// each arriving as its own realtime event) would fire Obx 1-3 times
  /// — every observer of `tours` would rebuild for each event. With it,
  /// the burst collapses to one rebuild per microtask.
  bool _notifyScheduled = false;

  /// Mark the `tours` list as dirty and schedule a single notification.
  /// Multiple calls within the same microtask collapse to one Obx fire.
  /// Mutate `tours.value` (the underlying List) before calling this —
  /// `tours[idx] = x` style mutations are NOT used because the RxList
  /// notifies on every assignment, defeating the coalescing.
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      tours.refresh();
    });
  }

  @override
  void onInit() {
    super.onInit();
    // ignore: unawaited_futures
    _bootstrapLoad();
    _subscribeToChanges();
  }

  /// Cold-start entry: wait for [AuthController.whenRestored] so the first
  /// fetch runs with JWT + admin owner scope, then load. If that still fails
  /// with an empty list, automatically retry once — the same action the user
  /// was forced to take on every launch when connectivity/auth raced.
  Future<void> _bootstrapLoad() async {
    await _awaitAuthRestored();
    await _loadTours();
    if (hasError.value && tours.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (hasError.value && tours.isEmpty) {
        await _loadTours();
      }
    }
  }

  Future<void> _awaitAuthRestored() async {
    if (!Get.isRegistered<AuthController>()) return;
    try {
      await Get.find<AuthController>().whenRestored.timeout(
        const Duration(seconds: 12),
      );
    } on TimeoutException {
      // Same bound as splash — proceed with whatever auth state we have.
    }
  }

  @override
  void onClose() {
    _realtimeSub?.cancel();
    _refreshDebounce?.cancel();
    super.onClose();
  }

  void _subscribeToChanges() {
    // Refresh whenever we come back online — covers offline → online edges
    // where realtime might have missed events while the socket was down.
    ever(_sync.isOnline, (online) {
      if (online) _scheduleRefresh();
    });

    // Live updates: apply each Postgres change directly to local state.
    // The previous implementation triggered a full debounced refetch
    // (3 round-trips: tours + passengers + buses) on every event, which
    // thrashes hard when two devices are writing at the same time. Now
    // we mutate the matching row in place; we only fall back to a full
    // refetch when the payload lacks information we need (e.g. a
    // passenger event arrived before its parent tour) or anything in
    // the incremental path throws.
    _realtimeSub = _realtime.events.listen(_applyRealtimeEvent);
  }

  /// Coalesce bursts of realtime events into a single fetch — used by
  /// connectivity-recovery edges and as the safety net when an
  /// incremental apply can't resolve a parent row locally.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), _loadTours);
  }

  void _applyRealtimeEvent(DataChangedEvent event) {
    try {
      switch (event.table) {
        case LiveTable.tours:
          _applyTourEvent(event);
        case LiveTable.passengers:
          _applyPassengerEvent(event);
        case LiveTable.buses:
          _applyBusEvent(event);
        case LiveTable.bookingRequests:
          // Customer-side audit row. The companion passenger row's own
          // realtime event is what carries the data we render, so we
          // can ignore this stream entirely from the tour controller.
          return;
      }
    } catch (e, st) {
      // Defensive: if a payload has an unexpected shape, drop back to
      // the old behaviour rather than leaving the local cache out of
      // sync with the server.
      dev.log('realtime apply failed: $e\n$st', name: 'TourController');
      _scheduleRefresh();
    }
  }

  void _applyTourEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final id = event.oldRow?['id']?.toString();
      if (id == null) return;
      final before = raw.length;
      raw.removeWhere((t) => t.id == id);
      if (raw.length != before) _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final id = row['id']?.toString();
    if (id == null) return;

    final idx = raw.indexWhere((t) => t.id == id);
    if (idx < 0) {
      // Brand-new tour. Nested passengers/buses arrive via their own
      // realtime events; in the meantime we render the tour with empty
      // lists, which is what the server actually has at this instant.
      raw.add(Tour.fromMap(row));
      _scheduleNotify();
      return;
    }
    // Update — preserve the nested passengers/buses we already hold so
    // we don't drop them just because they're not in the top-level
    // tours payload.
    final existing = raw[idx];
    raw[idx] = Tour.fromMap(
      row,
    ).copyWith(buses: existing.buses, passengers: existing.passengers);
    _scheduleNotify();
  }

  void _applyPassengerEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final tourId = event.oldRow?['tour_id']?.toString();
      final passengerId = event.oldRow?['id']?.toString();
      if (tourId == null || passengerId == null) return;
      final idx = raw.indexWhere((t) => t.id == tourId);
      if (idx < 0) return;
      final t = raw[idx];
      final next = t.passengers.where((p) => p.id != passengerId).toList();
      if (next.length == t.passengers.length) return;
      raw[idx] = t.copyWith(passengers: next);
      _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final tourId = row['tour_id']?.toString();
    final pid = row['id']?.toString();
    if (tourId == null || pid == null) return;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) {
      // Parent tour not loaded yet — likely racing its own INSERT. Fall
      // back to a debounced refetch so we don't drop the passenger.
      _scheduleRefresh();
      return;
    }
    final t = raw[idx];
    final newPassenger = Passenger.fromMap(row);
    final next = List<Passenger>.from(t.passengers);
    final pIdx = next.indexWhere((p) => p.id == pid);
    // A customer-cancelled passenger (migration 034) is kept in the DB but must
    // leave the active roster — treat a cancel like a delete for the in-memory
    // tour so capacity/roster stop counting it. Nothing to do if it was never
    // in the active list.
    if (newPassenger.isCancelled) {
      if (pIdx < 0) return;
      next.removeAt(pIdx);
      raw[idx] = t.copyWith(passengers: next);
      _scheduleNotify();
      return;
    }
    if (pIdx < 0) {
      next.add(newPassenger);
    } else {
      next[pIdx] = newPassenger;
    }
    raw[idx] = t.copyWith(passengers: next);
    _scheduleNotify();
  }

  void _applyBusEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final tourId = event.oldRow?['tour_id']?.toString();
      final busId = event.oldRow?['id']?.toString();
      if (tourId == null || busId == null) return;
      final idx = raw.indexWhere((t) => t.id == tourId);
      if (idx < 0) return;
      final t = raw[idx];
      final next = t.buses.where((b) => b.id != busId).toList();
      if (next.length == t.buses.length) return;
      raw[idx] = t.copyWith(buses: next);
      _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final tourId = row['tour_id']?.toString();
    final bid = row['id']?.toString();
    if (tourId == null || bid == null) return;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) {
      _scheduleRefresh();
      return;
    }
    final t = raw[idx];
    final newBus = Bus.fromMap(row);
    final next = List<Bus>.from(t.buses);
    final bIdx = next.indexWhere((b) => b.id == bid);
    if (bIdx < 0) {
      next.add(newBus);
    } else {
      next[bIdx] = newBus;
    }
    raw[idx] = t.copyWith(buses: next);
    _scheduleNotify();
  }

  /// Tour visibility scope for the current viewer:
  /// - An authenticated admin sees ONLY their own tours (an explicit `owner_id`
  ///   filter on top of RLS), under a per-admin cache key so an earlier
  ///   anonymous "all public tours" fetch (done at app start, before login)
  ///   can't bleed into the admin's list.
  /// - A customer / anonymous viewer sees ALL public tours
  ///   (RLS `tours_public_read`).
  String get _tourCacheKey {
    final adminId = _auth.currentAdmin.value?.id;
    return _auth.isAdmin && adminId != null
        ? 'tours_admin_$adminId'
        : 'tours_public';
  }

  Map<String, String>? get _tourFilters {
    final adminId = _auth.currentAdmin.value?.id;
    return _auth.isAdmin && adminId != null ? {'owner_id': adminId} : null;
  }

  Future<void> _loadTours() async {
    final gen = ++_loadGeneration;
    isLoading.value = true;
    hasError.value = false;
    try {
      // ── Phase 1: tour headers only ─────────────────────────────────
      // On 2G the roster+layout payload dwarfs the tour list. Paint titles
      // as soon as headers arrive so Home is never a blank spinner for the
      // full relation round-trip.
      List<Map<String, dynamic>> tourRows;
      try {
        tourRows = await _withTourReadRetry(
          () => _sync.fetchTourRows(
            filters: _tourFilters,
            orderBy: 'created_at',
          ),
        );
      } catch (e) {
        if (gen != _loadGeneration) return;
        if (tours.isEmpty) {
          hasError.value = true;
          errorMessage.value = SyncService.describeReadError(e);
        } else {
          AppSnackBar.warning(tr('errors.refresh_showing_cached'));
        }
        isLoading.value = false;
        return;
      }
      if (gen != _loadGeneration) return;

      final pendingIds = await _sync.pendingEntityIdsForTable('tours');
      if (gen != _loadGeneration) return;

      final headerTours = tourRows.map(Tour.fromMap).toList();
      final serverIds = headerTours.map((t) => t.id).toSet();
      final preserved = tours
          .where((t) => !serverIds.contains(t.id) && pendingIds.contains(t.id))
          .toList();

      // Keep already-loaded rosters for tours that are still on the server so a
      // refresh doesn't blank the dashboard while Phase 2 runs.
      final priorById = {for (final t in tours) t.id: t};
      final mergedHeaders = [
        for (final t in headerTours)
          if (priorById[t.id] case final prior?)
            t.copyWith(
              passengers: prior.passengers,
              buses: prior.buses,
              groups: prior.groups,
            )
          else
            t,
        ...preserved,
      ];
      tours.assignAll(mergedHeaders);
      // Headers are enough to leave the error/empty state — roster follows.
      isLoading.value = false;

      // ── Phase 2: passengers + buses (NO layout jsonb) ──────────────
      final scope = coldStartHydrationScope(tourRows);
      final rel = await _sync.fetchRelationsForTours(scope);
      if (gen != _loadGeneration) return;

      // ignore: invalid_use_of_protected_member
      final raw = tours.value;
      for (final tourId in scope) {
        final idx = raw.indexWhere((t) => t.id == tourId);
        if (idx < 0) continue;
        final passengers = rel.passengers
            .where((m) => m['tour_id'] == tourId && m['cancelled_at'] == null)
            .map(Passenger.fromMap)
            .toList();
        final buses = rel.buses
            .where((m) => m['tour_id'] == tourId)
            .map(Bus.fromMap)
            .toList();
        final groups = rel.groups
            .where((m) => m['tour_id'] == tourId)
            .map(PassengerGroup.fromMap)
            .toList();
        // New bus rows from the server replace prior ones; clear layout-fetched
        // marks for buses that disappeared so ids don't leak forever.
        for (final b in raw[idx].buses) {
          if (!buses.any((n) => n.id == b.id)) {
            _layoutFetchedBusIds.remove(b.id);
          }
        }
        // Preserve layouts we already paid for on a prior prefetch.
        final withLayouts = [
          for (final b in buses)
            if (priorById[tourId]
                    ?.buses
                    .where((x) => x.id == b.id && x.layout != null)
                    .firstOrNull
                case final priorBus?)
              b.copyWith(layout: priorBus.layout)
            else
              b,
        ];
        raw[idx] = raw[idx].copyWith(
          passengers: passengers,
          buses: withLayouts,
          groups: groups,
        );
      }
      _scheduleNotify();

      _hydratedTourIds
        ..clear()
        ..addAll(scope);

      await _archiveExpiredTours();
      await _applyRememberedPriority();

      // ── Phase 3: layout jsonb in the background ────────────────────
      // Dashboard capacity / charts need grids, but they must not gate first
      // paint. Prefetch for hydrated (running) tours only.
      // ignore: unawaited_futures
      _prefetchLayoutsForHydratedTours();
    } catch (e) {
      if (gen != _loadGeneration) return;
      if (tours.isEmpty) {
        hasError.value = true;
        errorMessage.value = SyncService.describeReadError(e);
      } else {
        AppSnackBar.warning(tr('errors.refresh_showing_cached'));
      }
    }
    if (gen == _loadGeneration) isLoading.value = false;
  }

  /// Transient-safe wrapper around a single tour-header read (mirrors
  /// smartFetch retry policy without the relations payload). Never retries
  /// auth / missing-table / permanent PostgREST errors — those only burn the
  /// 2G radio and delay the error UI.
  Future<List<Map<String, dynamic>>> _withTourReadRetry(
    Future<List<Map<String, dynamic>>> Function() action,
  ) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await action();
      } catch (e) {
        last = e;
        if (attempt == 2 ||
            !retry.isRetryable(e, retryOnTimeout: true)) {
          break;
        }
        await Future<void>.delayed(
          Duration(milliseconds: (400 * math.pow(3, attempt)).round()),
        );
      }
    }
    Error.throwWithStackTrace(last!, StackTrace.current);
  }

  Future<void> _prefetchLayoutsForHydratedTours() async {
    for (final id in _hydratedTourIds.toList()) {
      try {
        await ensureBusLayoutsForTour(id);
      } catch (e, st) {
        dev.log('layout prefetch failed for $id: $e\n$st', name: 'TourController');
      }
    }
  }

  /// Auto-ARCHIVES tours whose trip has been over for more than a day so the
  /// active list stays clean — without ever destroying data. The cutoff is
  /// `(returnDate ?? departureDate) + 1 day` (compared at local midnight): a
  /// tour returning on the 5th drops out of "active" from the 6th onward but
  /// stays fully viewable in the archive (chart, money, passengers intact).
  ///
  /// Only the signed-in admin owner archives; a customer/anonymous viewer
  /// never writes (RLS would reject it anyway). Each archive reuses
  /// [completeTour], so a failure surfaces its own snackbar and the loop keeps
  /// sweeping the rest rather than aborting.
  Future<void> _archiveExpiredTours() async {
    if (!_auth.isAdmin) return;
    final now = DateTime.now();
    // ARCHIVE (soft), never hard-delete. Auto-deleting a tour on load would
    // permanently destroy its passengers, seat assignments and money records
    // with no undo on the first app open after the return date — a clock skew
    // or a mistyped date would silently wipe real financial data. Instead we
    // flip expired-but-still-active tours to `completed` so they drop out of
    // the active list while every record stays viewable in the archive.
    final expiredIds = tours
        .where((t) {
          if (t.status == TourStatus.completed) return false;
          final end = t.returnDate ?? t.departureDate;
          final cutoff = DateTime(
            end.year,
            end.month,
            end.day,
          ).add(const Duration(days: 1));
          return now.isAfter(cutoff);
        })
        .map((t) => t.id)
        .toList();
    for (final id in expiredIds) {
      try {
        await completeTour(id);
      } catch (_) {
        // completeTour surfaces its own error; keep sweeping the rest.
      }
    }
  }

  /// Auto-restores priority for returning customers: if a passenger has no
  /// explicit decision yet (status `none`/`requested`) but their phone is
  /// remembered as `approved` from a past tour, approve them. Idempotent —
  /// once approved the row is skipped on later loads — and never overrides an
  /// explicit `approved`/`declined` the agent set on THIS tour. Admin-only;
  /// no-op until [CustomerMemoryController] has loaded.
  /// Guards against re-entry: [setPassengerPriority] calls `refreshTours()` on
  /// a write failure, which would loop back into this sweep.
  bool _applyingRememberedPriority = false;

  Future<void> _applyRememberedPriority() async {
    if (_applyingRememberedPriority) return;
    if (!_auth.isAdmin) return;
    if (!Get.isRegistered<CustomerMemoryController>()) return;
    final memory = Get.find<CustomerMemoryController>();
    _applyingRememberedPriority = true;
    try {
      for (final tour in tours.toList()) {
        if (tour.status == TourStatus.completed) continue;
        for (final p in tour.passengers) {
          if (p.priorityStatus == PriorityStatus.approved ||
              p.priorityStatus == PriorityStatus.declined) {
            continue;
          }
          if (memory.forPhone(p.phone)?.priorityStatus ==
              PriorityStatus.approved) {
            try {
              await setPassengerPriority(tour.id, p.id, true);
            } catch (_) {
              // Best-effort; a failed write retries on the next load.
            }
          }
        }
      }
    } finally {
      _applyingRememberedPriority = false;
    }
  }

  /// Force a fresh fetch from Supabase. Used by pull-to-refresh and
  /// by callers that just wrote data and want it reflected in the UI.
  /// Bypasses the 2-minute smartFetch cache by invalidating it first.
  Future<void> refreshTours() async {
    await _sync.invalidateCache(_tourCacheKey);
    await _loadTours();
  }

  // Tour CRUD
  Future<Tour> createTour({
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    // Tour-level price is no longer collected at creation — pricing is set
    // per-bus during bus creation. Kept (defaulting to 0) so the model field
    // and edit-tour flow stay intact; add_bus only prefills when it's > 0.
    double pricePerSeat = 0,
    String? description,
    String? broadcastMessage,
    String? broadcastImageUrl,
  }) async {
    // RLS on `tours` requires owner_id = auth.uid(). Refuse to queue an
    // insert without an admin session — otherwise we'd write a row with a
    // null owner_id that RLS rejects on every retry until the 5-retry cap.
    final adminId = _auth.currentAdmin.value?.id;
    if (adminId == null) {
      AppSnackBar.error(
        tr('errors.sign_in_to_create_tour'),
        title: tr('errors.sign_in_required'),
      );
      throw StateError('createTour requires an authenticated admin session');
    }

    final tour = Tour(
      title: title,
      fromCity: fromCity,
      toCity: toCity,
      departureDate: departureDate,
      departureTime: departureTime,
      returnDate: returnDate,
      returnTime: returnTime,
      pricePerSeat: pricePerSeat,
      description: description,
      broadcastMessage: broadcastMessage,
      broadcastImageUrl: broadcastImageUrl,
      createdBy: _auth.userPhone.value,
    );

    final tourData = {...tour.toMap(), 'owner_id': adminId};
    await _write(
      // Optimistic add so the UI feels instant; on failure _write snaps back
      // to server truth, which drops the phantom (it was never persisted).
      optimistic: () {
        tours.add(tour);
        tours.refresh();
      },
      persist: () =>
          _sync.smartInsert(table: 'tours', entityId: tour.id, data: tourData),
      failure: tr('errors.create_tour'),
    );
    return tour;
  }

  Future<void> editTour({
    required String tourId,
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    required double pricePerSeat,
    String? description,
  }) async {
    await _updateTour(
      tourId,
      (t) => Tour(
        id: t.id,
        title: title,
        fromCity: fromCity,
        toCity: toCity,
        departureDate: departureDate,
        departureTime: departureTime,
        returnDate: returnDate,
        returnTime: returnTime,
        pricePerSeat: pricePerSeat,
        description: description,
        status: t.status,
        handlerId: t.handlerId,
        createdBy: t.createdBy,
        isPublic: t.isPublic,
        buses: t.buses,
        passengers: t.passengers,
        createdAt: t.createdAt,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Tour? getTour(String id) {
    final idx = tours.indexWhere((t) => t.id == id);
    return idx >= 0 ? tours[idx] : null;
  }

  /// A `(busId, seatId) -> SeatType?` lookup over [tour]'s bus layouts, used to
  /// feed [resolveAssignmentLegs] when persisting manually-placed / moved seats
  /// so each berth is stamped with the leg of the request line it satisfies.
  SeatType? Function(String, String) _cellTypeLookup(Tour tour) =>
      (busId, seatId) {
        final bus = tour.buses.where((b) => b.id == busId).firstOrNull;
        for (final c in bus?.layout?.grid ?? const <SeatCell>[]) {
          if (c.seatId == seatId) return c.seatType;
        }
        return null;
      };

  Future<void> deleteTour(String id) async {
    // Snapshot returning-customer memory (priority + travel companions) BEFORE
    // the tour — and its cascade-deleted passenger rows — are gone. Best-effort:
    // never block a delete on the memory write.
    final tour = getTour(id);
    if (tour != null && Get.isRegistered<CustomerMemoryController>()) {
      try {
        await Get.find<CustomerMemoryController>().captureFromTour(tour);
      } catch (_) {}
    }

    await _write(
      optimistic: () => tours.removeWhere((t) => t.id == id),
      persist: () => _sync.smartDelete(table: 'tours', entityId: id),
      failure: tr('errors.delete_tour'),
    );
  }

  // Status Transitions
  Future<void> updateStatus(String tourId, TourStatus status) async {
    await _updateTour(tourId, (t) => t.copyWith(status: status));
  }

  Future<void> startCollecting(String tourId) =>
      updateStatus(tourId, TourStatus.collecting);

  Future<void> markBusBooked(String tourId) =>
      updateStatus(tourId, TourStatus.busBooked);

  Future<void> startAssigning(String tourId) =>
      updateStatus(tourId, TourStatus.assigning);

  Future<void> lockTour(String tourId) =>
      updateStatus(tourId, TourStatus.locked);

  /// Mark a tour completed (also the auto-archive path for expired tours).
  ///
  /// Before flipping status we freeze the seat history so a past tour keeps its
  /// chart. Both captures are best-effort (their own try/catch swallows any
  /// failure), so the status transition always proceeds:
  /// - outbound, `overwriteIfExists: false` — covers tours that expire without
  ///   a GO-leg completion (seats still intact) and never clobbers the
  ///   authoritative pre-wipe capture from [completeOutboundLeg].
  /// - return, `overwriteIfExists: true` — round-trip + return-only riders
  ///   (`.ret`); skipped automatically when empty (one-way tours).
  Future<void> completeTour(String tourId) async {
    await _captureSeatSnapshot(tourId, SnapshotLeg.outbound,
        overwriteIfExists: false);
    await _captureSeatSnapshot(tourId, SnapshotLeg.return_,
        overwriteIfExists: true);
    await updateStatus(tourId, TourStatus.completed);
  }

  /// Complete the OUTBOUND (GO) leg of a tour: every GO-only (outboundOnly)
  /// passenger has finished their only leg, so free their seats (the return
  /// chart then shows them empty) and mark them [Passenger.journeyDone] — the
  /// record is KEPT, they just drop off the active roster. Round-trip and
  /// return-only passengers are untouched. Returns how many were cleared.
  Future<int> completeOutboundLeg(String tourId) async {
    final tour = getTour(tourId);
    if (tour == null) return 0;

    // Freeze the authoritative GO chart BEFORE the optimistic clear below wipes
    // outbound-only riders' seats. This must run even when there are no
    // outbound-only riders to clear (the loop below adds nothing): completing
    // the leg should always preserve the GO chart. Best-effort & idempotent on
    // the (tour_id, leg) key — overwrite so a re-run reflects the latest state.
    await _captureSeatSnapshot(tourId, SnapshotLeg.outbound,
        overwriteIfExists: true);

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final p in tour.passengers) {
          if (p.tripType != TripType.outboundOnly || p.journeyDone) continue;
          Passenger? updated;
          _updatePassengerLocal(tourId, p.id, (cur) {
            updated = cur.copyWith(assignedSeats: const [], journeyDone: true);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.save_passenger'),
    );
    return changed.length;
  }

  // ── Seat-history snapshots ────────────────────────────────

  /// Freeze the LIVE per-leg seat chart for [tourId] and upsert it into
  /// `tour_seat_snapshots`. This is the one piece of seat data the live editor
  /// destroys (GO seats are recycled for the return leg), so we capture it at
  /// the leg/tour completion edges and keep it for the past-tour history view.
  ///
  /// The occupant per seat is resolved with [seatOccupantsForBus]: for
  /// [SnapshotLeg.outbound] we take each seat's `.go` rider, for
  /// [SnapshotLeg.return_] its `.ret` rider. Buses with no captured seats are
  /// skipped, and a snapshot with zero seats across all buses is NOT written
  /// (e.g. a one-way tour has no return occupants).
  ///
  /// The natural key is `(tour_id, leg)`, so we use a deterministic entity id
  /// `'<tourId>_<leg.wire>'` to make the upsert idempotent — an existing row is
  /// updated in place, never duplicated. When [overwriteIfExists] is false an
  /// already-present snapshot is left untouched (so a later, lossy re-capture
  /// can't clobber the authoritative pre-wipe chart).
  ///
  /// Best-effort by contract: the whole body is guarded; any failure (including
  /// a missing migration) is swallowed and logged, NEVER rethrown — capturing
  /// history must not break a completion.
  Future<void> _captureSeatSnapshot(String tourId, SnapshotLeg leg,
      {required bool overwriteIfExists}) async {
    try {
      final tour = getTour(tourId);
      if (tour == null) return;

      // Is there already a stored snapshot for this (tourId, leg)? Drives both
      // the don't-clobber guard and the insert-vs-update choice below.
      final existing = await loadSeatSnapshots(tourId);
      final hasExisting = existing.any((s) => s.leg == leg);
      if (hasExisting && !overwriteIfExists) return;

      // Build the per-leg chart from the LIVE tour; null means nothing occupied
      // for this leg (e.g. a one-way tour has no return riders) — skip storing.
      final snapshot = buildSeatSnapshot(
        tourId: tourId,
        leg: leg,
        buses: tour.buses,
        passengers: tour.passengers,
        capturedAt: DateTime.now(),
      );
      if (snapshot == null) return;

      // Deterministic id over the natural (tour_id, leg) key keeps the upsert
      // idempotent; include it in the insert payload so the row id matches.
      final entityId = '${tourId}_${leg.wire}';
      final data = snapshot.toMap();
      if (hasExisting) {
        await _sync.smartUpdate(
          table: 'tour_seat_snapshots',
          entityId: entityId,
          data: data,
        );
      } else {
        await _sync.smartInsert(
          table: 'tour_seat_snapshots',
          entityId: entityId,
          data: {'id': entityId, ...data},
        );
      }

      // Write through to the in-memory cache so a freshly-opened history view
      // sees this leg without waiting on a refetch.
      final cached = List<TourSeatSnapshot>.from(_seatSnapshots[tourId] ?? const [])
        ..removeWhere((s) => s.leg == leg)
        ..add(snapshot);
      _seatSnapshots[tourId] = cached;
    } catch (e, st) {
      // Best-effort: history capture must never break a completion.
      dev.log('seat snapshot capture failed: $e\n$st', name: 'TourController');
    }
  }

  /// Lazy-load the frozen seat charts for [tourId] (used by the past-tour seat
  /// history view). Returns the in-memory cache when present, otherwise fetches
  /// from `tour_seat_snapshots` and caches the result.
  ///
  /// [SyncService.smartFetch] returns `[]` on any error or a missing table, so
  /// an un-applied migration yields an empty list rather than a crash — the
  /// history view degrades to its live-chart fallback.
  Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async {
    final cached = _seatSnapshots[tourId];
    if (cached != null) return cached;

    final result = await _sync.smartFetch(
      table: 'tour_seat_snapshots',
      cacheKey: 'seat_snapshots_$tourId',
      filters: {'tour_id': tourId},
      orderBy: 'captured_at',
      maxAge: 120000,
    );
    // History is best-effort: a failed/missing-table read degrades to the live
    // chart fallback, so we just take whatever rows came back.
    final snapshots = result.rows.map(TourSeatSnapshot.fromMap).toList();
    _seatSnapshots[tourId] = snapshots;
    return snapshots;
  }

  /// GO-only passengers still active (not yet cleared by [completeOutboundLeg]).
  /// Drives whether the "Complete GO leg" action is offered.
  int outboundOnlyActiveCount(String tourId) {
    final tour = getTour(tourId);
    if (tour == null) return 0;
    return tour.passengers
        .where((p) => p.tripType == TripType.outboundOnly && !p.journeyDone)
        .length;
  }

  /// Cancel the RETURN leg for the rider currently holding a return seat, so
  /// the agent can rebook it. A return-only rider never rode, so they are
  /// removed outright. A round-trip rider already rode the GO leg, so we keep
  /// their record but drop the return: convert every round-trip request line
  /// to outbound-only, clear their seats (freeing the berth), and flag
  /// journeyDone — exactly like completeOutboundLeg does for one-way riders.
  Future<void> cancelReturnSeat(String tourId, String passengerId) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    if (p == null) return;

    final updated = cancelReturnSeatTransform(p);
    if (updated == null) {
      // Return-only rider never rode the GO leg → remove outright.
      await removePassenger(tourId, passengerId);
      return;
    }

    // Round-trip / mixed rider: keep the record, demote to outbound-only. Same
    // optimistic-local + persist pattern as completeOutboundLeg.
    await _write(
      optimistic: () =>
          _updatePassengerLocal(tourId, passengerId, (_) => updated),
      persist: () => _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated.toMap(),
      ),
      failure: tr('errors.save_passenger'),
    );
  }

  // Passenger Management
  Future<void> addPassenger(
    String tourId,
    Passenger passenger, {
    bool overrideLock = false,
  }) async {
    // Bookings close to CUSTOMERS once the tour is locked/completed — but that
    // gate lives on the anonymous submit_booking_request RPC (migration 026/030),
    // the ONLY path a customer can create a request through. This controller
    // method is reached exclusively by admin/handler surfaces (Requests
    // "Add request", the return-ticket sheet), so its acceptsBookings check is a
    // soft default, not the customer gate — the organiser must still be able to
    // manage a locked tour by hand.
    //
    // [overrideLock] is the organiser's deliberate "add anyway", passed by every
    // real admin add path: the manual Add-request form (a late walk-in/phone
    // booking on a locked tour) and booking a new RETURN-only ticket into a freed
    // seat during the return phase. It skips ONLY the acceptsBookings gate;
    // everything else is identical.
    final existing = getTour(tourId);
    if (!overrideLock && existing != null && !existing.acceptsBookings) {
      AppSnackBar.error(tr('errors.bookings_closed'));
      return;
    }
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(passengers: [...t.passengers, passenger]),
      ),
      persist: () => _sync.smartInsert(
        table: 'passengers',
        entityId: passenger.id,
        data: passenger.toMap(),
      ),
      failure: tr('errors.save_passenger'),
    );
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.planning) {
      await updateStatus(tourId, TourStatus.collecting);
    }
  }

  Future<void> removePassenger(String tourId, String passengerId) => _write(
    optimistic: () => _updateTourLocal(
      tourId,
      (t) => t.copyWith(
        passengers: t.passengers.where((p) => p.id != passengerId).toList(),
      ),
    ),
    persist: () =>
        _sync.smartDelete(table: 'passengers', entityId: passengerId),
    failure: tr('errors.remove_passenger'),
  );

  Future<void> updatePassenger(String tourId, Passenger passenger) => _write(
    optimistic: () =>
        _updatePassengerLocal(tourId, passenger.id, (p) => passenger),
    persist: () => _sync.smartUpdate(
      table: 'passengers',
      entityId: passenger.id,
      data: passenger.toMap(),
    ),
    failure: tr('errors.update_passenger'),
  );

  /// Persist a passenger whose REQUEST LINES were just edited (e.g. a trip-leg
  /// change on the edit-request sheet). A leg edit must repropagate to money,
  /// capacity and tint — all of which read the per-seat [SeatAssignment.leg] —
  /// so re-derive every held seat's leg from the NEW request lines. The stored
  /// legs are NULLED first so the preserve-branch in [resolveAssignmentLegs]
  /// (which keeps an already-stamped leg) can't pin the STALE one; they are then
  /// re-stamped in request order. Without this, editing a rider's leg after
  /// their seats were assigned left the seats on their old leg and money/
  /// capacity read that stale leg (regression from the per-seat-leg pricing).
  Future<void> updatePassengerFromRequestEdit(
    String tourId,
    Passenger passenger,
  ) {
    final tour = getTour(tourId);
    var restamped = passenger;
    if (tour != null && passenger.assignedSeats.isNotEmpty) {
      final bare = [
        for (final a in passenger.assignedSeats)
          SeatAssignment(busId: a.busId, seatId: a.seatId, locked: a.locked),
      ];
      restamped = passenger.copyWith(
        assignedSeats: resolveAssignmentLegs(
          requestLines: passenger.requestLines,
          assigned: bare,
          cellTypeAt: _cellTypeLookup(tour),
        ),
      );
    }
    return updatePassenger(tourId, restamped);
  }

  /// Organiser DISMISSES a customer's cancellation request (migration 036) —
  /// keeps the passenger on the tour and clears the `cancel_requested_at` marker
  /// on BOTH the passenger row (this roster's badge/CTA) and the linked
  /// booking_request (the customer's pending-cancellation banner + re-request
  /// gate). The counterpart to approving (which removes the passenger). Routes
  /// through the SECURITY DEFINER RPC because the booking_request marker is not
  /// admin-writable directly; a server refusal reverts the optimistic clear.
  Future<void> dismissCancellationRequest(String tourId, String passengerId) =>
      _write(
        optimistic: () => _updatePassengerLocal(
          tourId,
          passengerId,
          (p) => p.copyWith(clearCancelRequested: true),
        ),
        persist: () async {
          final ok = await _sync.callRpcResult(
            'booking_request_admin_dismiss_cancel',
            {'p_passenger_id': passengerId},
          );
          if (ok != true) throw Exception('dismiss cancellation refused');
        },
        failure: tr('errors.dismiss_cancel'),
      );

  Future<void> updatePassengerPayment(
    String tourId,
    String passengerId,
    PaymentStatus status,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(paymentStatus: status);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_payment'),
    );
  }

  // Seat Assignment
  //
  // Both methods follow the same shape as the other CRUD operations: stage
  // an optimistic mutation locally, await the server write, and on failure
  // pull fresh state from the server + surface the error. Without the
  // try/refresh path, a silent server reject (RLS, JSON cast, etc.) leaves
  // the user staring at the OLD seats: optimistic mutation flashes the new
  // seats, then the next realtime refetch overwrites local with the
  // unchanged server row — making the change look reverted with no
  // explanation.

  /// Buses a passenger was just UNSEATED from, keyed `'tourId|passengerId'`.
  ///
  /// The natural way to transfer a rider between buses is two taps: free their
  /// seat on bus 1, then place them on bus 2. Step one leaves the money
  /// reconciler nothing to work with (there is no seat left to re-home the
  /// collection row onto), and by step two the passenger row no longer
  /// remembers bus 1 — so the placement looks like a FIRST seating and the
  /// carry-over is skipped. The rider is then billed the full destination fare
  /// while the cash they already handed over stays stranded on bus 1.
  ///
  /// This note is the missing link. It ONLY decides whether the reconcile is
  /// worth an on-demand collections read; when the money tables are already
  /// loaded the reconcile runs regardless, and the amounts it computes never
  /// depend on this map. Cleared the moment the passenger is seated again.
  final Map<String, Set<String>> _vacatedBusIds = {};

  static String _vacatedKey(String tourId, String passengerId) =>
      '$tourId|$passengerId';

  /// Bus ids [passengerId] currently holds a seat on, read BEFORE a write.
  Set<String> _busIdsHeldBy(String tourId, String passengerId) {
    final p = getTour(tourId)
        ?.passengers
        .firstWhereOrNull((x) => x.id == passengerId);
    return {for (final a in p?.assignedSeats ?? const []) a.busId};
  }

  /// Remember that [passengerId] just gave up every seat they held on [buses],
  /// so their next placement knows their money may still be parked there.
  void _rememberVacated(String tourId, String passengerId, Set<String> buses) {
    if (buses.isEmpty) return;
    final key = _vacatedKey(tourId, passengerId);
    _vacatedBusIds.update(
      key,
      (existing) => existing..addAll(buses),
      ifAbsent: () => {...buses},
    );
  }

  Future<void> assignSeats(
    String tourId,
    String passengerId,
    List<SeatAssignment> assignments,
  ) async {
    // F1 group cohesion: never let a manual assignment SPLIT a group across
    // buses. Empty assignments (= unseat) are always allowed; a same-bus
    // placement is allowed; and the FIRST member to be seated (no sibling
    // seated anywhere yet) is allowed. We only block when this write would put
    // a grouped passenger on one bus while a sibling already sits on a
    // DIFFERENT bus. Re-seating the whole group together goes through
    // [moveGroupToBus] instead.
    if (assignments.isNotEmpty &&
        _wouldSplitGroup(tourId, passengerId, assignments)) {
      AppSnackBar.warning(tr('seat.group_locked_msg'));
      return;
    }
    // Buses this passenger sits on RIGHT NOW, read before the write. Together
    // with anything remembered from an earlier unseat, this is what tells the
    // money reconcile whether cash may be parked on a bus the rider is leaving.
    final busesBefore = _busIdsHeldBy(tourId, passengerId);

    // Stamp each berth with the leg of the request line it satisfies, so a
    // booking split across one-way legs (e.g. "1 seater GO + 1 seater RET")
    // keeps the per-seat leg after manual placement / swap-in. Falls back to
    // the raw assignments when the tour/passenger can't be resolved (the empty
    // = unseat case carries no legs anyway).
    final tourForLegs = getTour(tourId);
    final pForLegs =
        tourForLegs?.passengers.firstWhereOrNull((p) => p.id == passengerId);
    final stamped = (tourForLegs != null && pForLegs != null)
        ? resolveAssignmentLegs(
            requestLines: pForLegs.requestLines,
            assigned: assignments,
            cellTypeAt: _cellTypeLookup(tourForLegs),
          )
        : assignments;
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(assignedSeats: stamped);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.save_seat_assignment'),
    );

    // Past this point the write landed (_write rethrows on failure).
    //
    // Everything the rider is walking away from: seats they held a moment ago
    // plus anything an earlier unseat parked in [_vacatedBusIds]. Clearing the
    // note here (and re-arming it below when they end up with no seats at all)
    // keeps it accurate for exactly one hand-off.
    final key = _vacatedKey(tourId, passengerId);
    final leaving = {...busesBefore, ...?_vacatedBusIds.remove(key)};
    final busesAfter = {for (final a in stamped) a.busId};

    if (assignments.isEmpty) {
      // Step one of a free-then-place transfer. There is no seat to re-home the
      // collection row onto yet, so a reconcile here is a guaranteed no-op —
      // remember the vacated bus instead and let the placement do the work.
      _rememberVacated(tourId, passengerId, leaving);
      return;
    }

    // The first real seat placement moves the tour into the "assigning" phase.
    // Without this the status machine stalled at `busBooked` forever, which in
    // turn left the per-tour Lock CTA permanently disabled (it gated on
    // `status == assigning`). Now seating progress is reflected in the
    // lifecycle and the lock gate.
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }
    // A seat placed from the chart on a not-yet-confirmed rider IS the
    // confirmation: flip the flag + fire the WhatsApp greeting, matching the
    // Requests "Confirm" button (which otherwise never runs on this path).
    await _confirmAndNotifyOnSeat(tourId, [passengerId]);

    // Carry the money with the rider. `moveSeat` has always done this; a plain
    // assignment never did, so the very natural "free the seat on bus 1, then
    // place them on bus 2" transfer left the collection row pointing at bus 1
    // and billed the rider the FULL destination fare instead of the difference.
    //
    // [crossedBus] is true only when this write actually takes the rider OFF a
    // bus they were on (directly, or via the unseat remembered above). That
    // keeps the reconcile's on-demand collections read off the common path —
    // a first-time placement can strand nothing, so it never pays for a fetch.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerId],
      crossedBus: leaving.difference(busesAfter).isNotEmpty,
    );
  }

  /// F1 group cohesion: re-seat [anchorPassengerId] AND every group sibling
  /// onto [destinationBusId] as ONE atomic move, so a group is always wholly on
  /// a single bus (within a bus, arrangement is free). The seat math is
  /// delegated to [GroupCascade.planAssignments], which mirrors the engine on a
  /// single-bus snapshot; each member's ENTIRE `assignedSeats` is REPLACED with
  /// the engine-proposed berths on the destination bus (so nobody is left
  /// behind on the old bus).
  ///
  /// Returns true on success. Returns false (after an
  /// [AppSnackBar.warning]) when the group does not fully fit on the
  /// destination, or when the tour/anchor can't be resolved.
  ///
  /// Mirrors [fillTour]'s persistence: an optimistic local update, then the
  /// atomic `applySeatAssignments` RPC with a per-passenger
  /// [RpcUnavailableException] fallback, snapping back to server truth on a
  /// hard write failure.
  Future<bool> moveGroupToBus({
    required String tourId,
    required String anchorPassengerId,
    required String destinationBusId,
  }) async {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final anchor = tour.passengers.firstWhereOrNull(
      (p) => p.id == anchorPassengerId,
    );
    final destination = tour.buses.firstWhereOrNull(
      (b) => b.id == destinationBusId,
    );
    if (anchor == null || destination == null) {
      AppSnackBar.warning(tr('seat.group_move_failed'));
      return false;
    }

    final plan = GroupCascade.planAssignments(
      mover: anchor,
      destinationBus: destination,
      passengers: tour.passengers,
    );
    if (plan == null) {
      // Does not fully fit on the destination bus. Name the bus and the party
      // size: "the whole group does not fit on this bus" left the operator
      // guessing which bus and how many people the app was talking about.
      final gid = anchor.groupId;
      final count = (gid == null || gid.isEmpty)
          ? 1
          : tour.passengers.where((p) => p.groupId == gid).length;
      AppSnackBar.warning(
        tr(
          'seat.group_move_no_fit_on',
          namedArgs: {'bus': destination.name, 'count': '$count'},
        ),
      );
      return false;
    }

    // Apply every moved member LOCALLY in one pass (one repaint), REPLACING the
    // member's entire assignedSeats — so any berths they held on the OLD bus are
    // dropped, not merged.
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        final ns = plan[p.id];
        return ns == null ? p : p.copyWith(assignedSeats: ns);
      }).toList();
      return t.copyWith(passengers: list);
    });

    try {
      try {
        await _sync.applySeatAssignments(
          tourId: tourId,
          assignments: [
            for (final entry in plan.entries)
              {
                'id': entry.key,
                'assigned_seats': entry.value
                    .map((s) => s.toMap())
                    .toList(),
              },
          ],
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to per-passenger writes.
        final updated = getTour(tourId);
        for (final id in plan.keys) {
          final p = updated?.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: id,
            data: p.toMap(),
          );
        }
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('seat.group_move_save', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      return false;
    }

    // A group move is a real seat placement: advance the lifecycle the same way
    // assignSeats / fillTour do, so the Lock CTA unlocks.
    final t = getTour(tourId);
    if (t != null && t.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }
    // A group move can seat a previously-unseated sibling: confirm + notify any
    // moved rider who was never confirmed, same as a single-seat placement.
    await _confirmAndNotifyOnSeat(tourId, plan.keys);
    // Every member just changed bus, so each one's paid-vs-due gap is re-priced
    // at the destination's bands.
    await _reconcileMoneyAfterMove(tourId, plan.keys, crossedBus: true);
    return true;
  }

  /// Auto-fill an entire tour with the deterministic [SeatingEngine].
  ///
  /// Finds the tour, asks the engine to [SeatingEngine.propose] a plan from
  /// its buses + passengers, diffs that against current state via
  /// [SeatingPlanApplier.diff], and persists ONLY the passengers that
  /// actually changed — each through the existing offline-first
  /// [assignSeats] path (no double-writes, no bypassing SyncService). A
  /// passenger whose seats are unchanged is skipped entirely, so a re-run
  /// with nothing to change is a no-op on the wire.
  ///
  /// The returned [SeatingPlan] (also cached in [lastPlanByTour]) carries
  /// the exceptions the UI surfaces as "needs your decision".
  Future<SeatingPlan> fillTour(String tourId) async {
    await ensureTourReadyForSeating(tourId);
    final tour = getTour(tourId);
    if (tour == null) {
      // Nothing to fill — hand back an empty plan so callers don't null-check.
      const empty = SeatingPlan(
        assignmentsByPassenger: {},
        exceptions: [],
        reasons: [],
      );
      lastPlanByTour[tourId] = empty;
      lastPlanByTour.refresh();
      return empty;
    }

    final plan = SeatingEngine.propose(
      buses: tour.buses,
      passengers: tour.passengers,
    );

    // Cache the plan so the Overview screen can render exceptions even if
    // the caller didn't hold the return value.
    lastPlanByTour[tourId] = plan;
    lastPlanByTour.refresh();

    final changes = SeatingPlanApplier.diff(
      plan: plan,
      passengers: tour.passengers,
    );
    if (changes.isEmpty) return plan;

    // Apply every changed passenger LOCALLY in one pass (one repaint), then
    // persist the WHOLE plan in a single atomic transaction (DI-2). If the
    // server write fails it's all-or-nothing, so we just snap back to server
    // truth and ask the agent to re-generate — never a half-applied plan.
    final changeMap = {
      for (final c in changes) c.passengerId: c.newAssignedSeats,
    };
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        final ns = changeMap[p.id];
        return ns == null ? p : p.copyWith(assignedSeats: ns);
      }).toList();
      return t.copyWith(passengers: list);
    });

    try {
      try {
        await _sync.applySeatAssignments(
          tourId: tourId,
          assignments: [
            for (final c in changes)
              {
                'id': c.passengerId,
                'assigned_seats': c.newAssignedSeats
                    .map((s) => s.toMap())
                    .toList(),
              },
          ],
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to per-passenger writes,
        // but STOP on the first failure so we never leave a half-applied plan
        // (DI-2). Refresh then surfaces server truth.
        final updated = getTour(tourId);
        for (final c in changes) {
          final p = updated?.passengers.firstWhereOrNull(
            (x) => x.id == c.passengerId,
          );
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: c.passengerId,
            data: p.toMap(),
          );
        }
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('errors.autofill_save', namedArgs: {'e': '$e'}),
        title: tr('errors.autofill_failed'),
      );
      return plan;
    }

    // First placement moves the tour into the "assigning" phase (once), which
    // unlocks the per-tour Lock CTA. Mirrors the single-seat assignSeats path.
    final t = getTour(tourId);
    if (t != null && t.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }

    // Any rider auto-fill just SEATED who was never confirmed is confirmed +
    // notified now — the same implicit confirmation as a manual chart placement.
    await _confirmAndNotifyOnSeat(tourId, changes.map((c) => c.passengerId));

    // F2 priority: surface a warning right after auto-fill (from ANY screen)
    // when an approved-priority passenger was seated but could not get a lower
    // berth — the dedicated alert lives on the seating-exceptions screen, but
    // this snack flags it immediately so it isn't missed.
    if (plan.exceptions.any(
      (e) => e.type == SeatingExceptionType.priorityNoLowerBerth,
    )) {
      AppSnackBar.warning(tr('priority.no_lower_snack'));
    }

    return plan;
  }

  /// Free every seat [passengerId] holds on [tourId].
  ///
  /// No money reconcile runs here, on purpose: with no seat left there is
  /// nothing to re-home a collection row ONTO, so the collection reconciler
  /// would return an empty plan by construction. The cash stays visible as detached
  /// cash on the bus that took it (money is never deleted), and the bus is
  /// noted in [_vacatedBusIds] so the rider's NEXT placement — the second half
  /// of a free-then-place transfer — carries it across and re-prices it.
  Future<void> unassignSeats(String tourId, String passengerId) async {
    final vacating = _busIdsHeldBy(tourId, passengerId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(assignedSeats: []);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.clear_seat_assignment'),
    );
    _rememberVacated(tourId, passengerId, vacating);
  }

  /// Free every seat on [busId] across all passengers of [tourId] in one go.
  /// Each passenger keeps any seats they hold on OTHER buses, and their
  /// request lines are left intact — so they reappear as needing assignment
  /// and can be re-seated immediately. Persists only the passengers that
  /// actually changed.
  ///
  /// Emptying a bus is a free-then-place transfer for everyone who was on it,
  /// so each cleared rider is noted in [_vacatedBusIds] — their re-seating on
  /// another bus then carries their money over instead of billing them the full
  /// fare again. See [unassignSeats] for why no reconcile runs here.
  Future<void> unassignBus(String tourId, String busId) async {
    final tour = getTour(tourId);
    if (tour == null) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final p in tour.passengers) {
          if (!p.assignedSeats.any((a) => a.busId == busId)) continue;
          final remaining = p.assignedSeats
              .where((a) => a.busId != busId)
              .toList();
          Passenger? updated;
          _updatePassengerLocal(tourId, p.id, (cur) {
            updated = cur.copyWith(assignedSeats: remaining);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.clear_bus'),
    );
    for (final p in changed) {
      _rememberVacated(tourId, p.id, {busId});
    }
  }

  /// Customer-cancels a single seat — common phone-in flow: "I booked 3
  /// seats but I only need 2 now". The agent picks the seat to drop and
  /// this method does BOTH the unassignment AND the request-line
  /// decrement so the passenger doesn't keep showing up in the Requests
  /// tab as "1 seat outstanding".
  ///
  /// Looks up the seat's type+position from the bus layout to find the
  /// right RequestLine to decrement (prefers exact type+position match,
  /// falls back to seatType-only). If qty drops to 0 the line is removed
  /// from the list entirely. If no matching line exists, only the seat
  /// is freed and the request is left untouched.
  Future<void> cancelOneSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String seatId,
  }) async {
    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    SeatCell? cell;
    if (layout != null) {
      for (final c in layout.grid) {
        if (c.seatId == seatId) {
          cell = c;
          break;
        }
      }
    }
    final type = cell?.seatType;
    final pos = cell?.position;

    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        final newAssigned = p.assignedSeats
            .where((a) => !(a.busId == busId && a.seatId == seatId))
            .toList();

        List<RequestLine> newRequest = List.of(p.requestLines);
        if (type != null) {
          // First pass: exact (type + position) match.
          var idx = newRequest.indexWhere(
            (l) => l.seatType == type && l.position == pos && l.qty > 0,
          );
          // Second pass: seat-type-only match (handles requests that came
          // in without an explicit upper/lower preference).
          if (idx < 0) {
            idx = newRequest.indexWhere((l) => l.seatType == type && l.qty > 0);
          }
          if (idx >= 0) {
            final line = newRequest[idx];
            if (line.qty > 1) {
              newRequest[idx] = line.copyWith(qty: line.qty - 1);
            } else {
              newRequest.removeAt(idx);
            }
          }
        }

        updated = p.copyWith(
          assignedSeats: newAssigned,
          requestLines: newRequest,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.cancel_seat'),
    );
  }

  /// Consolidate a set of source seats (typically two single sofas
  /// previously cross-filled to satisfy a `doubleSofa` request) into
  /// a single whole Double Sofa for the same passenger. The drag-drop
  /// overview tab calls this when the admin drags one of those singles
  /// onto a free Double Sofa — the partner single is released in the
  /// same atomic write and the passenger ends up owning both berths
  /// on the target double.
  ///
  /// All [sourceSeatIds] on [busId] are removed from the passenger's
  /// `assignedSeats`; exactly 2 entries are added at [targetSeatId].
  /// Assignments on other buses or other seats are untouched.
  Future<void> consolidateOntoDouble({
    required String tourId,
    required String passengerId,
    required String busId,
    required String targetSeatId,
    required List<String> sourceSeatIds,
  }) async {
    // A Double Sofa holds exactly two berths, so consolidation always folds
    // EXACTLY two source singles into the one target cell. This guards the
    // contract: it adds two target berths below regardless of how many
    // sources it removed, so a single-source call would over-assign the
    // passenger (remove 1, add 2). Catch that in debug/tests.
    assert(
      sourceSeatIds.length == 2,
      'consolidateOntoDouble expects exactly 2 source seats, got '
      '${sourceSeatIds.length}',
    );
    final tour = getTour(tourId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        final next =
            p.assignedSeats
                .where(
                  (a) =>
                      !(a.busId == busId && sourceSeatIds.contains(a.seatId)),
                )
                .toList()
              ..add(SeatAssignment(busId: busId, seatId: targetSeatId))
              ..add(SeatAssignment(busId: busId, seatId: targetSeatId));
        // Re-stamp per-seat legs: the leg multiset is unchanged by folding two
        // singles into a whole double, but the seatIds changed.
        final stamped = tour == null
            ? next
            : resolveAssignmentLegs(
                requestLines: p.requestLines,
                assigned: next,
                cellTypeAt: _cellTypeLookup(tour),
              );
        updated = p.copyWith(assignedSeats: stamped);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.consolidate_double'),
    );
  }

  /// Move a single seat from one slot to another within the same bus for
  /// the same passenger. The drag-and-drop overview tab uses this when
  /// the agent drops an occupied seat onto a free slot.
  ///
  /// Both ends of the swap have to land on the server for the chart to
  /// stay consistent — failure here triggers a server refresh so the UI
  /// snaps back to truth instead of holding a phantom move.
  ///
  /// [toBusId] defaults to [busId] (a same-bus move). Pass a different
  /// [toBusId] to move the passenger onto ANOTHER bus — the source berths are
  /// matched on [busId]/[fromSeatId] and re-created on [toBusId]/[toSeatId], so
  /// a whole-double crosses intact.
  /// [berths] caps how many berths move. Null moves every berth the passenger
  /// holds on [fromSeatId] (the default — a whole-double crosses intact). Pass
  /// 1 to PEEL a single berth off a substitute whole-double (a split): one berth
  /// lands on [toSeatId] and the remainder stays on the source cell.
  /// Carry the money with the people who just moved.
  ///
  /// Collections are keyed `(passenger_id, bus_id, seat_id)` and every fare is
  /// resolved from the bus the rider currently sits on, so a seat move that is
  /// not mirrored onto the collection rows leaves a rider who ALREADY PAID
  /// billed the full fare again on the destination bus while their cash sits
  /// stranded on the old one. [MoneyController.reconcileAfterSeatMove] re-homes
  /// the row and re-prices it to the destination bus's band; the deltas it
  /// returns are what is left to collect (or hand back) at the new price.
  ///
  /// Best-effort on purpose. The seat move is already persisted and on screen
  /// by the time this runs, so a money failure must not unwind it — the money
  /// controller surfaces its own error and refetches.
  Future<void> _reconcileMoneyAfterMove(
    String tourId,
    Iterable<String> passengerIds, {
    required bool crossedBus,
  }) async {
    if (!Get.isRegistered<MoneyController>()) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    try {
      final deltas = await Get.find<MoneyController>().reconcileAfterSeatMove(
        tour: tour,
        passengerIds: passengerIds,
        crossedBus: crossedBus,
      );
      await SeatMoveMoneyNotice.show(deltas, tour: tour);
    } catch (e, st) {
      // Best-effort really is best-effort: the seat move is already persisted
      // and drawn, so nothing here may propagate and unwind it. The money
      // controller raises its own toast for write failures; anything reaching
      // this point (a missing dependency, no overlay to draw the notice into)
      // is logged and dropped.
      //
      // What happens to the rows then: they stay orphaned until the NEXT write
      // that touches this passenger's seats runs a reconcile — a move, a swap,
      // a group cascade, or a plain (re)assignment. Nothing heals them merely
      // by opening the collection screen; [MoneyController.reconcileAfterSeatMove]
      // is only ever called from here. So an orphan can outlive the session,
      // and until it is re-homed the collection screen shows the cash as
      // detached on the origin bus rather than credited on the destination.
      dev.log(
        'money reconcile after seat move failed — $e\n$st',
        name: 'TourController',
      );
    }
  }

  /// Returns what actually happened — see [SeatMoveOutcome]. Callers that show
  /// a "moved" confirmation, clear a relocate banner, or decide whether to
  /// re-notify a rider MUST branch on it: a cross-bus move of a grouped rider
  /// is rerouted into [moveGroupToBus], which can refuse outright.
  Future<SeatMoveOutcome> moveSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String fromSeatId,
    required String toSeatId,
    String? toBusId,
    int? berths,
  }) async {
    final targetBusId = toBusId ?? busId;

    // F1 group cohesion: a CROSS-bus move of a grouped passenger whose siblings
    // are not ALL already on the destination bus would split the group — reroute
    // the whole group via moveGroupToBus instead of moving this one berth. (The
    // engine re-seats the group on the destination, so the specific [toSeatId]
    // is intentionally not preserved for grouped movers — which is why this
    // reports [SeatMoveOutcome.groupReseated] and not a plain `moved`.) Same-bus
    // moves and ungrouped movers fall through to the plain per-seat path below.
    if (targetBusId != busId &&
        _groupNotAllOnBus(tourId, passengerId, targetBusId)) {
      final ok = await moveGroupToBus(
        tourId: tourId,
        anchorPassengerId: passengerId,
        destinationBusId: targetBusId,
      );
      // The cascade's verdict is the move's verdict. Dropping it on the floor
      // is what let the app report "moved" while the whole family stayed put.
      return ok ? SeatMoveOutcome.groupReseated : SeatMoveOutcome.failed;
    }

    final tour = getTour(tourId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        // Count how many berths this passenger holds on the source cell.
        // 2 happens when they own a whole-double; 1 in every other case.
        // We replicate that count onto the target so a whole-double move
        // doesn't silently downgrade to a half-double — unless [berths] caps it
        // (a split), in which case the surplus stays put on the source cell.
        final held = p.assignedSeats
            .where((a) => a.busId == busId && a.seatId == fromSeatId)
            .length;
        if (held == 0) {
          updated = p;
          return p;
        }
        final moveCount = berths == null
            ? held
            : (berths < held ? berths : held);
        final keepOnSource = held - moveCount;
        final next = p.assignedSeats
            .where((a) => !(a.busId == busId && a.seatId == fromSeatId))
            .toList();
        for (var i = 0; i < keepOnSource; i++) {
          next.add(SeatAssignment(busId: busId, seatId: fromSeatId));
        }
        for (var i = 0; i < moveCount; i++) {
          next.add(SeatAssignment(busId: targetBusId, seatId: toSeatId));
        }
        // Re-stamp per-seat legs: a move keeps the leg multiset (only seatIds
        // change), so resolve against the same request lines on the new cells.
        final stamped = tour == null
            ? next
            : resolveAssignmentLegs(
                requestLines: p.requestLines,
                assigned: next,
                cellTypeAt: _cellTypeLookup(tour),
              );
        updated = p.copyWith(assignedSeats: stamped);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.move_seat'),
    );

    // Only reached when the seat write actually landed (_write rethrows), so
    // the money is never carried for a move that snapped back.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerId],
      crossedBus: targetBusId != busId,
    );
    return SeatMoveOutcome.moved;
  }

  /// Move EVERY occupant of [fromSeatId] together onto [toSeatId] on the same
  /// bus — the drag-and-drop grid uses this when a SHARED double (two people on
  /// one sofa) is dropped onto a fully-free double. Each occupant keeps the
  /// berth count and leg they held, so a shared pair lands intact and a
  /// leg-disjoint reuse stays paired. Same-bus only, so no group can be split.
  Future<void> moveSharedPair({
    required String tourId,
    required String busId,
    required String fromSeatId,
    required String toSeatId,
  }) async {
    if (fromSeatId == toSeatId) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    final movers = tour.passengers
        .where(
          (p) => p.assignedSeats
              .any((a) => a.busId == busId && a.seatId == fromSeatId),
        )
        .toList();
    if (movers.isEmpty) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final m in movers) {
          Passenger? updated;
          _updatePassengerLocal(tourId, m.id, (p) {
            final berths = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == fromSeatId)
                .length;
            if (berths == 0) {
              updated = p;
              return p;
            }
            final next = p.assignedSeats
                .where((a) => !(a.busId == busId && a.seatId == fromSeatId))
                .toList();
            for (var i = 0; i < berths; i++) {
              next.add(SeatAssignment(busId: busId, seatId: toSeatId));
            }
            // Re-stamp per-seat legs: moving the pair keeps each occupant's leg
            // multiset, only the seatId changes.
            final stamped = resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: _cellTypeLookup(tour),
            );
            updated = p.copyWith(assignedSeats: stamped);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.move_seat'),
    );
  }

  /// Exchange the FULL contents of two seats on one bus — every occupant of
  /// [seatAId] moves to [seatBId] and vice versa, each keeping their berth count
  /// and leg. Used by the drag grid for a pair-for-pair Double Sofa swap (two
  /// couples exchange sofas) where a one-for-one [swapSeats] can't express the
  /// multi-occupant exchange. Same-bus only, so no group can be split.
  Future<void> swapSeatContents({
    required String tourId,
    required String busId,
    required String seatAId,
    required String seatBId,
  }) async {
    if (seatAId == seatBId) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    // Everyone holding a berth on EITHER seat is affected (a passenger can't be
    // on both distinct cells, so the two sides never overlap on one person).
    final affected = tour.passengers
        .where(
          (p) => p.assignedSeats.any(
            (a) => a.busId == busId && (a.seatId == seatAId || a.seatId == seatBId),
          ),
        )
        .toList();
    if (affected.isEmpty) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final m in affected) {
          Passenger? updated;
          _updatePassengerLocal(tourId, m.id, (p) {
            final onA = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == seatAId)
                .length;
            final onB = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == seatBId)
                .length;
            if (onA == 0 && onB == 0) {
              updated = p;
              return p;
            }
            final next = p.assignedSeats
                .where((a) => !(a.busId == busId &&
                    (a.seatId == seatAId || a.seatId == seatBId)))
                .toList();
            for (var i = 0; i < onA; i++) {
              next.add(SeatAssignment(busId: busId, seatId: seatBId));
            }
            for (var i = 0; i < onB; i++) {
              next.add(SeatAssignment(busId: busId, seatId: seatAId));
            }
            // Re-stamp per-seat legs: a contents swap keeps each occupant's leg
            // multiset, only the seatIds change.
            final stamped = resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: _cellTypeLookup(tour),
            );
            updated = p.copyWith(assignedSeats: stamped);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.move_seat'),
    );
  }

  /// Exchange seats between two passengers on the same bus. Used by the
  /// drag-and-drop overview when one occupied seat is dropped onto
  /// another occupied seat.
  ///
  /// Local state is mutated in one synchronous pass so the UI never
  /// shows a halfway state where both passengers appear to hold the
  /// same seat. Persistence prefers the atomic `swap_passenger_seats`
  /// RPC (migration 011); if that RPC is undeployed we fall back to two
  /// sequential writes and refresh on failure.
  ///
  /// [busBId] defaults to [busId] (both passengers on one bus). Pass a
  /// different [busBId] to swap ACROSS buses: A lands on B's bus/seat and B on
  /// A's bus/seat. Each side keeps its own berth count (whole doubles stay
  /// whole).
  Future<void> swapSeats({
    required String tourId,
    required String busId,
    required String passengerAId,
    required String seatAId,
    required String passengerBId,
    required String seatBId,
    String? busBId,
    List<({String passengerId, String busId, String seatId})> bump = const [],
  }) async {
    if (passengerAId == passengerBId) return;
    final busAId = busId;
    final bBusId = busBId ?? busId;
    if (busAId == bBusId && seatAId == seatBId) return;

    // F1 group cohesion: a CROSS-bus swap where either side belongs to a group
    // would split that group. A plain berth-for-berth swap can't keep a group
    // whole, so reroute the grouped side(s) through moveGroupToBus — A's group
    // re-seats onto B's bus and/or B's group onto A's bus. (If both are grouped,
    // each group moves to the other's bus.) Same-bus swaps and all-ungrouped
    // swaps fall through to the plain two-row swap below.
    if (busAId != bBusId) {
      final tour = getTour(tourId);
      final pA = tour?.passengers.firstWhereOrNull((p) => p.id == passengerAId);
      final pB = tour?.passengers.firstWhereOrNull((p) => p.id == passengerBId);
      final aGid = pA?.groupId;
      final bGid = pB?.groupId;
      final aGrouped = aGid != null && aGid.isNotEmpty;
      final bGrouped = bGid != null && bGid.isNotEmpty;
      if (aGrouped || bGrouped) {
        if (aGrouped) {
          await moveGroupToBus(
            tourId: tourId,
            anchorPassengerId: passengerAId,
            destinationBusId: bBusId,
          );
        }
        // Only move B's group separately when it is a DIFFERENT group than A's.
        // If A and B share one group, moving A's group to B's bus already pulls
        // B along — a second move would just undo it.
        if (bGrouped && bGid != aGid) {
          await moveGroupToBus(
            tourId: tourId,
            anchorPassengerId: passengerBId,
            destinationBusId: busAId,
          );
        }
        return;
      }
    }

    // Capacity backstop (defense-in-depth): never write more berths onto a cell
    // than it can hold. A whole double (2 berths) must not land on a single, nor
    // vice-versa — that silently over-books the cell and corrupts the chart.
    // Callers SHOULD already gate this (the drag engine and SwapCandidateFinder
    // both do), but this is the last line before persistence — and the only one
    // that also covers cross-bus swaps.
    {
      final tour = getTour(tourId);
      if (tour != null) {
        int capOf(String bId, String sId) {
          for (final b in tour.buses) {
            if (b.id != bId) continue;
            for (final cl in b.layout?.grid ?? const <SeatCell>[]) {
              if (cl.seatId == sId) {
                return cl.seatType == SeatType.doubleSofa ? 2 : 1;
              }
            }
          }
          return 1;
        }

        int berthsOn(String pid, String bId, String sId) =>
            tour.passengers
                .firstWhereOrNull((x) => x.id == pid)
                ?.assignedSeats
                .where((a) => a.busId == bId && a.seatId == sId)
                .length ??
            0;

        final bA = berthsOn(passengerAId, busAId, seatAId);
        final bB = berthsOn(passengerBId, bBusId, seatBId);
        if (bB > capOf(busAId, seatAId) || bA > capOf(bBusId, seatBId)) {
          AppSnackBar.error(tr('errors.move_seat'));
          return;
        }
      }
    }

    // Leg-conflict resolution (set by the UI guard): occupants to bump OFF a
    // seat so the incoming passenger doesn't over-book a shared leg. Each is
    // cleared from its (busId, seatId) — requestLines are kept, so they return
    // to the unseated pool rather than losing their booking. Keyed by passenger
    // → the set of "busId|seatId" berths to drop.
    final bumpBySeat = <String, Set<String>>{};
    for (final x in bump) {
      (bumpBySeat[x.passengerId] ??= <String>{}).add('${x.busId}|${x.seatId}');
    }
    final updatedBumped = <Passenger>[];

    Passenger? updatedA;
    Passenger? updatedB;
    _updateTourLocal(tourId, (t) {
      // Berth counts on each side. The swap preserves each passenger's
      // berth count: A's berths on seatA → A's berths on seatB, and
      // vice versa. Whole-double swaps still carry both berths.
      final pA = t.passengers.firstWhere(
        (p) => p.id == passengerAId,
        orElse: () => t.passengers.first,
      );
      final pB = t.passengers.firstWhere(
        (p) => p.id == passengerBId,
        orElse: () => t.passengers.first,
      );
      final berthsA = pA.assignedSeats
          .where((a) => a.busId == busAId && a.seatId == seatAId)
          .length;
      final berthsB = pB.assignedSeats
          .where((a) => a.busId == bBusId && a.seatId == seatBId)
          .length;

      // Re-stamp per-seat legs after the swap: each side keeps its leg multiset
      // (only seatIds change), so resolve against that passenger's own request
      // lines on the new cells. [t] is the tour, so its layouts feed the lookup.
      final cellTypeAt = _cellTypeLookup(t);

      final newPassengers = t.passengers.map((p) {
        if (p.id == passengerAId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == busAId && a.seatId == seatAId))
              .toList();
          for (var i = 0; i < berthsA; i++) {
            next.add(SeatAssignment(busId: bBusId, seatId: seatBId));
          }
          updatedA = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          return updatedA!;
        }
        if (p.id == passengerBId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == bBusId && a.seatId == seatBId))
              .toList();
          for (var i = 0; i < berthsB; i++) {
            next.add(SeatAssignment(busId: busAId, seatId: seatAId));
          }
          updatedB = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          return updatedB!;
        }
        final dropSeats = bumpBySeat[p.id];
        if (dropSeats != null && dropSeats.isNotEmpty) {
          final next = p.assignedSeats
              .where((a) => !dropSeats.contains('${a.busId}|${a.seatId}'))
              .toList();
          final u = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          updatedBumped.add(u);
          return u;
        }
        return p;
      }).toList();
      return t.copyWith(passengers: newPassengers);
    });

    final a = updatedA;
    final b = updatedB;
    if (a == null || b == null) return;

    try {
      // Persist any bumped occupants first so the freed leg is real before the
      // incoming passenger lands on it.
      for (final u in updatedBumped) {
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: u.id,
          data: u.toMap(),
        );
      }
      try {
        // Atomic: both rows move in one server transaction (no double-booked
        // berth window). DI-1.
        await _sync.swapPassengerSeats(
          passengerAId: passengerAId,
          seatsA: a.assignedSeats.map((s) => s.toMap()).toList(),
          passengerBId: passengerBId,
          seatsB: b.assignedSeats.map((s) => s.toMap()).toList(),
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to the two-step write.
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerAId,
          data: a.toMap(),
        );
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerBId,
          data: b.toMap(),
        );
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('errors.swap_seats', namedArgs: {'e': '$e'}),
        title: tr('errors.swap_failed'),
      );
      rethrow;
    }

    // Both sides of a cross-bus swap change price band, and a bumped occupant
    // loses berths — re-price all three groups so nobody keeps a fare from a
    // bus they no longer sit on.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerAId, passengerBId, for (final u in updatedBumped) u.id],
      crossedBus: busAId != bBusId,
    );
  }

  /// Toggles a passenger's waitlist flag. Moving onto the waitlist
  /// also clears any seat assignments — they should not hold seats
  /// while waitlisted.
  Future<void> setWaitlisted(
    String tourId,
    String passengerId,
    bool waitlisted,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          isWaitlisted: waitlisted,
          assignedSeats: waitlisted
              ? const <SeatAssignment>[]
              : p.assignedSeats,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_waitlist'),
    );
  }

  /// Confirm (or un-confirm) a request: a confirmed passenger is eligible for
  /// seat allotment and moves to the Confirmed list. Confirming also clears any
  /// waitlist hold. Mirrors [setWaitlisted].
  Future<void> setConfirmed(
    String tourId,
    String passengerId,
    bool confirmed,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          isConfirmed: confirmed,
          // A confirmed passenger leaves the waitlist.
          isWaitlisted: confirmed ? false : p.isWaitlisted,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_confirmed'),
    );
  }

  /// Implicit confirmation for seats placed from the CHART. The app's model is
  /// "Confirm → then seat": the Requests "Confirm" button both flips
  /// `isConfirmed` and fires the WhatsApp greeting. But a seat can also be placed
  /// straight from the chart (tap-to-place, auto-fill, group move) on a rider who
  /// was never confirmed — historically that seated them SILENTLY, with no
  /// message. This closes that gap: any of [passengerIds] who now holds a seat
  /// while still unconfirmed is confirmed (persisted) AND sent the same greeting,
  /// so a seat assigned from ANY surface always notifies the customer.
  ///
  /// Idempotent: an already-confirmed rider is skipped, so re-seating / moving /
  /// swapping never re-sends, and the front-door Confirm flow never double-sends.
  /// The WhatsApp send is fire-and-forget so seat placement is never blocked on
  /// the network.
  Future<void> _confirmAndNotifyOnSeat(
    String tourId,
    Iterable<String> passengerIds,
  ) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final newly = <Passenger>[];
    for (final id in passengerIds.toSet()) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null || p.isConfirmed || p.assignedSeats.isEmpty) continue;
      newly.add(p);
    }
    if (newly.isEmpty) return;

    for (final p in newly) {
      await setConfirmed(tourId, p.id, true);
    }
    unawaited(_broadcastConfirmed(tour, newly));
  }

  /// Fires the WhatsApp confirmation to each freshly-confirmed rider (bounded to
  /// what [_confirmAndNotifyOnSeat] just flipped) and surfaces a SINGLE summary
  /// toast — never one-per-rider, so a bulk auto-fill doesn't spam. A
  /// per-recipient failure is logged and skipped, never thrown.
  Future<void> _broadcastConfirmed(Tour tour, List<Passenger> passengers) async {
    var sent = 0;
    for (final p in passengers) {
      try {
        if (await confirmedSender(tour, p)) sent++;
      } catch (e) {
        dev.log('auto-confirm WhatsApp failed for ${p.id}: $e',
            name: 'TourController');
      }
    }
    if (sent <= 0) return;
    try {
      AppSnackBar.success(
        passengers.length == 1
            ? tr('seat.auto_confirm_sent_one',
                namedArgs: {'name': passengers.first.name})
            : tr('seat.auto_confirm_sent_many', namedArgs: {'count': '$sent'}),
      );
    } catch (_) {
      // The toast is best-effort feedback — never let a missing localization or
      // navigator context turn this fire-and-forget send into a crash.
    }
  }

  /// Persist that [passengerIds] have been WhatsApp-notified of their CURRENT
  /// seats: stamps each rider's [Passenger.seatSignature] onto
  /// `seats_notified_sig`. A later post-lock seat edit changes the live
  /// signature, re-flagging them as "changed" for the Notify screen's targeted
  /// re-notify. Silently skips ids that don't resolve.
  Future<void> markSeatsNotified(
    String tourId,
    Iterable<String> passengerIds,
  ) async {
    final ids = passengerIds.toSet();
    if (ids.isEmpty) return;
    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final id in ids) {
          Passenger? updated;
          _updatePassengerLocal(tourId, id, (p) {
            updated = p.copyWith(seatsNotifiedSig: p.seatSignature);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.save_seat_assignment'),
    );
  }

  // Handler
  Future<void> setHandler(String tourId, String passengerId) async {
    // Remember who held the flag before, so we persist only the rows that
    // actually flip — not every passenger.
    final previousHandlerId = getTour(tourId)?.handlerId;
    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final updatedPassengers = t.passengers.map((p) {
          if (p.isHandler) return p.copyWith(isHandler: false);
          if (p.id == passengerId) return p.copyWith(isHandler: true);
          return p;
        }).toList();
        return t.copyWith(
          handlerId: passengerId,
          passengers: updatedPassengers,
        );
      }),
      persist: () async {
        final tour = getTour(tourId);
        if (tour == null) return;
        // The tour row's handlerId is authoritative; write it once.
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: tour.toMap(),
        );
        // Only the new handler and the one it replaced changed isHandler — a
        // 60-passenger tour no longer means 60 sequential writes.
        final changedIds = <String>{passengerId, ?previousHandlerId};
        for (final id in changedIds) {
          final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.set_handler'),
    );
  }

  Future<void> removeHandler(String tourId) => _write(
    optimistic: () => _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers
          .map((p) => p.isHandler ? p.copyWith(isHandler: false) : p)
          .toList();
      return t.copyWith(handlerId: null, passengers: updatedPassengers);
    }),
    persist: () async {
      final tour = getTour(tourId);
      if (tour == null) return;
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: tour.toMap(),
      );
    },
    failure: tr('errors.remove_handler'),
  );

  // Per-bus handler (F3)
  //
  // The handler is now PER BUS (a per-bus handler later sees ONLY their own
  // bus). The bus row owns the pointer via `handler_passenger_id`; the
  // passenger's `is_handler` flag is kept in sync (true while they handle ANY
  // bus); and the legacy tour-wide `tours.handler_id` pointer is maintained so
  // older "tour has a handler" reads keep working.

  /// Assign [passengerId] as the handler of [busId] on [tourId].
  ///
  /// Sets `bus.handlerPassengerId = passengerId` and `passenger.isHandler =
  /// true`. If a DIFFERENT passenger previously handled this bus and handles no
  /// OTHER bus, their `isHandler` is cleared. Also points the legacy
  /// `tours.handler_id` at [passengerId]. Persists only the rows that change.
  Future<void> setBusHandler(
    String tourId,
    String busId,
    String passengerId,
  ) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
    if (bus == null) return;

    // The passenger this bus pointed at before (if any), so we can clear their
    // flag when they no longer handle any bus.
    final previousHandlerId = bus.handlerPassengerId;
    // Whether the previous handler still handles some OTHER bus after this
    // change — if so, keep their is_handler flag.
    final prevStillHandlesOther = previousHandlerId != null &&
        previousHandlerId != passengerId &&
        tour.buses
            .any((b) => b.id != busId && b.handlerPassengerId == previousHandlerId);

    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextBuses = t.buses
            .map((b) => b.id == busId
                ? b.copyWith(handlerPassengerId: passengerId)
                : b)
            .toList();
        final nextPassengers = t.passengers.map((p) {
          if (p.id == passengerId && !p.isHandler) {
            return p.copyWith(isHandler: true);
          }
          if (p.id == previousHandlerId &&
              previousHandlerId != passengerId &&
              !prevStillHandlesOther &&
              p.isHandler) {
            return p.copyWith(isHandler: false);
          }
          return p;
        }).toList();
        return t.copyWith(
          handlerId: passengerId,
          buses: nextBuses,
          passengers: nextPassengers,
        );
      }),
      persist: () async {
        final t = getTour(tourId);
        if (t == null) return;
        // The bus row owns the per-bus pointer. Patch ONLY that column: a whole
        // -row write here used to ship `layout: null` for any bus whose grid had
        // not been fetched yet (cold start omits the jsonb), erasing the seat
        // chart as a side effect of naming a handler.
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.updatePatch(
            table: 'buses',
            entityId: busId,
            fields: {'handler_passenger_id': bus.handlerPassengerId},
          );
        }
        // The tour row carries the legacy handler_id pointer.
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: t.toMap(),
        );
        // Only the new handler and the one it replaced changed is_handler.
        final changedIds = <String>{passengerId, ?previousHandlerId};
        for (final id in changedIds) {
          final p = t.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.set_handler'),
    );
  }

  /// Remove the handler from [busId] on [tourId].
  ///
  /// Clears `bus.handlerPassengerId`. The removed passenger keeps `isHandler`
  /// only if they still handle some OTHER bus. The legacy `tours.handler_id` is
  /// recomputed to another bus's handler (deterministically, by bus id) or null.
  Future<void> removeBusHandler(String tourId, String busId) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
    if (bus == null) return;
    final removedHandlerId = bus.handlerPassengerId;
    if (removedHandlerId == null) return; // nothing to clear.

    // Does the removed handler still handle any OTHER bus?
    final stillHandlesOther = tour.buses.any(
      (b) => b.id != busId && b.handlerPassengerId == removedHandlerId,
    );

    // Recompute the legacy tour-wide pointer: another bus's handler (lowest bus
    // id for determinism), or null when no bus has a handler anymore.
    final remainingHandlerBuses = tour.buses
        .where((b) => b.id != busId && b.handlerPassengerId != null)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final nextTourHandlerId =
        remainingHandlerBuses.firstOrNull?.handlerPassengerId;

    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextBuses = t.buses
            .map((b) => b.id == busId ? _busWithHandler(b, null) : b)
            .toList();
        final nextPassengers = t.passengers.map((p) {
          if (p.id == removedHandlerId && !stillHandlesOther && p.isHandler) {
            return p.copyWith(isHandler: false);
          }
          return p;
        }).toList();
        return t.copyWith(
          handlerId: nextTourHandlerId,
          buses: nextBuses,
          passengers: nextPassengers,
        );
      }),
      persist: () async {
        final t = getTour(tourId);
        if (t == null) return;
        // Clearing the pointer is the same one-column write as setting it.
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.updatePatch(
            table: 'buses',
            entityId: busId,
            fields: {'handler_passenger_id': bus.handlerPassengerId},
          );
        }
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: t.toMap(),
        );
        if (!stillHandlesOther) {
          final p =
              t.passengers.firstWhereOrNull((x) => x.id == removedHandlerId);
          if (p != null) {
            await _sync.smartUpdate(
              table: 'passengers',
              entityId: p.id,
              data: p.toMap(),
            );
          }
        }
      },
      failure: tr('errors.remove_handler'),
    );
  }

  // Bus Management
  Future<void> addBus(String tourId, Bus bus) async {
    final tourGate = getTour(tourId);
    if (tourGate != null && !tourGate.status.allowsLayoutEdit) {
      AppSnackBar.info(tr('manage_buses.layout_locked_body'),
          title: tr('manage_buses.layout_locked_title'));
      return;
    }
    final boundBus = bus.copyWith(tourId: tourId);
    final busData = {
      ...boundBus.toMap(),
      'owner_id': _auth.currentAdmin.value?.id,
    };
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(buses: [...t.buses, boundBus]),
      ),
      persist: () => _sync.smartInsert(
        table: 'buses',
        entityId: boundBus.id,
        data: busData,
      ),
      failure: tr('errors.add_bus'),
    );
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.collecting) {
      await updateStatus(tourId, TourStatus.busBooked);
    }
  }

  /// Persist edits to [bus].
  ///
  /// [layoutChanged] MUST be true only when the caller actually built a new seat
  /// layout in this operation. It is a caller declaration, never inferred from
  /// `bus.layout != null` — an unloaded layout and a real one are
  /// indistinguishable in memory, and guessing wrong erases the seat chart.
  /// When false the `layout` column is left out of the write entirely, so the
  /// grid on the server survives untouched.
  Future<void> updateBus(
    String tourId,
    Bus bus, {
    required bool layoutChanged,
  }) async {
    final tourGate = getTour(tourId);
    if (tourGate != null && !tourGate.status.allowsLayoutEdit) {
      AppSnackBar.info(tr('manage_buses.layout_locked_body'),
          title: tr('manage_buses.layout_locked_title'));
      return;
    }
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == bus.id ? bus : b).toList(),
        ),
      ),
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: bus.id,
        fields: bus.toPatch(includeLayout: layoutChanged),
      ),
      failure: tr('errors.update_bus'),
    );
  }

  Future<void> removeBus(String tourId, String busId) async {
    final tourGate = getTour(tourId);
    if (tourGate != null && !tourGate.status.allowsLayoutEdit) {
      AppSnackBar.info(tr('manage_buses.layout_locked_body'),
          title: tr('manage_buses.layout_locked_title'));
      return;
    }
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.where((b) => b.id != busId).toList(),
          busId: t.busId == busId ? null : t.busId,
        ),
      ),
      persist: () async {
        await _sync.smartDelete(table: 'buses', entityId: busId);
        // Persist the tour's busId clear in the SAME guarded write, so a
        // failure here also rolls back (was previously an unguarded trailing
        // write — audit M3).
        final tour = getTour(tourId);
        if (tour != null) {
          await _sync.smartUpdate(
            table: 'tours',
            entityId: tourId,
            data: tour.toMap(),
          );
        }
      },
      failure: tr('errors.remove_bus'),
    );
  }

  // Queries
  List<Tour> toursByStatus(TourStatus status) =>
      tours.where((t) => t.status == status).toList();

  /// Cross-booking groups for [tourId] (empty when the tour is unknown or
  /// has no groups yet). Loaded by the sync layer alongside passengers/buses.
  List<PassengerGroup> groupsForTour(String tourId) =>
      getTour(tourId)?.groups ?? const <PassengerGroup>[];

  /// Suggested groups derived from customer memory: clusters of passengers
  /// PRESENT in [tourId] who are remembered to travel together (from past
  /// tours) and are ALL currently ungrouped. Restricting to fully-ungrouped
  /// clusters keeps the one-tap [recreateCompanionGroup] unambiguous — it
  /// never has to move someone out of an existing group. Each cluster has 2+
  /// members; empty when memory is unavailable or nothing matches.
  List<List<Passenger>> suggestedCompanionGroups(String tourId) {
    if (!Get.isRegistered<CustomerMemoryController>()) return const [];
    final tour = getTour(tourId);
    if (tour == null) return const [];
    final memory = Get.find<CustomerMemoryController>();

    final byPhone = <String, Passenger>{
      for (final p in tour.passengers.where((p) => p.groupId == null))
        normalisePhone(p.phone): p,
    };
    if (byPhone.length < 2) return const [];

    // Union-find over eligible passengers; edges are remembered companions.
    final parent = {for (final k in byPhone.keys) k: k};
    String find(String x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]!]!;
        x = parent[x]!;
      }
      return x;
    }

    var anyEdge = false;
    for (final phone in byPhone.keys) {
      for (final comp in memory.companionPhonesFor(phone)) {
        final cp = normalisePhone(comp);
        if (byPhone.containsKey(cp)) {
          parent[find(phone)] = find(cp);
          anyEdge = true;
        }
      }
    }
    if (!anyEdge) return const [];

    final clusters = <String, List<Passenger>>{};
    for (final phone in byPhone.keys) {
      (clusters[find(phone)] ??= <Passenger>[]).add(byPhone[phone]!);
    }
    return clusters.values.where((m) => m.length >= 2).toList();
  }

  /// One-tap creation of a remembered companion group: makes a fresh group
  /// (labelled from the members' first names) and attaches every member.
  Future<void> recreateCompanionGroup(
    String tourId,
    List<Passenger> members,
  ) async {
    if (members.length < 2) return;
    final label = members
        .map((m) => m.name.trim().split(RegExp(r'\s+')).first)
        .where((s) => s.isNotEmpty)
        .take(3)
        .join(' & ');
    final groupId = await createGroup(
      tourId,
      label.isEmpty ? tr('errors.default_group_label') : label,
      colorIndex: groupsForTour(tourId).length,
    );
    for (final m in members) {
      await setPassengerGroup(tourId, m.id, groupId);
    }
  }

  /// True once [tourId]'s roster has actually been fetched. A screen can use
  /// this to show a loading state instead of an empty roster.
  bool isTourHydrated(String tourId) => _hydratedTourIds.contains(tourId);

  /// Loads passengers/buses/groups for [tourId] if cold start skipped them.
  ///
  /// Cold start deliberately fetches rosters only for RUNNING tours, because
  /// pulling every archived tour's roster on every launch is what breaks 2G
  /// (measured: 105 kB → 10.7s on EDGE, vs 10 kB → 1.0s when scoped). Opening
  /// an archived tour pays its own small cost, once, at the moment the user
  /// actually asks for it.
  ///
  /// Idempotent and race-safe: already-hydrated tours return immediately, and
  /// concurrent callers share a single in-flight request. On failure the tour
  /// is NOT marked hydrated, so a later open retries rather than showing an
  /// empty roster forever.
  Future<void> ensureTourHydrated(String tourId) {
    if (tourId.isEmpty || _hydratedTourIds.contains(tourId)) {
      return Future<void>.value();
    }
    // Local roster already present (test seed, optimistic write, or a prior
    // session that painted passengers/buses before the hydrate set was marked).
    // Cold-start headers always land with BOTH lists empty, so an empty tour
    // still pays the network hydrate when opened from archive.
    final local = getTour(tourId);
    if (local != null &&
        (local.passengers.isNotEmpty || local.buses.isNotEmpty)) {
      _hydratedTourIds.add(tourId);
      return Future<void>.value();
    }
    final existing = _hydrationsInFlight[tourId];
    if (existing != null) return existing;

    final future = _hydrateTour(tourId).whenComplete(() {
      _hydrationsInFlight.remove(tourId);
    });
    _hydrationsInFlight[tourId] = future;
    return future;
  }

  Future<void> _hydrateTour(String tourId) async {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) return;

    final priorBuses = raw[idx].buses;
    final rel = await _sync.fetchRelationsForTours([tourId]);

    // Mirror the cold-start read: a customer-cancelled passenger stays in the
    // DB for history but must never enter the active roster.
    final passengers = rel.passengers
        .where((m) => m['cancelled_at'] == null)
        .map(Passenger.fromMap)
        .toList();
    final buses = rel.buses.map(Bus.fromMap).toList();
    final groups = rel.groups.map(PassengerGroup.fromMap).toList();

    // Preserve layouts already paid for — hydrate must never throw away a
    // chart the agent is looking at just because the roster refresh omitted
    // the jsonb column.
    final withLayouts = [
      for (final b in buses)
        if (priorBuses
            .where((x) => x.id == b.id && x.layout != null)
            .firstOrNull
            case final prior?)
          b.copyWith(layout: prior.layout)
        else
          b,
    ];

    raw[idx] = raw[idx].copyWith(
      passengers: passengers,
      buses: withLayouts,
      groups: groups,
    );
    _hydratedTourIds.add(tourId);
    _scheduleNotify();

    // Chart / capacity screens usually open next — pull layouts immediately
    // for this one tour rather than waiting on the background prefetch queue.
    await ensureBusLayoutsForTour(tourId);
  }

  /// Ensures every bus on [tourId] has had its `layout` jsonb fetched (or
  /// confirmed absent). Idempotent and coalesces concurrent callers.
  ///
  /// Cold start deliberately omits layouts (~71% of bus payload on a live
  /// probe). Call this before seating engine, seat charts, or manage-buses.
  Future<void> ensureBusLayoutsForTour(String tourId) {
    if (tourId.isEmpty) return Future<void>.value();
    final existing = _layoutFetchesInFlight[tourId];
    if (existing != null) return existing;
    final future = _fetchLayoutsForTour(tourId).whenComplete(() {
      _layoutFetchesInFlight.remove(tourId);
    });
    _layoutFetchesInFlight[tourId] = future;
    return future;
  }

  Future<void> _fetchLayoutsForTour(String tourId) async {
    final tour = getTour(tourId);
    if (tour == null || tour.buses.isEmpty) return;

    // Layouts already in memory (seed / prior prefetch / realtime full row)
    // count as fetched — never re-pay the 2G cost for jsonb we hold.
    for (final b in tour.buses) {
      if (b.layout != null) _layoutFetchedBusIds.add(b.id);
    }

    final need = tour.buses
        .where((b) => !_layoutFetchedBusIds.contains(b.id))
        .map((b) => b.id)
        .toList();
    if (need.isEmpty) return;

    final rows = await _sync.fetchBusLayouts(need);
    final byId = {
      for (final r in rows) r['id'] as String: r['layout'],
    };

    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) return;

    final updatedBuses = raw[idx].buses.map((b) {
      _layoutFetchedBusIds.add(b.id);
      if (!byId.containsKey(b.id)) return b;
      final layoutVal = byId[b.id];
      if (layoutVal == null) return b;
      return Bus.fromMap({
        ...b.toMap(),
        'layout': layoutVal,
      });
    }).toList();

    raw[idx] = raw[idx].copyWith(buses: updatedBuses);
    _capacityCache.remove(tourId);
    _actualCapacityCache.remove(tourId);
    _scheduleNotify();
  }

  /// Roster + layouts — what chart / fill / manage-buses need before work.
  Future<void> ensureTourReadyForSeating(String tourId) async {
    await ensureTourHydrated(tourId);
    await ensureBusLayoutsForTour(tourId);
  }

  List<Tour> get activeTours =>
      tours.where((t) => t.status != TourStatus.completed).toList();

  List<Tour> get completedTours =>
      tours.where((t) => t.status == TourStatus.completed).toList();

  /// Live count of NEW (un-actioned) booking requests across all active tours.
  ///
  /// Mirrors exactly the "New" filter pill in RequestsScreen: a passenger is
  /// New when their journey isn't done and they are neither waitlisted,
  /// confirmed, nor fully assigned. Derived from the existing `tours`
  /// observable (via [activeTours]) so reading it inside an Obx is reactive;
  /// adds no persisted state. Used to badge the Requests dock-nav tab.
  int get pendingRequestCount {
    var count = 0;
    for (final tour in activeTours) {
      for (final p in tour.passengers) {
        if (p.journeyDone) continue;
        if (!p.isWaitlisted && !p.isConfirmed && !p.isFullyAssigned) {
          count++;
        }
      }
    }
    return count;
  }

  // Groups (cross-booking)
  //
  // Groups live in their own `passenger_groups` table (one row per group,
  // keyed by tour_id) and are embedded into Tour.groups by the sync layer.
  // These mirror the existing offline-first CRUD shape: stage an optimistic
  // local mutation, await the server write, and on failure pull fresh state
  // + surface the error.

  /// Create a new cross-booking group on [tourId]. Returns the new group id.
  Future<String> createGroup(
    String tourId,
    String label, {
    int colorIndex = 0,
  }) async {
    final group = PassengerGroup(
      tourId: tourId,
      label: label,
      colorIndex: colorIndex,
    );
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(groups: [...t.groups, group]),
      ),
      persist: () => _sync.smartInsert(
        table: 'passenger_groups',
        entityId: group.id,
        data: group.toMap(),
      ),
      failure: tr('errors.create_group'),
    );
    return group.id;
  }

  /// Set or clear a passenger's group membership. Pass `null` to ungroup.
  Future<void> setPassengerGroup(
    String tourId,
    String passengerId,
    String? groupId,
  ) async {
    Passenger? updated;
    await _write(
      // copyWith uses `??`, so it can't clear group_id back to null. Build the
      // updated passenger explicitly to allow an explicit null (ungroup).
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = _passengerWithGroup(p, groupId);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_group'),
    );
  }

  /// Delete a group: first clears `group_id` on every member (locally and on
  /// the server) so no passenger row dangles a reference to a deleted group,
  /// then deletes the group row itself.
  Future<void> deleteGroup(String tourId, String groupId) async {
    final tour = getTour(tourId);
    if (tour == null) return;

    final members = tour.passengers.where((p) => p.groupId == groupId).toList();

    await _write(
      // Optimistic local update: clear members, drop the group row.
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextPassengers = t.passengers
            .map((p) => p.groupId == groupId ? _passengerWithGroup(p, null) : p)
            .toList();
        final nextGroups = t.groups.where((g) => g.id != groupId).toList();
        return t.copyWith(passengers: nextPassengers, groups: nextGroups);
      }),
      persist: () async {
        for (final p in members) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: _passengerWithGroup(p, null).toMap(),
          );
        }
        await _sync.smartDelete(table: 'passenger_groups', entityId: groupId);
      },
      failure: tr('errors.delete_group'),
    );
  }

  // Priority

  /// Approve or clear a passenger's priority (front/sofa) status. `approved`
  /// maps to [PriorityStatus.approved]; otherwise [PriorityStatus.none].
  Future<void> setPassengerPriority(
    String tourId,
    String passengerId,
    bool approved,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          priorityStatus: approved
              ? PriorityStatus.approved
              : PriorityStatus.none,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_priority'),
    );
  }

  // Seat flags (forward / reserved)
  //
  // Both flags live on individual SeatCells inside the bus layout grid, so
  // toggling one means rebuilding that bus's layout and persisting the whole
  // bus row — the same shape updateBus uses.

  /// Toggle the "forward / premium" flag on a single seat of [busId].
  Future<void> setSeatForward(
    String tourId,
    String busId,
    String seatId,
    bool forward,
  ) => _updateSeatFlag(
    tourId,
    busId,
    seatId,
    (cell) => cell.copyWith(forward: forward),
  );

  /// Toggle the "reserved / held back" flag on a single seat of [busId].
  Future<void> setSeatReserved(
    String tourId,
    String busId,
    String seatId,
    bool reserved,
  ) => _updateSeatFlag(
    tourId,
    busId,
    seatId,
    (cell) => cell.copyWith(reserved: reserved),
  );

  // Internals
  /// Rebuild [Passenger] with an explicit (possibly null) group id.
  ///
  /// Routed through [Passenger.copyWith] + its `clearGroup` escape, NOT a
  /// hand-rolled full constructor. The old rebuild listed every field by hand
  /// and so silently dropped each one added after it was written — pickup
  /// location, cancelledAt, cancelRequestedAt and seatsNotifiedSig were all
  /// being nulled. Since the result is persisted via `toMap()`, that wasn't a
  /// local-only glitch: (un)grouping a passenger WIPED those columns on the
  /// server (resurrecting cancelled riders, losing their pickup point, and
  /// falsely flagging seats as changed-since-notified). copyWith can never
  /// drop a field, so this cannot rot again.
  Passenger _passengerWithGroup(Passenger p, String? groupId) =>
      p.copyWith(groupId: groupId, clearGroup: groupId == null);

  /// Rebuild [Bus] with an explicit (possibly null) handler passenger id.
  /// Needed because [Bus.copyWith] uses `??`, so it can't clear
  /// `handlerPassengerId` back to null when a bus's handler is removed. Every
  /// other field is preserved verbatim.
  Bus _busWithHandler(Bus b, String? handlerPassengerId) {
    return Bus(
      id: b.id,
      ownerId: b.ownerId,
      tourId: b.tourId,
      handlerPassengerId: handlerPassengerId,
      name: b.name,
      busNumber: b.busNumber,
      driverName: b.driverName,
      driverPhone: b.driverPhone,
      ownerName: b.ownerName,
      ownerPhone: b.ownerPhone,
      isAC: b.isAC,
      busType: b.busType,
      totalSeatsLegacy: b.totalSeatsLegacy,
      pricePerSeat: b.pricePerSeat,
      busPrice: b.busPrice,
      boardingPoint: b.boardingPoint,
      departureTime: b.departureTime,
      singleSofaPrice: b.singleSofaPrice,
      doubleSofaPrice: b.doubleSofaPrice,
      seaterPrice: b.seaterPrice,
      rearRows: b.rearRows,
      rearPrice: b.rearPrice,
      priceBands: b.priceBands,
      notes: b.notes,
      layout: b.layout,
      createdAt: b.createdAt,
      updatedAt: DateTime.now(),
    );
  }

  // ── F1 group cohesion guards (shared by moveSeat/assignSeats) ──

  /// True when [passengerId] travels with OTHERS and not every group member
  /// already sits wholly on [busId]. Drives the cross-bus reroute in [moveSeat]:
  /// moving a lone berth to another bus would split the group, so the whole
  /// group must cascade. An ungrouped passenger (or a group already entirely on
  /// [busId]) is never split, so this returns false.
  ///
  /// A ONE-PERSON group is deliberately not a group. Bookings carry a groupId
  /// long after the party shrinks to a single rider, and treating that as a
  /// group sent a solo mover through the engine cascade — which re-seats at
  /// engine-chosen berths and therefore SILENTLY DISCARDED the seat the operator
  /// tapped. Nobody can be split from themselves, so a lone member takes the
  /// plain per-seat path and lands exactly where they were put.
  bool _groupNotAllOnBus(String tourId, String passengerId, String busId) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    final gid = p?.groupId;
    if (gid == null || gid.isEmpty) return false;
    final members = tour.passengers.where((x) => x.groupId == gid).toList();
    if (members.length < 2) return false;
    // A member "splits" if they hold any seat on a bus OTHER than [busId].
    return members.any(
      (m) => m.assignedSeats.any((a) => a.busId != busId),
    );
  }

  /// True when writing [assignments] for [passengerId] would SPLIT their group
  /// across buses: the passenger is grouped, the new assignments place them on a
  /// bus, and some sibling already sits on a DIFFERENT bus. Used by
  /// [assignSeats] to block group-splitting manual writes. (The first member to
  /// be seated — no sibling seated anywhere yet — never splits, so returns
  /// false; an ungrouped passenger never splits.)
  bool _wouldSplitGroup(
    String tourId,
    String passengerId,
    List<SeatAssignment> assignments,
  ) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    final gid = p?.groupId;
    if (gid == null || gid.isEmpty) return false;

    // Buses this write would place the passenger on.
    final newBusIds = assignments.map((a) => a.busId).toSet();
    if (newBusIds.isEmpty) return false;

    // Buses any OTHER group member already sits on.
    final siblingBusIds = <String>{};
    for (final m in tour.passengers) {
      if (m.id == passengerId || m.groupId != gid) continue;
      for (final a in m.assignedSeats) {
        siblingBusIds.add(a.busId);
      }
    }
    if (siblingBusIds.isEmpty) return false; // no sibling seated yet — allowed.

    // Split when the new placement lands on any bus a sibling is NOT on.
    return newBusIds.any((b) => !siblingBusIds.contains(b));
  }

  /// Shared seat-flag toggler used by [setSeatForward] / [setSeatReserved].
  /// Finds the seat cell on [busId] by [seatId], applies [transform], rebuilds
  /// the layout (preserving every other cell), optimistically updates local
  /// state, and persists the whole bus row.
  Future<void> _updateSeatFlag(
    String tourId,
    String busId,
    String seatId,
    SeatCell Function(SeatCell) transform,
  ) async {
    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    if (bus == null || layout == null) return;

    final target = layout.grid.where((c) => c.seatId == seatId).firstOrNull;
    if (target == null) return;

    final updatedBus = bus.copyWith(
      layout: layout.updateCell(transform(target)),
    );

    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == busId ? updatedBus : b).toList(),
        ),
      ),
      // Seat-cell edits change exactly one column. `layout` is non-null here —
      // the guard above returned early otherwise — so this is the one write that
      // legitimately carries a grid.
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: busId,
        fields: {'layout': updatedBus.layout?.toMap()},
      ),
      failure: tr('errors.update_seat'),
    );
  }

  /// Rebuild the seat layout of a bus whose `layout` jsonb was lost, inferring
  /// the original grid from the seat ids its riders are still assigned to.
  ///
  /// Repairs the damage described in migration 065. Safe by construction: the
  /// rebuilt grid is only written when [recoverBusLayout] identifies EXACTLY one
  /// candidate, and that candidate contains every surviving seat id, so no
  /// passenger moves — unlike regenerating through the bus editor, which
  /// renumbers seats and calls [unassignBus] to clear everyone first.
  ///
  /// Returns the outcome so a caller can report ambiguity or an inconsistency
  /// instead of silently doing nothing. Refuses on a bus that still HAS a
  /// layout — this only ever fills a hole, never overwrites a live grid.
  Future<LayoutRecovery> recoverBusLayoutFor(String tourId, String busId) async {
    await ensureBusLayoutsForTour(tourId);

    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    if (tour == null || bus == null) {
      return const LayoutRecovery(reason: 'bus not found');
    }
    if (busBerths(bus).fromGrid) {
      return const LayoutRecovery(
        reason: 'bus already has a seat layout — nothing to recover',
      );
    }

    final survivors = <String>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == busId) survivors.add(a.seatId);
      }
    }

    final result = recoverBusLayout(
      totalSeats: bus.totalSeatsLegacy,
      busType: BusType.fromString(bus.busType),
      assignedSeatIds: survivors,
    );
    final rebuilt = result.layout;
    if (rebuilt == null) return result;

    final updatedBus = bus.copyWith(layout: rebuilt);
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == busId ? updatedBus : b).toList(),
        ),
      ),
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: busId,
        fields: {'layout': rebuilt.toMap()},
      ),
      failure: tr('errors.update_bus'),
    );
    return result;
  }

  /// THE single place optimistic writes live.
  ///
  /// Applies [optimistic] to local state immediately (so the UI feels instant),
  /// runs [persist] against the server, and on ANY failure snaps the local
  /// state back to server truth ([refreshTours]) and surfaces [failure] to the
  /// user. Every mutating method routes through this — so the "what happens
  /// when the write fails" rule lives in exactly ONE place and can never be
  /// forgotten when someone adds a new method. Change the recovery policy here,
  /// once, and it applies everywhere.
  Future<void> _write({
    required void Function() optimistic,
    required Future<void> Function() persist,
    required String failure,
  }) async {
    optimistic();
    try {
      await persist();
    } catch (e) {
      await refreshTours();
      // A Postgres unique-violation (code 23505) — e.g. the same bus
      // registration twice on one tour — is an expected conflict, not a crash.
      // Show a clean, localized message instead of dumping the raw
      // PostgrestException text at the agent.
      final raw = e.toString().toLowerCase();
      final isDuplicate =
          raw.contains('23505') || raw.contains('duplicate key');
      AppSnackBar.error(
        isDuplicate ? tr('errors.duplicate') : '$failure $e',
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  /// Write ONLY the booking-mode / collection columns (migrations 048–050).
  ///
  /// Deliberately a narrow, hand-rolled update rather than going through
  /// [_updateTour]: those columns are absent from [Tour.toMap] on purpose,
  /// because PostgREST rejects the WHOLE payload when it carries a column the
  /// live schema doesn't have — shipping them in the ordinary tour write would
  /// break every tour save on a server where 048–050 aren't applied yet. Sent
  /// alone, a missing column fails only this call, loudly, with nothing else
  /// affected.
  Future<void> updateBookingSettings(
    String tourId, {
    BookingMode? bookingMode,
    int? advancePerBerthPaise,
    bool clearAdvance = false,
    String? collectVpa,
    String? collectPayeeName,
  }) async {
    final payload = <String, dynamic>{};
    if (bookingMode != null) {
      payload['booking_mode'] = bookingMode.storageKey;
    }
    if (clearAdvance) {
      payload['advance_per_berth_paise'] = null;
    } else if (advancePerBerthPaise != null) {
      payload['advance_per_berth_paise'] = advancePerBerthPaise;
    }
    if (collectVpa != null) {
      payload['collect_vpa'] =
          collectVpa.trim().isEmpty ? null : collectVpa.trim();
    }
    if (collectPayeeName != null) {
      payload['collect_payee_name'] =
          collectPayeeName.trim().isEmpty ? null : collectPayeeName.trim();
    }
    if (payload.isEmpty) return;

    _updateTourLocal(
      tourId,
      (t) => t.copyWith(
        bookingMode: bookingMode,
        advancePerBerthPaise: clearAdvance ? null : advancePerBerthPaise,
        collectVpa: collectVpa,
        collectPayeeName: collectPayeeName,
      ),
    );
    try {
      // Routed through the sync layer so it inherits the same retry/backoff
      // behaviour as every other write.
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: payload,
      );
    } catch (e) {
      dev.log('updateBookingSettings failed — $e', name: 'TourController');
      AppSnackBar.error(tr('booking_settings.err_save'));
      rethrow;
    }
  }

  Future<void> _updateTour(String tourId, Tour Function(Tour) updater) async {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx < 0) return;
    late Tour updated;
    await _write(
      optimistic: () {
        updated = updater(tours[idx]);
        tours[idx] = updated;
        tours.refresh();
      },
      persist: () => _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: updated.toMap(),
      ),
      failure: tr('errors.save_change'),
    );
  }

  void _updateTourLocal(String tourId, Tour Function(Tour) updater) {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx >= 0) {
      tours[idx] = updater(tours[idx]);
      tours.refresh();
    }
  }

  void _updatePassengerLocal(
    String tourId,
    String passengerId,
    Passenger Function(Passenger) updater,
  ) {
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        return p.id == passengerId ? updater(p) : p;
      }).toList();
      return t.copyWith(passengers: list);
    });
  }
}

/// Pure transformation behind [TourController.cancelReturnSeat] — kept top-level
/// so it can be unit-tested without GetX/SyncService.
///
/// Returns `null` when the rider should be REMOVED outright: a return-only rider
/// (every request line is [TripType.returnOnly]) never rode any leg, so dropping
/// the return drops them entirely.
///
/// Otherwise returns the demoted passenger: every round-trip line becomes
/// outbound-only, outbound-only lines are kept as-is, return-only lines are
/// dropped (the cancelled return portion), seats are freed, and [journeyDone] is
/// set — mirroring how completeOutboundLeg retires a one-way rider after their
/// only leg.
Passenger? cancelReturnSeatTransform(Passenger p) {
  final lines = p.requestLines;
  final usesReturnOnly =
      lines.isNotEmpty && lines.every((l) => l.leg == TripType.returnOnly);
  if (usesReturnOnly) return null;

  final newLines = <RequestLine>[
    for (final l in lines)
      if (l.leg == TripType.roundTrip)
        l.copyWith(leg: TripType.outboundOnly)
      else if (l.leg == TripType.outboundOnly)
        l,
    // returnOnly lines are intentionally dropped (the cancelled return portion).
  ];

  return p.copyWith(
    requestLines: newLines,
    assignedSeats: const [],
    journeyDone: true,
    tripType: TripType.outboundOnly,
  );
}

/// Pure builder: freeze the [leg] seat chart for a tour. Returns null when no
/// seat on any bus is occupied for this leg (e.g. a one-way tour has no return
/// riders) — callers skip storing an empty snapshot.
///
/// Captures EVERY rider on each seat for [leg], not one. It used to read
/// `seatOccupantsForBus(...).go / .ret`, which keeps a single holder per leg —
/// so a Double Sofa whose two berths were taken by two DIFFERENT same-leg
/// riders archived only the first, and this snapshot is written at GO-leg
/// completion and never rebuilt. The loss was permanent.
///
/// The leg comes from the SEAT ([Passenger.legForSeat]), not the rider's overall
/// tripType: a round-trip rider whose GO berth and RET berth are different seats
/// would otherwise be frozen onto both seats on both legs.
TourSeatSnapshot? buildSeatSnapshot({
  required String tourId,
  required SnapshotLeg leg,
  required List<Bus> buses,
  required List<Passenger> passengers,
  required DateTime capturedAt,
}) {
  // Build one SnapshotBus per bus, skipping buses with no captured seats.
  final snapshotBuses = <SnapshotBus>[];
  var seatCount = 0;
  for (final bus in buses) {
    final occupants = occupantListForBus(passengers, bus.id);
    final seats = <SnapshotSeat>[];
    occupants.forEach((seatId, riders) {
      for (final p in riders) {
        final rideLeg = p.legForSeat(seatId, busId: bus.id);
        final onThisLeg = leg == SnapshotLeg.outbound
            ? rideLeg.usesOutbound
            : rideLeg.usesReturn;
        if (!onThisLeg) continue;
        seats.add(SnapshotSeat(
          seatId: seatId,
          name: p.displayName,
          phone: p.phone,
        ));
      }
    });
    if (seats.isEmpty) continue;
    seatCount += seats.length;
    snapshotBuses.add(SnapshotBus(busId: bus.id, seats: seats));
  }

  // Don't store an empty snapshot (e.g. one-way tour → no return riders).
  if (seatCount == 0) return null;

  return TourSeatSnapshot(
    tourId: tourId,
    leg: leg,
    buses: snapshotBuses,
    capturedAt: capturedAt,
  );
}
