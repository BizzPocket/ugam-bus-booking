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
// Geometry — pure, and therefore testable.
// ─────────────────────────────────────────────────────────────────────────────

/// One column of the chart: a lane of the coach.
///
/// [position] is only ever set for the centre pair on the back bench, which is
/// the single place the 5-column grid holds two cells at one coordinate (see
/// `SeatCell`'s identity note). Splitting it into two lanes keeps the whole
/// chart a strict grid — no special-cased bench packing — and keeps the visual
/// left-to-right order identical to `compareAisleOrder`'s slot ranking, which
/// is what stops "next outstanding" from jumping backwards across the screen.
@immutable
class BoardLane {
  final int col;
  final SeatPosition? position;

  const BoardLane(this.col, [this.position]);

  bool get isAisle => col == SeatGridCols.aisle;

  bool holds(SeatCell cell) =>
      cell.col == col && (position == null || cell.position == position);

  @override
  bool operator ==(Object other) =>
      other is BoardLane && other.col == col && other.position == position;

  @override
  int get hashCode => Object.hash(col, position);

  @override
  String toString() => 'BoardLane($col, ${position?.name})';
}

/// The lanes of [layout], left to right across the bus.
///
/// Mirrors `CombinedSeatGrid._row` (and so `compareAisleOrder`): left wall,
/// left-inner, the aisle, then the right lanes drawn LOWER-then-UPPER so both
/// lower berths sit toward the centre. Lanes no berth in the whole bus uses are
/// dropped, so an all-double coach stays centred instead of being shoved to one
/// side by a permanently blank column; the walkway lane is kept whenever both
/// sides exist, because the gap is what makes the chart read as a bus.
List<BoardLane> boardLanes(BusLayout? layout) {
  final used = <int>{};
  var aisleUpper = false;
  var aisleLower = false;
  for (final c in layout?.grid ?? const <SeatCell>[]) {
    if (!c.hasSeat) continue;
    if (c.col == SeatGridCols.aisle) {
      if (c.position == SeatPosition.lower) {
        aisleLower = true;
      } else {
        aisleUpper = true;
      }
      continue;
    }
    used.add(c.col);
  }

  final hasLeft =
      used.contains(SeatGridCols.singleUpper) ||
      used.contains(SeatGridCols.singleLower);
  final hasRight =
      used.contains(SeatGridCols.doubleUpper) ||
      used.contains(SeatGridCols.doubleLower);

  return <BoardLane>[
    if (used.contains(SeatGridCols.singleUpper))
      const BoardLane(SeatGridCols.singleUpper),
    if (used.contains(SeatGridCols.singleLower))
      const BoardLane(SeatGridCols.singleLower),
    if (aisleUpper)
      const BoardLane(SeatGridCols.aisle, SeatPosition.upper)
    else if (!aisleLower && hasLeft && hasRight)
      // The walkway itself: a blank lane, kept only when there are two sides
      // for it to sit between.
      const BoardLane(SeatGridCols.aisle),
    if (aisleLower) const BoardLane(SeatGridCols.aisle, SeatPosition.lower),
    if (used.contains(SeatGridCols.doubleLower))
      const BoardLane(SeatGridCols.doubleLower),
    if (used.contains(SeatGridCols.doubleUpper))
      const BoardLane(SeatGridCols.doubleUpper),
  ];
}

/// Row indices that carry at least one berth, front to back. Empty rows are
/// dropped so a hand-edited layout with a gap does not print a blank band.
List<int> boardRows(BusLayout? layout) {
  final rows = <int>{};
  for (final c in layout?.grid ?? const <SeatCell>[]) {
    if (c.hasSeat) rows.add(c.row);
  }
  final list = rows.toList()..sort();
  return List<int>.unmodifiable(list);
}

/// The size of one tile, plus the gap between tiles.
///
/// Named against the BUS rather than the screen, because landscape transposes
/// the chart: [laneExtent] is always measured across the coach (a width in
/// portrait, a height in landscape) and [rowExtent] always front-to-back.
@immutable
class BoardTileMetrics {
  /// Across the bus.
  final double laneExtent;

  /// Front to back.
  final double rowExtent;

  final double gap;

  /// True when the chart is drawn nose-left instead of nose-up.
  final bool landscape;

  const BoardTileMetrics({
    required this.laneExtent,
    required this.rowExtent,
    required this.gap,
    required this.landscape,
  });

  /// A tile that decides its own footprint, given in SCREEN terms (the size the
  /// widget actually paints at).
  ///
  /// This is the path the shipped berth tile takes: it packs a fixed face plus
  /// a transparent live margin into one slot and asks the canvas to reserve
  /// exactly that, so a lens switch cannot reflow the bus by changing a glyph's
  /// width. The transposition is still the canvas's: in landscape the tile is
  /// unchanged but the LAYOUT turns, so the same box is measured across the
  /// lanes by its height instead of its width.
  ///
  /// [gap] defaults to zero because such a tile carries its own gutter inside
  /// the slot; a gap on top would double it.
  factory BoardTileMetrics.fixed(
    Size size, {
    required bool landscape,
    double gap = 0,
  }) => BoardTileMetrics(
    laneExtent: landscape ? size.height : size.width,
    rowExtent: landscape ? size.width : size.height,
    gap: gap,
    landscape: landscape,
  );

