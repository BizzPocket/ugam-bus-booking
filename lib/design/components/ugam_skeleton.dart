import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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

class _UgamSkeletonState extends State<UgamSkeleton> {
  // Every skeleton shares ONE app-wide ticker instead of spinning up its own
  // AnimationController. A loading list of N skeletons used to create N tickers
  // AND repaint N moving 3-stop gradient shaders every frame — a real
  // raster-thread spike on low-end GPUs at the exact moment the device is busy
  // fetching data. Now it's one ticker (auto-paused when no skeleton is on
  // screen) and a cheap solid-colour pulse (no shader).
  late final Animation<double> _pulse = _SkeletonPulse.instance.acquire();

  @override
  void dispose() {
    _SkeletonPulse.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, _) {
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              color: Color.lerp(c.cardElev, c.card, _pulse.value),
            ),
          );
        },
      ),
    );
  }
}

/// App-wide, ref-counted shimmer driver. One [AnimationController] backs every
/// [UgamSkeleton] on screen; it starts when the first skeleton mounts and stops
/// when the last one is disposed, so idle screens pay nothing.
class _SkeletonPulse {
  _SkeletonPulse._();
  static final _SkeletonPulse instance = _SkeletonPulse._();

  AnimationController? _controller;
  int _refs = 0;

  Animation<double> acquire() {
    _refs++;
    final ctrl = _controller ??= AnimationController(
      vsync: _GlobalTickerProvider(),
      duration: UgamMotion.shimmer,
    );
    if (!ctrl.isAnimating) ctrl.repeat(reverse: true);
    return ctrl.view;
  }

  void release() {
    _refs--;
    if (_refs <= 0) {
      _refs = 0;
      _controller?.stop();
    }
  }
}

/// A minimal app-lifetime [TickerProvider] for the shared shimmer controller.
class _GlobalTickerProvider implements TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}
