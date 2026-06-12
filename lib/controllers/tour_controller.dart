import 'dart:async';
import 'dart:developer' as dev;
import 'package:easy_localization/easy_localization.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent;
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
import '../models/trip_type.dart';
import '../services/group_cascade.dart';
import '../services/realtime_service.dart';
import '../services/seating_engine.dart';
import '../services/seating_plan_applier.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/phone_normalize.dart';
import 'auth_controller.dart';
import 'customer_memory_controller.dart';

class TourController extends GetxController {
  final tours = <Tour>[].obs;
  final isLoading = false.obs;
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

  SyncService get _sync => Get.find<SyncService>();
  AuthController get _auth => Get.find<AuthController>();
  RealtimeService get _realtime => Get.find<RealtimeService>();

  StreamSubscription<DataChangedEvent>? _realtimeSub;
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
    _loadTours();
    _subscribeToChanges();
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
    isLoading.value = true;
    hasError.value = false;
    try {
      // Paint cached tours immediately on cold start so weak networks
      // don't leave the whole app blank while the live fetch crawls.
      if (tours.isEmpty) {
        final cached = await _sync.getCachedList(_tourCacheKey);
        if (cached != null && cached.isNotEmpty) {
          tours.assignAll(cached.map((item) => Tour.fromMap(item)).toList());
        }
      }

      Future<List<Map<String, dynamic>>> fetch() => _sync.smartFetch(
        table: 'tours',
        cacheKey: _tourCacheKey,
        filters: _tourFilters,
        orderBy: 'created_at',
        maxAge: 120000,
      );

      var data = await fetch();

      // COLD START: on the very first load the Supabase session and the
      // connectivity probe can still be settling, so a transient fetch failure
      // is expected — and we have no local cache to fall back on. Quietly retry
      // a couple of times before surfacing anything, so launch never flashes
      // the "Could not load tours" error screen for a blip that self-heals.
      for (
        var attempt = 0;
        _sync.lastReadFailed && tours.isEmpty && attempt < 2;
        attempt++
      ) {
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
        data = await fetch();
      }

      // smartFetch returns [] on BOTH "no tours" and "refresh failed". If it
      // (still) failed, don't let the empty result blank an already-loaded
      // list — keep what we have and warn, or raise the hard error only when we
      // genuinely have nothing to show after the retries.
      if (_sync.lastReadFailed) {
        if (tours.isEmpty) {
          hasError.value = true;
          errorMessage.value = tr('errors.load_tours');
        } else {
          AppSnackBar.warning(tr('errors.refresh_showing_saved'));
        }
        isLoading.value = false;
        return;
      }

      final loaded = data.map((item) => Tour.fromMap(item)).toList();

      // Preserve local tours that have a pending insert op — they exist
      // locally but the server fetch may have raced ahead of the write
      // and returned without them. Otherwise the freshly-created tour
      // would vanish under the user.
      final pendingIds = await _sync.pendingEntityIdsForTable('tours');
      final serverIds = loaded.map((t) => t.id).toSet();
      final preserved = tours
          .where((t) => !serverIds.contains(t.id) && pendingIds.contains(t.id))
          .toList();

      tours.assignAll([...loaded, ...preserved]);

      // Archive (not delete) tours whose trip ended more than a day ago.
      await _archiveExpiredTours();

      // Restore remembered priority for returning customers.
      await _applyRememberedPriority();
    } catch (_) {
      if (tours.isEmpty) {
        hasError.value = true;
        errorMessage.value = tr('errors.load_tours');
      } else {
        AppSnackBar.warning(tr('errors.refresh_showing_cached'));
      }
    }
    isLoading.value = false;
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
    required double pricePerSeat,
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

  Future<void> completeTour(String tourId) =>
      updateStatus(tourId, TourStatus.completed);

  /// Clearing seats on a LOCKED tour un-finalizes the allocation — drop it back
  /// to `assigning` so the agent can re-seat and the "Lock & notify" action
  /// reappears (a locked tour otherwise only offers "Mark completed"). No-op
  /// for any other status.
  Future<void> _revertLockOnUnseat(String tourId) async {
    final t = getTour(tourId);
    if (t != null && t.status == TourStatus.locked) {
      await updateStatus(tourId, TourStatus.assigning);
    }
  }

