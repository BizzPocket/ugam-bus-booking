import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../design/tokens.dart';

/// Production-ready dialog utilities.
class AppDialogs {
  AppDialogs._();

  /// Shows a confirmation dialog for destructive or important actions.
  /// Returns `true` if confirmed, `false` if cancelled. When [confirmText] or
  /// [cancelText] are omitted, the localised defaults from `app.action.*` are
  /// used so dialogs read in the active language.
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
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;

          return AlertDialog(
            backgroundColor: UgamColors.of(context).card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: colorScheme.onSurface,
              ),
            ),
            content: Text(
              message,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: Text(
                  resolvedCancel,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                style: TextButton.styleFrom(
                  foregroundColor: isDestructive
                      ? colorScheme.error
                      : colorScheme.primary,
                ),
                child: Text(
                  resolvedConfirm,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          );
        },
      ),
      barrierDismissible: true,
    );
    return result ?? false;
  }

  /// Shows an error dialog for critical errors that need acknowledgment.
  static Future<void> error({
    required String title,
    required String message,
  }) async {
    await Get.dialog(
      Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;

          return AlertDialog(
            backgroundColor: UgamColors.of(context).card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            icon: Icon(
              Icons.error_outline_rounded,
              color: colorScheme.error,
              size: 40,
            ),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: colorScheme.onSurface,
              ),
            ),
            content: Text(
              message,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Get.back(),
                  child: Text(
                    tr('app.action.ok'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
