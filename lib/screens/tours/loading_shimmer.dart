part of '../tours_screen.dart';

/// First-load placeholder. Shaped like the list it stands in for — a group
/// header (title + count badge) over full-width tour cards at the row's real
/// height — so the shimmer/content swap is a fill change, not a re-layout.
/// The gutters and the dock clearance match the real [ListView.builder] above,
/// so nothing shifts sideways or hides under the dock when the data lands.
class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.dockClearance,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        _ShimmerGroupHeader(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        _ShimmerGroupHeader(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
      ],
    );
  }
}

class _ShimmerGroupHeader extends StatelessWidget {
  const _ShimmerGroupHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        UgamSkeleton(height: 20, width: 116, radius: 6),
        SizedBox(width: UgamSpacing.sm),
        UgamSkeleton(height: 16, width: 24, radius: 6),
      ],
    );
  }
}
