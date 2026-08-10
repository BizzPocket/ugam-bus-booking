import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import '../utils/formatters.dart';
import '../utils/chart_seat_availability.dart';

/// Fixed geometry for every customer chart tile.
///
/// *** WHY THIS EXISTS AS A CONST, NOT AS PER-TILE LAYOUT ***
/// `_WholeTile` used to be a Container sized by its text and `_SplitTile` was
/// hardcoded to 34x17 berths. CombinedSeatGrid wraps both in
/// FittedBox(scaleDown) — which never scales UP — so each tile rendered at its
/// own natural size. Measured, that was FIVE different footprints across the
/// states of one chart: a free single 36x14, a selected single 34x12, a free
/// double 36x24, a half-taken double 41x43.
///
/// Two visible bugs came out of that:
///   1. Singles read as short pills next to blob-like doubles.
///   2. The 20s availability poll swapped a whole tile for a split tile
///      mid-scroll. Different size -> FittedBox rescale -> the whole row
///      reflowed. That was the "chart flickers" report.
///
/// So size is decided HERE, once, and both tiles are pinned to it. FittedBox in
/// the grid drops from being the layout mechanism to a safety net for the
/// wider back-bench row. Sized to sit inside the grid's 44x46 slot with a
/// hairline of breathing room, at the app's established cockpit density.
class ChartSeatMetrics {
  const ChartSeatMetrics._();

  /// Grown from 40x42 so a tile can carry a WORD and a PRICE, not just an
  /// identifier. `SU1` told the customer nothing; "નીચે ₹1,400" tells them the
  /// two things they are actually choosing on.
  ///
  /// The recorded density rule — spacing compressed to a cockpit density, do
  /// not re-widen — was set for the OPERATOR app. This changes only the
  /// customer seat tile. No shared spacing token moves, and the operator and
  /// handler charts are untouched.
  static const double width = 56;
  static const double height = 52;

  /// Inset between the tile edge and the two berths of a split double.
  static const double splitPadding = 3;

  /// Gap between the upper and lower berth of a split double.
  static const double splitGap = 3;

  /// The split tile's outline. Counted below because a Border eats into the
  /// content box on TOP of the padding — omitting it overflowed the berths by
  /// exactly 2px (1px per edge) and tripped the RenderFlex assertion.
  static const double splitBorder = 1;

  /// Space left for the two berths once padding and border are removed.
  static const double _splitInset = (splitPadding + splitBorder) * 2;

  /// Height of one berth inside a split double.
  static const double berthHeight = (height - _splitInset - splitGap) / 2;

  /// Width of one berth inside a split double.
  static const double berthWidth = width - _splitInset;
}

/// The i18n key naming what this cell IS, in the customer's words.
///
/// `SU1` is Single Upper 1 — engineer output, with the single most consequential
/// fact in Indian sleeper travel (upper vs lower berth) encoded in one letter.
/// An elderly passenger who must have a lower berth could not see which seats
/// those were. This is the fix, kept pure so it can be tested without a widget.
///
/// A double sofa reports how many people it holds rather than its deck: that is
/// what a customer is choosing on, and the glyph already shows the deck.
String berthWordKey(SeatCell cell) {
  if (cell.seatType == SeatType.seater) return 'seat_ui.berth_seater';
  if (cell.seatType == SeatType.doubleSofa) return 'seat_ui.berth_sofa_two';
  return cell.position == SeatPosition.lower
      ? 'seat_ui.berth_lower'
      : 'seat_ui.berth_upper';
}

/// One seat on the CUSTOMER seat chart.
///
/// Deliberately NOT [SeatChartTile] (the admin/handler tile): that one renders
/// occupant identity, and a customer must never see who is sitting where. This
/// tile is fed only by the anonymised availability feed — counts and a ladies
/// marker, no names, no phones.
///
/// *** THE SIGNATURE ***
/// A double sofa is TWO berths, and it is drawn as two. Every competitor draws
/// a berth as one flat box — GSRTC ships 18x20px GIFs in a table — so none of
/// them can show HALF a sofa, because none of them sell half a sofa. This app
/// does: a double with one berth gone renders as a split tile, one half taken
/// and one still open.
class ChartSeatTile extends StatelessWidget {
  final SeatCell cell;
  final SeatAvailability? occupancy;

  /// The leg the customer chose. Availability is resolved FOR that leg, so
  /// "open" on this tile always means "open for you" — which is why there is
  /// no per-leg badge anywhere on it.
  final TripType leg;

