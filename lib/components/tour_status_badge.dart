import 'package:flutter/material.dart';
import '../models/tour_status.dart';
import '../design/tokens.dart';

class TourStatusBadge extends StatelessWidget {
  final TourStatus status;
  final bool compact;

  const TourStatusBadge({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Status hues resolve from the active token set so they flip with the
    // theme. `assigning` keeps a dedicated rose — it's a distinct status
    // signal, not a brand colour — and reads on both light and dark.
    final (Color color, IconData icon) = switch (status) {
      TourStatus.planning   => (c.ink2,               Icons.edit_note_rounded),
      TourStatus.collecting => (c.accent,             Icons.people_alt_rounded),
      TourStatus.busBooked  => (c.warm,               Icons.directions_bus_rounded),
      TourStatus.assigning  => (const Color(0xFFEC4899), Icons.event_seat_rounded),
      TourStatus.locked     => (c.good,               Icons.lock_rounded),
      TourStatus.completed  => (c.ink3,               Icons.check_circle_rounded),
    };
    // Tint derived from the hue itself (~14% alpha) instead of a baked
    // light-mode swatch, so the chip background works in either theme.
    final bg = color.withAlpha(36);

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          status.displayName,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            status.displayName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
