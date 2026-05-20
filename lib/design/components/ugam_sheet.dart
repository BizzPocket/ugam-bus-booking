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
  }) {
    final isCupertino =
        Theme.of(context).platform == TargetPlatform.iOS ||
            Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return showCupertinoModalPopup<T>(
        context: context,
        builder: (ctx) => _SheetShell(title: title, child: builder(ctx)),
      );
    }

    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: true,
      builder: (ctx) => _SheetShell(title: title, child: builder(ctx)),
    );
  }
}

class _SheetShell extends StatelessWidget {
  final String? title;
  final Widget child;

  const _SheetShell({this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
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
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.ink3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          if (title != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xl),
              child: Text(title!,
                  style: UgamText.titleL.copyWith(color: c.ink)),
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
    );
  }
}
