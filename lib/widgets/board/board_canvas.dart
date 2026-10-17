/// The Board canvas — spec §3, §7 and §10 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
///
/// **The canvas is the Board.** Eleven screens exist today because "the bus
/// coloured by money" was built as a different screen from "the bus coloured by
/// who is aboard"; this draws the bus once and lets [BoardLens] decide the
/// colour. Everything else here is a consequence of ONE number: a real sleeper
/// coach is 36-74 berths — 12 to 18 rows on a 375pt phone — which is the thing
/// the visual mockups (4-5 rows) never showed.
///
/// What that number forces:
///
///  * **Two densities** ([BoardDensity]), because no single tile size both fits
///    the coach and stays tappable. Compact tiles are deliberately below 44pt
///    and compensate with nearest-berth hit resolution (see
///    [BoardGridGeometry.nearest]) rather than by growing.
///  * **Landscape as a real layout, not a stretched portrait.** A coach is long
///    and narrow. Rotated, the canvas TRANSPOSES: rows run front-to-back left
///    to right, the five lanes stack down the screen, and the whole bus scrolls
///    along one axis with occupant names visible. This is the natural
///    orientation for a seat chart and almost nothing in the category supports
///    it.
///  * **A sticky strip** that is a sibling of the scroll view, never a child of
///    it (`BoardSummaryStrip`).
///  * **Analytic geometry.** Every tile's rect is computed, not measured
///    ([BoardGridGeometry]), so "scroll this berth into view", "which berth did
///    that tap mean" and "hold the reader's place across a density switch" are
///    all arithmetic on the same numbers the paint uses, and all unit-testable.
///
/// **What this file does NOT own:** the berth tile ([BoardBerthTileBuilder] is
/// injected) and the passenger sheet (tap is a callback). It also never writes
/// data — every mutation leaves through a callback so undo (spec §8) and the
/// offline queue (spec §9) stay in one place.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controllers/board_controller.dart';
import '../../design/components/ugam_empty.dart';
import '../../design/components/ugam_pinch_zoom.dart';
import '../../design/components/ugam_tappable.dart';
import '../../design/text_styles.dart';
import '../../design/tokens.dart';
import '../../design/ui_scale.dart';
import '../../models/board_lens.dart';
import '../../models/seat_layout.dart';
import '../../models/seat_type.dart';
import '../../utils/aisle_order.dart';
import 'board_summary_strip.dart';

part 'board_canvas_geometry.dart';
part 'board_canvas_bus_view.dart';
part 'board_canvas_berth_host.dart';

// ─────────────────────────────────────────────────────────────────────────────
// What the canvas is given, and what it hands back to the tile.
// ─────────────────────────────────────────────────────────────────────────────

/// One bus of a (possibly multi-bus) tour — one page of the swipe.
@immutable
class BoardBusPage {
  /// Stable id, used as the page's storage key so a bus keeps its scroll
  /// position when you swipe away and back.
  final String busId;

  /// What the page indicator announces. Null falls back to `Bus 2`.
  final String? label;

  /// The seat plan. Null (or empty) renders the "no seat plan yet" state of
  /// spec §13 rather than a blank rectangle.
  final BusLayout? layout;

  /// Berth facts by `SeatCell.seatId`. A cell with no entry is drawn as a
  /// vacant berth, so a partially-loaded manifest degrades to "empty" instead
  /// of to a hole in the chart.
  final Map<String, BoardBerth> berths;

  const BoardBusPage({
    required this.busId,
    this.label,
    this.layout,
    this.berths = const {},
  });
}

/// Everything the canvas knows about one drawable tile, handed to the tile
/// builder. A double sofa is two berths but ONE slot — one code, one fill, one
/// sheet — exactly as `aisle_order.dart` walks it.
@immutable
class BoardBerthSlot {
  /// Geometry: where this tile sits in the bus.
  final SeatCell cell;

  /// Lens facts: who is here and what they owe.
  final BoardBerth berth;

  /// The active lens's answer for this berth — fill, ink and the glyph that
  /// carries the same meaning without colour (spec §11). Precomputed so a tile
  /// does not have to know how to reach a lens.
  final BerthPaint paint;

