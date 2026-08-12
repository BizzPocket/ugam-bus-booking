import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// Floating capsule dock nav. Replaces the prior `_PillBottomNav`.
///
/// Anatomy: a single capsule pinned 12 px from the bottom with 12 px
/// lateral padding, holding 2–5 nav targets. EVERY target shows its icon
/// *and* its label, stacked — both Apple HIG and Material require a label on
/// primary navigation, and these destinations (Tours / Charts / Requests) are
/// not guessable from a glyph, least of all for the Gujarati-first operators
/// this app is built for.
///
/// The current tab is distinguished by *fill, weight and colour* rather than
/// by being the only one with text: it sits in a cabin-lamp amber pill with
/// near-black ink at a heavier weight, while the rest stay transparent with
/// secondary ink. The accent is still rationed to exactly one tab.
///
/// Layout: the targets are equal-width [Expanded] cells, so the row can never
/// overflow the capsule (the old content-sized + `spaceBetween` row did on a
/// narrow phone whenever the widest tab was active — which is what made the
/// last item's pill look like it ran into the dock's right edge). Labels
/// shrink to fit their cell via [BoxFit.scaleDown] instead of disappearing.
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
              // Level 2. The dock is not a card ON the page — the body uses
              // extendBody, so the page scrolls UNDER it: it is a persistent
              // layer above everything, which is the same contract a sheet or
              // dialog has, and it is the only chrome that never moves out of
              // the way. `rest` would put it at the same height as the cards
              // sliding beneath it.
              //
              // Was a hand-rolled 32% black in Midnight — the exact value the
              // scale was cut back from, and the reason the capsule sat in a
              // visible smudge. Depth in Midnight comes from `cardElev` being
              // lighter than the ground, which this surface already is.
              boxShadow: UgamElevation.of(context).raised,
            ),
            // Lateral inset is one step wider than the vertical one. The
            // capsule's ends are a 26 px arc; at a 4 px inset the last tab's
            // amber pill nests exactly concentric with it and reads as if it
            // were running into (or being clipped by) the dock's edge. 8 px
            // leaves a visible, even gap at the caps no matter how wide the
            // outermost label grows. Vertical stays at 4 — the dock's height
            // is not what needs air.
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.sm,
                vertical: UgamSpacing.xs,
              ),
              child: Row(
                children: List.generate(items.length, (i) {
                  final active = i == currentIndex;
                  // Equal-width cells: every tab owns the same slice of the
                  // capsule whichever one is active, so nothing can be pushed
                  // past the right edge and the row never overflows.
                  return Expanded(
                    child: _DockButton(
                      item: items[i],
                      active: active,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onTap(i);
                      },
                    ),
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

  /// Short uppercase label (e.g. "HOME"). Always rendered under the icon —
  /// keep it to one short word so it survives the dock's narrow cell.
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

    // `micro` is the smallest step on the ladder, and its eyebrow tracking
    // (1.4) is far too wide for a ~55 px cell — it alone costs 11 px on an
    // 8-character label like SETTINGS. Tightened to 0.3 here, and the line
    // box opened to 1.3 so Gujarati/Devanagari matras (બુકિંગ, સેટિંગ) have
    // room above and below the baseline.
    final labelStyle = UgamText.micro.copyWith(
      letterSpacing: 0.3,
      height: 1.3,
      fontWeight: active ? FontWeight.w700 : FontWeight.w600,
      color: active ? c.onAccent : c.ink2,
    );

    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        // The whole cell is the tap target (44 pt floor), not just the pill,
        // so the finger has the full width of the slice to land in. Min — not
        // fixed — height, so an accessibility text scale grows the dock
        // instead of overflowing it.
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
          // `heightFactor: 1` makes this shrink-wrap the pill. Scaffold hands
          // the dock LOOSE (not unbounded) constraints, so a plain Center
          // would stretch to the full screen height instead of hugging.
          child: Align(
            alignment: Alignment.center,
            heightFactor: 1,
            child: AnimatedContainer(
              duration: UgamMotion.dock,
              curve: UgamMotion.easeOut,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.sm,
                vertical: UgamSpacing.xs,
              ),
              // At least as wide as it is tall, so a short label (Gujarati
              // "ટૂર") gives a round pill instead of a narrow vertical slab.
              // The 8 pt lateral padding is also the minimum that keeps the
              // label inside the stadium's curved cap: the label sits below
              // the pill's centre line, where the fill has already started
              // curving inward.
              constraints: BoxConstraints(minWidth: UgamScale.tap(context, 44)),
              decoration: BoxDecoration(
                color: active ? c.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              // Hugs its content and is centred in the cell, so the pill can
              // never reach the capsule's rounded end — the last tab's pill is
              // inset by the same gap as every other tab's.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _badged(
                    c,
                    Icon(
                      item.icon,
                      size: 19,
                      color: active ? c.onAccent : c.ink2,
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  // Every destination keeps its name. When the label cannot
                  // fit its cell (long word, large accessibility text scale)
                  // it scales down rather than being dropped or clipped.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: AnimatedDefaultTextStyle(
                      duration: UgamMotion.dock,
                      curve: UgamMotion.easeOut,
                      style: labelStyle,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
