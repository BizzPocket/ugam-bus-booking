import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// Play policy requires a plain-language disclosure BEFORE the OS prompt for
/// background location: what is collected, who sees it, when it stops, and how
/// to stop it early. This is that disclosure.
///
/// Shown once ever — the caller owns the seen-flag — and dismissible, because
/// the bus chart must stay usable for a handler who declines.
///
/// Returns true if the handler chose to continue to the OS prompt.
Future<bool> showLocationRationale(BuildContext context) async {
  final result = await UgamSheet.show<bool>(
    context,
    title: tr('tracking.rationale_title'),
    builder: (sheetContext) {
      final c = UgamColors.of(sheetContext);
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          0,
          UgamSpacing.gutter,
          UgamSpacing.gutter,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.location_on_outlined, color: c.accent, size: 20),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('tracking.rationale_body'),
                    style: UgamText.body.copyWith(color: c.ink2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.lg),
            UgamCTA(
              label: tr('tracking.rationale_continue'),
              leadingIcon: Icons.check_rounded,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: UgamSpacing.sm),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: Text(
                  tr('tracking.rationale_not_now'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  // A dismiss (tap-outside, drag-down, close button) is a decline, not a yes.
  return result ?? false;
}