  /// Spec §11's full label: *"DL3, Priti Patel, paid, double sofa, boarding at
  /// Adajan"* — never just "DL3".
  ///
  /// The canvas COMPUTES it and the tile SPEAKS it. Wrapping the tile in a
  /// second `Semantics` here would give a screen reader two nodes for one
  /// berth and read the sentence twice, so the guarantee is discharged by
  /// composition: any tile put on this canvas must annotate itself, either with
  /// this string or with `lens.semanticLabel(slot.berth)`, which is the same
  /// sentence.
  final String semanticLabel;

  /// The active lens itself, not just its id — a tile needs the object to paint
  /// its own state words, and rebuilding it per tile would be 74 allocations a
  /// frame for a value that is identical across the bus.
  final BoardLens lens;

  final BoardDensity density;

  /// The box the tile is laid out in. Compact is below the 44pt minimum by
  /// design; see the library doc.
  final Size size;

  /// Filtered out by a legend swatch, or missed by the search. Draw at 30%.
  final bool isDimmed;

  /// A live search match — pulsing and scrolled into view (spec §10).
  final bool isSearchHit;

  /// In the multi-select set (spec §7).
  final bool isSelected;

  /// The aisle walk is parked here — the berth "next outstanding" last handed
  /// out, or the last one tapped (spec §4).
  final bool isCursor;

  /// Live drop classification while a drag is in flight over this berth.
  final BoardDropState dropState;

  /// Position along the aisle walk, for a "berth 14 of 40" readout.
  final int aisleIndex;

  const BoardBerthSlot({
    required this.cell,
    required this.berth,
    required this.paint,
    required this.semanticLabel,
    required this.lens,
    required this.density,
    required this.size,
    required this.aisleIndex,
    this.isDimmed = false,
    this.isSearchHit = false,
    this.isSelected = false,
    this.isCursor = false,
    this.dropState = BoardDropState.none,
  });

  String? get seatId => cell.seatId;

  BoardLensId get lensId => lens.id;

  bool get isCompact => density == BoardDensity.compact;
}

/// What an in-flight drag says about the berth under the finger.
enum BoardDropState {
  /// No drag, or this berth is not under it.
  none,

  /// Release here and it will work.
  valid,

  /// Occupied, blocked, wrong seat type, gender rule — the berth flashes danger
  /// and the drag returns to origin (spec §7). Never a silent failure.
  invalid,
}

/// What is being dragged. Exactly one of [fromSeatId] / [passengerId] is set:
/// berth→berth is a move or swap, rail→berth is an assignment.
@immutable
class BoardDragPayload {
  final String? fromSeatId;
  final String? passengerId;

  /// Shown on the chip that follows the finger.
  final String label;

  const BoardDragPayload.fromBerth({
    required String this.fromSeatId,
    required this.label,
  }) : passengerId = null;

  const BoardDragPayload.fromRail({
    required String this.passengerId,
    required this.label,
  }) : fromSeatId = null;

  bool get isBerthMove => fromSeatId != null;
}

/// Builds the visual for one berth. Owned by another agent; the canvas supplies
/// the slot and the box, and expects a widget that fills [BoardBerthSlot.size].
typedef BoardBerthTileBuilder =
    Widget Function(BuildContext context, BoardBerthSlot slot);

// ─────────────────────────────────────────────────────────────────────────────
// The canvas.
// ─────────────────────────────────────────────────────────────────────────────

/// Travel, in logical pixels, that separates "I held this berth and let go"
/// (multi-select) from "I moved this passenger" (a drag).
///
/// Spec §7: *"drag threshold before a drag starts, so scrolling the chart never
/// accidentally moves a passenger. This is critical: the canvas both scrolls
/// and drags."* Two rules together make that true:
///
///  1. a drag is only armed after [kBoardDragHold] of stillness, and ANY
///     movement before that goes to the scroll view instead (this is
///     `DelayedMultiDragGestureRecognizer`'s own contract, which
///     `LongPressDraggable` is built on) — so a scroll can never become a drag;
///  2. once armed, a release that travelled less than this is treated as the
///     long-press it looks like, and enters multi-select rather than dropping
///     a passenger somewhere they did not mean.
const double kBoardDragSlop = 24;

