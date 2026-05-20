import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Full-width sticky pill CTA. Sits in the `Scaffold.bottomNavigationBar`
/// slot (or above the dock nav for primary workflow buttons) and ends
/// every action screen.
///
/// Slots:
///   * [label] (required) — primary action verb
///   * [leadingIcon] — optional, sits before the label
///   * [trailingValue] — optional tabular value (price, count) shown
///     on the right, followed by a circle-arrow chip
class UgamCTA extends StatefulWidget {
  final String label;
  final IconData? leadingIcon;
  final String? trailingValue;
  final VoidCallback? onPressed;
  final bool loading;

  const UgamCTA({
    super.key,
    required this.label,
    this.leadingIcon,
    this.trailingValue,
    this.onPressed,
    this.loading = false,
  });

  @override
  State<UgamCTA> createState() => _UgamCTAState();
}

class _UgamCTAState extends State<UgamCTA>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: UgamMotion.tapOut,
    reverseDuration: UgamMotion.tapIn,
    value: 1,
  );

  late final Animation<double> _scale = Tween<double>(begin: 0.96, end: 1)
      .chain(CurveTween(curve: UgamMotion.easeOut))
      .animate(_ctrl);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final inner = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.xl,
        vertical: UgamSpacing.lg + 2,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.leadingIcon != null) ...[
            Icon(widget.leadingIcon, size: 18, color: c.onAccent),
            const SizedBox(width: UgamSpacing.sm),
          ],
          if (widget.loading)
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation(c.onAccent),
              ),
            )
          else
            Flexible(
              child: Text(
                widget.label,
                style: UgamText.titleS.copyWith(color: c.onAccent),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widget.trailingValue != null && !widget.loading) ...[
            const Spacer(),
            Text(
              widget.trailingValue!,
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.onAccent),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: c.onAccent.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 14,
                color: c.onAccent,
              ),
            ),
          ],
        ],
      ),
    );

    final body = Container(
      decoration: BoxDecoration(
        color: _enabled ? c.accent : c.accent.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: inner,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled
          ? (_) {
              _ctrl.reverse();
              HapticFeedback.lightImpact();
            }
          : null,
      onTapUp: _enabled ? (_) => _ctrl.forward() : null,
      onTapCancel: _enabled ? () => _ctrl.forward() : null,
      onTap: _enabled ? widget.onPressed : null,
      child: ScaleTransition(scale: _scale, child: body),
    );
  }
}

/// Container that pins a [UgamCTA] to the bottom of a screen with a
/// gradient fade from the scaffold background, so scrolling content
/// passes under the CTA without a hard line.
class UgamStickyCTA extends StatelessWidget {
  final Widget child;

  const UgamStickyCTA({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.xxl,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.bg.withValues(alpha: 0), c.bg],
            stops: const [0, 0.45],
          ),
        ),
        child: child,
      ),
    );
  }
}
