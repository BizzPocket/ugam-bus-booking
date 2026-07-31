import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// One item in a [UgamSelectorPills] strip.
///   * [label] (required) — the pill text
///   * [leadingColor] — optional dot before the label (bus/group colour)
///   * [count] — optional trailing count badge
class UgamSelectorItem {
  final String label;
  final Color? leadingColor;
  final int? count;
  const UgamSelectorItem({required this.label, this.leadingColor, this.count});
}

/// Horizontal, single-select pill strip — the shared control for the tour /
/// bus / filter selector rows hand-rolled across Charts, Requests, Notify,
/// Seat-assignment and Handler-chart.
///
/// The active pill is **tonal** (accentFill + accent ink + hairline accent
/// border), never solid champagne — solid gold stays reserved for the one
/// focal CTA per screen (the accent-rationing law).
class UgamSelectorPills extends StatelessWidget {
  final List<UgamSelectorItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;
  final EdgeInsetsGeometry padding;

  const UgamSelectorPills({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SizedBox(
      // Interactive strip: every pill is a tap target, so this routes through
      // [UgamScale.tap]. 38 was below the 44pt minimum on EVERY device — the
      // floor raises it to a legal 44 and holds it there as the device shrinks.
      height: UgamScale.tap(context, 38),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (_, i) {
          final item = items[i];
          final active = i == currentIndex;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(i);
            },
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: active ? c.accentFill : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: Border.all(
                  color: active
                      ? c.accent.withValues(alpha: 0.32)
                      : Colors.transparent,
                ),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.leadingColor != null) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: item.leadingColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm - 2),
                  ],
                  Text(
                    item.label,
                    style: UgamText.bodyStrong.copyWith(
                      color: active ? c.accent : c.ink2,
                      fontSize: 12.5,
                    ),
                  ),
                  if (item.count != null) ...[
                    const SizedBox(width: UgamSpacing.sm - 2),
                    Text(
                      '${item.count}',
                      style: UgamText.tabular(
                        UgamText.bodyStrong.copyWith(
                          color: active ? c.accent : c.ink3,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
