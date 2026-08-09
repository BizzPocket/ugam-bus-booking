import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Segmented pill tabs. Supports 2–5 segments. Active segment fills with
/// surface card; inactive segments stay transparent on the cardElev container.
///
/// With 5 segments the row scrolls horizontally so Gujarati labels stay
/// readable instead of being crushed by equal [Expanded] flex.
class UgamTabPills extends StatelessWidget {
  final List<UgamTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;

  const UgamTabPills({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
  }) : assert(items.length >= 2 && items.length <= 5);

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final scrollable = items.length >= 5;
    final segments = List.generate(items.length, (i) {
      final active = i == currentIndex;
      final segment = _TabSegment(
        item: items[i],
        active: active,
        scrollable: scrollable,
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(i);
        },
      );
      return scrollable ? segment : Expanded(child: segment);
    });

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: scrollable
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: segments),
            )
          : Row(children: segments),
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
  final bool scrollable;
  final VoidCallback onTap;

  const _TabSegment({
    required this.item,
    required this.active,
    required this.onTap,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final label = Text(
      item.label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: UgamText.bodyStrong.copyWith(
        color: active ? c.ink : c.ink2,
        fontSize: 12,
      ),
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // 44pt hit box around an UNCHANGED painted pill. The `Center` is
      // load-bearing: without it the ConstrainedBox's minHeight propagates
      // into the AnimatedContainer and inflates the visible pill.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            padding: EdgeInsets.symmetric(
              vertical: 8,
              horizontal: scrollable ? 12 : 0,
            ),
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
              mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
              children: [
                if (item.icon != null) ...[
                  Icon(item.icon, size: 14, color: active ? c.ink : c.ink2),
                  const SizedBox(width: 5),
                ],
                if (scrollable) label else Flexible(child: label),
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
        ),
      ),
    );
  }
}
