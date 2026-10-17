part of 'passenger_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The undo toast host
// ─────────────────────────────────────────────────────────────────────────────

/// Puts a [UgamSnackbar] carrying an undo action into the ROOT overlay.
///
/// TEMPORARY, AND DELIBERATELY SMALL. The app's imperative toast API
/// (`lib/utils/app_snackbar.dart`) has no `action:` parameter yet — it predates
/// [UgamSnackAction], so there is currently no way to raise an undoable toast
/// through it. Rather than block the Board on that file (owned elsewhere this
/// run), this hosts the same widget in the same place with the same dwell.
/// **When `AppSnackBar` grows an action parameter, delete this class and call
/// it instead** — the two must not both exist for long, or a Board toast and an
/// app toast will stack on top of each other.
///
/// The root overlay is used so the toast outlives the sheet that raised it: the
/// mutation pops the sheet, and the undo has to still be reachable after that.
class BoardUndoToast {
  const BoardUndoToast._();

  static OverlayEntry? _live;
  static Timer? _timer;

  /// [overlay] is captured by the caller BEFORE its `await`, so no
  /// [BuildContext] crosses an async gap.
  ///
  /// [onUndo] null renders a plain confirmation with no action — used when the
  /// write genuinely cannot be reversed, which the caller has to say out loud
  /// rather than us guessing.
  static void show(
    OverlayState? overlay, {
    required String message,
    FutureOr<void> Function()? onUndo,
    String? semanticLabel,
  }) {
    if (overlay == null || !overlay.mounted) return;
    // One toast at a time. A collection round fires these several a minute and
    // a stack of them would bury the chart.
    dismiss();

    final entry = OverlayEntry(
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        // Above the keyboard when it is up, above the floating dock when it is
        // down — the same arithmetic AppSnackBar uses, from the same token.
        final lift = media.viewInsets.bottom > 0
            ? media.viewInsets.bottom
            : media.padding.bottom + UgamSnackbar.dockClearance;
        return Positioned(
          left: UgamSpacing.gutter,
          right: UgamSpacing.gutter,
          bottom: lift + UgamSpacing.md,
          child: UgamSnackbar(
            message: message,
            tone: UgamSnackTone.success,
            action: onUndo == null
                ? null
                : UgamSnackAction.undo(
                    onUndo: () {
                      dismiss();
                      onUndo();
                    },
                    semanticLabel: semanticLabel,
                  ),
          ),
        );
      },
    );
    _live = entry;
    overlay.insert(entry);
    // An actionable toast gets the doubled dwell: reading it, realising it is
    // wrong, and reaching for undo is three steps, not one.
    _timer = Timer(
      onUndo == null ? UgamMotion.snackbar : UgamSnackbar.actionDuration,
      dismiss,
    );
  }

  /// Safe to call at any time, including from a test `tearDown`.
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _live;
    _live = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}
