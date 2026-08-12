import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../models/attendance.dart';
import '../models/bus_details.dart';
import '../models/bus_handover.dart';
import '../models/collection.dart';
import '../models/expense.dart';
import '../models/handler_bus_money.dart';
import '../models/handler_manifest.dart';
import '../models/handler_phase.dart';
import '../models/handler_report.dart';
import '../models/income_entry.dart';
import '../models/passenger.dart';
import '../services/customer_requests_store.dart';
import '../utils/boarding_stops.dart';
import '../utils/collection_seat_resolver.dart';
import '../utils/collection_write.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_occupants.dart';
import 'pickup_controller.dart';

/// Signature of [CustomerRequestsStore.handlerTourManifest].
typedef HandlerManifestReader =
    Future<HandlerManifest?> Function(String requestId);

/// Why a fetch is running. This decides two things a refresh loop gets wrong if
/// it treats every fetch alike: whether a spinner is shown, and what a FAILURE
/// is allowed to do to whatever is already on screen.
enum HandlerLoadKind {
  /// Screen open, or Retry from the error card. Nothing on screen to protect,
  /// so this one shows the skeleton and a failure may take over the body.
  initial,

  /// The handler pulled down. The RefreshIndicator owns the spinner, so we show
  /// none of our own; a failure keeps the rows and toasts instead.
  pull,

  /// A background reconcile — after a write, or on app resume. Deliberately
  /// invisible: no spinner, no skeleton, and a silent failure, because these
  /// fire on every saved expense and every return from the lock screen.
  silent,
}

/// Everything the handler surface knows, in one place.
///
/// The old handler screen kept the manifest and all five caches in
/// `_HandlerBusChartScreenState` and mutated them with `setState`. That is the
/// mechanical reason the features never behaved as one app: state that lives
/// inside one widget cannot be read by a sibling, so collecting cash could not
/// re-tint a seat on the chart, closing the GO leg could not move the boarding
/// list to the return, and the money hero could not know whether the bus had
/// even departed. Every one of those was a wiring problem, not a missing
/// feature.
///
/// Holding it in a controller instead means the four tabs are pure readers of
/// one reactive source. A write lands in the cache once and every surface that
/// depends on it re-renders — no cross-tab callbacks, no duplicated derivation.
class HandlerController extends GetxController {
  HandlerController({required this.requestId, this.manifestReader});

  final String requestId;

  /// TEST SEAM for the manifest read — [CustomerRequestsStore] is a
  /// private-constructor singleton wired straight to Supabase, so without this
  /// a widget test could only ever drive the failure path. Production leaves it
  /// null. Only the manifest needs one: every other read is best-effort and
  /// degrades to empty (see [_safe]).
  final HandlerManifestReader? manifestReader;

  final _store = CustomerRequestsStore();

  // ── Raw state ─────────────────────────────────────────────

  final loading = true.obs;
  final error = RxnString();
  final manifest = Rxn<HandlerManifest>();
  final selectedBusId = RxnString();

  /// True once a fetch has genuinely succeeded. It is what lets a LATER failure
  /// be treated as "keep what we have" rather than "show the error card", so a
  /// transient timeout mid-trip can't wipe a screen full of good figures.
  bool loadedOnce = false;

  /// Monotonic token identifying the newest in-flight fetch. Several can be in
  /// the air at once (a silent post-write reconcile fired while a pull-to-
  /// refresh is still running) and they can land out of order; only the load
  /// still holding the current token may commit.
  int _loadToken = 0;

  /// Collection rows keyed `passengerId|busId|seatId`.
  final collections = <String, Collection>{}.obs;

  /// Expense rows keyed by id.
  final expenses = <String, Expense>{}.obs;

  /// Income rows keyed by id.
  final incomes = <String, IncomeEntry>{}.obs;

  /// Attendance rows keyed `passengerId|busId|leg`.
  final attendance = <String, Attendance>{}.obs;

  /// Cash already handed to the admin, keyed by id.
  final handovers = <String, BusHandover>{}.obs;

  /// Per-bus outbound progress, keyed by bus id.
  final legState = <String, HandlerBusLegState>{}.obs;

  /// Per-bus trip milestones, keyed by bus id.
  final tripState = <String, HandlerTripState>{}.obs;

