import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../models/tour_status.dart';
import '../design/ugam.dart';

class PhaseIndicator extends StatelessWidget {
  final TourStatus currentStatus;

  const PhaseIndicator({super.key, required this.currentStatus});

  static const _phases = [
    (Icons.edit_note_rounded, 'plan'),
    (Icons.campaign_rounded, 'collect'),
    (Icons.directions_bus_rounded, 'book'),
    (Icons.event_seat_rounded, 'assign'),
    (Icons.lock_rounded, 'lock'),
    (Icons.check_circle_rounded, 'done'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
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
                color: done ? c.good : c.border,
              ),
            );
          }

          final phaseIdx = i ~/ 2;
          final (icon, label) = _phases[phaseIdx];
          final isActive = phaseIdx == step;
          final isDone = phaseIdx < step;

          return _PhaseNode(
            icon: icon,
            label: tr('app.label.phase_$label'),
            isActive: isActive,
            isDone: isDone,
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

  const _PhaseNode({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.isDone,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final e = UgamElevation.of(context);
    final Color circleColor;
    final Color iconColor;
    final Color textColor;

    if (isActive) {
      circleColor = c.accent;
      iconColor = c.onAccent;
      textColor = c.accent;
    } else if (isDone) {
      circleColor = c.good;
      iconColor = c.onAccent;
      textColor = c.good;
    } else {
      circleColor = c.border;
      iconColor = c.ink3;
      textColor = c.ink3;
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
            // The step you are ON is the one node in this strip that sits on
            // the page rather than being part of it, so it takes level 1 and
            // every other node is explicitly level 0 — `flat`, not a bare `[]`
            // that reads as an oversight.
            //
            // Was a hand-rolled amber halo (`accent` @ 24%, blur 8) that
            // predated the scale. Two problems: it made this the only surface
            // in the app whose depth was a COLOUR rather than a level, and in
            // Daylight the deep amber smeared visibly onto the white page
            // around the dot. The active node already outranks its neighbours
            // by size (34 vs 28), by a solid accent fill against a border-grey
            // one, and by a bolder label — it does not need a glow to be found.
            boxShadow: isActive ? e.rest : e.flat,
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
          style: UgamText.micro.copyWith(
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