/// How long a berth must be held before a drag is armed. Shorter than the
/// platform's 500ms long-press: the handler is doing this over and over.
const Duration kBoardDragHold = Duration(milliseconds: 320);

/// Opacity a berth drops to when a legend swatch filters it out, or when the
/// search passes it over (spec §5, §10).
const double kBoardDimOpacity = 0.3;

/// The canvas's own geometry — the numbers that are neither spacing nor radius
/// and so have no token, kept in one named place for the same reason
/// `BerthTileMetrics` exists: a magic `1.5` three screens down is how two
/// hairlines end up different widths.
class BoardCanvasMetrics {
  const BoardCanvasMetrics._();

  /// The floor line down the middle of the coach. Thinner than a border, and
  /// faded — it is a hint that this is a bus, not a divider.
  static const double walkwayThickness = 1.5;
  static const double walkwayAlpha = 0.25;

  /// The search-hit ring (spec §10). Matches the tile's own emphasis ring, so a
  /// pulsing berth and a selected one read as the same weight of signal.
  static const double pulseRing = 2;
  static const double pulseBlur = 12;
  static const double pulseSpread = 2;
  static const double pulseGlowAlpha = 0.35;

  /// The multi-bus page dots. The active one stretches rather than growing, so
  /// the row's height never changes as you swipe.
  static const double dotSize = 7;
  static const double dotActiveWidth = 20;

  /// How far from a berth a compact-mode tap may land and still count as that
  /// berth (spec §3). One touch minimum: past that the thumb was aiming at
  /// nothing.
  static const double nearestTapRadius = 44;
}

/// How long the search box must be quiet before the canvas scrolls the first
/// match into view (spec §10).
///
/// Search HIGHLIGHTS as you type — the dimming is immediate — but the scroll is
/// held back: revealing on every keystroke would drag the chart three times
/// while somebody types `રમેશ`, and each of those scrolls moves the berth they
/// were about to tap.
const Duration kBoardSearchRevealDelay = Duration(milliseconds: 180);

/// The Board's chart.
///
/// Reads [BoardController] for lens, density, filter, search, selection, bus
/// and walk cursor; writes nothing but view state (the page index, the walk's
/// layout and the tapped cursor). Data mutations leave through the callbacks.
class BoardCanvas extends StatefulWidget {
  final BoardController controller;

  /// One entry per bus. Multi-bus tours swipe between them (spec §3) — a
  /// gesture, not a dropdown, because bus switching happens constantly.
  final List<BoardBusPage> buses;

  /// Owned by another agent. See [BoardBerthTileBuilder].
  final BoardBerthTileBuilder berthTileBuilder;

  /// The box to reserve per berth, when the tile decides its own footprint.
  ///
  /// Pass the tile's own metric (the shipped tile exposes exactly this shape)
  /// and the canvas lays the bus out around it. Null instead sizes tiles
  /// elastically from the viewport — wider in landscape, narrower on a small
  /// phone — which suits a tile that adapts to the box it is handed.
  final Size Function(BuildContext context, BoardDensity density)? slotSizeOf;

  /// Bucket colours for the pickup / group lenses. Ignored by the others.
  final BoardTintScale tints;

  /// Tap a berth → the passenger sheet. Not called while multi-select is on;
  /// there the tap toggles the selection instead.
  final void Function(BoardBerthSlot slot)? onBerthTap;

  /// Long-press → multi-select (spec §7). The canvas has already told the
  /// controller; this is for the bulk-action bar to hear about it.
  final void Function(BoardBerthSlot slot)? onBerthLongPress;

  /// Whether this berth can be picked up at all. Null (the default) disables
  /// berth→berth dragging entirely, which is the safe state for a read-only
  /// lens — rail→berth drops still work.
  final bool Function(BoardBerthSlot slot)? canDragBerth;

  /// The caller's drop rules (occupied, blocked, wrong seat type, gender). No
  /// validator means no drops are accepted.
  final bool Function(BoardDragPayload payload, BoardBerthSlot target)? canDrop;

  final void Function(BoardDragPayload payload, BoardBerthSlot target)? onDrop;

  /// A refused drop. The canvas has already fired the "no" haptic and the tile
  /// has already been told to flash; this is where the reason goes into a
  /// snackbar (spec §7 — never a silent failure).
  final void Function(BoardDragPayload payload, BoardBerthSlot target)?
  onInvalidDrop;

