import 'package:flutter/material.dart';

import '../../design/ugam.dart';

/// Skeleton placeholder shown on first load while the tour list is fetched —
/// mirrors the dashboard layout (greeting, hero, quick-action row, sections).
class DashboardLoadingShimmer extends StatelessWidget {
  final UgamColorSet c;
  const DashboardLoadingShimmer({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 60, radius: 16),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 150, radius: 20),
        SizedBox(height: UgamSpacing.xl),
        Row(children: [
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
        ]),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 140, radius: 22),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 56, radius: 18),
        SizedBox(height: 8),
        UgamSkeleton(height: 56, radius: 18),
      ],
    );
  }
}
