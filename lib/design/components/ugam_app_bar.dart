import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Shared top-app-bar for every pushed screen, so the back button and
/// title read identically across the app.
///
/// This is a PLAIN widget — NOT a Material [AppBar]. Place it as the
/// first child of a screen's body [Column], inside the [SafeArea], so it
/// flows with the rest of the content instead of sitting in the scaffold
/// chrome.
///
/// Slots:
///   * [title] (required) — screen heading, single line with ellipsis
///   * [eyebrow] — optional small champagne label ABOVE the title (section
///     context, e.g. "FINANCE" / "TOUR MONEY"). Rendered uppercase.
///   * [subtitle] — optional muted line BELOW the title (e.g. a route, a date)
///   * [showBack] — render the circular back button (default `true`)
///   * [onBack] — override the default `Get.back` pop behaviour
///   * [actions] — trailing [UgamAppBarAction]s, laid out right of the title
class UgamAppBar extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final String? subtitle;
  final bool showBack;
  final VoidCallback? onBack;
  final List<Widget> actions;

  const UgamAppBar({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.showBack = true,
    this.onBack,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          if (showBack) ...[
            Semantics(
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  (onBack ?? Get.back).call();
                },
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.arrow_back_rounded,
                    size: 19,
                    color: c.ink,
                  ),
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (eyebrow != null) ...[
                  Text(
                    eyebrow!.toUpperCase(),
                    style: UgamText.micro.copyWith(
                      color: c.accent,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  title,
                  style: UgamText.titleL.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          for (final action in actions) ...[
            const SizedBox(width: UgamSpacing.sm),
            action,
          ],
        ],
      ),
    );
  }
}

/// A circular icon button for the trailing [UgamAppBar.actions] slot.
///
///   * [icon] (required) — the glyph to render
///   * [onTap] (required) — tap handler (preceded by a selection haptic)
///   * [tooltip] — wraps the button in a [Tooltip] when set
///   * [tint] — overrides the icon colour
///   * [active] — highlights the button with the accent fill + accent ink
class UgamAppBarAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? tint;
  final bool active;

  const UgamAppBarAction({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.tint,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    Widget button = Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: active ? c.accentFill : c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 19,
            color: tint ?? (active ? c.accent : c.ink),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }

    return button;
  }
}
