import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../models/tour.dart';

/// One actionable blocker surfaced in the dashboard "Needs attention" list.
/// Built by [DashboardScreen] (which owns the lifecycle priority order) and
/// rendered by [DashboardAttentionRow].
class AttentionItem {
  final Tour tour;
  final String reason;
  final String ctaLabel;
  final IconData ctaIcon;
  final UgamStatusTone tone;
  final VoidCallback onTap;
  const AttentionItem({
    required this.tour,
    required this.reason,
    required this.ctaLabel,
    required this.ctaIcon,
    required this.tone,
    required this.onTap,
  });
}

/// A single recent passenger request (a passenger paired with its tour), shown
/// in the dashboard "Recent requests" list.
class RecentEntry {
  final Tour tour;
  final Passenger passenger;
  RecentEntry({required this.tour, required this.passenger});
}
