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
      // Radii come off the token scale and match the REAL widget each
      // placeholder stands in for, so the corners don't visibly change shape
      // when the shimmer is replaced: the greeting, the hero, the four
      // quick-action tiles and the attention block all resolve to
      // `UgamCard.plain` (UgamRadius.card), and the two recent-request rows to
      // `UgamRequestRow` (UgamRadius.row). Was a hand-picked 16/20/22/18 spread,
      // none of which was a token.
      children: const [
        UgamSkeleton(height: 60, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 150, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        Row(children: [
          Expanded(child: UgamSkeleton(height: 92, radius: UgamRadius.card)),
          SizedBox(width: UgamSpacing.sm),
          Expanded(child: UgamSkeleton(height: 92, radius: UgamRadius.card)),
          SizedBox(width: UgamSpacing.sm),
          Expanded(child: UgamSkeleton(height: 92, radius: UgamRadius.card)),
          SizedBox(width: UgamSpacing.sm),
          Expanded(child: UgamSkeleton(height: 92, radius: UgamRadius.card)),
        ]),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 140, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 56, radius: UgamRadius.row),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 56, radius: UgamRadius.row),
      ],
    );
  }
}
