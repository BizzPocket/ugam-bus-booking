import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;
import '../models/bus.dart';
import '../config/theme.dart';

class BusCard extends StatelessWidget {
  final Bus bus;
  final int bookedSeats;
  final VoidCallback? onTap;

  const BusCard({
    super.key,
    required this.bus,
    required this.bookedSeats,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final pct = bus.totalCapacity > 0 ? bookedSeats / bus.totalCapacity : 0.0;
    final isDanger = pct > 0.8;
    final available = bus.totalCapacity - bookedSeats;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
          boxShadow: isDark
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withAlpha(8),
                    offset: const Offset(0, 4),
                    blurRadius: 12,
                  ),
                ],
        ),
        child: Row(
          children: [
            // ── Circular indicator ──
            SizedBox(
              width: 56,
              height: 56,
              child: CustomPaint(
                painter: _OccupancyRing(
                  pct: pct,
                  color: isDanger ? AppTheme.danger : theme.colorScheme.primary,
                  bgColor: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
                child: Center(
                  child: Text(
                    '${(pct * 100).toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDanger
                          ? AppTheme.danger
                          : theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(width: 16),

            // ── Info ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bus.name,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _InfoChip(
                        icon: Icons.event_seat_rounded,
                        text: '${bus.totalCapacity} seats',
                        theme: theme,
                        isDark: isDark,
                      ),
                      const SizedBox(width: 10),
                      _InfoChip(
                        icon: Icons.person_rounded,
                        text: '$bookedSeats booked',
                        theme: theme,
                        isDark: isDark,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Available badge ──
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDanger
                    ? AppTheme.danger.withAlpha(15)
                    : AppTheme.success.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Text(
                    '$available',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: isDanger ? AppTheme.danger : AppTheme.success,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'free',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: (isDanger ? AppTheme.danger : AppTheme.success)
                          .withAlpha(180),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final ThemeData theme;
  final bool isDark;

  const _InfoChip({
    required this.icon,
    required this.text,
    required this.theme,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: theme.colorScheme.onSurface.withAlpha(100),
        ),
        const SizedBox(width: 3),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withAlpha(130),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _OccupancyRing extends CustomPainter {
  final double pct;
  final Color color;
  final Color bgColor;

  _OccupancyRing({
    required this.pct,
    required this.color,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    const strokeWidth = 5.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = bgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * pct,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _OccupancyRing old) =>
      old.pct != pct || old.color != color;
}
