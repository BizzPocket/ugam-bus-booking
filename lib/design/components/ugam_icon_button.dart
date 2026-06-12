import 'package:flutter/material.dart';

import '../tokens.dart';

/// Tint variants for [UgamIconButton].
enum UgamIconButtonTone {
  /// Standard neutral chrome action (back, manage-buses, expand-chart …).
  neutral,

  /// Destructive action (clear seats, delete) — danger-tinted fill + icon.
  danger,
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

  const UgamIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tone = UgamIconButtonTone.neutral,
    this.size = 44,
    this.iconSize = 19,
    this.semanticLabel,
  });

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
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );
  }
}
