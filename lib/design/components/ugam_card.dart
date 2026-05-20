import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Base card surface. Two variants:
///
/// * [UgamCard.plain] — text-only card, default 14 px inner padding.
/// * [UgamCard.media] — card whose top region holds a hero photo
///   (16 px radius, 124 px tall by default), with the photo positioned
///   inside an 8 px outer padding so the card edge surrounds it. The
///   [child] sits below the photo with its own padding.
///
/// Cards never nest other cards. Use the `elev: true` flag when you
/// need a slightly raised inner surface — it swaps fill from
/// [UgamColorSet.card] to [UgamColorSet.cardElev].
class UgamCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool elev;
  final double radius;

  const UgamCard.plain({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(UgamSpacing.gutter),
    this.onTap,
    this.elev = false,
    this.radius = UgamRadius.card,
  });

  /// Media variant: caller is responsible for placing a photo as the
  /// first child inside [child] (typically a [ClipRRect] with
  /// [UgamRadius.photo]). This factory just standardises the outer
  /// padding (8) and corner radius.
  const UgamCard.media({
    super.key,
    required this.child,
    this.onTap,
    this.elev = false,
    this.radius = UgamRadius.card,
  }) : padding = const EdgeInsets.all(UgamSpacing.sm);

  @override
  State<UgamCard> createState() => _UgamCardState();
}

class _UgamCardState extends State<UgamCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: UgamMotion.tapOut,
    reverseDuration: UgamMotion.tapIn,
    lowerBound: 0,
    upperBound: 1,
    value: 1,
  );

  late final Animation<double> _scale = Tween<double>(begin: 0.97, end: 1)
      .chain(CurveTween(curve: UgamMotion.easeOut))
      .animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(_) {
    if (widget.onTap == null) return;
    _ctrl.reverse();
    HapticFeedback.lightImpact();
  }

  void _up(_) {
    if (widget.onTap == null) return;
    _ctrl.forward();
  }

  void _cancel() {
    if (widget.onTap == null) return;
    _ctrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget surface = Container(
      decoration: BoxDecoration(
        color: widget.elev ? c.cardElev : c.card,
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x14000000),
                  offset: Offset(0, 3),
                  blurRadius: 14,
                ),
              ],
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    if (widget.onTap == null) return surface;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _cancel,
      behavior: HitTestBehavior.opaque,
      child: ScaleTransition(scale: _scale, child: surface),
    );
  }
}