  /// Berths of this cell in the customer's current, uncommitted selection.
  final int selectedBerths;

  /// What ONE berth of this cell costs, already adjusted for the leg.
  ///
  /// Shown on the tile face so band pricing is visible BEFORE the tap. It used
  /// to be discoverable only by selecting a seat and watching the footer total
  /// move. Null hides the price (the caller has no bus context).
  final double? berthPrice;

  const ChartSeatTile({
    super.key,
    required this.cell,
    required this.occupancy,
    required this.leg,
    this.selectedBerths = 0,
    this.berthPrice,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    if (!cell.hasSeat) return const SizedBox.shrink();

    final capacity = berthsOfCell(cell);
    final free = freeBerths(cell: cell, occupancy: occupancy, leg: leg);
    final state = chartSeatState(
      cell: cell,
      occupancy: occupancy,
      leg: leg,
      selectedBerths: selectedBerths,
    );
    final lady = hasLadyOn(occupancy: occupancy, leg: leg);

    // A two-berth cell that is neither wholly free nor wholly ours splits, so
    // the customer can see there is still one berth to take.
    final splits = capacity == 2 &&
        (state == ChartSeatState.partlyTaken ||
            (selectedBerths == 1 && free >= 1));

    return SizedBox(
      width: ChartSeatMetrics.width,
      height: ChartSeatMetrics.height,
      child: splits
          ? _SplitTile(
              c: c,
              seatId: cell.seatId ?? '',
              takenIsLady: lady,
              selectedBerths: selectedBerths,
            )
          : _WholeTile(
              c: c,
              cell: cell,
              // A two-person sofa quotes the WHOLE sofa; the half price belongs
              // in the share sheet, next to the words explaining what half means.
              price: berthPrice == null
                  ? null
                  : berthPrice! * (capacity == 2 ? 2 : 1),
              seatId: cell.seatId ?? '',
              state: state,
              lady: lady,
              isDouble: capacity == 2,
            ),
    );
  }
}

/// The seat id, scaled down rather than clipped when a layout uses long ids
/// (a 40-seat seater runs to "ST40"). Scaling the TEXT keeps the TILE fixed,
/// which is the whole point of [ChartSeatMetrics].
class _SeatLabel extends StatelessWidget {
  final String text;
  final Color color;
  final double fontSize;

  const _SeatLabel({
    required this.text,
    required this.color,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        style: UgamText.tabular(
          UgamText.micro.copyWith(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        maxLines: 1,
      ),
    );
  }
}

class _WholeTile extends StatelessWidget {
  final UgamColorSet c;
  final SeatCell cell;
  final String seatId;
  final ChartSeatState state;
  final bool lady;
  final bool isDouble;

  /// Total for this whole cell (a two-person sofa quotes both berths).
  final double? price;

  const _WholeTile({
    required this.c,
    required this.cell,
    required this.seatId,
    required this.state,
    required this.lady,
    required this.isDouble,
    required this.price,
  });

  /// Whether quoting a price here means anything. A sold or held-back seat
  /// cannot be bought, so a price on it is noise.
  bool get _quotable =>
      state != ChartSeatState.taken && state != ChartSeatState.blocked;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    Color? border;

    switch (state) {
      case ChartSeatState.free:
        bg = c.cardElev;
        fg = c.ink2;
        border = c.border;
      case ChartSeatState.selected:
        // The ONE saturated thing on the screen: amber means "yours".
        bg = c.accent;
        fg = c.onAccent;
      case ChartSeatState.taken:
        // Recedes into the ground rather than being greyed — and it is not
        // tappable, which is GSRTC's own mechanism for an unavailable seat.
        bg = lady ? c.warmFill : c.bg;
        fg = lady ? c.warm : c.ink3;
        border = lady ? null : c.border;
      case ChartSeatState.partlyTaken:
        bg = c.cardElev;
        fg = c.ink2;
        border = c.border;
      case ChartSeatState.blocked:
        bg = c.bg;
        fg = c.ink3;
        border = c.border;
    }

