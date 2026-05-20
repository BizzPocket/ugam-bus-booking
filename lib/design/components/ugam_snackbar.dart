import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

enum UgamSnackTone { success, error, info }

/// Floating toast content widget. Pure widget — does NOT call
/// `ScaffoldMessenger`. The imperative API lives in
/// `lib/utils/app_snackbar.dart` so this stays decoupled from `Get` /
/// the app's specific routing setup.
class UgamSnackbar extends StatelessWidget {
  final String message;
  final String? title;
  final UgamSnackTone tone;

  const UgamSnackbar({
    super.key,
    required this.message,
    this.title,
    this.tone = UgamSnackTone.info,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (bg, fg, icon) = switch (tone) {
      UgamSnackTone.success => (
          c.goodFill,
          c.good,
          Icons.check_circle_rounded
        ),
      UgamSnackTone.error => (
          c.danger.withValues(alpha: 0.16),
          c.danger,
          Icons.error_rounded
        ),
      UgamSnackTone.info => (
          c.accentFill,
          c.accent,
          Icons.info_rounded
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: fg),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(title!,
                      style:
                          UgamText.bodyStrong.copyWith(color: c.ink)),
                Text(message, style: UgamText.body.copyWith(color: c.ink2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
