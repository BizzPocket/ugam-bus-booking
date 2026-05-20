import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Segmented pill tabs. Up to 3 segments for visual balance. Active
/// segment fills with surface card; inactive segments stay transparent
/// on the cardElev container.
class UgamTabPills extends StatelessWidget {
  final List<UgamTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;

  const UgamTabPills({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
  }) : assert(items.length >= 2 && items.length <= 4);

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: List.generate(items.length, (i) {
          final active = i == currentIndex;
          return Expanded(
            child: _TabSegment(
              item: items[i],
              active: active,
              onTap: () {
                HapticFeedback.selectionClick();
                onChanged(i);
              },
            ),
          );
        }),
      ),
    );
  }
}

class UgamTabItem {
  final String label;
  final IconData? icon;
  final int? count;

  const UgamTabItem({required this.label, this.icon, this.count});
}

class _TabSegment extends StatelessWidget {
  final UgamTabItem item;
  final bool active;
  final VoidCallback onTap;

  const _TabSegment({
    required this.item,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? c.card : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          boxShadow: active
              ? const [
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (item.icon != null) ...[
              Icon(item.icon, size: 14, color: active ? c.ink : c.ink2),
              const SizedBox(width: 5),
            ],
            Text(
              item.label,
              style: UgamText.bodyStrong.copyWith(
                color: active ? c.ink : c.ink2,
                fontSize: 12,
              ),
            ),
            if (item.count != null) ...[
              const SizedBox(width: 5),
              Text(
                '${item.count}',
                style: UgamText.tabular(
                  UgamText.caption.copyWith(
                    color: active ? c.accent : c.ink3,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