  double get width => landscape ? rowExtent : laneExtent;

  double get height => landscape ? laneExtent : rowExtent;

  Size get size => Size(width, height);

  /// Resolves the tile box for [density] against the space available ACROSS the
  /// lanes ([crossExtent] — the viewport width in portrait, its height in
  /// landscape).
  ///
  /// The lane extent is elastic between a floor and a ceiling: it grows to use
  /// a wide screen (which is what makes landscape show names) and stops before
  /// a two-lane minibus turns into two enormous slabs. The row extent is fixed
  /// per mode — it is what actually decides whether 18 rows fit.
  ///
  /// Comfortable never resolves below 44pt in either axis; compact deliberately
  /// does, and the canvas pays for that with nearest-berth hit resolution
  /// rather than by growing the tile (spec §3).
  static BoardTileMetrics resolve({
    required BoardDensity density,
    required bool landscape,
    required double crossExtent,
    required int laneCount,
  }) {
    final compact = density == BoardDensity.compact;
    final gap = compact ? 3.0 : 6.0;

    final (double min, double max, double rowExtent) = switch ((
      compact,
      landscape,
    )) {
      // Portrait compact: whole coach in one screen. 22pt rows put 18 rows in
      // 450pt of scroll — the "scanning" mode.
      (true, false) => (24.0, 56.0, 22.0),
      // Portrait comfortable: the working mode. 48 clears the touch minimum.
      (false, false) => (48.0, 132.0, 48.0),
      // Landscape compact: the lane extent is now a HEIGHT, so five lanes have
      // to fit a ~390pt screen; the row extent is a width.
      (true, true) => (20.0, 44.0, 34.0),
      // Landscape comfortable: wide tiles, because this is the mode that exists
      // to show occupant names.
      (false, true) => (44.0, 76.0, 104.0),
    };

    final lanes = laneCount < 1 ? 1 : laneCount;
    final free = crossExtent - gap * (lanes - 1);
    final raw = free / lanes;

    // The floor yields rather than overflowing. A six-lane coach (a back bench
    // splits the aisle into two lanes) on a narrow phone in comfortable mode
    // wants more width than there is; growing past the viewport would push the
    // right-hand lane off the edge of a chart that only scrolls the other way,
    // so the tile goes under its nominal minimum instead. `raw` is never
    // exceeded, which is what makes "the grid always fits across" true.
    final laneExtent = raw < min ? math.max(raw, 16.0) : math.min(raw, max);

    return BoardTileMetrics(
      laneExtent: laneExtent,
      rowExtent: rowExtent,
      gap: gap,
      landscape: landscape,
    );
  }
}

/// One placed tile: the cell and the rect it occupies in chart space.
@immutable
class BoardCellRect {
  final SeatCell cell;
  final Rect rect;

  const BoardCellRect(this.cell, this.rect);
}

/// Every tile's rect, computed rather than measured.
///
/// This is the spine of the canvas. Because paint, hit-testing and scrolling
/// all read the SAME arithmetic:
///
///  * "scroll berth DL7 into view" is a subtraction, not a widget-tree walk;
///  * a tap in the gap between two compact tiles resolves to the nearer berth
///    with no expanded hit box (which a parent's own bounds check would eat
///    anyway);
///  * a density switch can hold the handler's place, because the anchor berth's
///    new centre is known before the frame is built.
@immutable
class BoardGridGeometry {
  final List<BoardCellRect> cells;
  final List<BoardLane> lanes;
  final List<int> rows;
  final BoardTileMetrics metrics;
  final Size size;

  final Map<String, int> _byId;

  const BoardGridGeometry._({
    required this.cells,
    required this.lanes,
    required this.rows,
    required this.metrics,
    required this.size,
    required Map<String, int> byId,
  }) : _byId = byId;

  static const BoardGridGeometry empty = BoardGridGeometry._(
    cells: <BoardCellRect>[],
    lanes: <BoardLane>[],
    rows: <int>[],
    metrics: BoardTileMetrics(
      laneExtent: 0,
      rowExtent: 0,
      gap: 0,
      landscape: false,
    ),
    size: Size.zero,
    byId: <String, int>{},
  );

