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
import '../../models/seat_type.dart';
import '../../models/tour.dart';
import '../../models/tour_status.dart';
import '../../models/trip_type.dart';
import '../../routes/app_routes.dart';
import '../../services/seat_move_flow.dart';
import '../../services/seat_swap_guard.dart';
import '../../utils/aisle_order.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/collection_write.dart';
import '../../utils/formatters.dart';
import '../../utils/passenger_display.dart';
import '../../utils/seat_drop_engine.dart';
import '../../utils/seat_money_state.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/board/berth_tile.dart';
import '../../widgets/board/board_canvas.dart';
import '../../widgets/board/board_empty_states.dart';
import '../../widgets/board/board_legend.dart';
import '../../widgets/board/lens_switcher.dart';
import '../../widgets/board/passenger_sheet.dart';
import '../add_bus_screen.dart';

part 'board_mapping.dart';
part 'board_sheet_actions.dart';
part 'board_moves.dart';
part 'board_chrome.dart';

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

  /// The first hydrate is still in flight — see [_empty] for what depends on it.
  ///
  /// Starts TRUE, because the first build runs BEFORE `initState`'s post-frame
  /// callback does: on a cold open (or a deep link) `_tour` is null while
  /// `TourController` is still fetching, and the Board used to answer that with
  /// its "no such tour" empty state. An empty state is a VERDICT, and a verdict
  /// delivered 300ms early reads to the agent as "the chart failed to load" —
  /// on the one screen they open when a bus is about to leave. Cleared in the
  /// hydrate's `whenComplete`, so noTour / noBus are only ever painted once the
  /// answer is genuinely "there is nothing here".
  bool _hydrating = true;

  /// Tap-to-place relocate (spec §7, and the seat grid's own `_relocate`): who
  /// is held "in hand" and the berth they were lifted from, so the next berth
  /// tap MOVES them onto a free berth or SWAPS them with its occupant. Set by
  /// [_beginRelocate] when the move flow's destination picker hands control
  /// back here; null when no relocate is in progress.
  ({Passenger mover, String fromBusId, String fromSeatId})? _relocate;

  TourController? get _tours =>
      Get.isRegistered<TourController>() ? Get.find<TourController>() : null;

  /// Null in a widget test and in the customer app. Every money read degrades
  /// to zero rather than throwing, and the money lens then says "set fares to
  /// track collection" (spec §13) instead of painting ₹0 across the bus.
  MoneyController? get _money =>
      Get.isRegistered<MoneyController>() ? Get.find<MoneyController>() : null;

  Tour? get _tour => _tours?.getTour(widget.tourId);

  /// `setState` for the part-file extensions (it is protected on [State]).
  void _update(VoidCallback fn) => setState(fn);

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
      _hydrate();
    });
  }

  /// Layouts are lazily fetched (a whole-row write once nulled them), so the
  /// Board asks for them explicitly rather than assuming the tour it was
  /// handed is chart-ready. Also the retry behind [_failed].
  void _hydrate() {
    final tourCtrl = _tours;
    final moneyCtrl = _money;
    final hydrate = <Future<void>>[
      if (tourCtrl != null) tourCtrl.ensureTourReadyForSeating(widget.tourId),
      if (moneyCtrl != null) moneyCtrl.loadForTour(widget.tourId),
    ];
    unawaited(
      Future.wait(hydrate)
          // A FAILED load still ends the wait. All this flag decides is whether
          // the Board is still expecting an answer; a failed roster read is
          // told apart from a genuinely empty tour by the controller's
          // [TourController.rosterStateOf], so it lands on the retry state —
          // never on "no bus · Add bus".
          .catchError((Object _) => <void>[])
          .whenComplete(() {
            if (!mounted) return;
            setState(() => _hydrating = false);
          }),
    );
  }

  void _retryHydrate() {
    setState(() => _hydrating = true);
    _hydrate();
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
    return BoardLens.of(id, tints: _tintsFor(page));
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
      // [AppRoutes.seatGrid], never [AppRoutes.seatAssignment]: that one is the
      // "open this bus's chart" alias and it resolves back to THIS screen while
      // `boardReplacesChart` is on, so "place riders" pushed a second Board on
      // top of the one the agent was already looking at. The seat grid is the
      // only surface with an assign path, and it takes the same arguments.
      case BoardEmptyAction.placeRiders:
        Get.toNamed(
          AppRoutes.seatGrid,
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
          // "Not yet" and "not there" are different answers, and only the
          // hydrate can tell them apart — see [_hydrating]. Until it settles,
          // an unresolved tour (or a tour whose buses have not arrived) is a
          // skeleton, never the error-shaped empty state.
          if (tour == null) {
            if (_hydrating) return _loading(null);
            // The tour list itself failed to load: "no such tour" is not the
            // answer, "couldn't load" is.
            return _tours?.hasError.value == true
                ? _failed(null)
                : _empty(_EmptyKind.noTour, null);
          }
          if (tour.buses.isEmpty) {
            if (_hydrating) return _loading(tour);
            return _tours?.rosterStateOf(tour.id) == TourRosterState.failed
                ? _failed(tour)
                : _empty(_EmptyKind.noBus, tour);
          }

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

              // Somebody is in hand: say who, on which bus, and offer the ONE
              // way out. Directly above the chart, because the next tap it is
              // explaining goes into the chart.
              if (_relocate != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    0,
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                  ),
                  child: _RelocateBanner(
                    moverName: _relocate!.mover.displayName,
                    busName: bus.customerLabel,
                    onCancel: _cancelRelocate,
                  ),
                ),

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
                    onBerthTap: (slot) =>
                        unawaited(_onBerthTap(tour, bus, page, slot)),
                    // Spec §7's drag, finally connected. The canvas has always
                    // known how to arm a berth drag and paint a live drop
                    // target; it refuses to unless BOTH of these are supplied
                    // (`_BerthHost._canDrag`), and the Board supplied neither —
                    // so every one of those gestures was dead code on a screen
                    // whose main job is moving people around a bus.
                    canDragBerth: (slot) => _canDragBerth(tour, bus, slot),
                    canDrop: (payload, target) =>
                        _canDropOnBerth(tour, bus, payload, target),
                    onDrop: (payload, target) =>
                        unawaited(_handleDrop(tour, bus, payload, target)),
                    onInvalidDrop: (payload, target) =>
                        _explainRefusedDrop(tour, bus, payload, target),
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

  /// The chart, still on its way.
  ///
  /// Shaped like the Board rather than like a spinner — the strip's band, then
  /// rows of berths in the two-lanes-aisle-two-lanes silhouette of a coach — so
  /// the wait reads as "this is loading" and nothing jumps when the real bus
  /// lands in the same places. [UgamSkeleton] is the app's loading primitive
  /// (its own doc: spinners are for pull-to-refresh and submit buttons).
  Widget _loading(Tour? tour) => Column(
    children: [
      UgamAppBar(
        title: tour?.title ?? tr('board_screen.title'),
        eyebrow: tour == null ? null : tr('board_screen.title'),
      ),
      Expanded(
        child: Semantics(
          label: tr('board_screen.loading'),
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.gutter,
            ),
            // Clipped, not scrolled: six rows fill any phone, and a placeholder
            // is never something the agent needs to reach the bottom of. The
            // OverflowBox is what keeps a large text scale from turning that
            // into an overflow stripe.
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const UgamSkeleton(height: 40, radius: UgamRadius.row),
                    const SizedBox(height: UgamSpacing.md),
                    for (var row = 0; row < 6; row++) ...[
                      const _LoadingBerthRow(),
                      const SizedBox(height: UgamSpacing.sm),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  /// The roster (or the tour list) could not be read. Same chrome as the empty
  /// state, with the shared retry in place of the verdict.
  Widget _failed(Tour? tour) => Column(
    children: [
      UgamAppBar(
        title: tour?.title ?? tr('board_screen.title'),
        eyebrow: tour == null ? null : tr('board_screen.title'),
      ),
      Expanded(
        child: UgamEmpty.error(
          onRetry: tour == null
              ? () => _tours?.refreshTours()
              : _retryHydrate,
        ),
      ),
    ],
  );

  Widget _empty(_EmptyKind kind, Tour? tour) {
    final (icon, titleKey, bodyKey) = switch (kind) {
      _EmptyKind.noTour => (
        Icons.explore_off_rounded,
        'board_screen.no_tour_title',
        'board_screen.no_tour_body',
      ),
      _EmptyKind.noBus => (
        Icons.directions_bus_outlined,
        'board_screen.no_bus_title',
        'board_screen.no_bus_body',
      ),
    };
    return Column(
      children: [
        UgamAppBar(
          title: tour?.title ?? tr('board_screen.title'),
          eyebrow: tour == null ? null : tr('board_screen.title'),
        ),
        Expanded(
          child: UgamEmpty(
            icon: icon,
            title: tr(titleKey),
            body: tr(bodyKey),
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
}