  /// Complete the OUTBOUND (GO) leg of a tour: every GO-only (outboundOnly)
  /// passenger has finished their only leg, so free their seats (the return
  /// chart then shows them empty) and mark them [Passenger.journeyDone] — the
  /// record is KEPT, they just drop off the active roster. Round-trip and
  /// return-only passengers are untouched. Returns how many were cleared.
  Future<int> completeOutboundLeg(String tourId) async {
    final tour = getTour(tourId);
    if (tour == null) return 0;

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

  /// GO-only passengers still active (not yet cleared by [completeOutboundLeg]).
  /// Drives whether the "Complete GO leg" action is offered.
  int outboundOnlyActiveCount(String tourId) {
    final tour = getTour(tourId);
    if (tour == null) return 0;
    return tour.passengers
        .where((p) => p.tripType == TripType.outboundOnly && !p.journeyDone)
        .length;
  }

  // Passenger Management
  Future<void> addPassenger(String tourId, Passenger passenger) async {
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
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(assignedSeats: assignments);
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
    // The first real seat placement moves the tour into the "assigning" phase.
    // Without this the status machine stalled at `busBooked` forever, which in
    // turn left the per-tour Lock CTA permanently disabled (it gated on
    // `status == assigning`). Now seating progress is reflected in the
    // lifecycle and the lock gate.
    if (assignments.isNotEmpty) {
      final tour = getTour(tourId);
      if (tour != null && tour.status == TourStatus.busBooked) {
        await updateStatus(tourId, TourStatus.assigning);
      }
    }
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
      // Does not fully fit on the destination bus.
      AppSnackBar.warning(tr('seat.group_move_no_fit'));
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
        // Migration 011 not deployed yet — fall back to per-passenger writes.
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

  Future<void> unassignSeats(String tourId, String passengerId) async {
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
    await _revertLockOnUnseat(tourId);
  }

  /// Free every seat on [busId] across all passengers of [tourId] in one go.
  /// Each passenger keeps any seats they hold on OTHER buses, and their
  /// request lines are left intact — so they reappear as needing assignment
  /// and can be re-seated immediately. Persists only the passengers that
  /// actually changed.
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
    await _revertLockOnUnseat(tourId);
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
    await _revertLockOnUnseat(tourId);
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
        updated = p.copyWith(assignedSeats: next);
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
  Future<void> moveSeat({
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
    // is intentionally not preserved for grouped movers.) Same-bus moves and
    // ungrouped movers fall through to the plain per-seat path below.
    if (targetBusId != busId &&
        _groupNotAllOnBus(tourId, passengerId, targetBusId)) {
      await moveGroupToBus(
        tourId: tourId,
        anchorPassengerId: passengerId,
        destinationBusId: targetBusId,
      );
      return;
    }

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
        updated = p.copyWith(assignedSeats: next);
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
            updated = p.copyWith(assignedSeats: next);
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
  /// same seat. The two server updates run sequentially; if the second
  /// fails we pull fresh state so neither side ends up out of sync.
  ///
  /// CAVEAT (DI-1): the two writes are NOT a single transaction. A crash or
  /// connectivity loss between them leaves the server with A on B's seat while
  /// B still holds it — a realtime event in that window would deliver a
  /// double-booked berth to other devices. The complete fix is a SECURITY
  /// DEFINER Postgres RPC `swap_passenger_seats(...)` that updates both rows in
  /// one transaction; this client path is the best-effort mitigation until
  /// that backend function is deployed.
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

      final newPassengers = t.passengers.map((p) {
        if (p.id == passengerAId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == busAId && a.seatId == seatAId))
              .toList();
          for (var i = 0; i < berthsA; i++) {
            next.add(SeatAssignment(busId: bBusId, seatId: seatBId));
          }
          updatedA = p.copyWith(assignedSeats: next);
          return updatedA!;
        }
        if (p.id == passengerBId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == bBusId && a.seatId == seatBId))
              .toList();
          for (var i = 0; i < berthsB; i++) {
            next.add(SeatAssignment(busId: busAId, seatId: seatAId));
          }
          updatedB = p.copyWith(assignedSeats: next);
          return updatedB!;
        }
        return p;
      }).toList();
      return t.copyWith(passengers: newPassengers);
    });

    final a = updatedA;
    final b = updatedB;
    if (a == null || b == null) return;

    try {
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
        // The bus row owns the per-bus pointer.
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.smartUpdate(
            table: 'buses',
            entityId: busId,
            data: bus.toMap(),
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
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.smartUpdate(
            table: 'buses',
            entityId: busId,
            data: bus.toMap(),
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

  Future<void> updateBus(String tourId, Bus bus) => _write(
    optimistic: () => _updateTourLocal(
      tourId,
      (t) => t.copyWith(
        buses: t.buses.map((b) => b.id == bus.id ? bus : b).toList(),
      ),
    ),
    persist: () =>
        _sync.smartUpdate(table: 'buses', entityId: bus.id, data: bus.toMap()),
    failure: tr('errors.update_bus'),
  );

  Future<void> removeBus(String tourId, String busId) => _write(
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

  List<Tour> get activeTours =>
      tours.where((t) => t.status != TourStatus.completed).toList();

  List<Tour> get completedTours =>
      tours.where((t) => t.status == TourStatus.completed).toList();

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
  /// Rebuild [Passenger] with an explicit (possibly null) group id. Needed
  /// because [Passenger.copyWith] can't clear a field back to null.
  Passenger _passengerWithGroup(Passenger p, String? groupId) {
    return Passenger(
      id: p.id,
      tourId: p.tourId,
      userId: p.userId,
      name: p.name,
      phone: p.phone,
      ageGroup: p.ageGroup,
      requestLines: p.requestLines,
      assignedSeats: p.assignedSeats,
      paymentStatus: p.paymentStatus,
      isHandler: p.isHandler,
      isWaitlisted: p.isWaitlisted,
      // Preserve isConfirmed / journeyDone: a full-constructor rebuild that
      // omits them would silently reset a confirmed passenger to unconfirmed
      // and resurrect a GO-leg-completed passenger onto the active roster the
      // moment they're (un)grouped.
      isConfirmed: p.isConfirmed,
      note: p.note,
      tripType: p.tripType,
      groupId: groupId,
      priorityStatus: p.priorityStatus,
      priorityReason: p.priorityReason,
      journeyDone: p.journeyDone,
      createdAt: p.createdAt,
    );
  }

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

  /// True when [passengerId] is grouped AND not every group member already sits
  /// wholly on [busId]. Drives the cross-bus reroute in [moveSeat]: moving a
  /// lone berth to another bus would split the group, so the whole group must
  /// cascade. An ungrouped passenger (or a group already entirely on [busId])
  /// is never split, so this returns false.
  bool _groupNotAllOnBus(String tourId, String passengerId, String busId) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    final gid = p?.groupId;
    if (gid == null || gid.isEmpty) return false;
    final members = tour.passengers.where((x) => x.groupId == gid);
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
      persist: () => _sync.smartUpdate(
        table: 'buses',
        entityId: busId,
        data: updatedBus.toMap(),
      ),
      failure: tr('errors.update_seat'),
    );
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
      AppSnackBar.error('$failure $e', title: tr('errors.save_failed'));
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
