import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_button.dart';

// [UgamButton] and [UgamButtonKind] used to be declared in THIS file, which is
// why screens hand-rolled buttons instead of finding it. They now live in
// `ugam_button.dart`; this re-export keeps every existing
// `import '.../ugam_dialog.dart'` compiling unchanged.
export 'ugam_button.dart';

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
