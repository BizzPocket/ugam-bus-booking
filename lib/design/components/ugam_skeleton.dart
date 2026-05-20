import 'package:flutter/material.dart';

import '../tokens.dart';

/// Shimmering placeholder rectangle. Used in lists during initial load
/// instead of a `CircularProgressIndicator`. Spinners stay only for
/// pull-to-refresh and inline submit buttons.
class UgamSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final double radius;

  const UgamSkeleton({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.radius = 12,
  });

  /// Card-sized placeholder. Matches a hero tour card.
  const UgamSkeleton.card({super.key})
      : width = double.infinity,
        height = 168,
        radius = UgamRadius.card;

  /// Row-sized placeholder. Matches a request row.
  const UgamSkeleton.row({super.key})
      : width = double.infinity,
        height = 64,
        radius = UgamRadius.row;

  /// Chip placeholder.
  const UgamSkeleton.chip({super.key})
      : width = 60,
        height = 28,
        radius = UgamRadius.chip;

  /// Inline text placeholder.
  const UgamSkeleton.text({super.key, this.width = 120})
      : height = 14,
        radius = 4;

  @override
  State<UgamSkeleton> createState() => _UgamSkeletonState();
}

class _UgamSkeletonState extends State<UgamSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: UgamMotion.shimmer,
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t = _ctrl.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              gradient: LinearGradient(
                colors: [c.cardElev, c.card, c.cardElev],
                stops: [
                  (t - 0.3).clamp(0, 1).toDouble(),
                  t.clamp(0, 1).toDouble(),
                  (t + 0.3).clamp(0, 1).toDouble(),
                ],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          );
        },
      ),
    );
  }
}