    // Animated, not plain: tapping a seat is the primary interaction on this
    // screen and it used to snap between colours with no feedback at all. Size
    // is pinned by ChartSeatMetrics, so only paint animates — nothing reflows.
    final tile = AnimatedContainer(
      duration: UgamMotion.tapOut,
      curve: UgamMotion.easeOut,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: border != null ? Border.all(color: border, width: 1) : null,
      ),
      // The berth marker is a CORNER badge, not a second text line. A second
      // line changed the tile's height, which is what made doubles taller than
      // singles in the first place.
      child: Stack(
        children: [
          // WHAT IT IS, then WHAT IT COSTS. The seat code used to be the
          // headline; it told a customer nothing and hid upper-vs-lower, the
          // one attribute that actually matters to an elderly passenger.
          Padding(
            padding: const EdgeInsets.fromLTRB(3, 4, 3, 3),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _BerthGlyph(
                  color: fg,
                  // The bar sits high for an upper berth and low for a lower
                  // one, so the deck reads at a glance even before the word.
                  high: cell.position == SeatPosition.upper,
                  wide: isDouble,
                ),
                const SizedBox(height: 3),
                _SeatLabel(
                  text: tr(berthWordKey(cell)),
                  color: fg,
                  fontSize: 9.5,
                ),
                // A seat nobody can buy does not advertise a price.
                if (price != null && _quotable) ...[
                  const SizedBox(height: 1),
                  _SeatLabel(
                    text: Formatters.formatMoneyInr(price!),
                    color: fg,
                    fontSize: 10.5,
                  ),
                ],
              ],
            ),
          ),
          // The code still has to match the printed ticket and the handler's
          // call at boarding, so it stays — just not as the headline.
          Positioned(
            right: 3,
            bottom: 2,
            child: Text(
              seatId,
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: fg.withValues(alpha: 0.55),
                  fontSize: 7.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (state != ChartSeatState.blocked) return tile;
    // Held back by the organiser — hatched so it reads as deliberately out of
    // play rather than merely sold.
    return CustomPaint(
      foregroundPainter: _HatchPainter(c.ink3.withValues(alpha: 0.35)),
      child: tile,
    );
  }
}

/// A berth drawn as a berth: a bar for the mattress, sitting HIGH in its box
/// for an upper berth and LOW for a lower one.
///
/// Carries the deck without words, which matters when the label is a long
/// Gujarati string and when the reader is not confident with text at all.
class _BerthGlyph extends StatelessWidget {
  final Color color;
  final bool high;
  final bool wide;

  const _BerthGlyph({
    required this.color,
    required this.high,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: wide ? 26 : 18,
      height: 10,
      child: Column(
        mainAxisAlignment:
            high ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

/// A double sofa mid-sale: one berth gone, one still available.
///
/// Occupies EXACTLY [ChartSeatMetrics.width] x [ChartSeatMetrics.height], the
/// same as [_WholeTile], so a poll that flips a double from whole to split
/// cannot reflow the row.
class _SplitTile extends StatelessWidget {
  final UgamColorSet c;
  final String seatId;
  final bool takenIsLady;
  final int selectedBerths;

  const _SplitTile({
    required this.c,
    required this.seatId,
    required this.takenIsLady,
    required this.selectedBerths,
  });

  @override
  Widget build(BuildContext context) {
    Widget berth({required Color bg, required Color fg, String? label}) {
      return AnimatedContainer(
        duration: UgamMotion.tapOut,
        curve: UgamMotion.easeOut,
        width: ChartSeatMetrics.berthWidth,
        height: ChartSeatMetrics.berthHeight,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.seat - 3),
        ),
        alignment: Alignment.center,
        child: label == null
            ? null
            : _SeatLabel(text: label, color: fg, fontSize: 8.5),
      );
    }

    // Top berth = the one already spoken for (or the one we've taken);
    // bottom berth = what is left.
    final topTaken = selectedBerths == 0;

    return Container(
      padding: const EdgeInsets.all(ChartSeatMetrics.splitPadding),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(
          color: c.border,
          width: ChartSeatMetrics.splitBorder,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (topTaken)
            berth(
              bg: takenIsLady ? c.warm.withValues(alpha: 0.22) : c.cardElev,
              fg: takenIsLady ? c.warm : c.ink3,
            )
          else
            berth(bg: c.accent, fg: c.onAccent, label: seatId),
          const SizedBox(height: ChartSeatMetrics.splitGap),
          if (selectedBerths >= 2)
            berth(bg: c.accent, fg: c.onAccent)
          else
            berth(
              bg: c.cardElev,
              fg: c.ink3,
              label: topTaken ? seatId : null,
            ),
        ],
      ),
    );
  }
}

/// Diagonal hatch for a seat the organiser has held back.
class _HatchPainter extends CustomPainter {
  final Color color;
  const _HatchPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 5.0;
    for (var x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}