  factory BoardGridGeometry.of({
    required BusLayout? layout,
    required BoardTileMetrics metrics,
  }) {
    final lanes = boardLanes(layout);
    final rows = boardRows(layout);
    if (lanes.isEmpty || rows.isEmpty) return empty;

    final landscape = metrics.landscape;
    final laneStride = metrics.laneExtent + metrics.gap;
    final rowStride = metrics.rowExtent + metrics.gap;

    final cells = <BoardCellRect>[];
    final byId = <String, int>{};

    for (var r = 0; r < rows.length; r++) {
      for (var l = 0; l < lanes.length; l++) {
        final lane = lanes[l];
        SeatCell? found;
        for (final c in layout?.grid ?? const <SeatCell>[]) {
          if (c.hasSeat && c.row == rows[r] && lane.holds(c)) {
            found = c;
            break;
          }
        }
        if (found == null) continue;

        final rect = landscape
            ? Rect.fromLTWH(
                r * rowStride,
                l * laneStride,
                metrics.rowExtent,
                metrics.laneExtent,
              )
            : Rect.fromLTWH(
                l * laneStride,
                r * rowStride,
                metrics.laneExtent,
                metrics.rowExtent,
              );

        final id = found.seatId;
        if (id != null && id.isNotEmpty) {
          byId.putIfAbsent(id, () => cells.length);
        }
        cells.add(BoardCellRect(found, rect));
      }
    }

    final across = lanes.length * laneStride - metrics.gap;
    final along = rows.length * rowStride - metrics.gap;

    return BoardGridGeometry._(
      cells: List.unmodifiable(cells),
      lanes: List.unmodifiable(lanes),
      rows: rows,
      metrics: metrics,
      size: landscape ? Size(along, across) : Size(across, along),
      byId: Map.unmodifiable(byId),
    );
  }

  bool get isEmpty => cells.isEmpty;

  /// The scrolling axis: a coach is drawn nose-up and scrolled down, or
  /// nose-left and scrolled sideways.
  Axis get axis => metrics.landscape ? Axis.horizontal : Axis.vertical;

  /// The chart's extent along the scrolling axis.
  double get scrollExtent => metrics.landscape ? size.width : size.height;

  /// The chart's extent across the scrolling axis.
  double get crossExtent => metrics.landscape ? size.height : size.width;

  Rect? rectOf(String? seatId) {
    if (seatId == null) return null;
    final i = _byId[seatId];
    return i == null ? null : cells[i].rect;
  }

  /// The berth nearest [point] in chart space, within [maxDistance].
  ///
  /// This is how a compact-mode tap works. Compact tiles are ~20pt, below the
  /// touch minimum by design, so the canvas does not try to grow their hit box
  /// — an oversized box would be clipped by its own slot's bounds check anyway.
  /// Instead a tap that lands in the gaps is resolved to the berth the thumb was
  /// most plausibly aiming at, which is exactly what spec §3 asks for.
  SeatCell? nearest(
    Offset point, {
    double maxDistance = BoardCanvasMetrics.nearestTapRadius,
  }) {
    SeatCell? best;
    var bestDistance = double.infinity;
    for (final placed in cells) {
      final d = _distanceTo(placed.rect, point);
      if (d < bestDistance) {
        bestDistance = d;
        best = placed.cell;
      }
    }
    return bestDistance <= maxDistance ? best : null;
  }