  /// Whether to pin the summary strip. Off only for an embedded preview.
  final bool showSummaryStrip;

  /// The strip's right-hand slot — where "આગળનું બાકી →" belongs.
  final Widget? stripTrailing;

  /// Queued offline mutations, shown in the strip (spec §9).
  final int pendingSyncCount;

  /// The primary action of the "this bus has no seat plan yet" state
  /// (spec §13). Without one the canvas still explains itself, but a screen
  /// that can create a layout should always pass this.
  final Widget? noLayoutAction;

  const BoardCanvas({
    super.key,
    required this.controller,
    required this.buses,
    required this.berthTileBuilder,
    this.slotSizeOf,
    this.tints = BoardTintScale.empty,
    this.onBerthTap,
    this.onBerthLongPress,
    this.canDragBerth,
    this.canDrop,
    this.onDrop,
    this.onInvalidDrop,
    this.showSummaryStrip = true,
    this.stripTrailing,
    this.pendingSyncCount = 0,
    this.noLayoutAction,
  });

  @override
  State<BoardCanvas> createState() => _BoardCanvasState();
}

class _BoardCanvasState extends State<BoardCanvas> {
  late final PageController _pages;
  final _busKeys = <String, GlobalKey<_BoardBusViewState>>{};
  final _workers = <Worker>[];

  /// Owned outright rather than taken from GetX's `debounce` worker: that
  /// worker's `dispose` cancels the SUBSCRIPTION and leaves its pending timer
  /// running, so a Board torn down mid-typing would still fire a reveal at a
  /// dead widget (and a widget test fails outright on the leaked timer).
  Timer? _searchReveal;

  @override
  void initState() {
    super.initState();
    _pages = PageController(
      initialPage: widget.controller.busIndex.value.clamp(
        0,
        math.max(0, widget.buses.length - 1),
      ),
    );
    _syncBuses();

    // The walk cursor moves for two reasons — a tap, and "next outstanding" —
    // and both must bring the berth on screen. Doing it from a worker rather
    // than from build() keeps the reveal a single scroll per move instead of
    // one per rebuild.
    _workers.add(ever<String?>(widget.controller.cursor, (id) => _reveal(id)));
    _workers.add(
      ever<String>(widget.controller.searchQuery, (_) => _scheduleSearchReveal()),
    );
    _workers.add(
      ever<int>(widget.controller.busIndex, (i) {
        if (!_pages.hasClients) return;
        if (_pages.page?.round() == i) return;
        _pages.jumpToPage(i.clamp(0, math.max(0, widget.buses.length - 1)));
      }),
    );
  }

