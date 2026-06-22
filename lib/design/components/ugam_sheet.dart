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
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    String? title,
    bool isDismissible = true,
    bool enableDrag = true,
    bool showClose = true,
  }) {
    final isCupertino =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return showCupertinoModalPopup<T>(
        context: context,
        builder: (ctx) => _SheetShell(
          title: title,
          showClose: showClose,
          child: builder(ctx),
        ),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
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
      builder: (ctx) =>
          _SheetShell(title: title, showClose: showClose, child: builder(ctx)),
    );
  }
}

class _SheetShell extends StatelessWidget {
  final String? title;
  final bool showClose;
  final Widget child;

  const _SheetShell({this.title, this.showClose = true, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // A Material ancestor is required so Text widgets get proper styling
    // instead of the yellow "no Material" debug underlines. The Cupertino
    // presentation path (showCupertinoModalPopup) provides no Material, so
    // we add a transparent one here that doesn't alter the existing visual
    // (no background, elevation, or clip of its own).
    return Material(
      type: MaterialType.transparency,
      child: Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: UgamSpacing.sm),
          // Tappable grab handle — a second, discoverable way to dismiss
          // (besides swipe-down and tap-outside).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
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
    );
  }
}