  /// Problems raised with the agent, newest first.
  final reports = <HandlerReport>[].obs;

  /// The leg the handler has explicitly switched the boarding list to, or null
  /// to follow the phase. Kept separate from the effective leg so that
  /// [legForBoarding] can lead by default without ever fighting a handler who
  /// deliberately looked at the other leg.
  final legOverride = Rxn<AttendanceLeg>();

  // ── Keys ──────────────────────────────────────────────────

  String _collectionKey(String passengerId, String busId, String seatId) =>
      '$passengerId|$busId|$seatId';

  String _attKey(String passengerId, String busId, AttendanceLeg leg) =>
      '$passengerId|$busId|${leg.name}';

  // ── Derived: buses ────────────────────────────────────────

  List<Bus> get buses => manifest.value?.buses ?? const <Bus>[];

  bool get isMultiBus => buses.length > 1;

  Bus? get selectedBus {
    final list = buses;
    if (list.isEmpty) return null;
    final id = selectedBusId.value;
    if (id != null) {
      for (final b in list) {
        if (b.id == id) return b;
      }
    }
    return list.first;
  }

  void selectBus(String busId) => selectedBusId.value = busId;

  /// Which bus stays selected after a re-read. A refresh must NOT yank a
  /// multi-bus handler back to bus 1 — these fire on every save and every
  /// resume. Only a bus that has genuinely gone away falls back.
  String? _busIdAfterReload(HandlerManifest? m) {
    final list = m?.buses ?? const <Bus>[];
    if (list.isEmpty) return null;
    final current = selectedBusId.value;
    if (current != null && list.any((b) => b.id == current)) return current;
    return list.first.id;
  }

  // ── Derived: phase ────────────────────────────────────────

  HandlerTripState tripFor(String busId) =>
      tripState[busId] ?? HandlerTripState.fresh(busId);

  /// Whether [busId] carries anyone on the return leg. Read from leg state
  /// rather than counted client-side so it matches what the seat-release RPC
  /// sees. A backend without migration 046 reports nothing, and the safe answer
  /// there is "assume there is a return" — that keeps the handler in the
  /// boarding flow rather than jumping them to settlement on a bus that is
  /// still going home.
  bool hasReturnRiders(String busId) {
    final s = legState[busId];
    if (s == null) return true;
    return s.ridersOnReturn > 0;
  }

  /// The phase of the currently selected bus. Everything the shell shows —
  /// banner, milestone CTA, default leg, which tab is worth being on — reads
  /// this one value.
  HandlerPhase get phase {
    final bus = selectedBus;
    if (bus == null) return HandlerPhase.boardingGo;
    return phaseForBus(bus);
  }

  HandlerPhase phaseForBus(Bus bus) => resolveHandlerPhase(
    trip: tripFor(bus.id),
    hasReturnRiders: hasReturnRiders(bus.id),
    moneySettled: summaryFor(bus).isSettled,
  );

  /// The single milestone offered right now, or null when the phase's next step
  /// is a handover rather than a stamp.
  HandlerMilestone? get milestone => milestoneFor(phase);

  /// Which leg the boarding list and its tally are about: the handler's own
  /// choice if they made one, otherwise whichever leg the phase implies.
  ///
  /// This is the wiring that was missing. Before, the attendance toggle sat on
  /// GO until somebody moved it by hand, so a handler boarding the return
  /// marked people onto the outbound leg.
  AttendanceLeg get legForBoarding {
    final override = legOverride.value;
    if (override != null) return override;
    return phase.isReturnSide ||
            phase == HandlerPhase.settling ||
            phase == HandlerPhase.closed
        ? AttendanceLeg.ret
        : AttendanceLeg.go;
  }

  void setLeg(AttendanceLeg leg) => legOverride.value = leg;

  // ── Derived: money ────────────────────────────────────────

