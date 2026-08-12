/// **The Board** — one canvas, one lens switcher, in place of eleven screens.
///
/// Spec: `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
/// This file is the *assembly*, and deliberately nothing else. Every piece it
/// mounts was built and tested on its own:
///
///  * `BoardController`      — lens / density / filter / search / walk state
///  * `BoardCanvas`          — the bus, its geometry, its gestures, its strip
///  * `BoardSummaryStrip`    — the number that must never scroll away (§3)
///  * `BoardLensSwitcher`    — the tab bar that replaces the eleven screens (§5)
///  * `BoardLegend`          — the colour key that is also the filter (§5)
///  * `BerthTile`            — one berth, painted by whichever lens is active
///  * `PassengerSheet`       — one sheet, whichever lens opened it
///
/// What is genuinely NEW here is three things, and they are the three things
/// nothing else could own:
///
///  1. **Data.** A tour is turned into `BoardBusPage`s — one per bus, berth
///     facts keyed by seat id. The mapping is pure ([boardBerthsForBus]) so it
///     is provable in a unit test rather than eyeballed on a device.
///  2. **The aisle-order walk (§4).** "આગળનું બાકી →" advances the cursor in
///     physical walking order, reveals the berth, opens its sheet, and — when
///     the lens's own action completes — advances again. A 22-person collection
///     round becomes 22 taps with no navigation. This is the single most
///     important interaction on the Board and it lives in [_advanceWalk].
///  3. **The writes.** Collecting cash goes through `MoneyController` and hands
///     back a real undo (§8), so a mis-tap at 5am is one tap away from being
///     put back.
///
/// **What this wave deliberately does NOT do**, so the stop-and-review gate
/// (§15 step 2) reviews something honest rather than something half-wired:
///
///  * Only the two shipped lenses are offered (`kShippedBoardLenses`). The
///    pickup / group / boarding lenses are modelled in full but have no data
///    source on the admin side yet, and a Board that opened on one of them
///    would show a convincing chart of nothing.
///  * No drag-to-assign and no assign picker (§7). Tapping a VACANT berth parks
///    the walk cursor and nothing more — the seat editor still lives at its own
///    route and is untouched. Wiring a half-assign flow into the review would
///    be the one way to make the gate answer the wrong question.
///  * No offline queue (§9). Board writes go straight through the existing sync
///    layer, exactly as the collection screen's do.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/board_controller.dart';
import '../../controllers/money_controller.dart';
import '../../controllers/tour_controller.dart';
// Not in the `ugam.dart` barrel yet — imported directly, exactly as
// `berth_tile.dart` and the rest of the Board's widgets do.
import '../../design/components/ugam_tappable.dart';
import '../../design/ugam.dart';
import '../../models/board_lens.dart';
import '../../models/bus_details.dart';
import '../../models/collection.dart';
import '../../models/handler_phase.dart';
import '../../models/passenger.dart';
import '../../models/seat_layout.dart';
import '../../models/tour.dart';
import '../../models/tour_status.dart';
import '../../routes/app_routes.dart';
import '../../utils/aisle_order.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/collection_write.dart';
import '../../utils/formatters.dart';
import '../../utils/passenger_display.dart';
import '../../utils/seat_money_state.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/board/berth_tile.dart';
import '../../widgets/board/board_canvas.dart';
import '../../widgets/board/board_empty_states.dart';
import '../../widgets/board/board_legend.dart';
import '../../widgets/board/lens_switcher.dart';
import '../../widgets/board/passenger_sheet.dart';
import '../add_bus_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pure mapping — tour facts → Board facts.
// ─────────────────────────────────────────────────────────────────────────────

/// Whole calendar days from [now] to [departure]; negative once it has passed.
///
/// Calendar days, not elapsed hours: a bus leaving at 06:00 tomorrow is ONE day
/// out at 23:00 tonight and at 07:00 this morning alike, and the T-2d money
/// chase of spec §6 is a thing agents count in sleeps, not in hours.
int boardDaysUntilDeparture(DateTime departure, DateTime now) {
  final from = DateTime(now.year, now.month, now.day);
  final to = DateTime(departure.year, departure.month, departure.day);
  return to.difference(from).inDays;
}

/// The trip phase the ADMIN Board can honestly claim for [tour].
///
/// [HandlerPhase] is derived from the four timestamps a handler stamps on a bus
/// (`handler_bus_trip_state`), and the admin app does not hold them — so
/// inventing a phase here would be a guess dressed as a fact. Only one value is
/// knowable from tour state alone:
///
///  * a COMPLETED tour is [HandlerPhase.closed] — books square, read-only, and
///    spec §6 opens it on the roster rather than on a chase.
///
/// Everything else returns null, which [defaultLensForPhase] reads as "the bus
/// is still being filled" and then resolves against
/// [BoardController.daysUntilDeparture] — the one fact the admin side really
/// does know. That is what makes a tour two days out open on Money and a tour
/// two months out open on Occupancy, with no handler session in sight.
HandlerPhase? boardPhaseForTour(Tour tour) =>
    tour.status == TourStatus.completed ? HandlerPhase.closed : null;

