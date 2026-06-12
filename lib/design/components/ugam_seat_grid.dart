import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

enum UgamSeatState { available, selected, taken, ladies, aisle, driver }

@immutable
class UgamSeatCell {
  final String? label;
  final UgamSeatState state;

  const UgamSeatCell({this.label, this.state = UgamSeatState.available});

  const UgamSeatCell.aisle()
      : label = null,
        state = UgamSeatState.aisle;

  const UgamSeatCell.driver()
      : label = null,
        state = UgamSeatState.driver;
}

/// Row-major grid of seat cells. The 3rd column (index 2) of every row
/// is reserved as an aisle gap — callers should pass `UgamSeatCell.aisle()`
/// in that slot. Driver corner sits in row 0 col 4 typically.
///
/// Container is intended to live inside a parent that already provides
/// padding and a [UgamCard] background. Use [UgamSeatGridSurface] for
/// the wrapped variant including the legend.
class UgamSeatGrid extends StatelessWidget {
  final List<List<UgamSeatCell>> rows;
  final void Function(int row, int col)? onTapSeat;

  const UgamSeatGrid({super.key, required this.rows, this.onTapSeat});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final int cols = rows[0].length;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        const double minCellWidth = 48.0;
        const double cellGap = 7.0;
        final double totalGapsWidth = (cols - 1) * cellGap;
        final double calculatedCellWidth = (constraints.maxWidth - totalGapsWidth) / cols;
        final bool useScroll = calculatedCellWidth < minCellWidth;
        final double cellWidth = useScroll ? minCellWidth : calculatedCellWidth;

        final gridContent = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int r = 0; r < rows.length; r++) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int col = 0; col < rows[r].length; col++) ...[
                    SizedBox(
                      width: cellWidth,
                      height: cellWidth,
                      child: _SeatCell(
                        cell: rows[r][col],
                        onTap: onTapSeat == null
                            ? null
                            : () {
                                HapticFeedback.selectionClick();
                                onTapSeat!(r, col);
                              },
                      ),
                    ),
                    if (col != rows[r].length - 1) const SizedBox(width: cellGap),
                  ],
                ],
              ),
              if (r != rows.length - 1) const SizedBox(height: cellGap),
            ],
          ],
        );

        if (useScroll) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: gridContent,
          );
        }
        return gridContent;
      },
    );
  }
}

class _SeatCell extends StatelessWidget {
  final UgamSeatCell cell;
  final VoidCallback? onTap;

  const _SeatCell({required this.cell, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (cell.state == UgamSeatState.aisle) {
      return const SizedBox.shrink();
    }
    if (cell.state == UgamSeatState.driver) {
      return Container(
        alignment: Alignment.center,
        child: Icon(Icons.airline_seat_legroom_extra_rounded,
            size: 18, color: c.ink3),
      );
    }

    final Color fill;
    final Color textColor;
    List<BoxShadow>? glow;

    switch (cell.state) {
      case UgamSeatState.available:
        fill = c.cardElev;
        textColor = c.ink2;
        break;
      case UgamSeatState.selected:
        fill = c.accent;
        textColor = c.onAccent;
        glow = [
          BoxShadow(
            color: c.accent.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ];
        break;
      case UgamSeatState.taken:
        fill = c.ink3;
        textColor = c.bg;
        break;
      case UgamSeatState.ladies:
        fill = c.warm;
        textColor = c.onAccent;
        break;
      case UgamSeatState.aisle:
      case UgamSeatState.driver:
        fill = Colors.transparent;
        textColor = c.ink3;
        break;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(UgamRadius.seat),
          boxShadow: glow,
        ),
        alignment: Alignment.center,
        child: Text(
          cell.label ?? '',
          style: UgamText.micro.copyWith(
            color: textColor,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

/// Legend swatch row. Pair above [UgamSeatGrid] inside a [UgamCard].
class UgamSeatLegend extends StatelessWidget {
  const UgamSeatLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      children: [
        _swatch(c.cardElev, tr('app.label.available'), context),
        const SizedBox(width: UgamSpacing.md),
        _swatch(c.accent, tr('seat_ui.selected'), context),
        const SizedBox(width: UgamSpacing.md),
        _swatch(c.ink3, tr('seat_ui.taken'), context),
        const SizedBox(width: UgamSpacing.md),
        _swatch(c.warm, tr('seat_ui.ladies'), context),
      ],
    );
  }

  Widget _swatch(Color color, String label, BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: UgamText.micro.copyWith(color: c.ink2, fontSize: 9.5)),
      ],
    );
  }
}