  List<Expense> expensesForBus(String busId) {
    final list = expenses.values.where((e) => e.busId == busId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  List<IncomeEntry> incomesForBus(String busId) {
    final list = incomes.values.where((i) => i.busId == busId).toList();
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  List<BusHandover> handoversForBus(String busId) =>
      handovers.values.where((h) => h.busId == busId).toList()
        ..sort((a, b) => b.settledAt.compareTo(a.settledAt));

  /// Manifest rows with any locally-cached edit layered over the top, merged by
  /// ROW ID rather than by the cache key: a row can be adopted under a seat
  /// other than the one it stores, so keying the merge by seat would show the
  /// manifest's stale copy alongside the edited one and double-count it.
  Iterable<Collection> get mergedCollections {
    final byId = <String, Collection>{
      for (final c in manifest.value?.collections ?? const <Collection>[])
        c.id: c,
    };
    for (final c in collections.values) {
      byId[c.id] = c;
    }
    return byId.values;
  }

  /// The EXISTING collection row a tap on [seatId] must write into, or null
  /// when this seat genuinely deserves a new one. Resolves through
  /// [collectionRowForSeat], not the strict (passenger, bus, seat) triple — a
  /// rider who paid on one seat and later moved MISSED on that triple, so the
  /// sheet opened blank and the save INSERTed a second row that the ledger then
  /// double-posted.
  Collection? collectionFor(Passenger passenger, String busId, String seatId) =>
      collectionRowForSeat(
        passenger: passenger,
        busId: busId,
        seatId: seatId,
        collections: mergedCollections,
      );

  /// Per-bus money totals, built on the shared [HandlerBusMoney] so the handler
  /// can never disagree with the admin's money board on what was collected.
  ///
  /// No busRent here on purpose: the bus owner's rent is the ADMIN's cost,
  /// settled out of what the handler hands over.
  HandlerBusMoney summaryFor(Bus bus) {
    final m = manifest.value;
    if (m == null) {
      return HandlerBusMoney.compute(
        busId: bus.id,
        passengers: const [],
        collections: const [],
        expenses: const [],
        incomes: const [],
        handovers: const [],
        dueForSeat: bus.amountDueForSeat,
      );
    }
    return HandlerBusMoney.compute(
      busId: bus.id,
      passengers: m.passengers,
      collections: collections.values.toList(),
      expenses: expensesForBus(bus.id),
      incomes: incomesForBus(bus.id),
      handovers: handoversForBus(bus.id),
      dueForSeat: bus.amountDueForSeat,
    );
  }

  // ── Derived: attendance & boarding ────────────────────────

  Attendance? attendanceFor(
    String passengerId,
    String busId,
    AttendanceLeg leg,
  ) {
    final cached = attendance[_attKey(passengerId, busId, leg)];
    if (cached != null) return cached;
    return manifest.value?.attendanceFor(passengerId, busId, leg);
  }

  /// Unmarked passengers are NOT counted as boarded: the tally treats "no row"
  /// as "not yet boarded" so the handler can work through the manifest. The
  /// model's own default of present=true only applies once a row is written.
  bool isPresent(String passengerId, String busId, AttendanceLeg leg) =>
      attendanceFor(passengerId, busId, leg)?.present ?? false;

  /// Every passenger expected to board [bus] on [leg], deduped and name-sorted.
  /// The leg comes from the SEAT held on THIS bus, not from the rider's overall
  /// tripType — which listed a round-trip rider here for the return even when
  /// their return berth was on a different bus.
  List<Passenger> expectedForLeg(Bus bus, AttendanceLeg leg) {
    final m = manifest.value;
    if (m == null) return const [];
    final out = ridersOnBusForLeg(
      m.passengers,
      bus.id,
      leg == AttendanceLeg.go ? CollectLeg.go : CollectLeg.ret,
    );
    out.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return out;
  }

  /// The stop-by-stop boarding picture for [bus] on [leg].
  BoardingProgress boardingFor(Bus bus, AttendanceLeg leg) {
    final pk = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    return buildBoardingProgress(
      expectedForLeg(bus, leg),
      isPresent: (p) => isPresent(p.id, bus.id, leg),
      rankOf: pk == null ? null : (id, name) => pk.rankFor(id: id, name: name),
    );
  }

  /// Unacknowledged problem reports — what the Trip tab badges.
  int get openReportCount => reports.where((r) => !r.isAcknowledged).length;

  // ── Load ──────────────────────────────────────────────────

  @override
  void onInit() {
    super.onInit();
    load();
    // Warm the global pickup list so boarding stops can be put in route order.
    // Registered lazily app-wide; absent under `flutter test`.
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
  }

  /// Fire-and-forget background re-read, used after every mutation and on app
  /// resume: the optimistic local patch already made the UI feel instant, and
  /// this confirms it against the server rather than trusting the cache
  /// forever.
  void reconcile() => unawaited(load(kind: HandlerLoadKind.silent));

  Future<void> load({HandlerLoadKind kind = HandlerLoadKind.initial}) async {
    final token = ++_loadToken;
    if (kind == HandlerLoadKind.initial && !loading.value) {
      loading.value = true;
      error.value = null;
    }
    try {
      final read = manifestReader ?? _store.handlerTourManifest;
      final fresh = await read(requestId);
      // These ride alongside the manifest rather than inside it (its live body
      // has drifted from the files, so it is never rewritten). All best-effort:
      // a handler whose backend predates any of these RPCs still gets a working
      // board, just without that affordance.
      final freshHandovers = await _safe(
        () => _store.handlerBusHandovers(requestId),
      );
      final freshLegState = await _safe(
        () => _store.handlerBusLegState(requestId),
      );
      final freshTrip = await _safe(
        () => _store.handlerBusTripState(requestId),
      );
      final freshReports = await _safe(() => _store.handlerReports(requestId));

      if (token != _loadToken) return;

      manifest.value = fresh;
      handovers.value = {for (final h in freshHandovers) h.id: h};
      legState.value = {for (final s in freshLegState) s.busId: s};
      tripState.value = {for (final t in freshTrip) t.busId: t};
      reports.value = freshReports;
      collections.value = {
        for (final c in fresh?.collections ?? const <Collection>[])
          _collectionKey(c.passengerId, c.busId, c.seatId): c,
      };
      expenses.value = {
        for (final e in fresh?.expenses ?? const <Expense>[]) e.id: e,
      };
      incomes.value = {
        for (final i in fresh?.incomes ?? const <IncomeEntry>[]) i.id: i,
      };
      attendance.value = {
        for (final a in fresh?.attendance ?? const <Attendance>[])
          _attKey(a.passengerId, a.busId, a.leg): a,
      };
      selectedBusId.value = _busIdAfterReload(fresh);
      loadedOnce = true;
      error.value = null;
      loading.value = false;
    } catch (_) {
      if (token != _loadToken) return;
      // Only COMMIT fetched rows when the load genuinely succeeded. Nothing
      // above ran, so a failure inherently keeps the last-known rows; what must
      // NOT happen is flipping to the error card and throwing away a screen
      // full of good figures over a dropped packet on the highway.
      if (loadedOnce) {
        loading.value = false;
        if (kind != HandlerLoadKind.silent) {
          _notifyRefreshFailed?.call();
        }
        return;
      }
      error.value = 'load';
      loading.value = false;
    }
  }

  /// Reads that must never take the whole screen down: on a backend where the
  /// migration behind them has not been run these RPCs do not exist and
  /// PostgREST answers PGRST202, which would otherwise land in [load]'s catch
  /// and show "could not load" over a board that is perfectly fine.
  Future<List<T>> _safe<T>(Future<List<T>> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return const [];
    }
  }

  /// Set by the shell so a failed non-silent refresh can toast. Kept as a hook
  /// rather than calling the snackbar directly so the controller stays free of
  /// UI imports and testable without a widget tree.
  void Function()? _notifyRefreshFailed;
  set onRefreshFailed(void Function()? cb) => _notifyRefreshFailed = cb;

  // ── Writes ────────────────────────────────────────────────

  /// Marks [p] present / left-behind on [bus] for [leg]. Throws on rejection so
  /// the caller can toast; the cache is only touched on success.
  Future<void> setPresent(
    Bus bus,
    Passenger p,
    AttendanceLeg leg,
    bool present,
  ) async {
    final tourId = (bus.tourId?.isNotEmpty == true) ? bus.tourId! : p.tourId;
    final existing = attendanceFor(p.id, bus.id, leg);
    final base =
        existing ??
        Attendance(tourId: tourId, busId: bus.id, passengerId: p.id, leg: leg);
    final saved = await _store.handlerUpsertAttendance(
      requestId,
      base.copyWith(present: present),
    );
    if (saved == null) throw StateError('Handler attendance save rejected.');
    attendance[_attKey(saved.passengerId, saved.busId, saved.leg)] = saved;
    reconcile();
  }

  /// Boards everyone still unmarked at one stop in a single call.
  ///
  /// The bulk action the flat list never had: at a stop where all six riders
  /// got on, six taps and six round-trips over 2G is the difference between
  /// the handler using the app and giving up on it. Failures are collected
  /// rather than aborting — a partial success still banks the riders it got.
  /// Returns the number actually boarded.
  Future<int> boardAllAt(Bus bus, AttendanceLeg leg, BoardingStop stop) async {
    var done = 0;
    for (final p in stop.riders) {
      if (isPresent(p.id, bus.id, leg)) continue;
      try {
        await setPresent(bus, p, leg, true);
        done++;
      } catch (_) {
        // Keep going: one rider's failed write must not strand the rest.
      }
    }
    return done;
  }

  /// Saves a collection against [seatId]. An ADOPTED row keeps its own seat_id,
  /// because the upsert's conflict target is (passenger_id, bus_id, seat_id)
  /// and rewriting it turns the update into an INSERT that collides on the PK.
  Future<void> saveCollection({
    required Bus bus,
    required Passenger passenger,
    required String seatId,
    required double due,
    required double received,
    required double manualReturned,
    required String collectedBy,
    required String note,
  }) async {
    final existing = collectionFor(passenger, bus.id, seatId);
    final tourId = (bus.tourId?.isNotEmpty == true)
        ? bus.tourId!
        : passenger.tourId;
    final updated = buildCollectionToSave(
      existing: existing,
      tourId: tourId,
      busId: bus.id,
      passengerId: passenger.id,
      seatId: seatId,
      due: due,
      received: received,
      manualReturned: manualReturned,
      collectedBy: collectedBy,
      note: note,
    );
    final saved = await _store.handlerUpsertCollection(requestId, updated);
    if (saved == null) throw StateError('Handler collection save rejected.');
    collections[_collectionKey(saved.passengerId, saved.busId, saved.seatId)] =
        saved;
    reconcile();
  }

  Future<void> saveExpense({
    required Bus bus,
    required String draftId,
    Expense? existing,
    required ExpenseCategory category,
    required String label,
    required double amount,
    required String paidBy,
  }) async {
    final tourId = bus.tourId?.isNotEmpty == true ? bus.tourId! : '';
    final base =
        existing ??
        Expense(id: draftId, tourId: tourId, busId: bus.id, label: label);
    final saved = await _store.handlerUpsertExpense(
      requestId,
      base.copyWith(
        busId: bus.id,
        category: category,
        label: label,
        amount: amount,
        paidBy: paidBy.isEmpty ? null : paidBy,
      ),
    );
    if (saved == null) throw StateError('Handler expense save rejected.');
    expenses[saved.id] = saved;
    reconcile();
  }

  Future<bool> deleteExpense(Expense e) async {
    final removed = await _store.handlerDeleteExpense(requestId, e.id);
    if (!removed) return false;
    expenses.remove(e.id);
    reconcile();
    return true;
  }

  Future<void> saveIncome({
    required Bus bus,
    required String draftId,
    IncomeEntry? existing,
    required IncomeCategory category,
    required String label,
    required double amount,
    required String receivedBy,
  }) async {
    final tourId = bus.tourId?.isNotEmpty == true ? bus.tourId! : '';
    final base =
        existing ??
        IncomeEntry(id: draftId, tourId: tourId, busId: bus.id, label: label);
    final saved = await _store.handlerUpsertIncome(
      requestId,
      base.copyWith(
        busId: bus.id,
        category: category,
        label: label,
        amount: amount,
        receivedBy: receivedBy.isEmpty ? null : receivedBy,
      ),
    );
    if (saved == null) throw StateError('Handler income save rejected.');
    incomes[saved.id] = saved;
    reconcile();
  }

  Future<bool> deleteIncome(IncomeEntry i) async {
    final removed = await _store.handlerDeleteIncome(requestId, i.id);
    if (!removed) return false;
    incomes.remove(i.id);
    reconcile();
    return true;
  }

  /// [draftId] is minted once per SHEET, not once per save attempt: the model
  /// constructors do `id = id ?? Uuid().v4()`, so building the row per attempt
  /// gave every retry a fresh id, and the RPCs conflict only on (id) — a retry
  /// after a commit whose response was lost became a plain INSERT, which the
  /// ledger sync then double-posted.
  Future<void> saveHandover({
    required Bus bus,
    required String draftId,
    required double expected,
    required double amount,
    required String? note,
  }) async {
    final m = manifest.value;
    final tourId = (bus.tourId?.isNotEmpty == true)
        ? bus.tourId!
        : (m?.passengers.isNotEmpty == true ? m!.passengers.first.tourId : '');
    final saved = await _store.handlerUpsertHandover(
      requestId,
      BusHandover(
        id: draftId,
        tourId: tourId,
        busId: bus.id,
        expectedAmount: expected,
        handedOverAmount: amount,
        note: note,
      ),
    );
    if (saved == null) throw StateError('Handover rejected.');
    handovers[saved.id] = saved;
    reconcile();
  }

  Future<bool> deleteHandover(BusHandover h) async {
    final removed = await _store.handlerDeleteHandover(requestId, h.id);
    if (!removed) return false;
    handovers.remove(h.id);
    reconcile();
    return true;
  }

  /// Releases outbound-only seats on [bus] — their riders have completed their
  /// only journey. Returns how many were cleared. The server freezes the
  /// outbound chart into a snapshot in the same transaction first.
  Future<int?> completeOutboundLeg(Bus bus) async {
    final cleared = await _store.handlerCompleteOutboundLeg(requestId, bus.id);
    if (cleared == null) throw StateError('Leg completion rejected.');
    // Seats moved server-side, so re-read rather than patching locally.
    await load(kind: HandlerLoadKind.silent);
    return cleared;
  }

  /// Stamps a trip milestone and advances the phase.
  ///
  /// [HandlerMilestone.arriveGo] additionally releases outbound-only seats when
  /// the bus carries any — the two belong together (the outbound is over, so
  /// those berths are free), and splitting them is what left the old
  /// leg-completion card floating with no relationship to anything around it.
  /// The release is best-effort: the stamp is what drives the phase, and a bus
  /// that has arrived must not be stuck en route because a seat release failed.
  Future<void> stampMilestone(Bus bus, HandlerMilestone milestone) async {
    final saved = await _store.handlerStampMilestone(
      requestId,
      bus.id,
      milestone,
    );
    if (saved == null) throw StateError('Milestone rejected.');
    tripState[bus.id] = saved;

    if (milestone == HandlerMilestone.arriveGo) {
      final s = legState[bus.id];
      final pending = (s?.outboundOnlyTotal ?? 0) - (s?.outboundOnlyDone ?? 0);
      if (pending > 0) {
        try {
          await completeOutboundLeg(bus);
        } catch (_) {
          // Phase already advanced; the Trip tab still offers the release.
        }
      }
    }

    // A new phase changes which leg the boarding list should show, so drop any
    // manual override — otherwise a handler who peeked at the return leg during
    // the outbound would find the list stuck there for the rest of the trip.
    legOverride.value = null;
    reconcile();
  }

  /// Raises a problem with the agent.
  Future<void> sendReport({
    required Bus bus,
    required String draftId,
    required HandlerReportKind kind,
    required String message,
    String? reportedBy,
  }) async {
    final m = manifest.value;
    final tourId = (bus.tourId?.isNotEmpty == true)
        ? bus.tourId!
        : (m?.passengers.isNotEmpty == true ? m!.passengers.first.tourId : '');
    final saved = await _store.handlerCreateReport(
      requestId,
      HandlerReport(
        id: draftId,
        tourId: tourId,
        busId: bus.id,
        kind: kind,
        message: message,
        reportedBy: reportedBy,
      ),
    );
    if (saved == null) throw StateError('Report rejected.');
    reports.insert(0, saved);
    reports.refresh();
  }

  /// A stable draft id for a sheet, so a retry after a lost response updates
  /// the same row instead of filing a second one.
  String newDraftId() => const Uuid().v4();
}
