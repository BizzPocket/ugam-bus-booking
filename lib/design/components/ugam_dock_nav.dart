import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import 'ugam_glass_container.dart';

/// Floating capsule dock nav. Replaces the prior `_PillBottomNav`.
///
/// Anatomy: a single capsule pinned 12 px from the bottom with 12 px
/// lateral padding, holding 3–5 circular icon buttons. Active item gets
/// a solid accent fill; inactive items are transparent with muted icons.
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

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.md,
          UgamSpacing.sm,
          UgamSpacing.md,
          UgamSpacing.md,
        ),
        child: UgamGlassContainer(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          radius: UgamRadius.chip,
          color: isDark 
              ? c.cardElev.withValues(alpha: 0.65)
              : c.cardElev.withValues(alpha: 0.75),
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
    );
  }
}

class UgamDockItem {
  final IconData icon;
  final String tooltip;

  const UgamDockItem({required this.icon, required this.tooltip});
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
          duration: UgamMotion.dock,
          curve: UgamMotion.easeOut,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: active ? c.accent : Colors.transparent,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            item.icon,
            size: 19,
            color: active ? c.onAccent : c.ink3,
          ),
        ),
      ),
    );
  }
}