/// Berth facts for one bus, keyed by `SeatCell.seatId`.
///
/// **Only OCCUPIED berths are emitted.** `boardBerthFor` already synthesises an
/// honest vacant / blocked berth for any cell the map has nothing for, from the
/// cell's own geometry, so filling this with 74 empty entries would be 74
/// allocations a rebuild to say what the canvas already knows. It also means a
/// partially-loaded roster degrades to "empty", never to a hole in the chart.
///
/// [collectionFor] resolves the money row for one rider on one berth — pass
/// `MoneyController.collectionFor`, which adopts a row the rider paid on a seat
/// they have since left. Reading the amounts through it rather than off the
/// passenger is what keeps the money lens agreeing with the money board.
///
/// A shared berth (a split sofa, or a GO rider and a RET rider on disjoint
/// legs) sums BOTH riders' fares and BOTH their payments, because the tile
/// draws one berth and the lens colours one berth. The individual positions are
/// resolved again, per rider, when the sheet opens.
Map<String, BoardBerth> boardBerthsForBus({
  required Bus bus,
  required List<Passenger> passengers,
  Map<String, String> groupNames = const <String, String>{},
  Collection? Function(Passenger passenger, String seatId)? collectionFor,
}) {
  final layout = bus.layout;
  if (layout == null) return const <String, BoardBerth>{};

  final occupants = occupantListForBus(passengers, bus.id);
  if (occupants.isEmpty) return const <String, BoardBerth>{};

  final out = <String, BoardBerth>{};
  for (final cell in layout.grid) {
    if (!cell.hasSeat) continue;
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) continue;
    final riders = occupants[seatId];
    if (riders == null || riders.isEmpty) continue;

    var fare = 0.0;
    var paid = 0.0;
    for (final p in riders) {
      fare += bus.amountDueForSeat(p, seatId);
      paid += collectionFor?.call(p, seatId)?.netCollected ?? 0;
    }

    final lead = riders.first;
    final groupId = lead.groupId;
    out[seatId] = BoardBerth(
      code: seatId,
      isOccupied: true,
      occupantName: lead.displayName,
      fareDue: fare,
      paid: paid,
      pickupStopId: lead.pickupLocationId,
      pickupStopName: lead.pickupLocationName,
      groupId: groupId,
      groupName: groupId == null ? null : groupNames[groupId],
      seatTypeLabel: cell.typeLabel,
    );
  }
  return out;
}

/// The pickup lens's colour budget for [berths] (spec §5's five-tint cap).
///
/// Buckets are keyed on `pickupStopId` and nothing else, because that is what
/// [PickupLens] asks a berth for — keying on the NAME here would tint a berth
/// the legend could then never match, and the swatch would filter to zero.
/// First-appearance order along the walk breaks ties, which for a bus is the
/// order it passes the stops.
BoardTintScale boardStopTints(Iterable<BoardBerth> berths) =>
    _tintsBy(berths, (b) => b.pickupStopId, (b) => b.pickupStopName);

/// The group lens's colour budget. Same rule, keyed on `groupId`.
BoardTintScale boardGroupTints(Iterable<BoardBerth> berths) =>
    _tintsBy(berths, (b) => b.groupId, (b) => b.groupName);