  static double _distanceTo(Rect rect, Offset p) {
    final dx = math.max(math.max(rect.left - p.dx, 0), p.dx - rect.right);
    final dy = math.max(math.max(rect.top - p.dy, 0), p.dy - rect.bottom);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// The scroll offset that puts [seatId] in the middle of a [viewportExtent]
  /// viewport, clamped to the scrollable range. Null when this bus has no such
  /// berth.
  ///
  /// [leading] / [trailing] are the scroll view's own padding along the axis:
  /// the chart's rects are grid-relative (they have to be — they position tiles
  /// INSIDE that padding), while a scroll offset is measured from the top of
  /// the padded content, and forgetting the difference puts every reveal one
  /// gutter off.
  double? offsetToCentre(
    String? seatId,
    double viewportExtent, {
    double leading = 0,
    double trailing = 0,
  }) {
    final rect = rectOf(seatId);
    if (rect == null) return null;
    final centre = metrics.landscape ? rect.center.dx : rect.center.dy;
    final max = math.max(
      0.0,
      leading + scrollExtent + trailing - viewportExtent,
    );
    return (leading + centre - viewportExtent / 2).clamp(0.0, max);
  }

  /// The berth sitting closest to the middle of the viewport — the reader's
  /// place, remembered so a density switch can restore it.
  ///
  /// A whole ROW shares one position along the scrolling axis, so the scroll
  /// axis alone leaves four to six berths tied and the winner would be decided
  /// by lane iteration order. That is not merely untidy: the anchor is fed back
  /// to [offsetToCentre] across a density switch, and an anchor that flips
  /// between two berths of the same row on successive scroll stops makes the
  /// restore unreproducible. The tie is therefore broken ACROSS the bus, toward
  /// the middle of the chart — which is the middle of the viewport too, because
  /// the canvas centres the grid in it.
  String? centredBerth(
    double scrollOffset,
    double viewportExtent, {
    double leading = 0,
  }) {
    const epsilon = 0.01;
    final centre = scrollOffset + viewportExtent / 2 - leading;
    final crossCentre = crossExtent / 2;
    String? best;
    var bestAlong = double.infinity;
    var bestCross = double.infinity;
    for (final placed in cells) {
      final id = placed.cell.seatId;
      if (id == null || id.isEmpty) continue;
      final along =
          ((metrics.landscape ? placed.rect.center.dx : placed.rect.center.dy) -
                  centre)
              .abs();
      final cross =
          ((metrics.landscape ? placed.rect.center.dy : placed.rect.center.dx) -
                  crossCentre)
              .abs();
      // Row first, lane second. A berth one row away is never a better anchor
      // than one in the right row, however close to the aisle it sits.
      final closerRow = along < bestAlong - epsilon;
      final sameRow = (along - bestAlong).abs() <= epsilon;
      if (closerRow || (sameRow && cross < bestCross)) {
        bestAlong = along;
        bestCross = cross;
        best = id;
      }
    }
    return best;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers the shell needs too.
// ─────────────────────────────────────────────────────────────────────────────

/// The berth facts for [cell], or an honest vacant berth when the manifest has
/// nothing for it.
///
/// Public because the "next outstanding →" control has to build its predicate
/// from the same mapping the canvas paints from; two slightly different answers
/// to "is this berth empty" would walk the handler to a berth that does not
/// look empty on screen.
BoardBerth boardBerthFor(SeatCell cell, Map<String, BoardBerth> berths) {
  final id = cell.seatId;
  final known = id == null ? null : berths[id];
  if (known != null) return known;
  return BoardBerth(
    code: id ?? '',
    isBlocked: cell.reserved,
    seatTypeLabel: cell.typeLabel,
  );
}

/// The aisle-walk predicate for [lens] over [berths] — "should the handler stop
/// here?". Feed it to `BoardController.advanceToNextOutstanding`.
BerthPredicate boardNeedsAction(BoardLens lens, Map<String, BoardBerth> berths) =>
    (cell) => lens.needsAction(boardBerthFor(cell, berths));

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

// ─────────────────────────────────────────────────────────────────────────────
// One bus: zoom + scroll + grid.
// ─────────────────────────────────────────────────────────────────────────────

class _BoardBusView extends StatefulWidget {
  final PageStorageKey<String> storageKey;
  final BoardController controller;
  final BoardBusPage page;
  final BoardLens lens;
  final BoardCanvas canvas;
  final bool isCurrent;

  const _BoardBusView({
    super.key,
    required this.storageKey,
    required this.controller,
    required this.page,
    required this.lens,
    required this.canvas,
    required this.isCurrent,
  });

  @override
  State<_BoardBusView> createState() => _BoardBusViewState();
}

class _BoardBusViewState extends State<_BoardBusView> {
  final _scroll = ScrollController();

  BoardGridGeometry _geometry = BoardGridGeometry.empty;

  /// The full extent of the scroll viewport along its axis — padding included,
  /// because that is the frame a scroll offset is measured in.
  double _viewportExtent = 0;

  /// The scroll view's gutter at the near end of the axis.
  double _pad = 0;

  /// The berth the handler is looking at, remembered on every scroll stop so a
  /// density switch has something to restore to.
  String? _anchor;

  BoardDensity? _lastDensity;
  String? _pendingReveal;
  bool _revealAnimated = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  /// Brings [seatId] to the middle of the viewport. Under reduced motion this
  /// is an instant jump, not a scroll (spec §11).
  void reveal(String seatId, {bool animate = true}) {
    _revealAnimated = animate;
    final target = _geometry.offsetToCentre(
      seatId,
      _viewportExtent,
      leading: _pad,
      trailing: _pad,
    );
    if (target == null || !_scroll.hasClients) {
      // The frame that owns this berth has not been laid out yet — most often
      // the very first reveal, before the first paint. Hold it for that frame.
      _pendingReveal = seatId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _drainReveal());
      return;
    }
    if ((target - _scroll.offset).abs() < 1) return;
    if (!animate || _reduceMotion) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: UgamMotion.sheet,
        curve: UgamMotion.easeOut,
      );
    }
  }

