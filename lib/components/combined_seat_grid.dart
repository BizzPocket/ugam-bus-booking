import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/components/ugam_bus_chassis.dart';
import '../design/text_styles.dart';
import '../design/tokens.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import 'seat_chart_tile.dart';

/// Renders a [BusLayout] as one combined 5-column grid (no deck toggle).
///
/// Column placement follows [SeatGridCols]: single-upper | single-lower |
/// aisle | double-upper | double-lower. The aisle (col 2) is an empty gap on a
/// normal row. The back bench — the last row, when it carries aisle berths — is
/// drawn flat instead: every seat in that row packed across the full width as
/// equal full-size tiles, with no centre gap.
///
/// The widget owns *placement*; the caller owns *appearance* via [tileBuilder]
/// (or uses [CombinedSeatGrid.seatTile] for the standard look). The grid scales
/// down to fit its width, so it never overflows the viewport.
class CombinedSeatGrid extends StatelessWidget {
  final BusLayout layout;

  /// Builds the tile for a non-empty [SeatCell]. The returned widget is scaled
  /// to fit its slot, so it can return its natural size.
  final Widget Function(BuildContext context, SeatCell cell) tileBuilder;

  final double cellWidth;
  final double cellHeight;
  final double colGap;
  final double rowGap;

  /// Show the driver indicator above the grid.
  final bool showDriver;
  final String? driverLabel;

  /// Reserve a full 44 px header band above the seats so a top-anchored overlay
  /// control (the [ChartExpandButton], pinned top-left) clears the first seat
  /// instead of bleeding onto it. Opt-in: read-only charts with no overlay keep
  /// the slim driver strip. Only takes effect when [showDriver] is true.
  final bool reserveTopAction;

  // ── Optional drag-to-move/swap + edit-flags hooks ──────────────────────────
  // All default off/null so existing (read-only) call sites are unaffected: the
  // grid wraps tiles in a [SeatDragWrapper] ONLY when [enableDrag] is true.

  /// Master switch for long-press drag of a booked seat onto another seat. When
  /// off the grid renders exactly as before (no [SeatDragWrapper] at all).
  final bool enableDrag;

  /// Fired when one seat is dropped onto another. The caller decides move (free
  /// target) vs swap (occupied target) and calls the group-safe controller
  /// (TourController.moveSeat / swapSeats). The grid writes NO data.
  final void Function(String fromSeatId, String toSeatId)? onSeatDraggedToSeat;

  /// Per-cell: can this seat be PICKED UP? The caller answers (e.g. "true only
  /// for a single, unambiguous occupant"). Defaults to false when null, so no
  /// seat is draggable unless the caller opts it in.
  final bool Function(SeatCell cell)? canDragSeat;

  /// Per-cell: the live drop-target classification against the in-flight drag.
  /// The caller owns the move-vs-swap/blocked rules; the grid only paints the
  /// returned highlight. Returns [SeatDropHighlight.none] when null.
  final SeatDropHighlight Function(SeatCell cell)? dropHighlightFor;

  /// True while a drag is in flight anywhere in this grid (drives whether the
  /// per-cell highlight paints). The caller flips this in its own setState from
  /// [onSeatDragStarted] / [onSeatDragEnded].
  final bool dragActive;

  /// Per-cell label for the chip that follows the finger (usually the occupant
  /// name). Null hides the name (seat id only).
  final String? Function(SeatCell cell)? dragLabelFor;

  /// True when a rejected drop should still be REPORTED (so the caller can toast
  /// the reason) instead of silently bouncing. Off by default.
  final bool reportRejectedDrops;

  /// Called when a seat is lifted / released. The caller toggles [dragActive].
  final void Function(SeatCell cell)? onSeatDragStarted;
  final VoidCallback? onSeatDragEnded;

  /// Per-seat "edit flags" affordance: long-press (when drag is OFF) opens the
  /// caller's flag editor (forward / reserved / handler …). Null disables it.
  /// Independent of [enableDrag]; a screen uses one OR the other.
  final void Function(String seatId)? onSeatLongPressForFlags;

