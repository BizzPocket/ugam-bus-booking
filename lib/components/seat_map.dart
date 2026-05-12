import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../config/theme.dart';

class SeatMap extends StatelessWidget {
  final int totalSeats;
  final List<String> bookedSeats;
  final Function(String seatNumber) onSeatTap;

  const SeatMap({
    super.key,
    required this.totalSeats,
    required this.bookedSeats,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 2 seats | aisle | 2 seats
    const cols = 4;
    final rows = (totalSeats / cols).ceil();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.border(context),
        ),
      ),
      child: Column(
        children: [
          // ── Driver icon ──
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt(context),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.border(context),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.drive_eta_rounded,
              color: AppColors.textMuted(context),
              size: 22,
            ),
          ),
          const SizedBox(height: 24),

          // ── Seat grid ──
          ...List.generate(rows, (row) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (col) {
                  // col 2 = aisle
                  if (col == 2) {
                    return const SizedBox(width: 24);
                  }
                  final seatCol = col > 2 ? col - 1 : col;
                  final seatIndex = row * cols + seatCol;
                  if (seatIndex >= totalSeats) {
                    return const SizedBox(width: 52);
                  }
                  final seatNum = '${seatIndex + 1}';
                  final isBooked = bookedSeats.contains(seatNum);

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SeatWidget(
                      seatNumber: seatNum,
                      isBooked: isBooked,
                      onTap: isBooked ? null : () => onSeatTap(seatNum),
                    ),
                  );
                }),
              ),
            );
          }),

          const SizedBox(height: 20),

          // ── Legend ──
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LegendDot(
                color: theme.colorScheme.primary.withAlpha(30),
                borderColor: theme.colorScheme.primary,
                label: tr('app.label.available'),
                theme: theme,
              ),
              const SizedBox(width: 20),
              _LegendDot(
                color: AppColors.surfaceAlt(context),
                borderColor: AppColors.textMuted(context),
                label: tr('app.label.booked'),
                theme: theme,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SeatWidget extends StatelessWidget {
  final String seatNumber;
  final bool isBooked;
  final VoidCallback? onTap;

  const SeatWidget({
    super.key,
    required this.seatNumber,
    required this.isBooked,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isBooked
        ? AppColors.surfaceAlt(context)
        : theme.colorScheme.primary.withAlpha(isDark ? 40 : 20);
    final borderColor = isBooked
        ? AppColors.textMuted(context)
        : theme.colorScheme.primary;
    final textColor = isBooked
        ? AppColors.textMuted(context)
        : theme.colorScheme.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            topRight: Radius.circular(10),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: borderColor, width: isBooked ? 1 : 1.5),
        ),
        child: Center(
          child: Text(
            seatNumber,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final Color borderColor;
  final String label;
  final ThemeData theme;

  const _LegendDot({
    required this.color,
    required this.borderColor,
    required this.label,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: borderColor, width: 1),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
