import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Floating capsule dock nav. Replaces the prior `_PillBottomNav`.
///
/// Anatomy: a single capsule pinned 12 px from the bottom with 12 px
/// lateral padding, holding 3–5 nav targets. The ACTIVE item expands into a
/// champagne pill that shows its icon *and* label; inactive items collapse to
/// a muted icon-only circle. Only one label is ever visible at a time, so the
/// destinations are legible (icon-only docks force users to guess) while the
/// accent stays rationed to the single current tab.
class UgamDockNav extends StatelessWidget {
  final List<UgamDockItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const UgamDockNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  }) : assert(items.length >= 2 && items.length <= 5);

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Bottom fade behind the floating capsule: the body uses extendBody, so
    // the list scrolls into the transparent strip around/below the dock. This
    // gradient hides that content (fades it into the scaffold bg) before the
    // screen edge, so nothing peeks out below the bar.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.bg.withValues(alpha: 0), c.bg],
          stops: const [0, 0.55],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.md,
            UgamSpacing.lg,
            UgamSpacing.md,
            UgamSpacing.md,
          ),
          // Solid, opaque capsule — no BackdropFilter. Real-time Gaussian
          // blur behind the dock was re-sampling the scrolling content
          // every frame on all 5 tabs (the single worst low-end GPU cost
          // in the app). An opaque elevated surface reads the same as a
          // floating dock but rasterizes once.
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(UgamSpacing.xs),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(items.length, (i) {
                  final active = i == currentIndex;
                  return _DockButton(
                    item: items[i],
                    active: active,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onTap(i);
                    },
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UgamDockItem {
  final IconData icon;

  /// Short uppercase label (e.g. "HOME"). Shown only when this item is the
  /// active tab; otherwise it lives in the [tooltip] for long-press.
  final String label;
  final String tooltip;

  /// Optional unread/pending count rendered as a small badge on the icon
  /// (e.g. new booking requests). `0` or `null` hides it.
  final int? badgeCount;

  const UgamDockItem({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.badgeCount,
  });
}

class _DockButton extends StatelessWidget {
  final UgamDockItem item;
  final bool active;
  final VoidCallback onTap;

  const _DockButton({
    required this.item,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: UgamMotion.sheet,
          curve: UgamMotion.easeOut,
          height: 44,
          padding: EdgeInsets.symmetric(
            horizontal: active ? UgamSpacing.lg : UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: active ? c.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _badged(
                c,
                Icon(item.icon, size: 19, color: active ? c.onAccent : c.ink3),
              ),
              // The label collapses to zero width when inactive, so only the
              // current tab's name is ever shown — keeps the dock compact for
              // 5 items while making the active destination unambiguous.
              AnimatedSize(
                duration: UgamMotion.sheet,
                curve: UgamMotion.easeOut,
                child: active
                    ? Padding(
                        padding: const EdgeInsets.only(left: UgamSpacing.sm),
                        child: Text(
                          item.label,
                          style: UgamText.micro.copyWith(color: c.onAccent),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Wraps [icon] with a small count badge on its top-right when the item has
  /// a positive [UgamDockItem.badgeCount].
  Widget _badged(UgamColorSet c, Widget icon) {
    final count = item.badgeCount ?? 0;
    if (count <= 0) return icon;
    final label = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          top: -6,
          right: -8,
          child: Container(
            constraints: const BoxConstraints(minWidth: 16),
            height: 16,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // On the active (champagne) pill the badge inverts to the dock
              // surface so it stays legible against the accent fill.
              color: active ? c.onAccent : c.accent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: c.cardElev, width: 1.5),
            ),
            child: Text(
              label,
              style: UgamText.micro.copyWith(
                fontSize: 9,
                letterSpacing: 0,
                color: active ? c.accent : c.onAccent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