  void _drainReveal() {
    final id = _pendingReveal;
    if (id == null || !mounted) return;
    _pendingReveal = null;
    reveal(id, animate: _revealAnimated);
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && _scroll.hasClients) {
      _anchor = _geometry.centredBerth(
        _scroll.offset,
        _viewportExtent,
        leading: _pad,
      );
    }
    return false;
  }

  /// A density switch changes every extent on the chart, so a pixel offset is
  /// meaningless across it. The BERTH is not: hold the one that was in the
  /// middle and put it back there (spec §3 — "switching cleanly without losing
  /// scroll position").
  void _handleDensityChange(BoardDensity next) {
    final was = _lastDensity;
    _lastDensity = next;
    if (was == null || was == next) return;
    final anchor =
        _anchor ??
        (_scroll.hasClients
            ? _geometry.centredBerth(
                _scroll.offset,
                _viewportExtent,
                leading: _pad,
              )
            : null);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(anchor, animate: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final density = controller.density;
        _handleDensityChange(density);

        final lanes = boardLanes(widget.page.layout);
        const padding = EdgeInsets.all(UgamSpacing.md);
        _pad = UgamSpacing.md;
        final crossAvailable = landscape
            ? constraints.maxHeight - padding.vertical
            : constraints.maxWidth - padding.horizontal;

        // A tile with a fixed footprint can be wider than the phone once a back
        // bench splits the aisle into six lanes. The chart only scrolls one
        // way, so the sixth lane would simply be gone; instead the whole bus is
        // scaled down to fit across, exactly as the existing seat chart does.
        // The SCALED box is what the geometry records, so hit-testing and
        // reveals stay honest, and the tile is painted at its natural size
        // inside a FittedBox so its internal layout is untouched.
        final fixed = widget.canvas.slotSizeOf?.call(context, density);
        Size? natural;
        final BoardTileMetrics metrics;
        if (fixed != null) {
          final perLane = landscape ? fixed.height : fixed.width;
          final needed = perLane * lanes.length;
          final scale = needed <= 0
              ? 1.0
              : math.min(1.0, crossAvailable / needed);
          metrics = BoardTileMetrics.fixed(fixed * scale, landscape: landscape);
          if (scale < 1) natural = fixed;
        } else {
          metrics = BoardTileMetrics.resolve(
            density: density,
            landscape: landscape,
            crossExtent: crossAvailable,
            laneCount: lanes.length,
          );
        }
        _geometry = BoardGridGeometry.of(
          layout: widget.page.layout,
          metrics: metrics,
        );
        _viewportExtent = landscape
            ? constraints.maxWidth
            : constraints.maxHeight;

        if (_geometry.isEmpty) return const SizedBox.shrink();

        final grid = _BoardGrid(
          geometry: _geometry,
          naturalTileSize: natural,
          controller: controller,
          page: widget.page,
          lens: widget.lens,
          canvas: widget.canvas,
          isCurrent: widget.isCurrent,
        );

        // Clipped because UgamPinchZoom deliberately does NOT clip (it is built
        // for diagrams that may be dragged past their box); on the Board a
        // zoomed chart bleeding over the sticky strip would hide the one number
        // that must never leave the screen.
        return ClipRect(
          child: UgamPinchZoom(
            // Gesture order, outside in: the page swipe and the chart scroll
            // both claim a one-finger drag at kTouchSlop (18) and so win the
            // arena ahead of InteractiveViewer's pan, which needs kPanSlop
            // (36). Two fingers reach the zoom, because a scale gesture is
            // something neither of the other two ever claims.
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: SingleChildScrollView(
                key: widget.storageKey,
                controller: _scroll,
                scrollDirection: _geometry.axis,
                padding: padding,
                child: Center(child: grid),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The grid itself.
// ─────────────────────────────────────────────────────────────────────────────

class _BoardGrid extends StatelessWidget {
  final BoardGridGeometry geometry;

  /// The tile's own footprint when the whole bus had to be scaled down to fit
  /// across the phone; null when the slot the geometry reserved IS the tile's
  /// natural size.
  final Size? naturalTileSize;

  final BoardController controller;
  final BoardBusPage page;
  final BoardLens lens;
  final BoardCanvas canvas;
  final bool isCurrent;

  const _BoardGrid({
    required this.geometry,
    required this.naturalTileSize,
    required this.controller,
    required this.page,
    required this.lens,
    required this.canvas,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    final berths = <BoardBerth>[
      for (final placed in geometry.cells)
        boardBerthFor(placed.cell, page.berths),
    ];
    // Rows nothing matches are dropped (spec §13), and the filter is asked
    // against the lens's OWN predicate rather than a bucket key re-invented per
    // tile — see BoardController.isBerthDimmed.
    final legend = lens.legendFor(berths, colors);
    final walk = controller.walk.value;

    final tiles = <Widget>[];
    for (var i = 0; i < geometry.cells.length; i++) {
      final placed = geometry.cells[i];
      final berth = berths[i];
      final seatId = placed.cell.seatId;

      final slot = BoardBerthSlot(
        cell: placed.cell,
        berth: berth,
        paint: lens.paint(berth, colors),
        semanticLabel: lens.semanticLabel(berth),
        lens: lens,
        density: controller.density,
        size: placed.rect.size,
        aisleIndex: walk.indexOf(seatId) ?? i,
        isDimmed: controller.isBerthDimmed(berth, legend),
        isSearchHit: controller.isBerthSearchHit(berth),
        isSelected: seatId != null && controller.isSelected(seatId),
        isCursor: isCurrent && seatId != null && controller.cursor.value == seatId,
      );

      tiles.add(
        Positioned.fromRect(
          rect: placed.rect,
          child: _BerthHost(
            slot: slot,
            naturalSize: naturalTileSize,
            controller: controller,
            canvas: canvas,
          ),
        ),
      );
    }

    return SizedBox(
      width: geometry.size.width,
      height: geometry.size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _walkway(colors),
          // Below the tiles: a tap that lands in the gaps between compact
          // tiles is resolved to the berth nearest the thumb (spec §3).
          if (controller.isCompact) _nearestBerthCatcher(context, colors),
          ...tiles,
        ],
      ),
    );
  }

  /// The centre aisle as a quiet floor line — the same walkway guide the
  /// existing seat chart draws, so the Board still reads as a bus rather than
  /// as a spreadsheet. Decorative only; never the accent.
  Widget _walkway(UgamColorSet colors) {
    // A coach with a back bench splits the aisle into two lanes (the bench's
    // upper and lower berths). The handler still walks ONE aisle, so the guide
    // is drawn down the middle of whatever block of aisle lanes exists.
    final first = geometry.lanes.indexWhere((l) => l.isAisle);
    if (first < 0) return const SizedBox.shrink();
    final last = geometry.lanes.lastIndexWhere((l) => l.isAisle);

    final m = geometry.metrics;
    final stride = m.laneExtent + m.gap;
    final at =
        (first * stride + last * stride + m.laneExtent) / 2;
    final color = colors.ink3.withValues(
      alpha: BoardCanvasMetrics.walkwayAlpha,
    );

    return m.landscape
        ? Positioned(
            top: at,
            left: 0,
            width: geometry.size.width,
            height: BoardCanvasMetrics.walkwayThickness,
            child: ColoredBox(color: color),
          )
        : Positioned(
            left: at,
            top: 0,
            width: BoardCanvasMetrics.walkwayThickness,
            height: geometry.size.height,
            child: ColoredBox(color: color),
          );
  }

  Widget _nearestBerthCatcher(BuildContext context, UgamColorSet colors) =>
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            final cell = geometry.nearest(details.localPosition);
            if (cell == null) return;
            _handleBerthTap(
              cell,
              controller: controller,
              page: page,
              lens: lens,
              canvas: canvas,
              density: controller.density,
              // The berth's OWN box, so a slot handed out by the gap-catcher is
              // indistinguishable from one handed out by the tile itself.
              size: geometry.rectOf(cell.seatId)?.size ?? geometry.metrics.size,
              aisleIndex: controller.walk.value.indexOf(cell.seatId) ?? 0,
              colors: colors,
            );
          },
        ),
      );
}

/// Shared tap handling for both routes into a berth (the tile itself, and the
/// compact-mode nearest-berth catcher), so the two can never drift.
void _handleBerthTap(
  SeatCell cell, {
  required BoardController controller,
  required BoardBusPage page,
  required BoardLens lens,
  required BoardCanvas canvas,
  required BoardDensity density,
  required Size size,
  required int aisleIndex,
  required UgamColorSet colors,
}) {
  final seatId = cell.seatId;
  HapticFeedback.selectionClick();

  if (controller.isMultiSelecting) {
    if (seatId != null) controller.toggleSelected(seatId);
    return;
  }

  // Park the walk where the handler actually is, so "next outstanding" carries
  // on from here rather than from wherever the last auto-advance left off.
  controller.setCursor(seatId);

  final berth = boardBerthFor(cell, page.berths);
  canvas.onBerthTap?.call(
    BoardBerthSlot(
      cell: cell,
      berth: berth,
      paint: lens.paint(berth, colors),
      semanticLabel: lens.semanticLabel(berth),
      lens: lens,
      density: density,
      size: size,
      aisleIndex: aisleIndex,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// One berth: semantics, dimming, pulse, gestures, drop target.
// ─────────────────────────────────────────────────────────────────────────────

class _BerthHost extends StatefulWidget {
  final BoardBerthSlot slot;
  final Size? naturalSize;
  final BoardController controller;
  final BoardCanvas canvas;

  const _BerthHost({
    required this.slot,
    required this.naturalSize,
    required this.controller,
    required this.canvas,
  });

  @override
  State<_BerthHost> createState() => _BerthHostState();
}

class _BerthHostState extends State<_BerthHost> {
  Offset? _pressAt;
  double _travel = 0;
  BoardDropState _dropState = BoardDropState.none;

  BoardBerthSlot get _slot => widget.slot;

  bool get _canDrag =>
      _slot.seatId != null &&
      (widget.canvas.canDragBerth?.call(_slot) ?? false) &&
      widget.canvas.onDrop != null;

  void _tap() {
    final id = _slot.seatId;
    HapticFeedback.selectionClick();
    if (widget.controller.isMultiSelecting) {
      if (id != null) widget.controller.toggleSelected(id);
      return;
    }
    widget.controller.setCursor(id);
    widget.canvas.onBerthTap?.call(_slot);
  }

  void _longPress() {
    final id = _slot.seatId;
    if (id != null) widget.controller.beginMultiSelect(id);
    widget.canvas.onBerthLongPress?.call(_slot);
  }

  bool _willAccept(BoardDragPayload payload) {
    if (payload.fromSeatId != null && payload.fromSeatId == _slot.seatId) {
      return false;
    }
    return widget.canvas.canDrop?.call(payload, _slot) ?? false;
  }

  void _drop(BoardDragPayload payload) {
    if (_willAccept(payload)) {
      HapticFeedback.lightImpact();
      widget.canvas.onDrop?.call(payload, _slot);
      return;
    }
    // The "no" pattern (spec §12): two heavy taps, not one, so it cannot be
    // mistaken for the success buzz.
    HapticFeedback.heavyImpact();
    Future<void>.delayed(
      const Duration(milliseconds: 90),
      HapticFeedback.heavyImpact,
    );
    widget.canvas.onInvalidDrop?.call(payload, _slot);
  }

  @override
  Widget build(BuildContext context) {
    final slot = _dropState == BoardDropState.none
        ? _slot
        : _copyWithDropState(_slot, _dropState);

    // The tile is given the box and fills it. Dimming is NOT applied here: the
    // canvas decides WHICH berths dim (it is the only thing that knows the
    // active filter, the search and the lens's legend predicates) and the tile
    // renders the fade, because fading a tinted fill by its own alpha reads far
    // better than dropping an opaque tile to 30% over the page.
    final natural = widget.naturalSize;
    Widget tile = SizedBox(
      width: slot.size.width,
      height: slot.size.height,
      child: natural == null
          ? widget.canvas.berthTileBuilder(context, slot)
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: natural.width,
                height: natural.height,
                child: widget.canvas.berthTileBuilder(context, slot),
              ),
            ),
    );

    if (slot.isSearchHit) tile = _BerthPulse(child: tile);

    Widget gestures = UgamTappable(
      onTap: _tap,
      // A draggable berth spends its long-press on the drag; the multi-select
      // that gesture also carries is resolved on release, by travel (see
      // [kBoardDragSlop]).
      onLongPress: _canDrag ? null : _longPress,
      // Berth taps are selectionClick, not the wrapper's lightImpact
      // (spec §12), and a handler tapping down a row of 22 would feel the
      // default as a rattle.
      haptic: false,
      pressedScale: slot.isCompact ? 0.90 : 0.96,
      child: tile,
    );

    if (_canDrag) gestures = _wrapDraggable(gestures);

    if (widget.canvas.canDrop != null) {
      // Captured by VALUE before the reassignment below. A builder that closed
      // over `gestures` itself would return the DragTarget from inside its own
      // builder — an infinite tree that mounts thousands of elements deep and
      // then trips a framework assertion rather than failing cleanly.
      final droppable = gestures;
      gestures = DragTarget<BoardDragPayload>(
        onWillAcceptWithDetails: (details) {
          // Dropping a berth back on itself is a cancel, not a move.
          if (details.data.fromSeatId != null &&
              details.data.fromSeatId == _slot.seatId) {
            return false;
          }
          final ok = _willAccept(details.data);
          // Both answers paint: an invalid target must say so BEFORE the finger
          // lifts, or the handler learns only from a snackbar after the fact.
          setState(
            () =>
                _dropState = ok ? BoardDropState.valid : BoardDropState.invalid,
          );
          // Accept the drop EVEN WHEN IT IS INVALID. Refusing here would make
          // the release fall through to the draggable's cancel path, and spec
          // §7 forbids a silent failure: the berth has to receive the drop in
          // order to flash danger, fire the "no" haptic and name the reason.
          return true;
        },
        onLeave: (_) => setState(() => _dropState = BoardDropState.none),
        onAcceptWithDetails: (details) {
          setState(() => _dropState = BoardDropState.none);
          _drop(details.data);
        },
        builder: (context, candidate, rejected) => droppable,
      );
    }

    // No Semantics wrapper: see [BoardBerthSlot.semanticLabel]. The tile is the
    // one node per berth.
    return gestures;
  }

  Widget _wrapDraggable(Widget child) {
    final payload = BoardDragPayload.fromBerth(
      fromSeatId: _slot.seatId!,
      label: _slot.berth.occupantName ?? _slot.berth.code,
    );

    return Listener(
      // Listener never joins the gesture arena, so it sees the whole pointer
      // stream regardless of who wins it — which is what lets a release be
      // classified as "held still" (multi-select) or "moved" (a drag).
      onPointerDown: (e) {
        _pressAt = e.position;
        _travel = 0;
      },
      onPointerMove: (e) {
        final from = _pressAt;
        if (from == null) return;
        final d = (e.position - from).distance;
        if (d > _travel) _travel = d;
      },
      child: LongPressDraggable<BoardDragPayload>(
        data: payload,
        delay: kBoardDragHold,
        hapticFeedbackOnStart: false,
        maxSimultaneousDrags: 1,
        onDragStarted: HapticFeedback.mediumImpact,
        // `onDragEnd` alone, deliberately. Flutter fires it for EVERY finished
        // drag and then fires `onDraggableCanceled` as well for a refused one,
        // so listening to both would settle a cancelled drag twice — and a
        // settle that lands under the travel threshold enters multi-select, so
        // the second one would announce a long-press the handler never made.
        onDragEnd: (_) => _settleDrag(),
        feedback: _DragChip(label: payload.label),
        childWhenDragging: Opacity(opacity: kBoardDimOpacity, child: child),
        child: child,
      ),
    );
  }

  /// A pick-up that never went anywhere was a long-press, and a long-press is
  /// multi-select (spec §7). Doing it here rather than binding both gestures at
  /// once is what keeps a tired thumb from assigning somebody to the wrong
  /// berth.
  void _settleDrag() {
    if (_travel < kBoardDragSlop) _longPress();
    _pressAt = null;
    _travel = 0;
  }

  static BoardBerthSlot _copyWithDropState(
    BoardBerthSlot slot,
    BoardDropState state,
  ) => BoardBerthSlot(
    cell: slot.cell,
    berth: slot.berth,
    paint: slot.paint,
    semanticLabel: slot.semanticLabel,
    lens: slot.lens,
    density: slot.density,
    size: slot.size,
    aisleIndex: slot.aisleIndex,
    isDimmed: slot.isDimmed,
    isSearchHit: slot.isSearchHit,
    isSelected: slot.isSelected,
    isCursor: slot.isCursor,
    dropState: state,
  );
}

/// The chip that follows the finger. Deliberately plain — the information is
/// WHO is moving, not a second copy of the tile.
class _DragChip extends StatelessWidget {
  final String label;

  const _DragChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final e = UgamElevation.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.tight,
          vertical: UgamSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          boxShadow: e.raised,
        ),
        child: Text(
          label,
          style: UgamText.caption.copyWith(color: c.ink),
        ),
      ),
    );
  }
}