  @override
  void didUpdateWidget(covariant BoardCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.buses.length != oldWidget.buses.length ||
        _currentPage.busId != _pageAt(oldWidget.buses, _index).busId ||
        _currentPage.layout != _pageAt(oldWidget.buses, _index).layout) {
      _syncBuses();
    }
  }

  @override
  void dispose() {
    _searchReveal?.cancel();
    for (final w in _workers) {
      w.dispose();
    }
    _pages.dispose();
    super.dispose();
  }

  int get _index => widget.controller.busIndex.value.clamp(
    0,
    math.max(0, widget.buses.length - 1),
  );

  BoardBusPage get _currentPage => _pageAt(widget.buses, _index);

  static BoardBusPage _pageAt(List<BoardBusPage> buses, int i) => buses.isEmpty
      ? const BoardBusPage(busId: '')
      : buses[i.clamp(0, buses.length - 1)];

  /// Keeps the controller's bus count and aisle walk in step with what is
  /// actually on screen. The walk is the source of [BoardController.berthCount]
  /// and so of the density default, which is why it cannot be left to a caller
  /// to remember.
  void _syncBuses() {
    final c = widget.controller;
    c.setBusCount(widget.buses.length);
    c.setLayout(_currentPage.layout);
  }

  void _onPageChanged(int i) {
    widget.controller.setBusIndex(i);
    widget.controller.setLayout(_pageAt(widget.buses, i).layout);
    HapticFeedback.selectionClick();
  }

  void _reveal(String? seatId) {
    if (seatId == null) return;
    _busKeys[_currentPage.busId]?.currentState?.reveal(seatId);
  }

  /// Restarts the quiet period before the first match is scrolled into view.
  ///
  /// Clearing the box cancels a pending reveal outright: the chart must stay
  /// exactly where the handler left it, not jump to whatever the half-typed
  /// query had matched a moment ago.
  void _scheduleSearchReveal() {
    _searchReveal?.cancel();
    if (!widget.controller.isSearching) return;
    _searchReveal = Timer(kBoardSearchRevealDelay, _revealFirstSearchHit);
  }

  /// Search does not navigate — it highlights and brings the first match into
  /// view (spec §10). "First" is first along the walk, so a handler scanning
  /// for `રમેશ` lands on the frontmost Ramesh rather than an arbitrary one.
  void _revealFirstSearchHit() {
    if (!mounted) return;
    final c = widget.controller;
    if (!c.isSearching) return;
    final page = _currentPage;
    for (final cell in c.walk.value.berths) {
      final berth = boardBerthFor(cell, page.berths);
      if (c.isBerthSearchHit(berth)) {
        _reveal(cell.seatId);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.buses.isEmpty) return _noLayout(context);

    return Obx(() {
      final c = widget.controller;

      // GetX only records the observables read INSIDE this closure, and the
      // chart's reactive state is read further down the tree — inside a
      // LayoutBuilder, inside a PageView's lazy itemBuilder — where nothing is
      // listening. So every observable the canvas depends on is touched here,
      // once, and the whole subtree is rebuilt from fresh widget instances.
      // Dropping one of these lines does not break a test; it breaks the
      // Board silently refusing to repaint on a density toggle at 5am.
      final index = _index;
      final lens = c.buildLens(tints: widget.tints);
      final page = _pageAt(widget.buses, index);
      final _ = (
        c.density,
        c.legendFilter.value,
        c.searchQuery.value,
        c.cursor.value,
        c.selection.length,
        c.multiSelect.value,
        c.walk.value,
      );

      // Aisle order, not seat-code order: the strip's "split group" reading and
      // every reveal depend on the same walk the handler physically takes.
      final ordered = <BoardBerth>[
        for (final cell in c.walk.value.berths)
          boardBerthFor(cell, page.berths),
      ];

      return Column(
        children: [
          if (widget.showSummaryStrip && ordered.isNotEmpty)
            BoardSummaryStrip(
              metric: lens.stripMetric,
              berths: ordered,
              trailing: widget.stripTrailing,
              pendingSyncCount: widget.pendingSyncCount,
            ),
          Expanded(
            child: widget.buses.length == 1
                ? _busView(context, 0, lens)
                : PageView.builder(
                    controller: _pages,
                    itemCount: widget.buses.length,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, i) => _busView(context, i, lens),
                  ),
          ),
          if (widget.buses.length > 1)
            _BusPageDots(
              count: widget.buses.length,
              index: index,
              labelOf: (i) =>
                  widget.buses[i].label ??
                  tr('board_canvas.bus_n', namedArgs: {'n': '${i + 1}'}),
              onSelect: (i) => _pages.animateToPage(
                i,
                duration: UgamMotion.tab,
                curve: UgamMotion.easeOut,
              ),
            ),
        ],
      );
    });
  }

  Widget _busView(BuildContext context, int i, BoardLens lens) {
    final page = widget.buses[i];
    final layout = page.layout;
    if (layout == null || boardRows(layout).isEmpty) return _noLayout(context);

    final key = _busKeys.putIfAbsent(
      page.busId,
      () => GlobalKey<_BoardBusViewState>(),
    );

    return _BoardBusView(
      key: key,
      storageKey: PageStorageKey<String>('board_bus_${page.busId}'),
      controller: widget.controller,
      page: page,
      lens: lens,
      canvas: widget,
      // Only the bus actually on screen owns the walk, so only it may resolve
      // "is this the cursor" or accept a tap that moves it.
      isCurrent: i == _index,
    );
  }

  Widget _noLayout(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge2),
    child: UgamEmpty(
      icon: Icons.event_seat_outlined,
      title: tr('board_canvas.no_layout_title'),
      body: tr('board_canvas.no_layout_body'),
      cta: widget.noLayoutAction,
    ),
  );
}
