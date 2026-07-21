import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// Shared first-load placeholder for the money screens (bus money, collection,
/// tour money board, trip P&L). Shown while `isLoading && !loadedOnce` so the
/// board never flashes an all-₹0 "settled" state before the first fetch lands.
/// Mirrors `finance_screen`'s `_Loading` shape (hero + stat row + rows).
class MoneyLoadingSkeleton extends StatelessWidget {
  const MoneyLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      children: const [
        UgamSkeleton(height: 184, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
            SizedBox(width: UgamSpacing.md),
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
          ],
        ),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
      ],
    );
  }
}
