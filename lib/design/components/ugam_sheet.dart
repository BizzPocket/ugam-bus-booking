import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Bottom-sheet wrapper. Enforces top-only 28 px radius, a 36×4 drag
/// handle, 20 px lateral padding, and platform-adaptive presentation
/// (Cupertino sheet on iOS, Material bottom sheet on Android).
class UgamSheet {
  const UgamSheet._();

  /// Shows a sheet whose content is built by [builder]. Returns the
  /// value the sheet was popped with, like `showModalBottomSheet`.
  ///
  /// [isDismissible] governs the tap-outside (barrier) path AND the grab
  /// handle, on BOTH platforms — see the two parameters' own notes.
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    String? title,

    /// Whether the sheet can be dismissed without the caller's consent —
    /// by tapping the scrim, or by tapping the grab handle.
    ///
    /// Honoured on both platforms. It was previously dropped on the
    /// Cupertino path (`showCupertinoModalPopup` defaults
    /// `barrierDismissible: true`), so a sheet declared non-dismissible
    /// was still tap-outside-dismissible on iOS/macOS but not on Android
    /// — the exact asymmetry a required-choice or unsaved-changes sheet
    /// cannot tolerate.
    ///
    /// Pass `showClose: false` alongside this unless the sheet wants to
    /// keep ONE deliberate escape hatch: the close button is the caller's
    /// affordance and is not gated by this flag.
    bool isDismissible = true,

    /// Whether a downward drag on the sheet dismisses it.
    ///
    /// **Material only.** `showCupertinoModalPopup` has no drag-to-dismiss
    /// gesture at all, so on iOS/macOS this parameter is inert: `false` is
    /// satisfied for free, and `true` simply does not get you a drag. The
    /// Android path is the only one where it changes anything. Do not rely
    /// on it as a dismissal *affordance* — rely on it only to REMOVE one
    /// (which it does correctly on both platforms).
    bool enableDrag = true,
    bool showClose = true,
  }) {
    final isCupertino =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;

    // The scrim is set HERE, not by callers — no call site passes one, so
    // every sheet in the app was inheriting a platform default that is far too
    // weak: `kCupertinoModalBarrierColor` is 20% black and Material's is 32%.
    // At those values the page behind an open sheet stays bright and fully
    // legible, so the sheet reads as one more card rather than as a layer
    // above everything. Platform guidance is 40-60%; [UgamElevation] resolves
    // 55% on Daylight / 60% on Midnight.
    final scrim = UgamElevation.of(context).scrim;

    if (isCupertino) {
      return showCupertinoModalPopup<T>(
        context: context,
        barrierColor: scrim,
        // `showCupertinoModalPopup` defaults this to true. Omitting it made
        // `isDismissible: false` a lie on iOS/macOS only — the caller's
        // guarantee held on Android and silently did not hold on iPhone.
        barrierDismissible: isDismissible,
        builder: (ctx) => _SheetShell(
          title: title,
          showClose: showClose,
          isDismissible: isDismissible,
          child: builder(ctx),
        ),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: scrim,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: true,
      // Present over the ROOT navigator (matching the iOS
      // showCupertinoModalPopup path, whose useRootNavigator defaults to
      // true). The shell ([MainShell]) hosts each tab in its own nested
      // Navigator inside a Scaffold with extendBody: true. A sheet pushed on
      // the nested navigator is confined to the Scaffold body slot, so the
      // bottomNavigationBar (UgamDockNav) paints on top of the sheet's bottom
      // and the scrim never covers the dock — clipping the last row(s) of
      // content (e.g. the third language option). Root navigator escapes that.
      useRootNavigator: true,
      builder: (ctx) => _SheetShell(
        title: title,
        showClose: showClose,
        isDismissible: isDismissible,
        child: builder(ctx),
      ),
    );
  }
}

class _SheetShell extends StatelessWidget {
  final String? title;
  final bool showClose;

  /// Mirrors `UgamSheet.show`'s flag. The grab handle is an incidental
  /// dismissal path, so it has to obey the same guarantee the barrier does —
  /// otherwise a non-dismissible sheet is still escapable by tapping a 36×4
  /// bar the user did not read as a control.
  final bool isDismissible;
  final Widget child;

  const _SheetShell({
    this.title,
    this.showClose = true,
    this.isDismissible = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // A Material ancestor is required so Text widgets get proper styling
    // instead of the yellow "no Material" debug underlines. The Cupertino
    // presentation path (showCupertinoModalPopup) provides no Material, so
    // we add a transparent one here that doesn't alter the existing visual
    // (no background, elevation, or clip of its own).
    // Cap height so tall bodies (numpad + details) can scroll inside
    // [Flexible] instead of overflowing. Cupertino popups otherwise leave the
    // column's max height loose enough for a min-sized Column to paint past
    // the screen. Short sheets stay short via [mainAxisSize: min].
    final maxH = MediaQuery.sizeOf(context).height * 0.92;

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(UgamRadius.sheet),
          ),
          // Level 2. The wide layer of `raised` carries no vertical offset
          // precisely so it casts UP over the page — the top edge is the only
          // edge of a bottom sheet anyone ever sees.
          boxShadow: UgamElevation.of(context).raised,
        ),
        padding: EdgeInsets.only(
          // The keyboard inset when the IME is up, the system nav-bar inset
          // when it is down. `useSafeArea: true` on the showModalBottomSheet
          // above insets the TOP ONLY — the framework resolves it to
          // SafeArea(bottom: false), so the sheet owns its own bottom inset
          // under enforced edge-to-edge (Android 15+). Flutter reports
          // padding.bottom as 0 while the IME is visible, so max() picks the
          // right one in both states without ever double-counting.
          bottom: math.max(
            MediaQuery.viewInsetsOf(context).bottom,
            MediaQuery.paddingOf(context).bottom,
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: UgamSpacing.sm),
              // Tappable grab handle — a second, discoverable way to dismiss
              // (besides swipe-down and tap-outside). Inert, but still
              // painted, when the sheet is non-dismissible: the bar is the
              // sheet's visual affordance for "this is a sheet" as much as it
              // is a control, so it stays, it just stops popping.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isDismissible
                    ? () => Navigator.of(context).maybePop()
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.ink3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              if (title != null) ...[
                const SizedBox(height: UgamSpacing.md),
                Padding(
                  padding: const EdgeInsets.only(
                    left: UgamSpacing.xl,
                    right: UgamSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title!,
                          style: UgamText.titleL.copyWith(color: c.ink),
                        ),
                      ),
                      if (showClose)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).maybePop(),
                          // 44×44 hit box around the UNCHANGED 32pt painted
                          // circle — the glyph and its disc are pixel-identical,
                          // only the target grows.
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: c.cardElev,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: c.ink2,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.xl,
                    UgamSpacing.lg,
                    UgamSpacing.xl,
                    UgamSpacing.xl,
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
