import 'package:easy_localization/easy_localization.dart';
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
  ///
  /// [cancelLabel] defaults to the localised `app.action.cancel` — it must NOT
  /// be given a plain-string default, or every call site that omits it renders
  /// an English button to Gujarati/Hindi users.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    String? message,
    required String confirmLabel,
    String? cancelLabel,
    bool destructive = false,
    IconData? confirmIcon,
  }) async {
    final result = await show<bool>(
      context,
      title: title,
      message: message,
      actions: (ctx) => [
        UgamButton(
          label: cancelLabel ?? tr('app.action.cancel'),
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
    // Set HERE, not by callers — exactly as `UgamSheet` does, and for the same
    // reason: no call site passes one, so every dialog in the app was
    // inheriting Material's default barrier (`Colors.black54`, 54%) or, worse,
    // reading as a card because the page behind it stayed legible. A dialog and
    // a sheet are the same layer, so they get the same scrim. [UgamElevation]
    // resolves 55% on Daylight / 60% on Midnight.
    final scrim = UgamElevation.of(context).scrim;

    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: scrim,
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        return Dialog(
          // The Material is reduced to a transparent, elevation-0 shell and the
          // Container below paints the whole surface — the same arrangement
          // `UgamSheet._SheetShell` uses. Two reasons it has to be this way:
          // Material's `elevation:` takes a single double feeding its own
          // preset shadow, which cannot express the two-layer [UgamElevationSet]
          // list; and at any elevation above 0 an M3 Material composites
          // `surfaceTint` (= colorScheme.primary = the amber accent) over the
          // fill, which would wash every dialog in the app copper.
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
          // Kept so the Material's own shape still agrees with the Container's
          // corner (it clips ink and defines the shell's geometry) even though
          // it no longer paints a fill.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UgamRadius.card),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(UgamRadius.card),
              // Level 2. A dialog floats clearly above everything, paired with
              // the scrim above — the same contract as a sheet. It had no
              // shadow at all, which is what left it flat on top of an app
              // whose cards are now all lifted.
              boxShadow: UgamElevation.of(ctx).raised,
            ),
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
