import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import '../ui_scale.dart';

/// Tint variants for [UgamIconButton].
enum UgamIconButtonTone {
  /// Standard neutral chrome action (back, manage-buses, expand-chart …).
  neutral,

  /// Destructive action (clear seats, delete) — danger-tinted fill + icon.
  danger,

  /// Accent-tinted chrome — a copper-inked round action (call, edit-seats)
  /// that a screen previously hand-rolled to keep its tint. Tonal
  /// (`accentFill` + `accent` ink), never a solid accent disc, so it does not
  /// spend the screen's one solid-accent point.
  accent,

  /// Success-tinted chrome — a green-inked round action (WhatsApp, mark-done).
  /// Tonal for the same reason as [accent].
  good,
}

/// The app's one circular icon button. Every 44×44 round chrome action — back,
/// manage-buses, expand-chart, clear-seats — renders through this so they all
/// read identically instead of each screen hand-rolling its own
/// `GestureDetector` + `Container(shape: circle)`.
///
/// **Press feedback.** The button acknowledges the finger: it scales to
/// [_pressedScale] and firms its fill on tap-down, and restores on tap-up or
/// tap-cancel (so a press that turns into a scroll drag never leaves the
/// button squashed). The timing is [UgamMotion.tapIn] down /
/// [UgamMotion.tapOut] up on [UgamMotion.easeOut] — the same controller shape
/// [UgamCard] uses, so a round chrome action and a card press feel like the
/// same app. The scale is deeper than the card's 0.97 only because a 44pt
/// circle needs more travel than a full-width surface to read at all.
///
/// A null [onTap] renders the button disabled (muted icon, no tap, no press
/// animation).
class UgamIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final UgamIconButtonTone tone;
  final double size;
  final double iconSize;

  /// Screen-reader label. Supply for every actionable icon so a11y is uniform.
  final String? semanticLabel;

  /// Fired before [onTap]. Hosts that owned a haptic before migrating here
  /// (e.g. [UgamAppBar]) pass it so the feel is preserved.
  ///
  /// When it is null the button supplies its OWN tap-down
  /// [HapticFeedback.selectionClick] — the tick every round chrome action used
  /// to be missing. Passing this suppresses that default rather than stacking
  /// on top of it, so no existing caller starts double-buzzing.
  final VoidCallback? onTapFeedback;

  /// Escape hatches for a host whose tint has no [UgamIconButtonTone] —
  /// today only [UgamAppBarAction]'s `active` (fill) and `tint` (ink) slots.
  /// When non-null they win over the [tone] switch. Prefer a tone.
  final Color? fillOverride;
  final Color? inkOverride;

  const UgamIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tone = UgamIconButtonTone.neutral,
    this.size = 44,
    this.iconSize = 19,
    this.semanticLabel,
    this.onTapFeedback,
    this.fillOverride,
    this.inkOverride,
  });

  /// Resolved box edge. At or above the 44pt minimum the size rides
  /// [UgamScale.tap] (shrinks with the device, never past 44). Below 44 the
  /// caller has deliberately asked for compact chrome, so the value is passed
  /// through untouched rather than inflated to 44.
  double _box(BuildContext context) =>
      size < 44 ? size : UgamScale.tap(context, size);

  @override
  State<UgamIconButton> createState() => _UgamIconButtonState();
}

/// Scale at full press. Between the 0.92–0.94 band that reads on small round
/// chrome without looking like the icon jumps away from the finger.
const double _pressedScale = 0.93;

/// Alpha of the button's own ink laid over its own fill at full press. Matches
/// Material's 12% pressed-overlay weight, so the fill firms in the direction
/// the surrounding system chrome already moves: a darken in light mode, a lift
/// on the warm-charcoal ground in dark mode.
const double _pressInkAlpha = 0.12;