  const CombinedSeatGrid({
    super.key,
    required this.layout,
    required this.tileBuilder,
    this.cellWidth = 46,
    this.cellHeight = 44,
    this.colGap = 6,
    this.rowGap = 6,
    this.showDriver = true,
    this.driverLabel,
    this.reserveTopAction = false,
    this.enableDrag = false,
    this.onSeatDraggedToSeat,
    this.canDragSeat,
    this.dropHighlightFor,
    this.dragActive = false,
    this.dragLabelFor,
    this.reportRejectedDrops = false,
    this.onSeatDragStarted,
    this.onSeatDragEnded,
    this.onSeatLongPressForFlags,
  });

  bool _rowHasSeats(int row) =>
      layout.grid.any((c) => c.row == row && c.hasSeat);

  /// Lane columns (0,1,3,4) that carry at least one seat anywhere in the bus.
  /// Entirely-empty lanes are dropped so single-lane buses (e.g. all-double)
  /// stay centred instead of being pushed to one side by permanent blanks.
  Set<int> get _usedLaneCols {
    final used = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat && cell.col != SeatGridCols.aisle) used.add(cell.col);
    }
    return used;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final rowsWithSeats = <int>[];
    for (var r = 0; r < layout.rows; r++) {
      if (_rowHasSeats(r)) rowsWithSeats.add(r);
    }
    final usedCols = _usedLaneCols;
    final hasLeft =
        usedCols.contains(SeatGridCols.singleUpper) ||
        usedCols.contains(SeatGridCols.singleLower);
    final hasRight =
        usedCols.contains(SeatGridCols.doubleUpper) ||
        usedCols.contains(SeatGridCols.doubleLower);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDriver) ...[
          // When an overlay control (expand-to-fullscreen) is pinned top-left,
          // reserve a fixed 44 px band so the seats start below it; the driver
          // label stays right-aligned and centres within that band. Without an
          // overlay, the slim intrinsic-height row is kept (the grid lives in an
          // unbounded scroll view, so a bare Row — not a stretched Align — is
          // what's safe there).
          if (reserveTopAction)
            SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerRight,
                child: _driverRow(c),
              ),
            )
          else
            _driverRow(c),
          const SizedBox(height: UgamSpacing.sm),
          Divider(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rowsWithSeats.length; i++) ...[
                _row(context, rowsWithSeats[i], usedCols, hasLeft, hasRight),
                if (i < rowsWithSeats.length - 1) SizedBox(height: rowGap),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The right-aligned driver indicator (icon + label). Kept as one builder so
  /// the slim and the reserved-band paths render an identical row.
  Widget _driverRow(UgamColorSet c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        UgamSteeringWheel(size: 15, color: c.ink3),
        const SizedBox(width: 6),
        Text(
          (driverLabel ?? tr('seat_ui.driver')).toUpperCase(),
          style: UgamText.micro.copyWith(letterSpacing: 1, color: c.ink3),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    int row,
    Set<int> usedCols,
    bool hasLeft,
    bool hasRight,
  ) {
    // A row carrying seats in the aisle column is the back bench: draw it flat
    // (full-width, full-size, no centre gap) so the leftover/balcony berths read
    // as a real bench rather than a tiny half-height middle sofa.
    final pair = layout.balconyPair(row);
    if (pair.upper.hasSeat || pair.lower.hasSeat) {
      return _benchRow(context, row);
    }

    // The aisle is a real (blank) column so the grid reads as 5-wide: it shows
    // whenever both lanes exist. Collapsed only when one whole lane is absent.
    final showAisle = hasLeft && hasRight;

    final cols = <Widget>[];
    void add(Widget w) {
      if (cols.isNotEmpty) cols.add(SizedBox(width: colGap));
      cols.add(w);
    }

    if (usedCols.contains(SeatGridCols.singleUpper)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.singleUpper)));
    }
    if (usedCols.contains(SeatGridCols.singleLower)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.singleLower)));
    }
    if (showAisle) {
      add(_aisleSlot(UgamColors.of(context)));
    }
    // Doubles render Lower then Upper (so the layout reads U L | L U, with the
    // two lower columns toward the centre aisle).
    if (usedCols.contains(SeatGridCols.doubleLower)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.doubleLower)));
    }
    if (usedCols.contains(SeatGridCols.doubleUpper)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.doubleUpper)));
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cols,
    );
  }

  /// The back bench: every seat in [row] (lane berths + the aisle berths) drawn
  /// as equal full-size tiles packed across the full width — no centre gap, no
  /// half-height split. A bench is wider than a normal 2+2 row, so the grid's
  /// [FittedBox] scales every tile down a touch to fit, exactly like the snug
  /// back row of a real coach.
  Widget _benchRow(BuildContext context, int row) {
    final cols = <Widget>[];
    void add(SeatCell cell) {
      if (!cell.hasSeat) return;
      if (cols.isNotEmpty) cols.add(SizedBox(width: colGap));
      cols.add(_slot(context, cell));
    }

    // Same left-to-right structure as a normal row, so the bench lines up with
    // the body above: single column on the LEFT, the aisle/balcony berth(s) in
    // the CENTRE (the gap on normal rows), then the doubles on the RIGHT drawn
    // Lower-then-Upper (lowers toward the centre) exactly like _row().
    add(layout.cellAt(row, SeatGridCols.singleUpper));
    add(layout.cellAt(row, SeatGridCols.singleLower));
    final pair = layout.balconyPair(row);
    add(pair.upper);
    add(pair.lower);
    add(layout.cellAt(row, SeatGridCols.doubleLower));
    add(layout.cellAt(row, SeatGridCols.doubleUpper));

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cols,
    );
  }

  /// The centre aisle — a quiet walkway guide rather than blank space. A short
  /// graphite bar centred in the slot; across rows the small top/bottom gaps
  /// read as a dashed floor line down the middle of the bus. Neutral only, so
  /// the accent stays rationed to the seats/CTA.
  Widget _aisleSlot(UgamColorSet c) {
    return SizedBox(
      width: cellWidth,
      height: cellHeight,
      child: Center(
        child: Container(
          width: 1.5,
          height: cellHeight * 0.7,
          decoration: BoxDecoration(
            color: c.ink3.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }

  /// A fixed lane slot. Empty cells render as blank space so columns align.
  /// Non-empty tiles are wrapped with the optional drag / flag affordances when
  /// the caller opted in; otherwise the tile renders exactly as before.
  Widget _slot(BuildContext context, SeatCell cell) {
    return SizedBox(
      width: cellWidth,
      height: cellHeight,
      child: cell.isEmpty
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: _wrapTile(context, cell, tileBuilder(context, cell)),
            ),
    );
  }

  /// Layers the optional drag-to-move/swap and flag-edit affordances over a
  /// rendered [tile]. Returns the bare tile unchanged when nothing is enabled,
  /// so read-only call sites are visually identical.
  Widget _wrapTile(BuildContext context, SeatCell cell, Widget tile) {
    final seatId = cell.seatId;
    if (enableDrag && seatId != null) {
      return SeatDragWrapper(
        seatId: seatId,
        draggable: canDragSeat?.call(cell) ?? false,
        dragLabel: dragLabelFor?.call(cell),
        dragActive: dragActive,
        highlight: dropHighlightFor?.call(cell) ?? SeatDropHighlight.none,
        acceptForReason: reportRejectedDrops,
        onDragStarted: onSeatDragStarted == null
            ? null
            : () => onSeatDragStarted!(cell),
        onDragEnd: onSeatDragEnded,
        onSeatDropped: onSeatDraggedToSeat,
        child: tile,
      );
    }
    if (onSeatLongPressForFlags != null && seatId != null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => onSeatLongPressForFlags!(seatId),
        child: tile,
      );
    }
    return tile;
  }

  /// Standard seat tile: rounded surface with the seat ID and a short type
  /// label. Callers pass the resolved colours for the cell's current state.
  static Widget seatTile(
    BuildContext context, {
    required String label,
    String? subLabel,
    required Color background,
    required Color border,
    required Color foreground,
    double width = 46,
    double height = 40,
    double borderWidth = 1,
    VoidCallback? onTap,
  }) {
    final tile = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border, width: borderWidth),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(fontSize: 11, color: foreground),
            ),
          ),
          if (subLabel != null)
            Text(
              subLabel,
              style: UgamText.micro.copyWith(
                fontSize: 7,
                fontWeight: FontWeight.w700,
                color: foreground.withValues(alpha: 0.8),
                letterSpacing: 0.4,
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return tile;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }

  /// Short uppercase label for a seat type ("SINGLE" / "DOUBLE" / "SEATER").
  static String shortType(SeatType t) => switch (t) {
    SeatType.singleSofa => tr('seat_ui.type_single'),
    SeatType.doubleSofa => tr('seat_ui.type_double'),
    SeatType.seater => tr('seat_ui.type_seater'),
  };
}
