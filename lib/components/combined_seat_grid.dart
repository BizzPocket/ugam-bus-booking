import 'package:flutter/material.dart';

import '../design/text_styles.dart';
import '../design/tokens.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';

/// Renders a [BusLayout] as one combined 5-column grid (no deck toggle).
///
/// Column placement follows [SeatGridCols]: single-upper | single-lower |
/// aisle | double-upper | double-lower. The aisle (col 2) is an empty gap
/// except on the balcony (back) row, where it carries an upper + lower berth
/// pair rendered as a single split tile.
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
    final hasLeft = usedCols.contains(SeatGridCols.singleUpper) ||
        usedCols.contains(SeatGridCols.singleLower);
    final hasRight = usedCols.contains(SeatGridCols.doubleUpper) ||
        usedCols.contains(SeatGridCols.doubleLower);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showDriver) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.account_circle_rounded, size: 16, color: c.ink3),
              const SizedBox(width: 6),
              Text(
                (driverLabel ?? 'DRIVER').toUpperCase(),
                style: UgamText.micro.copyWith(letterSpacing: 1, color: c.ink3),
              ),
            ],
          ),
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

  Widget _row(
    BuildContext context,
    int row,
    Set<int> usedCols,
    bool hasLeft,
    bool hasRight,
  ) {
    final pair = layout.balconyPair(row);
    final hasBalcony = pair.upper.hasSeat || pair.lower.hasSeat;

    // The aisle is a real (blank) column so the grid reads as 5-wide: it shows
    // whenever both lanes exist, and on the balcony row it carries the split
    // upper/lower pair. Collapsed only when one whole lane is absent.
    final showAisle = hasBalcony || (hasLeft && hasRight);

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
      add(hasBalcony
          ? _balconyAisle(context, pair)
          : SizedBox(width: cellWidth, height: cellHeight));
    }
    if (usedCols.contains(SeatGridCols.doubleUpper)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.doubleUpper)));
    }
    if (usedCols.contains(SeatGridCols.doubleLower)) {
      add(_slot(context, layout.cellAt(row, SeatGridCols.doubleLower)));
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: cols,
    );
  }

  /// A fixed lane slot. Empty cells render as blank space so columns align.
  Widget _slot(BuildContext context, SeatCell cell) {
    return SizedBox(
      width: cellWidth,
      height: cellHeight,
      child: cell.isEmpty
          ? null
          : FittedBox(fit: BoxFit.scaleDown, child: tileBuilder(context, cell)),
    );
  }

  /// The balcony aisle column: a full seat-width slot holding the upper berth
  /// stacked over the lower berth.
  Widget _balconyAisle(
    BuildContext context,
    ({SeatCell upper, SeatCell lower}) pair,
  ) {
    final halfH = (cellHeight - 2) / 2;
    Widget half(SeatCell cell) => SizedBox(
          width: cellWidth,
          height: halfH,
          child: cell.isEmpty
              ? null
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: tileBuilder(context, cell),
                ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        half(pair.upper),
        const SizedBox(height: 2),
        half(pair.lower),
      ],
    );
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
        SeatType.singleSofa => 'SINGLE',
        SeatType.doubleSofa => 'DOUBLE',
        SeatType.seater => 'SEATER',
      };
}