class _UgamIconButtonState extends State<UgamIconButton>
    with SingleTickerProviderStateMixin {
  // Same controller shape as [UgamCard]: it rests at 1 and REVERSES into the
  // press, so `duration` is the release and `reverseDuration` the press-down.
  // Built eagerly in initState for the reason documented there (a lazy
  // initializer can run inside dispose() and throw on the TickerMode lookup).
  late final AnimationController _ctrl;

  /// 0 at rest, 1 at full press. One value drives both the scale and the fill
  /// so they can never drift apart.
  late final Animation<double> _press;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: UgamMotion.tapOut,
      reverseDuration: UgamMotion.tapIn,
      lowerBound: 0,
      upperBound: 1,
      value: 1,
    );
    _press = Tween<double>(begin: 1, end: 0)
        .chain(CurveTween(curve: UgamMotion.easeOut))
        .animate(_ctrl);
  }

  @override
  void didUpdateWidget(covariant UgamIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A button that goes disabled mid-press (the action it fired removed its
    // own handler) must not stay squashed with no gesture left to restore it.
    if (widget.onTap == null && _ctrl.value != 1) _ctrl.value = 1;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) {
    if (widget.onTap == null) return;
    _ctrl.reverse();
    // Callers that already own a haptic keep theirs (fired before onTap);
    // everyone else finally gets one.
    if (widget.onTapFeedback == null) HapticFeedback.selectionClick();
  }

  void _up(TapUpDetails _) {
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
    final disabled = widget.onTap == null;

    final Color bg;
    final Color fg;
    switch (widget.tone) {
      case UgamIconButtonTone.danger:
        bg = c.danger.withValues(alpha: 0.14);
        fg = disabled ? c.ink3 : c.danger;
        break;
      case UgamIconButtonTone.accent:
        bg = c.accentFill;
        fg = disabled ? c.ink3 : c.accent;
        break;
      case UgamIconButtonTone.good:
        bg = c.goodFill;
        fg = disabled ? c.ink3 : c.good;
        break;
      case UgamIconButtonTone.neutral:
        bg = c.cardElev;
        fg = disabled ? c.ink3 : c.ink;
        break;
    }

    final Color ink = disabled ? fg : (widget.inkOverride ?? fg);
    final Color restFill = widget.fillOverride ?? bg;
    // The press fill is derived from THIS button's resolved ink, so a danger
    // circle deepens red and a neutral one just firms — no second palette.
    final Color pressFill = disabled
        ? restFill
        : Color.alphaBlend(ink.withValues(alpha: _pressInkAlpha), restFill);

    // Interactive box: [UgamScale.tap], not [px]. At the default 44 this
    // is a no-op on every device; it only matters when a caller passes a
    // larger size, which then shrinks down to — but never past — 44.
    //
    // A caller that deliberately asks for a COMPACT (<44) button keeps
    // its exact pixel size: [tap]'s 44 floor would silently inflate it,
    // which is a layout change this component is not allowed to make on
    // its callers' behalf (e.g. the 32pt driver-row buttons on the tour
    // detail card, whose row cannot fund 44 without ellipsizing the
    // phone number). Those sites are corrected screen-by-screen.
    final double box = widget._box(context);

    return Semantics(
      button: true,
      enabled: !disabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTap: disabled
            ? null
            : () {
                widget.onTapFeedback?.call();
                widget.onTap!();
              },
        onTapDown: disabled ? null : _down,
        onTapUp: disabled ? null : _up,
        onTapCancel: disabled ? null : _cancel,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _press,
          builder: (context, child) {
            final double t = _press.value;
            return Transform.scale(
              // Transform, not a layout change: the box the finger hits stays
              // exactly `box` wide, so the 44pt tap target never shrinks.
              scale: 1 - (1 - _pressedScale) * t,
              child: Container(
                width: box,
                height: box,
                decoration: BoxDecoration(
                  color: Color.lerp(restFill, pressFill, t),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: child,
              ),
            );
          },
          // The icon is passed as `child` so it is built once, not per frame.
          child: Icon(widget.icon, size: widget.iconSize, color: ink),
        ),
      ),
    );
  }
}
