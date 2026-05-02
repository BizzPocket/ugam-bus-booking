import 'package:flutter/material.dart';
import '../models/tour_status.dart';
import '../config/theme.dart';

class PhaseIndicator extends StatelessWidget {
  final TourStatus currentStatus;

  const PhaseIndicator({super.key, required this.currentStatus});

  static const _phases = [
    (Icons.edit_note_rounded, 'Plan'),
    (Icons.campaign_rounded, 'Collect'),
    (Icons.directions_bus_rounded, 'Book'),
    (Icons.event_seat_rounded, 'Assign'),
    (Icons.lock_rounded, 'Lock'),
    (Icons.check_circle_rounded, 'Done'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final step = currentStatus.stepIndex;

    return SizedBox(
      height: 64,
      child: Row(
        children: List.generate(_phases.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector line
            final phaseIdx = i ~/ 2;
            final done = phaseIdx < step;
            return Expanded(
              child: Container(
                height: 2,
                color: done
                    ? AppTheme.brand
                    : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              ),
            );
          }

          final phaseIdx = i ~/ 2;
          final (icon, label) = _phases[phaseIdx];
          final isActive = phaseIdx == step;
          final isDone = phaseIdx < step;

          return _PhaseNode(
            icon: icon,
            label: label,
            isActive: isActive,
            isDone: isDone,
            isDark: isDark,
            theme: theme,
          );
        }),
      ),
    );
  }
}

class _PhaseNode extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isDone;
  final bool isDark;
  final ThemeData theme;

  const _PhaseNode({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.isDark,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final Color circleColor;
    final Color iconColor;
    final Color textColor;

    if (isActive) {
      circleColor = AppTheme.brand;
      iconColor = Colors.white;
      textColor = AppTheme.brand;
    } else if (isDone) {
      circleColor = AppTheme.success;
      iconColor = Colors.white;
      textColor = AppTheme.success;
    } else {
      circleColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
      iconColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
      textColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: isActive ? 34 : 28,
          height: isActive ? 34 : 28,
          decoration: BoxDecoration(
            color: circleColor,
            shape: BoxShape.circle,
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppTheme.brand.withAlpha(60),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : [],
          ),
          child: Icon(
            isDone ? Icons.check_rounded : icon,
            size: isActive ? 16 : 13,
            color: iconColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: textColor,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}
