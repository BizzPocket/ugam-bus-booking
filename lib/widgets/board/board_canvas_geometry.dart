part of 'board_canvas.dart';

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
