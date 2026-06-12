import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';

/// Context-free dialog utilities (callable from controllers/anywhere via
/// `Get.dialog`). The visual treatment is shared with [UgamDialog] —
/// same card surface, title/body type, and [UgamButton] actions — so a
/// confirm raised here is indistinguishable from one raised with a
/// `BuildContext`.
class AppDialogs {
  AppDialogs._();

  /// Confirmation dialog for destructive or important actions. Returns
  /// `true` only if confirmed; barrier/back dismissal returns `false`.
  /// Localised `app.action.*` defaults are used when labels are omitted.
  static Future<bool> confirm({
    required String title,
    required String message,
    String? confirmText,
    String? cancelText,
    bool isDestructive = false,
  }) async {
    final resolvedConfirm = confirmText ?? tr('app.action.confirm');
    final resolvedCancel = cancelText ?? tr('app.action.cancel');
    final result = await Get.dialog<bool>(
      Builder(
        builder: (context) => _DialogShell(
          title: title,
          message: message,
          actions: [
            UgamButton(
              label: resolvedCancel,
              kind: UgamButtonKind.ghost,
              onPressed: () => Get.back(result: false),
            ),
            UgamButton(
              label: resolvedConfirm,
              kind: isDestructive
                  ? UgamButtonKind.danger
                  : UgamButtonKind.primary,
              onPressed: () => Get.back(result: true),
            ),
          ],
        ),
      ),
      barrierDismissible: true,
    );
    return result ?? false;
  }

  /// Error dialog that needs acknowledgement.
  static Future<void> error({
    required String title,
    required String message,
  }) async {
    await Get.dialog(
      Builder(
        builder: (context) {
          final c = UgamColors.of(context);
          return _DialogShell(
            icon: Icon(Icons.error_outline_rounded, color: c.danger, size: 40),
            title: title,
            message: message,
            centerText: true,
            actions: [
              UgamButton(
                label: tr('app.action.ok'),
                expand: true,
                onPressed: () => Get.back(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Shared visual shell so [AppDialogs] matches [UgamDialog] exactly.
class _DialogShell extends StatelessWidget {
  final String title;
  final String message;
  final List<Widget> actions;
  final Widget? icon;
  final bool centerText;

  const _DialogShell({
    required this.title,
    required this.message,
    required this.actions,
    this.icon,
    this.centerText = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final align = centerText
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.stretch;
    final textAlign = centerText ? TextAlign.center : TextAlign.start;
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
          crossAxisAlignment: align,
          children: [
            if (icon != null) ...[
              icon!,
              const SizedBox(height: UgamSpacing.md),
            ],
            Text(
              title,
              style: UgamText.titleM.copyWith(color: c.ink),
              textAlign: textAlign,
            ),
            const SizedBox(height: UgamSpacing.sm),
            Text(
              message,
              style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
              textAlign: textAlign,
            ),
            const SizedBox(height: UgamSpacing.xl),
            if (actions.length == 1)
              actions.first
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final a in actions) ...[
                    Flexible(child: a),
                    const SizedBox(width: UgamSpacing.sm),
                  ],
                ]..removeLast(),
              ),
          ],
        ),
      ),
    );
  }
}