BoardTintScale _tintsBy(
  Iterable<BoardBerth> berths,
  String? Function(BoardBerth berth) idOf,
  String? Function(BoardBerth berth) nameOf,
) {
  final order = <String>[];
  final names = <String, String>{};
  final counts = <String, int>{};
  for (final b in berths) {
    if (!b.isOccupied) continue;
    final id = idOf(b);
    if (id == null || id.isEmpty) continue;
    if (!counts.containsKey(id)) {
      order.add(id);
      final name = nameOf(b)?.trim();
      names[id] = (name == null || name.isEmpty) ? id : name;
    }
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return BoardTintScale.fromSeeds([
    for (final id in order)
      BoardTintSeed(id: id, label: names[id]!, count: counts[id]!),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// The screen.
// ─────────────────────────────────────────────────────────────────────────────

/// How many berths one "next outstanding" round may visit before the loop gives
/// up. A 74-berth coach cannot need more, and the guard means a predicate that
/// somehow never clears ends the round instead of pinning the UI.
const int kBoardMaxWalkSteps = 200;

class BoardScreen extends StatefulWidget {
  final String tourId;

  /// Which bus to open on. Null opens the tour's first bus; a bus the tour does
  /// not carry is ignored rather than showing an empty page.
  final String? initialBusId;

  const BoardScreen({super.key, required this.tourId, this.initialBusId});

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  /// Tagged per screen INSTANCE, not per tour: pushing the same tour's Board
  /// twice (a deep link on top of an open one) would otherwise have the second
  /// screen adopt — and then delete — the first one's controller.
  late final String _tag = 'board_${widget.tourId}_${identityHashCode(this)}';

  late final BoardController _board;
  final _workers = <Worker>[];
  final _search = TextEditingController();

  bool _searchOpen = false;

  /// Guards the walk so a double tap on "next outstanding" cannot start two
  /// rounds — the exact failure mode of a control tapped at speed.
  bool _walking = false;

  /// [BoardScreen.initialBusId] is applied once, and only once the tour is
  /// actually loaded: on a cold deep link the roster arrives after this screen.
  bool _busApplied = false;

  TourController? get _tours =>
      Get.isRegistered<TourController>() ? Get.find<TourController>() : null;

  /// Null in a widget test and in the customer app. Every money read degrades
  /// to zero rather than throwing, and the money lens then says "set fares to
  /// track collection" (spec §13) instead of painting ₹0 across the bus.
  MoneyController? get _money =>
      Get.isRegistered<MoneyController>() ? Get.find<MoneyController>() : null;

  Tour? get _tour => _tours?.getTour(widget.tourId);

  @override
  void initState() {
    super.initState();
    _board = Get.put(BoardController(), tag: _tag);

    // Bus count and index are settled BEFORE the canvas mounts: its
    // `PageController` is seeded from `busIndex` in its own initState, so a
    // deep link to bus 2 that arrived a frame late would open on bus 1 and
    // silently stay there.
    _syncTourFacts();

    final tours = _tours;
    if (tours != null) {
      _workers.add(ever<List<Tour>>(tours.tours, (_) => _syncTourFacts()));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Layouts are lazily fetched (a whole-row write once nulled them), so the
      // Board asks for them explicitly rather than assuming the tour it was
      // handed is chart-ready.
      unawaited(_tours?.ensureTourReadyForSeating(widget.tourId));
      unawaited(_money?.loadForTour(widget.tourId));
    });
  }

  @override
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    _search.dispose();
    BoardUndoToast.dismiss();
    Get.delete<BoardController>(tag: _tag);
    super.dispose();
  }

  /// Pushes the facts the lens default is derived from into the controller.
  ///
  /// Called from `initState` and from a worker on the tour list — never from
  /// `build`. Writing an observable the enclosing `Obx` has already read would
  /// mark it dirty inside its own build, and the Board would repaint twice on
  /// every frame the roster ticks.
  void _syncTourFacts() {
    final tour = _tour;
    if (tour == null) return;

    _board.setPhase(boardPhaseForTour(tour));
    _board.setDaysUntilDeparture(
      boardDaysUntilDeparture(tour.departureDate, DateTime.now()),
    );
    _board.setBusCount(tour.buses.length);

    if (_busApplied || tour.buses.isEmpty) return;
    _busApplied = true;
    final wanted = widget.initialBusId;
    if (wanted == null || wanted.isEmpty) return;
    final index = tour.buses.indexWhere((b) => b.id == wanted);
    if (index >= 0) _board.setBusIndex(index);
  }

  // ── Data ────────────────────────────────────────────────────

  Map<String, String> _groupNames(Tour tour) => {
    for (final g in tour.groups) g.id: g.label,
  };

  List<BoardBusPage> _pagesFor(Tour tour) {
    final money = _money;
    final names = _groupNames(tour);
    return [
      for (final bus in tour.buses)
        BoardBusPage(
          busId: bus.id,
          label: bus.customerLabel,
          layout: bus.layout,
          berths: boardBerthsForBus(
            bus: bus,
            passengers: tour.passengers,
            groupNames: names,
            collectionFor: money == null
                ? null
                : (p, seatId) => money.collectionFor(p, bus.id, seatId),
          ),
        ),
    ];
  }

  int _busIndex(int busCount) =>
      busCount <= 0 ? 0 : _board.busIndex.value.clamp(0, busCount - 1);

  /// The lens as it should be BUILT — with the tint scale the pickup and group
  /// lenses need, and only when one of them is active. Building a five-tint
  /// scale under the money lens would be a full pass over the bus for a value
  /// nothing reads.
  BoardLens _lensFor(BoardBusPage page) {
    final id = _board.lens;
    if (id != BoardLensId.pickup && id != BoardLensId.group) {
      return BoardLens.of(id);
    }
    final berths = page.berths.values;
    return BoardLens.of(
      id,
      tints: id == BoardLensId.pickup
          ? boardStopTints(berths)
          : boardGroupTints(berths),
    );
  }

  BoardTintScale _tintsFor(BoardBusPage page) {
    final id = _board.lens;
    if (id == BoardLensId.pickup) return boardStopTints(page.berths.values);
    if (id == BoardLensId.group) return boardGroupTints(page.berths.values);
    return BoardTintScale.empty;
  }

  // ── The aisle-order walk (spec §4) ──────────────────────────

  /// **The interaction the Board exists for.**
  ///
  /// One tap: advance the cursor to the next berth the lens still wants, IN
  /// AISLE ORDER (the canvas reveals it — the controller's `cursor` is watched),
  /// open its sheet, and when the lens's own action completes, do it again.
  /// Nobody is missed and nobody is asked twice, because
  /// [AisleWalk.next] never hands back the berth the cursor is already on and
  /// a completed action stops the berth matching.
  ///
  /// The loop ends on any of four things, all of them deliberate:
  ///
  ///  * nothing left matches → the round is announced complete;
  ///  * the sheet was dismissed without acting → the handler is doing something
  ///    else, and dragging them onward would be the app arguing with them;
  ///  * the action completed was NOT the lens's primary one — calling somebody
  ///    from the money lens does not settle their balance, so the round must
  ///    not skip past them;
  ///  * [kBoardMaxWalkSteps].
  Future<void> _advanceWalk() async {
    if (_walking) return;
    _walking = true;
    try {
      for (var step = 0; step < kBoardMaxWalkSteps; step++) {
        if (!mounted) return;
        final tour = _tour;
        if (tour == null || tour.buses.isEmpty) return;

        // Re-read every time round: a collection just landed, so the berths,
        // the predicate and the strip have all moved on since the last step.
        final pages = _pagesFor(tour);
        final index = _busIndex(pages.length);
        final page = pages[index];
        final bus = tour.buses[index];
        final lens = _lensFor(page);

        final cell = _board.advanceToNextOutstanding(
          boardNeedsAction(lens, page.berths),
        );
        if (cell == null) {
          AppSnackBar.success(tr('board_screen.round_done'));
          return;
        }
        // Spec §12: the auto-advance is a selection, never an impact — it fires
        // dozens of times a minute on a collection round.
        BerthHaptics.tap();

        final result = await _openSheet(
          cell: cell,
          tour: tour,
          bus: bus,
          page: page,
          lens: lens,
        );
        if (result == null || !result.completed) return;
        if (result.action != lens.primaryAction) return;
      }
    } finally {
      _walking = false;
    }
  }

  // ── The sheet ───────────────────────────────────────────────

  /// Opens the one passenger sheet for [cell]. Null when the berth holds
  /// nobody — a vacant berth has no passenger to show, and the assign picker of
  /// spec §7 is not in this wave (see the library doc).
  Future<PassengerSheetResult?> _openSheet({
    required SeatCell cell,
    required Tour tour,
    required Bus bus,
    required BoardBusPage page,
    required BoardLens lens,
  }) async {
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) return null;

    final riders = occupantListForBus(tour.passengers, bus.id)[seatId];
    if (riders == null || riders.isEmpty) return null;

    final names = _groupNames(tour);
    final occupants = [
      for (final p in riders)
        PassengerSheetOccupant(
          // Per RIDER, not per berth. A split sofa holds two people with
          // genuinely different balances, and showing the berth's combined
          // figure against one of their names is the bug the old sheet had.
          berth: _riderBerth(
            bus: bus,
            rider: p,
            seatId: seatId,
            cell: cell,
            groupNames: names,
          ),
          passenger: p,
        ),
    ];

    if (!mounted) return null;
    return PassengerSheet.show(
      context,
      occupants: occupants,
      lens: lens,
      tourId: tour.id,
      busId: bus.id,
      busName: bus.customerLabel,
      seatId: seatId,
      onCollect: _money == null
          ? null
          : (amount) => _collect(
              tour: tour,
              bus: bus,
              seatId: seatId,
              riders: riders,
              amount: amount,
            ),
    );
  }

  BoardBerth _riderBerth({
    required Bus bus,
    required Passenger rider,
    required String seatId,
    required SeatCell cell,
    required Map<String, String> groupNames,
  }) {
    final groupId = rider.groupId;
    return BoardBerth(
      code: seatId,
      isOccupied: true,
      occupantName: rider.displayName,
      fareDue: bus.amountDueForSeat(rider, seatId),
      paid: _money?.collectionFor(rider, bus.id, seatId)?.netCollected ?? 0,
      pickupStopId: rider.pickupLocationId,
      pickupStopName: rider.pickupLocationName,
      groupId: groupId,
      groupName: groupId == null ? null : groupNames[groupId],
      seatTypeLabel: cell.typeLabel,
    );
  }

  // ── Money (spec §8) ─────────────────────────────────────────

  /// Records [amount] against whoever on this berth is owed it, and hands back
  /// the undo.
  ///
  /// **Why the rider is resolved by amount.** `PassengerSheet.onCollect` reports
  /// the figure it collected but not WHICH of a shared berth's occupants it
  /// collected from — the sheet keeps that selection privately. On a solo berth
  /// (every berth on almost every bus) there is nothing to resolve. On a shared
  /// one the rider whose outstanding balance equals the amount is the one the
  /// sheet was showing. Reported upstream: the sheet should pass the occupant.
  Future<PassengerSheetUndo?> _collect({
    required Tour tour,
    required Bus bus,
    required String seatId,
    required List<Passenger> riders,
    required double amount,
  }) async {
    final money = _money;
    if (money == null || riders.isEmpty) return null;

    final rider = riders.length == 1
        ? riders.first
        : riders.firstWhereOrNull((p) {
            final due = bus.amountDueForSeat(p, seatId);
            final held = money.collectionFor(p, bus.id, seatId)?.netCollected ?? 0;
            return (due - held - amount).abs() <= Collection.kMoneyEpsilon;
          }) ??
              riders.first;

    final existing = money.collectionFor(rider, bus.id, seatId);
    final saved = buildCollectionToSave(
      existing: existing,
      tourId: tour.id,
      busId: bus.id,
      passengerId: rider.id,
      seatId: seatId,
      // The LIVE fare, never the amount snapshotted when earlier cash was
      // taken: fares are per-bus and a moved rider is re-priced.
      due: bus.amountDueForSeat(rider, seatId),
      received: (existing?.amountReceived ?? 0) + amount,
      // Only a GENUINE manual return survives; auto-booked change is
      // re-derived from the new received figure, exactly as the collection
      // screen does. Passing the stored refund straight back would freeze
      // stale change as a manual return and invent a shortfall.
      manualReturned: manualReturnToSeed(existing) ?? 0,
      collectedBy: '',
      note: existing?.note ?? '',
    );

    await money.upsertCollection(saved);

    final name = rider.displayName;
    final amountText = Formatters.formatMoneyInr(amount);
    return PassengerSheetUndo(
      message: tr(
        'passenger_sheet.collected_toast',
        namedArgs: {'amount': amountText, 'name': name},
      ),
      semanticLabel: tr(
        'board_screen.undo_collect_semantic',
        namedArgs: {'amount': amountText, 'name': name},
      ),
      // A row that did not exist before is DELETED rather than zeroed: a
      // zeroed row still posts to the ledger and still counts as "collected
      // from", which is not what "undo" means.
      undo: () => existing == null
          ? money.deleteCollection(saved.id)
          : money.upsertCollection(existing),
    );
  }

  // ── Chrome ──────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _search.clear();
        _board.clearSearch();
      }
    });
  }

  void _createLayout(Tour tour, Bus bus) {
    // The layout is generated in exactly one place in the app — the add/edit
    // bus wizard's save path. The empty state opens THIS bus there rather than
    // inventing a layout editor that does not exist (same hand-off
    // `charts_screen` uses).
    Get.to(
      () => AddBusScreen(tourId: tour.id, existing: bus),
      transition: Transition.cupertino,
    );
  }

  /// Wraps the canvas in its per-lens empty states, EXCEPT when the bus has no
  /// seat plan — see the note at the call site for why that one stays with the
  /// canvas.
  Widget _withEmptyStates({
    required bool hasLayout,
    required BoardEmptyFacts facts,
    required ValueChanged<BoardEmptyAction> onAction,
    required Widget canvas,
  }) {
    if (!hasLayout) return canvas;
    return BoardEmptyStates(
      lens: _board.lens,
      facts: facts,
      onAction: onAction,
      child: canvas,
    );
  }

  /// The way out of a spec §13 empty state.
  ///
  /// Every destination here already exists — none is a route invented for the
  /// Board — and the mapping is the one documented on [BoardEmptyAction].
  void _handleEmptyAction(BoardEmptyAction action, Tour tour, Bus bus) {
    switch (action) {
      // Both land on the add/edit-bus wizard: it is the only place in the app
      // that generates a layout, and per-bus fares live on its Step 3. It has
      // no "open at step N" parameter today, so "set fares" opens the wizard
      // at the top rather than pretending to deep-link.
      case BoardEmptyAction.createSeatPlan:
      case BoardEmptyAction.setFares:
        _createLayout(tour, bus);
      case BoardEmptyAction.placeRiders:
        Get.toNamed(
          AppRoutes.seatAssignment,
          arguments: {'tourId': tour.id, 'busId': bus.id},
        );
      case BoardEmptyAction.addPickupPoints:
        Get.toNamed(AppRoutes.pickupLocations);
      case BoardEmptyAction.createGroup:
        Get.toNamed(AppRoutes.tourGroups, arguments: {'tourId': tour.id});
      case BoardEmptyAction.reviewCollection:
        Get.toNamed(AppRoutes.tourMoney, arguments: {'tourId': tour.id});
      // In-Board on purpose: the expected headcount IS the occupancy lens, so
      // this switches the canvas instead of pushing a screen.
      case BoardEmptyAction.previewExpected:
        _board.selectLens(BoardLensId.occupancy);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          // Read BEFORE the early returns, and unconditionally.
          //
          // GetX only records observables touched inside the closure, and it
          // throws "improper use of a GetX" on a build that reads none — which
          // is exactly what the two empty states below would do. `busIndex` is
          // always there, is a real dependency (it decides which bus is drawn),
          // and costs nothing.
          final busIndex = _board.busIndex.value;
          // Touched so the Board repaints when cash lands — a bus whose berths
          // are all vacant reads no collection row and would otherwise never
          // hear about the first one.
          _money?.collections.length;

          final tour = _tour;
          if (tour == null) return _empty(_EmptyKind.noTour, null);
          if (tour.buses.isEmpty) return _empty(_EmptyKind.noBus, tour);

          final pages = _pagesFor(tour);
          final index = busIndex.clamp(0, pages.length - 1);
          final bus = tour.buses[index];
          final page = pages[index];
          final lens = _lensFor(page);

          // The bus in walking order, computed from the LAYOUT rather than read
          // off `BoardController.walk`.
          //
          // This is not a style choice. The canvas republishes the walk from
          // its own `initState` / `didUpdateWidget` — i.e. from inside the
          // build phase — and anything OUTSIDE the canvas's subtree that had
          // subscribed to it is then marked dirty mid-build, which Flutter
          // throws on. The walk is a pure function of the layout
          // (`aisle_order.dart`), so the chrome derives it directly and only
          // the canvas's own descendants (the "next outstanding" control) read
          // the observable. Same list, same order, no cross-subtree write.
          final ordered = aisleOrder(page.layout);
          final berths = [
            for (final cell in ordered) boardBerthFor(cell, page.berths),
          ];

          // Spec §13. The canvas has always known how to say "this bus has no
          // seat plan"; what it cannot know is the per-LENS version of the same
          // question — money with no fares set, boarding before departure day,
          // pickup with no stops — which is where the old screens painted ₹0
          // into every cell and let a working tour read as a broken one.
          // `resolveBoardEmptyState` owns that judgement, so the facts are
          // assembled once here and used for both the canvas slot and the
          // chrome decision below.
          final emptyFacts = BoardEmptyFacts(
            hasLayout: page.layout != null,
            berths: berths,
            daysUntilDeparture: _board.daysUntilDeparture.value,
            departureDate: tour.departureDate,
            // `context.locale` null-check-throws without an EasyLocalization
            // ancestor, which is exactly how the Board is mounted under test.
            // The locale only picks the month name and `_shortDate` already
            // falls back rather than throwing, so read it the nullable way.
            locale: Localizations.maybeLocaleOf(context)?.languageCode,
          );
          // "Never render a legend for berths that do not exist" — when the
          // panel replaces the chart the colour key describes nothing, so it
          // goes with it. Mirrors the wrapper decision below exactly: with no
          // layout the canvas draws its own state and `berths` is empty, which
          // already leaves BoardLegend with no row to print.
          final chartReplaced =
              page.layout != null &&
              boardEmptyReplacesChart(lens: _board.lens, facts: emptyFacts);

          return Column(
            children: [
              UgamAppBar(
                title: tour.title,
                eyebrow: tr('board_screen.title'),
                subtitle: bus.customerLabel,
                actions: [
                  UgamAppBarAction(
                    icon: Icons.search_rounded,
                    active: _searchOpen,
                    tooltip: tr(
                      _searchOpen
                          ? 'board_screen.search_close'
                          : 'board_screen.search_open',
                    ),
                    onTap: _toggleSearch,
                  ),
                  _DensityAction(board: _board, berthCount: ordered.length),
                ],
              ),

              if (_searchOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    0,
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                  ),
                  child: UgamSearchField(
                    controller: _search,
                    autofocus: true,
                    hint: tr('board_screen.search_hint'),
                    onChanged: _board.setSearch,
                    onClear: () {
                      _search.clear();
                      _board.clearSearch();
                    },
                  ),
                ),

              // The switcher is mounted ABOVE the canvas and reads none of the
              // observables the canvas writes on mount (the walk, the bus
              // count), so it can never be marked dirty from inside its own
              // sibling's initState.
              _LensBar(board: _board),
              const SizedBox(height: UgamSpacing.sm),

              // Two agents built an answer for "there is nothing to draw", and
              // the split between them is deliberate rather than accidental:
              //
              //  * The CANVAS keeps the no-seat-plan state, because it lives
              //    inside the multi-bus pager. Swiping to a second bus that has
              //    no layout must keep the pager and its page indicator, and an
              //    outer panel would replace both.
              //  * BoardEmptyStates owns the per-LENS states the canvas has no
              //    answer for at all — money with no fares, boarding before
              //    departure day, pickup with no stops — which is the half of
              //    spec §13 that was otherwise built, tested and unreachable.
              Expanded(
                child: _withEmptyStates(
                  hasLayout: page.layout != null,
                  facts: emptyFacts,
                  onAction: (action) => _handleEmptyAction(action, tour, bus),
                  canvas: BoardCanvas(
                    controller: _board,
                    buses: pages,
                    tints: _tintsFor(page),
                    slotSizeOf: BerthTileMetrics.slotSize,
                    berthTileBuilder: _berthTile,
                    onBerthTap: (slot) => unawaited(
                      _openSheet(
                        cell: slot.cell,
                        tour: tour,
                        bus: bus,
                        page: page,
                        lens: slot.lens,
                      ),
                    ),
                    stripTrailing: _NextOutstanding(
                      board: _board,
                      pages: pages,
                      lensOf: _lensFor,
                      onAdvance: _advanceWalk,
                    ),
                    noLayoutAction: UgamCTA(
                      label: tr('add_bus.title'),
                      leadingIcon: Icons.event_seat_rounded,
                      onPressed: () => _createLayout(tour, bus),
                    ),
                  ),
                ),
              ),

              // Below the canvas, so the colour key — which is also the filter
              // (spec §5) — sits under the thumb rather than above the bus.
              if (!chartReplaced)
                _LegendBar(board: _board, lens: lens, berths: berths),

              // Spec-adjacent, and the bug this screen must not repeat: the
              // floating dock belongs to the SHELL and every entry point pushes
              // this screen onto the shell's nested navigator, so the dock
              // never appears in our own metrics. Without this reserve the last
              // rows of a 74-berth coach sit behind it with no way to scroll
              // further — which is exactly the defect on several screens today.
              SizedBox(
                height: math.max(
                  UgamSpacing.dockClearance,
                  MediaQuery.paddingOf(context).bottom + UgamSpacing.lg,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// The canvas supplies the slot; the tile paints it.
  ///
  /// No `onTap` / `onLongPress` here on purpose: the canvas already owns both
  /// gestures (it has to — it is the only thing that knows about the walk
  /// cursor, multi-select and the compact-mode nearest-berth catcher), and a
  /// second recognizer on the same box would give one thumb two answers.
  Widget _berthTile(BuildContext context, BoardBerthSlot slot) => BerthTile(
    berth: slot.berth,
    lens: slot.lens,
    density: slot.density,
    isSelected: slot.isSelected,
    isCurrent: slot.isCursor,
    isDimmed: slot.isDimmed,
    isDropTarget: slot.dropState == BoardDropState.valid,
    isDropRejected: slot.dropState == BoardDropState.invalid,
  );

  Widget _empty(_EmptyKind kind, Tour? tour) => Column(
    children: [
      UgamAppBar(
        title: tour?.title ?? tr('board_screen.title'),
        eyebrow: tour == null ? null : tr('board_screen.title'),
      ),
      Expanded(
        child: UgamEmpty(
          icon: kind == _EmptyKind.noTour
              ? Icons.explore_off_rounded
              : Icons.directions_bus_outlined,
          title: tr(
            kind == _EmptyKind.noTour
                ? 'board_screen.no_tour_title'
                : 'board_screen.no_bus_title',
          ),
          body: tr(
            kind == _EmptyKind.noTour
                ? 'board_screen.no_tour_body'
                : 'board_screen.no_bus_body',
          ),
          cta: kind == _EmptyKind.noBus && tour != null
              ? UgamCTA(
                  label: tr('add_bus.title'),
                  leadingIcon: Icons.add_rounded,
                  onPressed: () => Get.to(
                    () => AddBusScreen(tourId: tour.id),
                    transition: Transition.cupertino,
                  ),
                )
              : null,
        ),
      ),
    ],
  );
}

enum _EmptyKind { noTour, noBus }

// ─────────────────────────────────────────────────────────────────────────────
// Chrome pieces — each with its own Obx, so a lens tap does not rebuild the bus
// and a walk step does not rebuild the switcher.
// ─────────────────────────────────────────────────────────────────────────────

class _DensityAction extends StatelessWidget {
  final BoardController board;

  /// Drawable tiles on the bus, taken from the LAYOUT. See the note below on
  /// why this is not read off the controller.
  final int berthCount;

  const _DensityAction({required this.board, required this.berthCount});

  @override
  Widget build(BuildContext context) => Obx(() {
    // `BoardController.density` falls back to the berth count, and it reads
    // that count off the aisle walk — an observable the canvas republishes
    // from inside its own build. Subscribing to it from the app bar, which is
    // a SIBLING of the canvas rather than an ancestor, makes the framework
    // throw the moment the layout changes.
    //
    // So the default half of the rule is evaluated here, against the same
    // threshold and the same number, and the controller is only asked once the
    // user HAS a stored preference — at which point `??` short-circuits before
    // the walk is touched.
    final compact = board.densityIsManual
        ? board.isCompact
        : berthCount > BoardController.compactBerthThreshold;
    return UgamAppBarAction(
      // Compact shows the whole coach, so the action offers the OTHER mode —
      // the icon names where the tap goes, not where you are.
      icon: compact
          ? Icons.density_medium_rounded
          : Icons.density_small_rounded,
      tooltip: tr(
        compact
            ? 'board_screen.density_comfortable'
            : 'board_screen.density_compact',
      ),
      onTap: board.toggleDensity,
    );
  });
}

class _LensBar extends StatelessWidget {
  final BoardController board;

  const _LensBar({required this.board});

  @override
  Widget build(BuildContext context) => Obx(() {
    // Ordered by the enum rather than by set iteration, so the strip never
    // re-orders itself between two loads of the same tour.
    final lenses = [
      for (final id in BoardLensId.values)
        if (board.availableLenses.contains(id)) id,
    ];
    if (lenses.isEmpty) return const SizedBox.shrink();
    return BoardLensSwitcher(
      lenses: lenses,
      current: board.lens,
      onChanged: board.selectLens,
    );
  });
}

class _LegendBar extends StatelessWidget {
  final BoardController board;
  final BoardLens lens;

  /// The bus on screen in aisle order. [BoardLegend] drops any row no berth
  /// here matches (spec §13), so this is what stops the Board doing what the
  /// chart does today: printing ten colour codes over an empty bus.
  final List<BoardBerth> berths;

  const _LegendBar({
    required this.board,
    required this.lens,
    required this.berths,
  });

  @override
  Widget build(BuildContext context) => Obx(
    () => Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: BoardLegend(
        lens: lens,
        berths: berths,
        activeId: board.legendFilter.value,
        onToggle: board.toggleLegendFilter,
      ),
    ),
  );
}

/// **"આગળનું બાકી →"** — the walk control of spec §4, in the summary strip's
/// trailing slot (which the strip reserves for exactly this).
///
/// It renders the arrow and the REMAINING COUNT rather than the words. That is
/// a width decision, not a shortcut: the strip's job is to pin `₹55,200 બાકી ·
/// 32% એકઠી` where it can never be lost, Gujarati is the primary language and
/// runs ~30% longer than English, and `આગળનું બાકી →` set beside that figure on
/// a 375pt phone ellipsizes the FIGURE — the one thing spec §3 says must never
/// go. The words are carried in full by the semantic label and the tooltip, and
/// the count is the more useful glance anyway: it is the length of the round.
///
/// When nothing is left the control does not vanish (it is "persistent"), it
/// goes quiet: a tick, no accent, no gesture, and a screen reader is told the
/// round is complete.
class _NextOutstanding extends StatelessWidget {
  static const Key tapKey = Key('board_screen.next_outstanding');

  final BoardController board;
  final List<BoardBusPage> pages;
  final BoardLens Function(BoardBusPage page) lensOf;
  final Future<void> Function() onAdvance;

  const _NextOutstanding({
    required this.board,
    required this.pages,
    required this.lensOf,
    required this.onAdvance,
  });

  @override
  Widget build(BuildContext context) => Obx(() {
    final c = UgamColors.of(context);
    if (pages.isEmpty) return const SizedBox.shrink();

    final page = pages[board.busIndex.value.clamp(0, pages.length - 1)];
    final needsAction = boardNeedsAction(lensOf(page), page.berths);
    // Reads the walk, so the count is live: it drops as the round is worked.
    final remaining = board.outstandingCount(needsAction);
    final hasNext = board.hasNextOutstanding(needsAction);

    final done = remaining == 0 || !hasNext;
    final ink = done ? c.ink3 : c.accent;

    return Semantics(
      button: !done,
      enabled: !done,
      label: done
          ? tr('board_screen.round_done_a11y')
          : tr(
              'board_screen.next_outstanding_a11y',
              namedArgs: {'count': '$remaining'},
            ),
      onTap: done ? null : () => unawaited(onAdvance()),
      child: ExcludeSemantics(
        child: Tooltip(
          message: done
              ? tr('board_screen.round_done')
              : tr('board_screen.next_outstanding'),
          child: UgamTappable(
            key: tapKey,
            onTap: done ? null : () => unawaited(onAdvance()),
            // The advance fires its own selectionClick (spec §12); the
            // wrapper's lightImpact on top would double-buzz every step of a
            // 22-person round.
            haptic: false,
            pressedScale: 0.93,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: UgamScale.tap(context, 44),
                minWidth: UgamScale.tap(context, 44),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: UgamSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: done ? c.card : c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: done
                          ? c.border
                          : c.accent.withValues(alpha: 0.55),
                      width: done ? 1 : 1.4,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!done)
                        Text(
                          '$remaining',
                          maxLines: 1,
                          style: UgamText.tabular(
                            UgamText.bodyStrong.copyWith(color: ink),
                          ),
                        ),
                      if (!done) const SizedBox(width: UgamSpacing.xs),
                      Icon(
                        done
                            ? Icons.check_rounded
                            : Icons.arrow_forward_rounded,
                        size: UgamScale.px(context, 18),
                        color: ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  });
}
