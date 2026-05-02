import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../config/theme.dart';

/// Production-ready snackbar utility using ScaffoldMessenger.
/// Replaces Get.snackbar for consistent, accessible feedback.
class AppSnackBar {
  AppSnackBar._();

  static void _show({
    required String message,
    String? title,
    required Color backgroundColor,
    required Color textColor,
    required IconData icon,
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    final context = Get.context;
    if (context == null) return;

    // Dismiss any existing snackbar first
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: textColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: textColor,
                      ),
                    ),
                  Text(
                    message,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      color: textColor.withAlpha(title != null ? 200 : 255),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: isDark
            ? backgroundColor.withAlpha(230)
            : backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        duration: duration,
        action: action,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  /// Success feedback (e.g., "Tour created", "Booking confirmed")
  static void success(String message, {String? title}) {
    _show(
      title: title,
      message: message,
      backgroundColor: AppTheme.successLight,
      textColor: AppTheme.success,
      icon: Icons.check_circle_rounded,
    );
  }

  /// Error feedback (e.g., "Invalid phone number", "Failed to send OTP")
  static void error(String message, {String? title}) {
    _show(
      title: title ?? 'Error',
      message: message,
      backgroundColor: AppTheme.dangerLight,
      textColor: AppTheme.danger,
      icon: Icons.error_rounded,
      duration: const Duration(seconds: 4),
    );
  }

  /// Warning feedback (e.g., "Missing date", "Incomplete form")
  static void warning(String message, {String? title}) {
    _show(
      title: title,
      message: message,
      backgroundColor: AppTheme.warningLight,
      textColor: const Color(0xFF92400E),
      icon: Icons.warning_rounded,
    );
  }

  /// Info feedback (e.g., "Copied to clipboard", "Export ready")
  static void info(String message, {String? title}) {
    _show(
      title: title,
      message: message,
      backgroundColor: AppTheme.infoLight,
      textColor: AppTheme.info,
      icon: Icons.info_rounded,
    );
  }
}
