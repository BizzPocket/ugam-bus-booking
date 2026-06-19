import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../utils/seat_money_state.dart';
import '../group_color.dart';
import '../text_styles.dart';
import '../tokens.dart';

/// The dot colour for a seat's collection state, co-located with the legend so
/// the swatch keys (paid = good, owing = danger) and the live seat dots stay in
/// lockstep. `uncollected` reads as a neutral hairline so it never competes
/// with the group / priority ring. Shared by every chart that paints a money
/// dot (handler, manual seat assignment, charts, bus status).
extension SeatMoneyStateColor on SeatMoneyState {
  Color dotColor(UgamColorSet c) {
    switch (this) {
      case SeatMoneyState.paid:
        return c.good;
      case SeatMoneyState.owing:
        return c.danger;
      case SeatMoneyState.returnDue:
        return c.warm;
      case SeatMoneyState.uncollected:
        return c.ink3;
    }
  }
}

/// The canonical seat-chart legend, shared by every occupancy screen so the
/// seat-state key looks and reads identically for every role — admin
/// (manual seat assignment), agent (charts / single-bus status) and handler.
///
/// Renders the full set, in order:
///   Free · Booked · Priority/forward · Held · Go (one-way) · Return (one-way)
///   · ½ half-fare · Paid · Owing
///
/// Labels come from the shared `seat_legend.*` translation namespace
/// (en/gu/hi parity). This is the single source of truth — screens must NOT
/// hand-roll their own legend. Extracted verbatim from the handler chart
/// legend, which was previously the richest variant.
class UgamSeatChartLegend extends StatelessWidget {
  final UgamColorSet c;
  const UgamSeatChartLegend({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UgamSpacing.md,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        _LegendItem(
          swatch: _LegendSwatch.dashed,
          label: tr('seat_legend.free'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.filled,
          label: tr('seat_legend.booked'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.warmRing,
          label: tr('seat_legend.priority'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.held,
          label: tr('seat_legend.held'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.go,
          label: tr('seat_legend.go'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.ret,
          label: tr('seat_legend.ret'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.halfFare,
          label: tr('seat_legend.half'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.paidDot,
          label: tr('seat_legend.paid'),
          c: c,
        ),
        _LegendItem(
          swatch: _LegendSwatch.owingDot,
          label: tr('seat_legend.owing'),
          c: c,
        ),
      ],
    );
  }
}

enum _LegendSwatch {
  dashed,
  filled,
  warmRing,
  held,
  go,
  ret,
  halfFare,
  paidDot,
  owingDot,
}

class _LegendItem extends StatelessWidget {
  final _LegendSwatch swatch;
  final String label;
  final UgamColorSet c;

  const _LegendItem({
    required this.swatch,
    required this.label,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    Widget dot;
    switch (swatch) {
      case _LegendSwatch.dashed:
        dot = CustomPaint(
          painter: _DashedBorderPainter(
            color: c.ink3.withValues(alpha: 0.7),
            radius: 3,
          ),
          child: const SizedBox(width: 12, height: 12),
        );
      case _LegendSwatch.filled:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
        );
      case _LegendSwatch.warmRing:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.warm, width: 2),
          ),
        );
      case _LegendSwatch.held:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.lock_outline_rounded, size: 8, color: c.ink3),
        );
      case _LegendSwatch.go:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kOneWayTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kOneWayTint, width: 1.6),
          ),
        );
      case _LegendSwatch.ret:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kReturnTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kReturnTint, width: 1.6),
          ),
        );
      case _LegendSwatch.halfFare:
        dot = Container(
          width: 16,
          height: 12,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.ink3.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(
              color: c.ink3.withValues(alpha: 0.6),
              width: 0.8,
            ),
          ),
          child: Text(
            '½',
            style: UgamText.micro.copyWith(
              color: c.ink2,
              fontSize: 8,
              fontWeight: FontWeight.w900,
            ),
          ),
        );
      case _LegendSwatch.paidDot:
        dot = _Dot(color: c.good, size: 12);
      case _LegendSwatch.owingDot:
        dot = _Dot(color: c.danger, size: 12);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    const dash = 3.0;
    const gap = 2.0;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = dist + dash;
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}
