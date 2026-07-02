import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Swipe-to-act row wrapper. Wraps any [child] in a [Dismissible] so list
/// rows get a consistent native swipe affordance instead of hand-rolled
/// gesture math at every call site.
///
/// * Left-swipe (endToStart) reveals a [c.danger] background + [deleteIcon]
///   and is the *destructive* gesture: if [confirmDelete] is given it gates
///   the dismiss, and [onDelete] fires once the row is dismissed.
/// * Right-swipe (startToEnd) is an optional *non-destructive* action.
///   When [rightIcon] is provided it reveals a [rightColor] background +
///   [rightIcon], fires [onRight], and then snaps the row back (the row is
///   NOT removed). Use it for "mark", "collect", etc.
///
/// The caller MUST pass a unique [ValueKey] so the Dismissible can track the
/// item across rebuilds.
class UgamSwipeAction extends StatelessWidget {
  final Widget child;

  /// Optional async gate for the destructive (left) swipe. Returning `false`
  /// cancels the dismiss; `true` lets it through and triggers [onDelete].
  final Future<bool> Function()? confirmDelete;

  /// Called after the row has been dismissed by the left swipe.
  final VoidCallback? onDelete;

  final IconData deleteIcon;

  /// Optional right-swipe action.
  final String? rightLabel;
  final IconData? rightIcon;
  final Color? rightColor;
  final VoidCallback? onRight;

  /// Corner radius for the revealed action backgrounds. Defaults to the
  /// standard row radius so it lines up under a card row.
  final BorderRadius? borderRadius;

  const UgamSwipeAction({
    super.key,
    required this.child,
    this.confirmDelete,
    this.onDelete,
    this.deleteIcon = Icons.delete_outline_rounded,
    this.rightLabel,
    this.rightIcon,
    this.rightColor,
    this.onRight,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final radius =
        borderRadius ?? BorderRadius.circular(UgamRadius.row);
    final right = rightColor ?? c.accent;

    return Dismissible(
      key: key!,
      direction: rightIcon != null
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      background: rightIcon == null
          ? const SizedBox.shrink()
          : _ActionPane(
              color: right,
              icon: rightIcon!,
              label: rightLabel,
              fg: _inkOn(right, c),
              alignment: Alignment.centerLeft,
              radius: radius,
            ),
      secondaryBackground: _ActionPane(
        color: c.danger,
        icon: deleteIcon,
        label: null,
        fg: Colors.white,
        alignment: Alignment.centerRight,
        radius: radius,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Right swipe — fire the action but never remove the row.
          HapticFeedback.lightImpact();
          onRight?.call();
          return false;
        }
        // Left swipe — destructive.
        if (confirmDelete != null) {
          final ok = await confirmDelete!();
          if (ok) HapticFeedback.mediumImpact();
          return ok;
        }
        HapticFeedback.mediumImpact();
        return true;
      },
      onDismissed: (_) => onDelete?.call(),
      child: child,
    );
  }

  /// Pick legible ink for a label sitting on [bg]. The brand action colors
  /// (copper / mint) all take near-black ink; fall back to white for dark
  /// custom tones.
  static Color _inkOn(Color bg, UgamColorSet c) {
    return bg.computeLuminance() > 0.4 ? c.onAccent : Colors.white;
  }
}

class _ActionPane extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String? label;
  final Color fg;
  final Alignment alignment;
  final BorderRadius radius;

  const _ActionPane({
    required this.color,
    required this.icon,
    required this.label,
    required this.fg,
    required this.alignment,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final left = alignment == Alignment.centerLeft;
    return Container(
      decoration: BoxDecoration(color: color, borderRadius: radius),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null && left) ...[
            Text(label!, style: UgamText.bodyStrong.copyWith(color: fg)),
            const SizedBox(width: UgamSpacing.sm),
          ],
          Icon(icon, size: 22, color: fg),
          if (label != null && !left) ...[
            const SizedBox(width: UgamSpacing.sm),
            Text(label!, style: UgamText.bodyStrong.copyWith(color: fg)),
          ],
        ],
      ),
    );
  }
}
