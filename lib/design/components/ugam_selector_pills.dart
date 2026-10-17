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
///
/// The selected pill is scrolled into view on first build and whenever
/// [currentIndex] changes — a tour picked from elsewhere (dashboard deep link,
/// last-used tour) used to sit selected but off-screen past the right edge.
class UgamSelectorPills extends StatefulWidget {
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
  State<UgamSelectorPills> createState() => _UgamSelectorPillsState();
}

class _UgamSelectorPillsState extends State<UgamSelectorPills> {
  final _keys = <int, GlobalKey>{};

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _revealSelected(animate: false);
  }

  @override
  void didUpdateWidget(covariant UgamSelectorPills old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex ||
        old.items.length != widget.items.length) {
      _revealSelected(animate: true);
    }
  }

  void _revealSelected({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = widget.currentIndex;
      if (i < 0 || i >= widget.items.length) return;
      final ctx = _keys[i]?.currentContext;
      if (ctx == null) return;
      final ro = ctx.findRenderObject();
      final scrollable = Scrollable.maybeOf(ctx);
      if (ro == null || scrollable == null) return;
      // Only THIS strip's own horizontal scrollable — never the page's
      // vertical one, which `Scrollable.ensureVisible` would also move.
      scrollable.position.ensureVisible(
        ro,
        alignment: 0.5,
        duration: animate ? UgamMotion.tab : Duration.zero,
        curve: UgamMotion.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final items = widget.items;
    final currentIndex = widget.currentIndex;
    final onChanged = widget.onChanged;
    final padding = widget.padding;

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
            key: _keyFor(i),
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
