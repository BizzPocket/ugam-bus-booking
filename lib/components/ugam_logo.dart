import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Ugam Booking brand mark — gold sun rays, gold half-disc, deep-red `ઉગમ`
/// Gujarati script, and a deep-red bus silhouette inside the disc.
///
/// Rendered as a vector via CustomPaint so it scales sharp from a 48×48
/// launcher icon to a 256×256 splash logo without bitmap artefacts.
class UgamLogo extends StatelessWidget {
  final double size;

  /// Whether to draw on a transparent background. When false, fills with
  /// the cream background colour `#FFF7ED` (used as the launcher-icon
  /// background layer).
  final bool transparentBackground;

  const UgamLogo({
    super.key,
    this.size = 180,
    this.transparentBackground = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _UgamLogoPainter(
          gujaratiTextStyle: GoogleFonts.notoSansGujarati(
            fontSize: size * 0.18,
            fontWeight: FontWeight.w800,
            color: const Color(0xFFB91C1C),
          ),
          backgroundColor:
              transparentBackground ? null : const Color(0xFFFFF7ED),
        ),
      ),
    );
  }
}

class _UgamLogoPainter extends CustomPainter {
  static const Color _rayColor = Color(0xFFFFC107);
  static const Color _discColor = Color(0xFFFFB300);
  static const Color _busColor = Color(0xFF991B1B);

  static const int _rayCount = 12;
  static const double _horizonYFrac = 0.55;
  static const double _discRadiusFrac = 0.35;
  static const double _longRayFrac = 0.35;
  static const double _shortRayFrac = 0.22;
  static const double _rayHalfWidthFrac = 0.018;

  final TextStyle gujaratiTextStyle;
  final Color? backgroundColor;

  _UgamLogoPainter({
    required this.gujaratiTextStyle,
    this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (backgroundColor != null) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = backgroundColor!,
      );
    }

    final s = math.min(size.width, size.height);
    final centerX = size.width / 2;
    final horizonY = size.height * _horizonYFrac;
    final discRadius = s * _discRadiusFrac;
    final longRay = s * _longRayFrac;
    final shortRay = s * _shortRayFrac;
    final rayHalfWidth = s * _rayHalfWidthFrac;

    _drawRays(
      canvas: canvas,
      center: Offset(centerX, horizonY),
      longRay: longRay,
      shortRay: shortRay,
      halfWidth: rayHalfWidth,
      discRadius: discRadius,
    );

    _drawHalfDisc(
      canvas: canvas,
      center: Offset(centerX, horizonY),
      radius: discRadius,
    );

    _drawGujaratiText(
      canvas: canvas,
      center: Offset(centerX, horizonY + discRadius * 0.35),
    );

    _drawBus(
      canvas: canvas,
      center: Offset(centerX, horizonY + discRadius * 0.78),
      width: discRadius * 0.9,
    );
  }

  void _drawRays({
    required Canvas canvas,
    required Offset center,
    required double longRay,
    required double shortRay,
    required double halfWidth,
    required double discRadius,
  }) {
    final paint = Paint()..color = _rayColor;

    for (int i = 0; i < _rayCount; i++) {
      // Spread rays across upper semicircle, biased slightly inward from
      // the horizon so the outermost rays don't sit flat on the line.
      final t = (i + 0.5) / _rayCount;
      final angle = math.pi + t * math.pi; // pi to 2*pi → upper semicircle
      final isLong = i.isEven;
      final length = isLong ? longRay : shortRay;
      final tipDistance = discRadius + length;
      final baseDistance = discRadius * 0.92;

      final tip = Offset(
        center.dx + math.cos(angle) * tipDistance,
        center.dy + math.sin(angle) * tipDistance,
      );
      final baseCenter = Offset(
        center.dx + math.cos(angle) * baseDistance,
        center.dy + math.sin(angle) * baseDistance,
      );
      final perp = Offset(-math.sin(angle), math.cos(angle));
      final base1 = baseCenter + perp * halfWidth;
      final base2 = baseCenter - perp * halfWidth;

      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(base1.dx, base1.dy)
        ..lineTo(base2.dx, base2.dy)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  void _drawHalfDisc({
    required Canvas canvas,
    required Offset center,
    required double radius,
  }) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()..color = _discColor;
    canvas.drawArc(rect, 0, math.pi, true, paint);
  }

  void _drawGujaratiText({
    required Canvas canvas,
    required Offset center,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: 'ઉગમ', style: gujaratiTextStyle),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  void _drawBus({
    required Canvas canvas,
    required Offset center,
    required double width,
  }) {
    final h = width * 0.42;
    final body = Rect.fromCenter(center: center, width: width, height: h);
    final bodyRRect =
        RRect.fromRectAndRadius(body, Radius.circular(h * 0.18));
    final paint = Paint()..color = _busColor;
    canvas.drawRRect(bodyRRect, paint);

    // Two windows
    final winPaint = Paint()..color = const Color(0xFFFFF7ED);
    final winH = h * 0.40;
    final winY = center.dy - h * 0.10;
    final winW = width * 0.22;
    final leftWin = Rect.fromCenter(
      center: Offset(center.dx - width * 0.18, winY),
      width: winW,
      height: winH,
    );
    final rightWin = Rect.fromCenter(
      center: Offset(center.dx + width * 0.18, winY),
      width: winW,
      height: winH,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(leftWin, Radius.circular(winH * 0.2)),
      winPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rightWin, Radius.circular(winH * 0.2)),
      winPaint,
    );

    // Wheels
    final wheelR = h * 0.22;
    final wheelY = center.dy + h * 0.45;
    final wheelPaint = Paint()..color = _busColor;
    canvas.drawCircle(
      Offset(center.dx - width * 0.28, wheelY),
      wheelR,
      wheelPaint,
    );
    canvas.drawCircle(
      Offset(center.dx + width * 0.28, wheelY),
      wheelR,
      wheelPaint,
    );
  }

  @override
  bool shouldRepaint(_UgamLogoPainter oldDelegate) =>
      oldDelegate.gujaratiTextStyle != gujaratiTextStyle ||
      oldDelegate.backgroundColor != backgroundColor;
}
