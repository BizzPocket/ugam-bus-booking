part of '../tour_controller.dart';

/// Shared state + write plumbing every [TourController] concern builds on.
///
/// [TourController] is ONE class assembled from a linear chain of private
/// mixins (one file per concern under `tour_controller/`). Each mixin is
/// declared `on` the one before it, so a concern may call anything defined
/// earlier in the chain; the single back-edge ([refreshTours], which the
/// optimistic-write recovery in [_write] needs) is declared abstract here.
abstract class _TourControllerBase extends GetxController {
  final tours = <Tour>[].obs;
  final isLoading = false.obs;
  /// Monotonic load generation — a stale in-flight fetch must not paint
  /// [hasError] over a newer success (cold-start auth reload + online ever
  /// can overlap the first attempt).
  int _loadGeneration = 0;
  final hasError = false.obs;
  final errorMessage = ''.obs;

  SyncService get _sync => Get.find<SyncService>();
  AuthController get _auth => Get.find<AuthController>();
  RealtimeService get _realtime => Get.find<RealtimeService>();

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

  /// Bus ids the SERVER has positively answered `layout: null` for.
  ///
  /// The distinction that keeps [layoutsLoadedFor] honest. A null layout in
  /// memory means one of two very different things, and only this set tells
  /// them apart:
  ///
  ///  * **in here** — the grid is genuinely absent server-side (the wipe
  ///    `recoverBusLayoutFor` repairs). "No seat plan" is the true answer and
  ///    re-fetching would burn a request on every refresh forever.
  ///  * **not in here** — we simply do not hold it: never fetched, or dropped
  ///    by a merge. The honest answer is "loading", and it must be re-fetched.
  ///
  /// Cleared the moment a grid arrives for that bus, so a recovered or
  /// re-generated bus stops being treated as known-empty.
  final _layoutKnownNullBusIds = <String>{};

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

  /// Force a fresh fetch from Supabase — implemented by the sync concern
  /// ([_TourSync]); declared here because [_write] snaps back through it.
  Future<void> refreshTours();

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
