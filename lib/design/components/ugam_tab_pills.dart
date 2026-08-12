import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

// ── Segment geometry ────────────────────────────────────────────────────
//
// These are the SINGLE source of truth for how wide a segment needs to be.
// [UgamTabPills._labelsFitEqually] measures with them and [_TabSegment]
// renders with them, so the fit decision can never drift away from the thing
// it is deciding about. Change one number and both sides follow.

/// Padding of the track (the `cardElev` container) around the segment row.
const double _trackPad = 3;

/// Horizontal inset inside a segment when the row divides the width equally.
/// Was 0, which let two Gujarati labels touch across a segment boundary at
/// the point where they only just fit.
const double _segPadFit = UgamSpacing.xs;

/// Horizontal inset inside a segment when the row scrolls and each segment is
/// its own natural width.
const double _segPadScroll = UgamSpacing.md;

const double _iconSize = 14;
const double _iconGap = 5;
const double _countGap = 5;

/// The label's TYPE, with no colour on it: colour is decided per segment at
/// paint time and has no effect on metrics. Hoisted out of [_TabSegment] so
/// the measurement below and the `Text` further down cannot disagree about
/// what is being measured.
final TextStyle _labelType = UgamText.bodyStrong.copyWith(fontSize: 12);

/// Ditto for the count badge.
final TextStyle _countType =
    UgamText.tabular(UgamText.caption.copyWith(fontWeight: FontWeight.w700));

/// Segmented pill tabs. Supports 2–5 segments. Active segment fills with
/// surface card; inactive segments stay transparent on the cardElev container.
///
/// ## Equal division vs. horizontal scroll is MEASURED, not counted
///
/// This used to be `items.length >= 5`, on the theory that five segments is
/// where Gujarati labels stop fitting. A count is only ever a proxy for the
/// thing that actually matters — whether the copy fits — and it was wrong in
/// both directions:
///
/// * `collection_screen`'s THREE segments crushed "પાછું આપવાનું" down to an
///   ellipsis in all sixteen locale/width/text-scale combinations the overflow
///   guard runs, including 375pt at text scale 1.0, where the label wanted
///   153.3pt and got 115.0;
/// * `add_bus_screen`'s TWO segments carry "બધા માટે સરખું" plus an icon, and
///   `notify_screen`/`passenger_sheet` fill their labels from USER DATA (tour
///   titles, passenger names), which has no length bound at all. No count
///   threshold can be right for those.
///
/// So the widget measures instead. Equal flex hands every segment exactly
/// `track / n`, which means the binding constraint is the WIDEST segment, not
/// the total: if the widest label (plus its icon, its count badge and its
/// insets) fits its share, no segment can ellipsise. When it does not fit, the
/// row falls back to the horizontal scroll strip, where every segment is its
/// own natural width and every label renders whole.
///
/// Consequences worth knowing:
///
/// * a control whose labels fit is byte-for-byte the layout it always was — it
///   gains no scroll affordance;
/// * the decision is re-made on every layout, so rotation and a change to the
///   OS text-scale setting move a control between the two modes by themselves;
/// * a set with very uneven labels (one long, two short) whose TOTAL fits but
///   whose widest × n does not will scroll, and the strip will then be
///   narrower than the track. That is cosmetic and rare; the alternative was
///   ellipsising the long one, which is not.
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final scrollable = !_labelsFitEqually(context, constraints.maxWidth);
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
          padding: const EdgeInsets.all(_trackPad),
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
      },
    );
  }

  /// True when EVERY label survives whole under an equal division of the
  /// track — the only condition under which the equal-[Expanded] layout is
  /// correct.
  bool _labelsFitEqually(BuildContext context, double maxWidth) {
    // Unbounded width — a `Row` child with no `Expanded`, a horizontal
    // scroller. `Expanded` cannot lay out there at all (the old code asserted),
    // so the scrolling strip, which can, is the only correct answer.
    if (!maxWidth.isFinite) return false;

    final share = (maxWidth - _trackPad * 2) / items.length;
    // Resolved exactly the way `Text` resolves its own style — merged onto the
    // ambient `DefaultTextStyle` — so this measures the string the renderer
    // will actually draw rather than an approximation of it.
    final base = DefaultTextStyle.of(context).style;
    final labelStyle = base.merge(_labelType);
    final countStyle = base.merge(_countType);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    for (final item in items) {
      var needed =
          _segPadFit * 2 + _measureWidth(item.label, labelStyle, scaler, direction);
      // `Icon` does not apply text scaling unless the ambient IconTheme asks
      // for it, and this app's does not, so the glyph is a flat 14pt.
      if (item.icon != null) needed += _iconSize + _iconGap;
      if (item.count != null) {
        needed +=
            _countGap + _measureWidth('${item.count}', countStyle, scaler, direction);
      }
      if (needed > share) return false;
    }
    return true;
  }
}

/// The unwrapped width of [text] — the same number `RenderParagraph` reports as
/// its max intrinsic width, which is what the ellipsis decision is made against.
double _measureWidth(
  String text,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
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
    final e = UgamElevation.of(context);
    final label = Text(
      item.label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: _labelType.copyWith(color: active ? c.ink : c.ink2),
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
              horizontal: scrollable ? _segPadScroll : _segPadFit,
            ),
            decoration: BoxDecoration(
              color: active ? c.card : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              // Level 1 for the selected segment, level 0 for the rest — the
              // thumb of a segmented control is lifted off its track (the
              // iOS/Material convention) while the unselected segments ARE the
              // track. Not `raised`: this is an inline control on the page, not
              // a layer over it.
              //
              // Was a hand-rolled 6% pure black, theme-blind and untinted. The
              // scale reads the two themes the way they actually differ: in
              // Daylight the pill's `card` fill is LIGHTER than the `cardElev`
              // track, so it wants (and now gets) a warm contact shadow; in
              // Midnight the same pair inverts — `card` is darker than
              // `cardElev` — so the selected segment already reads as an inset
              // well and `rest` correctly collapses to almost nothing there.
              boxShadow: active ? e.rest : e.flat,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
              children: [
                if (item.icon != null) ...[
                  Icon(item.icon, size: _iconSize, color: active ? c.ink : c.ink2),
                  const SizedBox(width: _iconGap),
                ],
                if (scrollable) label else Flexible(child: label),
                if (item.count != null) ...[
                  const SizedBox(width: _countGap),
                  Text(
                    '${item.count}',
                    style: _countType.copyWith(
                      color: active ? c.accent : c.ink3,
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
