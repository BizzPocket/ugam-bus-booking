import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// A painted coach shell that wraps a seat chart so it reads as a real bus
/// floor-plan instead of a bare grid of tiles.
///
/// It is a pure *frame*: it paints a rounded body with a raked front (the cab),
/// a rounded rear, a left-side boarding door notch, and faint window seams down
/// both walls, then insets its [child] (the unchanged seat grid) so the seats
/// sit inside the walls. It owns NO placement and NO seat logic — wrapping a
/// chart in it changes nothing about seating, drag, pricing or the PDF.
///
/// Strictly neutral: it uses only graphite tokens (`card` / `cardElev` /
/// `ink3` / `border`) and never the copper accent, so it respects the
/// accent-rationing law — the one accent on a chart screen stays the edit FAB /
/// selected seat, not the chassis.
class UgamBusChassis extends StatelessWidget {
  const UgamBusChassis({super.key, required this.child});

  /// The seat chart (normally a `CombinedSeatGrid`). Sized naturally; the
  /// chassis only adds wall padding around it.
  final Widget child;

  // Wall insets between the painted shell and the seats inside it.
  static const double _insetSide = 13;
  static const double _insetTop = 16;
  static const double _insetBottom = 14;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return CustomPaint(
      painter: _BusChassisPainter(c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _insetSide,
          _insetTop,
          _insetSide,
          _insetBottom,
        ),
        child: child,
      ),
    );
  }
}

class _BusChassisPainter extends CustomPainter {
  _BusChassisPainter(this.c);

  final UgamColorSet c;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w < 24 || h < 24) return;

    // Geometry — front (cab) at the top, rear bench at the bottom.
    final taper = math.min(10.0, w * 0.06); // how much the front narrows
    final noseH = math.min(26.0, math.max(18.0, h * 0.08)); // windshield rake
    final frontR = math.min(16.0, w * 0.10);
    final rearR = math.min(20.0, w * 0.12);
    const inset = 0.75; // keep the stroke fully inside the canvas
    final left = inset;
    final right = w - inset;
    final top = inset;
    final bottom = h - inset;

    final body = Path()
      // top edge (cab roofline), shortened by the taper + corner radius
      ..moveTo(left + taper + frontR, top)
      ..lineTo(right - taper - frontR, top)
      // top-right cab corner
      ..quadraticBezierTo(right - taper, top, right - taper, top + frontR)
      // right windshield rake out to full body width
      ..lineTo(right, top + noseH)
      // right wall
      ..lineTo(right, bottom - rearR)
      // bottom-right rear corner
      ..quadraticBezierTo(right, bottom, right - rearR, bottom)
      // rear edge
      ..lineTo(left + rearR, bottom)
      // bottom-left rear corner
      ..quadraticBezierTo(left, bottom, left, bottom - rearR)
      // left wall
      ..lineTo(left, top + noseH)
      // left windshield rake in
      ..lineTo(left + taper, top + frontR)
      // top-left cab corner
      ..quadraticBezierTo(left + taper, top, left + taper + frontR, top)
      ..close();

    // Faint floor lift so the bus body separates from the card behind it.
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.fill
        ..color = c.cardElev.withValues(alpha: 0.35),
    );

    // The shell outline — a quiet graphite hairline, never the accent.
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..color = c.ink3.withValues(alpha: 0.5),
    );

    // Windshield seam — a soft line where the cab meets the cabin.
    final glassY = top + noseH + 2;
    canvas.drawLine(
      Offset(left + taper * 0.5, glassY),
      Offset(right - taper * 0.5, glassY),
      Paint()
        ..strokeWidth = 1
        ..color = c.ink3.withValues(alpha: 0.28),
    );

    _paintDoor(canvas, left, glassY, h);
    _paintWindows(canvas, left, right, glassY, bottom - rearR);
  }

  /// A boarding-door notch just behind the cab on the LEFT wall (kerb side).
  void _paintDoor(Canvas canvas, double left, double glassY, double h) {
    final doorTop = glassY + 8;
    final doorH = math.min(30.0, h * 0.16);
    final rect = Rect.fromLTWH(left - 0.5, doorTop, 5, doorH);
    // Carve the doorway out of the wall, then frame it.
    canvas.drawRect(rect, Paint()..color = c.bg);
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = c.ink3.withValues(alpha: 0.5),
    );
    // The door leaf split.
    canvas.drawLine(
      Offset(left + 2, doorTop + 2),
      Offset(left + 2, doorTop + doorH - 2),
      Paint()
        ..strokeWidth = 0.8
        ..color = c.ink3.withValues(alpha: 0.3),
    );
  }

  /// Evenly spaced window seams down both side walls — barely-there texture
  /// that says "bus", not a loud graphic.
  void _paintWindows(
    Canvas canvas,
    double left,
    double right,
    double fromY,
    double toY,
  ) {
    final span = toY - fromY;
    if (span < 40) return;
    final count = (span / 26).floor().clamp(2, 9);
    final step = span / count;
    final paint = Paint()
      ..strokeWidth = 1
      ..color = c.ink3.withValues(alpha: 0.16);
    const tick = 5.0;
    for (var i = 1; i < count; i++) {
      final y = fromY + step * i;
      canvas.drawLine(Offset(left, y), Offset(left + tick, y), paint);
      canvas.drawLine(Offset(right - tick, y), Offset(right, y), paint);
    }
  }

  @override
  bool shouldRepaint(_BusChassisPainter old) => old.c != c;
}

/// A tiny painted steering wheel — Material ships no steering-wheel glyph, so
/// this is the canonical "front of the bus / driver" marker used in the chart
/// driver strip. Neutral graphite by default; pass [color] to tint.
class UgamSteeringWheel extends StatelessWidget {
  const UgamSteeringWheel({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final col = color ?? UgamColors.of(context).ink3;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SteeringWheelPainter(col)),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  _SteeringWheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, size.width * 0.1)
      ..color = color;

    // Outer rim.
    canvas.drawCircle(center, r - stroke.strokeWidth / 2, stroke);
    // Hub.
    canvas.drawCircle(
      center,
      r * 0.22,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
    // Three spokes (down, upper-left, upper-right) — the classic wheel read.
    final hub = r * 0.22;
    for (final a in [math.pi / 2, math.pi * 7 / 6, math.pi * 11 / 6]) {
      canvas.drawLine(
        center + Offset(math.cos(a) * hub, math.sin(a) * hub),
        center + Offset(math.cos(a) * (r - stroke.strokeWidth), math.sin(a) * (r - stroke.strokeWidth)),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter old) => old.color != color;
}
