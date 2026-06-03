import 'dart:async';
import 'dart:developer' as dev;
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgresChangeEvent;
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
import '../services/realtime_service.dart';
import '../services/seating_engine.dart';
import '../services/seating_plan_applier.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';
import 'auth_controller.dart';

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
    raw[idx] = Tour.fromMap(row).copyWith(
      buses: existing.buses,
      passengers: existing.passengers,
    );
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

      final data = await _sync.smartFetch(
        table: 'tours',
        cacheKey: _tourCacheKey,
        filters: _tourFilters,
        orderBy: 'created_at',
        maxAge: 120000,
      );
      final loaded = data.map((item) => Tour.fromMap(item)).toList();

      // Preserve local tours that have a pending insert op — they exist
      // locally but the server fetch may have raced ahead of the write
      // and returned without them. Otherwise the freshly-created tour
      // would vanish under the user.
      final pendingIds = await _sync.pendingEntityIdsForTable('tours');
      final serverIds = loaded.map((t) => t.id).toSet();
      final preserved = tours
          .where(
            (t) => !serverIds.contains(t.id) && pendingIds.contains(t.id),
          )
          .toList();

      tours.assignAll([...loaded, ...preserved]);
    } catch (_) {
      if (tours.isEmpty) {
        hasError.value = true;
        errorMessage.value = 'Could not load tours. Check your connection.';
      } else {
        AppSnackBar.warning(
          'Showing cached tours — refresh failed.',
        );
      }
    }
    isLoading.value = false;
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
    DateTime? returnDate,
    required double pricePerSeat,
    String? description,
  }) async {
    // RLS on `tours` requires owner_id = auth.uid(). Refuse to queue an
    // insert without an admin session — otherwise we'd write a row with a
    // null owner_id that RLS rejects on every retry until the 5-retry cap.
    final adminId = _auth.currentAdmin.value?.id;
    if (adminId == null) {
      AppSnackBar.error(
        'Please sign in with your admin password before creating a tour.',
        title: 'Sign in required',
      );
      throw StateError('createTour requires an authenticated admin session');
    }

    final tour = Tour(
      title: title,
      fromCity: fromCity,
      toCity: toCity,
      departureDate: departureDate,
      returnDate: returnDate,
      pricePerSeat: pricePerSeat,
      description: description,
      createdBy: _auth.userPhone.value,
    );

    // Optimistic add so the UI feels instant. If the server write fails,
    // we revert below so the user doesn't end up with a phantom tour they
    // think was saved.
    tours.add(tour);
    tours.refresh();

    final tourData = {
      ...tour.toMap(),
      'owner_id': adminId,
    };
    try {
      await _sync.smartInsert(
        table: 'tours',
        entityId: tour.id,
        data: tourData,
      );
    } catch (e) {
      tours.removeWhere((t) => t.id == tour.id);
      tours.refresh();
      AppSnackBar.error(
        'Could not create tour. $e',
        title: 'Save failed',
      );
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
    return tour;
  }

  Future<void> editTour({
    required String tourId,
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    DateTime? returnDate,
    required double pricePerSeat,
    String? description,
  }) async {
    await _updateTour(tourId, (t) => Tour(
          id: t.id,
          title: title,
          fromCity: fromCity,
          toCity: toCity,
          departureDate: departureDate,
          returnDate: returnDate,
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
        ));
  }

  Tour? getTour(String id) {
    final idx = tours.indexWhere((t) => t.id == id);
    return idx >= 0 ? tours[idx] : null;
  }

  Future<void> deleteTour(String id) async {
    tours.removeWhere((t) => t.id == id);
    try {
      await _sync.smartDelete(
        table: 'tours',
        entityId: id,
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not delete tour. $e', title: 'Delete failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
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

  // Passenger Management
  Future<void> addPassenger(String tourId, Passenger passenger) async {
    _updateTourLocal(tourId, (t) {
      final list = List<Passenger>.from(t.passengers)..add(passenger);
      return t.copyWith(passengers: list);
    });
    try {
      await _sync.smartInsert(
        table: 'passengers',
        entityId: passenger.id,
        data: passenger.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not save passenger. $e', title: 'Save failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.planning) {
      await updateStatus(tourId, TourStatus.collecting);
    }
  }

  Future<void> removePassenger(String tourId, String passengerId) async {
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.where((p) => p.id != passengerId).toList();
      return t.copyWith(passengers: list);
    });
    try {
      await _sync.smartDelete(
        table: 'passengers',
        entityId: passengerId,
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not remove passenger. $e', title: 'Delete failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  Future<void> updatePassenger(String tourId, Passenger passenger) async {
    _updatePassengerLocal(tourId, passenger.id, (p) => passenger);
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passenger.id,
        data: passenger.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not update passenger. $e',
        title: 'Save failed',
      );
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  Future<void> updatePassengerPayment(
      String tourId, String passengerId, PaymentStatus status) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(paymentStatus: status);
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not update payment status. $e',
        title: 'Save failed',
      );
      rethrow;
    }
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
      String tourId, String passengerId, List<SeatAssignment> assignments) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(assignedSeats: assignments);
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not save seat assignment. $e',
        title: 'Save failed',
      );
      rethrow;
    }
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

    // Persist each changed passenger through the SAME optimistic, offline-
    // first path the manual seat editor uses. assignSeats already stages a
    // local mutation, awaits the server write, and on failure pulls fresh
    // state + surfaces the error — so a mid-run failure won't leave a
    // half-applied phantom plan.
    for (final change in changes) {
      await assignSeats(tourId, change.passengerId, change.newAssignedSeats);
    }

    return plan;
  }

  Future<void> unassignSeats(String tourId, String passengerId) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(assignedSeats: []);
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not clear seat assignment. $e',
        title: 'Save failed',
      );
      rethrow;
    }
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
    for (final p in tour.passengers) {
      if (!p.assignedSeats.any((a) => a.busId == busId)) continue;
      final remaining =
          p.assignedSeats.where((a) => a.busId != busId).toList();
      Passenger? updated;
      _updatePassengerLocal(tourId, p.id, (cur) {
        updated = cur.copyWith(assignedSeats: remaining);
        return updated!;
      });
      if (updated != null) changed.add(updated!);
    }
    if (changed.isEmpty) return;

    try {
      for (final p in changed) {
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: p.id,
          data: p.toMap(),
        );
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not clear the bus. $e',
        title: 'Save failed',
      );
      rethrow;
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
    _updatePassengerLocal(tourId, passengerId, (p) {
      final newAssigned = p.assignedSeats
          .where((a) => !(a.busId == busId && a.seatId == seatId))
          .toList();

      List<RequestLine> newRequest = List.of(p.requestLines);
      if (type != null) {
        // First pass: exact (type + position) match.
        var idx = newRequest.indexWhere(
            (l) => l.seatType == type && l.position == pos && l.qty > 0);
        // Second pass: seat-type-only match (handles requests that came
        // in without an explicit upper/lower preference).
        if (idx < 0) {
          idx = newRequest.indexWhere(
              (l) => l.seatType == type && l.qty > 0);
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
    });
    if (updated == null) return;

    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not cancel the seat. $e',
        title: 'Cancel failed',
      );
      rethrow;
    }
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
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      final next = p.assignedSeats
          .where((a) =>
              !(a.busId == busId && sourceSeatIds.contains(a.seatId)))
          .toList()
        ..add(SeatAssignment(busId: busId, seatId: targetSeatId))
        ..add(SeatAssignment(busId: busId, seatId: targetSeatId));
      updated = p.copyWith(assignedSeats: next);
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not consolidate onto Double Sofa. $e',
        title: 'Move failed',
      );
      rethrow;
    }
  }

  /// Move a single seat from one slot to another within the same bus for
  /// the same passenger. The drag-and-drop overview tab uses this when
  /// the agent drops an occupied seat onto a free slot.
  ///
  /// Both ends of the swap have to land on the server for the chart to
  /// stay consistent — failure here triggers a server refresh so the UI
  /// snaps back to truth instead of holding a phantom move.
  Future<void> moveSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String fromSeatId,
    required String toSeatId,
  }) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      // Count how many berths this passenger holds on the source cell.
      // 2 happens when they own a whole-double; 1 in every other case.
      // We replicate that count onto the target so a whole-double move
      // doesn't silently downgrade to a half-double.
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
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not move the seat. $e',
        title: 'Move failed',
      );
      rethrow;
    }
  }

  /// Exchange seats between two passengers on the same bus. Used by the
  /// drag-and-drop overview when one occupied seat is dropped onto
  /// another occupied seat.
  ///
  /// Local state is mutated in one synchronous pass so the UI never
  /// shows a halfway state where both passengers appear to hold the
  /// same seat. The two server updates run sequentially; if the second
  /// fails we pull fresh state so neither side ends up out of sync.
  Future<void> swapSeats({
    required String tourId,
    required String busId,
    required String passengerAId,
    required String seatAId,
    required String passengerBId,
    required String seatBId,
  }) async {
    if (passengerAId == passengerBId) return;
    if (seatAId == seatBId) return;

    Passenger? updatedA;
    Passenger? updatedB;
    _updateTourLocal(tourId, (t) {
      // Berth counts on each side. The swap preserves each passenger's
      // berth count: A's berths on seatA → A's berths on seatB, and
      // vice versa. Whole-double swaps still carry both berths.
      final pA = t.passengers.firstWhere((p) => p.id == passengerAId,
          orElse: () => t.passengers.first);
      final pB = t.passengers.firstWhere((p) => p.id == passengerBId,
          orElse: () => t.passengers.first);
      final berthsA = pA.assignedSeats
          .where((a) => a.busId == busId && a.seatId == seatAId)
          .length;
      final berthsB = pB.assignedSeats
          .where((a) => a.busId == busId && a.seatId == seatBId)
          .length;

      final newPassengers = t.passengers.map((p) {
        if (p.id == passengerAId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == busId && a.seatId == seatAId))
              .toList();
          for (var i = 0; i < berthsA; i++) {
            next.add(SeatAssignment(busId: busId, seatId: seatBId));
          }
          updatedA = p.copyWith(assignedSeats: next);
          return updatedA!;
        }
        if (p.id == passengerBId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == busId && a.seatId == seatBId))
              .toList();
          for (var i = 0; i < berthsB; i++) {
            next.add(SeatAssignment(busId: busId, seatId: seatAId));
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
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not swap the seats. $e',
        title: 'Swap failed',
      );
      rethrow;
    }
  }

  /// Toggles a passenger's waitlist flag. Moving onto the waitlist
  /// also clears any seat assignments — they should not hold seats
  /// while waitlisted.
  Future<void> setWaitlisted(
      String tourId, String passengerId, bool waitlisted) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(
        isWaitlisted: waitlisted,
        assignedSeats: waitlisted ? const <SeatAssignment>[] : p.assignedSeats,
      );
      return updated!;
    });
    if (updated != null) {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
      await _sync.invalidateCache(_tourCacheKey);
    }
  }

  // Handler
  Future<void> setHandler(String tourId, String passengerId) async {
    _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers.map((p) {
        if (p.isHandler) return p.copyWith(isHandler: false);
        if (p.id == passengerId) return p.copyWith(isHandler: true);
        return p;
      }).toList();
      return t.copyWith(handlerId: passengerId, passengers: updatedPassengers);
    });
    final tour = getTour(tourId);
    if (tour != null) {
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: tour.toMap(),
      );
      for (final p in tour.passengers) {
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: p.id,
          data: p.toMap(),
        );
      }
    }
  }

  Future<void> removeHandler(String tourId) async {
    _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers
          .map((p) => p.isHandler ? p.copyWith(isHandler: false) : p)
          .toList();
      return t.copyWith(handlerId: null, passengers: updatedPassengers);
    });
    final tour = getTour(tourId);
    if (tour != null) {
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: tour.toMap(),
      );
    }
  }

  // Bus Management
  Future<void> addBus(String tourId, Bus bus) async {
    final boundBus = bus.copyWith(tourId: tourId);
    _updateTourLocal(tourId, (t) {
      final list = List<Bus>.from(t.buses)..add(boundBus);
      return t.copyWith(buses: list);
    });
    final busData = {
      ...boundBus.toMap(),
      'owner_id': _auth.currentAdmin.value?.id,
    };
    try {
      await _sync.smartInsert(
        table: 'buses',
        entityId: boundBus.id,
        data: busData,
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not add bus. $e', title: 'Save failed');
      rethrow;
    }
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.collecting) {
      await updateStatus(tourId, TourStatus.busBooked);
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  Future<void> updateBus(String tourId, Bus bus) async {
    _updateTourLocal(tourId, (t) {
      final list = t.buses.map((b) => b.id == bus.id ? bus : b).toList();
      return t.copyWith(buses: list);
    });
    try {
      await _sync.smartUpdate(
        table: 'buses',
        entityId: bus.id,
        data: bus.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not update bus. $e', title: 'Save failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  Future<void> removeBus(String tourId, String busId) async {
    _updateTourLocal(tourId, (t) {
      final list = t.buses.where((b) => b.id != busId).toList();
      return t.copyWith(buses: list, busId: t.busId == busId ? null : t.busId);
    });
    try {
      await _sync.smartDelete(
        table: 'buses',
        entityId: busId,
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not remove bus. $e', title: 'Delete failed');
      rethrow;
    }
    final tour = getTour(tourId);
    if (tour != null) {
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: tour.toMap(),
      );
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  // Queries
  List<Tour> toursByStatus(TourStatus status) =>
      tours.where((t) => t.status == status).toList();

  /// Cross-booking groups for [tourId] (empty when the tour is unknown or
  /// has no groups yet). Loaded by the sync layer alongside passengers/buses.
  List<PassengerGroup> groupsForTour(String tourId) =>
      getTour(tourId)?.groups ?? const <PassengerGroup>[];

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
  Future<String> createGroup(String tourId, String label,
      {int colorIndex = 0}) async {
    final group = PassengerGroup(
      tourId: tourId,
      label: label,
      colorIndex: colorIndex,
    );
    _updateTourLocal(tourId, (t) {
      final list = List<PassengerGroup>.from(t.groups)..add(group);
      return t.copyWith(groups: list);
    });
    try {
      await _sync.smartInsert(
        table: 'passenger_groups',
        entityId: group.id,
        data: group.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not create group. $e', title: 'Save failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
    return group.id;
  }

  /// Set or clear a passenger's group membership. Pass `null` to ungroup.
  Future<void> setPassengerGroup(
      String tourId, String passengerId, String? groupId) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      // copyWith uses `??`, so it can't clear group_id back to null. Build the
      // updated passenger explicitly to allow an explicit null (ungroup).
      updated = _passengerWithGroup(p, groupId);
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not update group. $e',
        title: 'Save failed',
      );
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  /// Delete a group: first clears `group_id` on every member (locally and on
  /// the server) so no passenger row dangles a reference to a deleted group,
  /// then deletes the group row itself.
  Future<void> deleteGroup(String tourId, String groupId) async {
    final tour = getTour(tourId);
    if (tour == null) return;

    final members =
        tour.passengers.where((p) => p.groupId == groupId).toList();

    // Optimistic local update: clear members, drop the group row.
    _updateTourLocal(tourId, (t) {
      final nextPassengers = t.passengers
          .map((p) => p.groupId == groupId ? _passengerWithGroup(p, null) : p)
          .toList();
      final nextGroups = t.groups.where((g) => g.id != groupId).toList();
      return t.copyWith(passengers: nextPassengers, groups: nextGroups);
    });

    try {
      for (final p in members) {
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: p.id,
          data: _passengerWithGroup(p, null).toMap(),
        );
      }
      await _sync.smartDelete(
        table: 'passenger_groups',
        entityId: groupId,
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not delete group. $e', title: 'Delete failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  // Priority

  /// Approve or clear a passenger's priority (front/sofa) status. `approved`
  /// maps to [PriorityStatus.approved]; otherwise [PriorityStatus.none].
  Future<void> setPassengerPriority(
      String tourId, String passengerId, bool approved) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(
        priorityStatus:
            approved ? PriorityStatus.approved : PriorityStatus.none,
      );
      return updated!;
    });
    if (updated == null) return;
    try {
      await _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated!.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        'Could not update priority. $e',
        title: 'Save failed',
      );
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  // Seat flags (forward / reserved)
  //
  // Both flags live on individual SeatCells inside the bus layout grid, so
  // toggling one means rebuilding that bus's layout and persisting the whole
  // bus row — the same shape updateBus uses.

  /// Toggle the "forward / premium" flag on a single seat of [busId].
  Future<void> setSeatForward(
          String tourId, String busId, String seatId, bool forward) =>
      _updateSeatFlag(tourId, busId, seatId,
          (cell) => cell.copyWith(forward: forward));

  /// Toggle the "reserved / held back" flag on a single seat of [busId].
  Future<void> setSeatReserved(
          String tourId, String busId, String seatId, bool reserved) =>
      _updateSeatFlag(tourId, busId, seatId,
          (cell) => cell.copyWith(reserved: reserved));

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
      note: p.note,
      tripType: p.tripType,
      groupId: groupId,
      priorityStatus: p.priorityStatus,
      priorityReason: p.priorityReason,
      createdAt: p.createdAt,
    );
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

    _updateTourLocal(tourId, (t) {
      final list = t.buses.map((b) => b.id == busId ? updatedBus : b).toList();
      return t.copyWith(buses: list);
    });

    try {
      await _sync.smartUpdate(
        table: 'buses',
        entityId: busId,
        data: updatedBus.toMap(),
      );
    } catch (e) {
      await refreshTours();
      AppSnackBar.error('Could not update the seat. $e', title: 'Save failed');
      rethrow;
    }
    await _sync.invalidateCache(_tourCacheKey);
  }

  Future<void> _updateTour(String tourId, Tour Function(Tour) updater) async {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx >= 0) {
      final updated = updater(tours[idx]);
      tours[idx] = updated;
      tours.refresh();
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: updated.toMap(),
      );
      await _sync.invalidateCache(_tourCacheKey);
    }
  }

  void _updateTourLocal(String tourId, Tour Function(Tour) updater) {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx >= 0) {
      tours[idx] = updater(tours[idx]);
      tours.refresh();
    }
  }

  void _updatePassengerLocal(
      String tourId, String passengerId, Passenger Function(Passenger) updater) {
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        return p.id == passengerId ? updater(p) : p;
      }).toList();
      return t.copyWith(passengers: list);
    });
  }
}