/// The search highlight (spec §10): the matching berth pulses while everything
/// else dims. Under reduced motion the pulse becomes a static accent ring —
/// still a second, non-colour signal, just not a moving one.
class _BerthPulse extends StatefulWidget {
  final Widget child;

  const _BerthPulse({required this.child});

  @override
  State<_BerthPulse> createState() => _BerthPulseState();
}

class _BerthPulseState extends State<_BerthPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: UgamMotion.shimmer,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.stop();
      _ctrl.value = 1;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true, min: 0.25);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(UgamRadius.seat),
          border: Border.all(
            color: c.accent,
            width: BoardCanvasMetrics.pulseRing,
          ),
          boxShadow: [
            BoxShadow(
              color: c.glow.withValues(
                alpha: BoardCanvasMetrics.pulseGlowAlpha * _ctrl.value,
              ),
              blurRadius: BoardCanvasMetrics.pulseBlur * _ctrl.value,
              spreadRadius: BoardCanvasMetrics.pulseSpread * _ctrl.value,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// The multi-bus page indicator (spec §3). Dots, because the count is small and
/// the gesture is the real control — this exists to say "there is another bus"
/// and to give the switch a keyboard/screen-reader route.
class _BusPageDots extends StatelessWidget {
  final int count;
  final int index;
  final String Function(int i) labelOf;
  final void Function(int i) onSelect;

  const _BusPageDots({
    required this.count,
    required this.index,
    required this.labelOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tap = UgamScale.tap(context, 44);

    return Semantics(
      label: tr(
        'board_canvas.bus_position',
        namedArgs: {'index': '${index + 1}', 'total': '$count'},
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              UgamTappable(
                onTap: i == index ? null : () => onSelect(i),
                semanticLabel: labelOf(i),
                pressedScale: 0.9,
                child: SizedBox(
                  width: tap / 2,
                  height: tap / 2,
                  child: Center(
                    child: AnimatedContainer(
                      duration: UgamMotion.tab,
                      curve: UgamMotion.easeOut,
                      width: i == index
                          ? BoardCanvasMetrics.dotActiveWidth
                          : BoardCanvasMetrics.dotSize,
                      height: BoardCanvasMetrics.dotSize,
                      decoration: BoxDecoration(
                        color: i == index ? c.accent : c.ink3,
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
