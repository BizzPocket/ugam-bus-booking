import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import '../utils/chart_seat_availability.dart';

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

  const ChartSeatTile({
    super.key,
    required this.cell,
    required this.occupancy,
    required this.leg,
    this.selectedBerths = 0,
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
    if (splits) {
      return _SplitTile(
        c: c,
        seatId: cell.seatId ?? '',
        takenIsLady: lady,
        selectedBerths: selectedBerths,
        freeBerths: free,
      );
    }

    return _WholeTile(
      c: c,
      seatId: cell.seatId ?? '',
      state: state,
      lady: lady,
      isDouble: capacity == 2,
      position: cell.position,
    );
  }
}

class _WholeTile extends StatelessWidget {
  final UgamColorSet c;
  final String seatId;
  final ChartSeatState state;
  final bool lady;
  final bool isDouble;
  final SeatPosition? position;

  const _WholeTile({
    required this.c,
    required this.seatId,
    required this.state,
    required this.lady,
    required this.isDouble,
    required this.position,
  });

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

    final tile = Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: border != null ? Border.all(color: border, width: 1) : null,
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            seatId,
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
            maxLines: 1,
          ),
          if (isDouble)
            Text(
              '2',
              style: UgamText.micro.copyWith(
                color: fg.withValues(alpha: 0.7),
                fontSize: 8,
                fontWeight: FontWeight.w600,
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

/// A double sofa mid-sale: one berth gone, one still available.
class _SplitTile extends StatelessWidget {
  final UgamColorSet c;
  final String seatId;
  final bool takenIsLady;
  final int selectedBerths;
  final int freeBerths;

  const _SplitTile({
    required this.c,
    required this.seatId,
    required this.takenIsLady,
    required this.selectedBerths,
    required this.freeBerths,
  });

  /// Intrinsic dimensions, NOT flex.
  ///
  /// CombinedSeatGrid wraps every tile in a FittedBox, which hands the child
  /// UNBOUNDED constraints and then scales the result. `Expanded` inside a
  /// Column under an unbounded height is a hard assertion failure ("RenderFlex
  /// children have non-zero flex but incoming height constraints are
  /// unbounded"), and it takes the whole chart down with it — the screen
  /// renders an empty body rather than one broken tile. So this tile sizes
  /// itself and lets the FittedBox do the fitting.
  static const double _berthH = 17;
  static const double _berthW = 34;

  @override
  Widget build(BuildContext context) {
    Widget berth({required Color bg, required Color fg, String? label}) {
      return Container(
        width: _berthW,
        height: _berthH,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.seat - 3),
        ),
        alignment: Alignment.center,
        child: label == null
            ? null
            : Text(
                label,
                style: UgamText.micro.copyWith(
                  color: fg,
                  fontSize: 7.5,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
      );
    }

    // Top berth = the one already spoken for (or the one we've taken);
    // bottom berth = what is left.
    final topTaken = selectedBerths == 0;

    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (topTaken)
            berth(
              bg: takenIsLady
                  ? c.warm.withValues(alpha: 0.22)
                  : c.cardElev,
              fg: takenIsLady ? c.warm : c.ink3,
            )
          else
            berth(bg: c.accent, fg: c.onAccent, label: seatId),
          const SizedBox(height: 2.5),
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
