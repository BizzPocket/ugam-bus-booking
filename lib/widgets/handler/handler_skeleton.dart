// The initial-load placeholder for the handler board.

import 'package:flutter/material.dart';
import '../../design/ugam.dart';

// ─── Loading skeleton ──────────────────────────────────────────────────

/// The initial-load placeholder for the chart body: the view toggle, the
/// money-summary tiles, and the roster card mocked as shimmering blocks so
/// the layout reads while the manifest fetches (replaces the bare spinner).
class HandlerLoadingSkeleton extends StatelessWidget {
  const HandlerLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mirrors what _body actually builds, so the header does not visibly
          // reflow when the manifest lands: the tab-pill strip, then ONE
          // full-width money hero, then the two-up boarded chips — not three
          // equal tiles.
          const UgamSkeleton(height: 44, radius: UgamRadius.input),
          const SizedBox(height: UgamSpacing.lg),
          const UgamSkeleton.text(width: 140),
          const SizedBox(height: UgamSpacing.md),
          const UgamSkeleton(height: 76, radius: UgamRadius.card),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: const [
              Expanded(child: UgamSkeleton(height: 38, radius: UgamRadius.row)),
              SizedBox(width: UgamSpacing.md),
              Expanded(child: UgamSkeleton(height: 38, radius: UgamRadius.row)),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          for (var i = 0; i < 4; i++) ...[
            const UgamSkeleton.row(),
            const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ),
    );
  }
}
