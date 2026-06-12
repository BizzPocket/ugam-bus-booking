import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Visual weight of a [UgamButton]. Maps tone → fill/text so callers
/// pick intent ("this is the primary action", "this destroys data")
/// rather than re-deriving colors at every call site.
enum UgamButtonKind {
  /// Solid accent. The single affirmative action on a surface.
  primary,

  /// Quiet, transparent. Cancel / dismiss — never competes with primary.
  ghost,

  /// Tonal neutral fill. A secondary action that still needs a hit area.
  neutral,

  /// Solid danger. A confirmed destructive action (delete, remove).
  danger,

  /// Tonal danger. A destructive action that shouldn't shout (inline
  /// "unassign", "clear") — danger-tinted but not a solid red slab.
  dangerTonal,
}

/// The one button used for dialog actions, sheet actions, and any
/// secondary CTA that isn't the full-width [UgamCTA]. Consistent height,
/// radius, loading + disabled handling — so destructive vs affirmative
/// reads the same on every screen instead of a color-only `TextButton`.
class UgamButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final UgamButtonKind kind;
  final bool loading;

  /// When true, the button stretches to fill its parent's width.
  final bool expand;

  const UgamButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.kind = UgamButtonKind.primary,
    this.loading = false,
    this.expand = false,
  });

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final (Color bg, Color fg, Color? border) = switch (kind) {
      UgamButtonKind.primary => (c.accent, c.onAccent, null),
      UgamButtonKind.ghost => (Colors.transparent, c.ink2, null),
      UgamButtonKind.neutral => (c.cardElev, c.ink, c.border),
      UgamButtonKind.danger => (c.danger, Colors.white, null),
      UgamButtonKind.dangerTonal => (
        c.danger.withValues(alpha: 0.12),
        c.danger,
        null,
      ),
    };

    final content = loading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation(fg),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: UgamSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  style: UgamText.bodyStrong.copyWith(color: fg),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );

    return Opacity(
      opacity: _enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _enabled
              ? () {
                  HapticFeedback.lightImpact();
                  onPressed!();
                }
              : null,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          child: Container(
            height: 50,
            width: expand ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: border == null ? null : Border.all(color: border),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Standardised dialogs. Replaces the per-screen `AlertDialog` +
/// `TextButton` pattern so confirm/destructive prompts look and behave
/// identically everywhere.
class UgamDialog {
  const UgamDialog._();

  /// A title + message confirmation. Returns `true` only if the user
  /// taps the confirm button; barrier/back dismissal returns `false`.
  /// Set [destructive] for delete/remove flows (confirm renders red).
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    bool destructive = false,
    IconData? confirmIcon,
  }) async {
    final result = await show<bool>(
      context,
      title: title,
      message: message,
      actions: (ctx) => [
        UgamButton(
          label: cancelLabel,
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        UgamButton(
          label: confirmLabel,
          icon: confirmIcon,
          kind: destructive ? UgamButtonKind.danger : UgamButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    );
    return result ?? false;
  }

  /// Generic styled dialog. [actions] are laid out in a trailing row;
  /// pass [content] for custom bodies beyond a plain message.
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    String? message,
    Widget? content,
    required List<Widget> Function(BuildContext) actions,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        return Dialog(
          backgroundColor: c.card,
          insetPadding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UgamRadius.card),
          ),
          child: Padding(
            padding: const EdgeInsets.all(UgamSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: UgamText.titleM.copyWith(color: c.ink)),
                if (message != null) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  Text(
                    message,
                    style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
                  ),
                ],
                if (content != null) ...[
                  const SizedBox(height: UgamSpacing.lg),
                  content,
                ],
                const SizedBox(height: UgamSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final a in actions(ctx)) ...[
                      Flexible(child: a),
                      const SizedBox(width: UgamSpacing.sm),
                    ],
                  ]..removeLast(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
