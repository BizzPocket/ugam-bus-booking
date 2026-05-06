import 'package:flutter/material.dart';
import '../models/tour_status.dart';
import '../config/theme.dart';

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
    final (Color color, Color bg, IconData icon) = switch (status) {
      TourStatus.planning   => (AppTheme.info,    AppTheme.info.withAlpha(15),    Icons.edit_note_rounded),
      TourStatus.collecting => (AppTheme.brand,   AppTheme.brand.withAlpha(15),   Icons.people_alt_rounded),
      TourStatus.busBooked     => (AppTheme.warning, AppTheme.warningLight,           Icons.directions_bus_rounded),
      TourStatus.assigning  => (const Color(0xFFEC4899), const Color(0xFFFDF2F8), Icons.event_seat_rounded),
      TourStatus.locked     => (AppTheme.success, AppTheme.successLight,          Icons.lock_rounded),
      TourStatus.completed  => (const Color(0xFF6B7280), const Color(0xFFF3F4F6), Icons.check_circle_rounded),
    };

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
