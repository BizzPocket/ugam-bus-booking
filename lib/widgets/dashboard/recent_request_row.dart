import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import 'dashboard_models.dart';

/// A recent passenger request rendered with the shared [UgamRequestRow]:
/// initials avatar + name + a seats chip + relative time.
class DashboardRecentRow extends StatelessWidget {
  final RecentEntry entry;
  final VoidCallback onTap;

  const DashboardRecentRow({
    super.key,
    required this.entry,
    required this.onTap,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) {
      return tr('dashboard.ago_days', namedArgs: {'n': '${d.inDays}'});
    }
    if (d.inHours > 0) {
      return tr('dashboard.ago_hours', namedArgs: {'n': '${d.inHours}'});
    }
    if (d.inMinutes > 0) {
      return tr('dashboard.ago_mins', namedArgs: {'n': '${d.inMinutes}'});
    }
    return tr('dashboard.ago_now');
  }

  @override
  Widget build(BuildContext context) {
    final p = entry.passenger;
    return UgamRequestRow(
      initials: _initials(p.name),
      name: p.name,
      timeAgo: _ago(p.createdAt),
      chips: [
        UgamReqChip(
          label: tr('dashboard.recent_seats_chip',
              namedArgs: {'n': '${p.totalSeatsRequested}'}),
          variant: UgamChipVariant.neutral,
        ),
      ],
      onTap: onTap,
    );
  }
}
