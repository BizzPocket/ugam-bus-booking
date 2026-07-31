import 'package:flutter/material.dart';

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
/// A null [onTap] renders the button disabled (muted icon, no tap).
class UgamIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final UgamIconButtonTone tone;
  final double size;
  final double iconSize;

  /// Screen-reader label. Supply for every actionable icon so a11y is uniform.
  final String? semanticLabel;

  /// Fired before [onTap]. Hosts that owned a haptic before migrating here
  /// (e.g. [UgamAppBar]) pass it so the feel is preserved.
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
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final disabled = onTap == null;

    final Color bg;
    final Color fg;
    switch (tone) {
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

    return Semantics(
      button: true,
      enabled: !disabled,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                onTapFeedback?.call();
                onTap!();
              },
        behavior: HitTestBehavior.opaque,
        child: Container(
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
          width: _box(context),
          height: _box(context),
          decoration: BoxDecoration(
            color: fillOverride ?? bg,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: iconSize,
            color: disabled ? fg : (inkOverride ?? fg),
          ),
        ),
      ),
    );
  }
}
