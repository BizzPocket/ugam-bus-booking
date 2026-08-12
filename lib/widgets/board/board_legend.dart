/// The Board's legend — spec §5 / §11 / §13 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/components/ugam_tappable.dart';
import '../../design/text_styles.dart';
import '../../design/tokens.dart';
import '../../design/ui_scale.dart';
import '../../models/board_lens.dart';

/// The colour chip in front of each label. Big enough to hold the entry's
/// glyph, which is what makes the key readable without colour at all.
const double _kSwatch = 20;

/// The "tap again to clear" mark on the active entry.
const double _kClearGlyph = 14;

/// Gap between the swatch and the label it names.
///
/// The scale has no named 6pt step for an INSIDE-a-control gap: `xs` (4) reads
/// as the swatch touching the word, `sm` (8) — which is also this chip's outer
/// padding — makes the pair stop reading as one unit. The codebase already hit
/// the step above and named it (`UgamSpacing.tight` is "the `sm + 2` idiom,
/// named"), so this follows that precedent instead of leaving bare arithmetic
/// at the call site. Reported as a token gap; `tokens.dart` is not this task's
/// to edit.
const double _kSwatchGap = UgamSpacing.sm - 2;

/// The Board's legend — **and its filter** (spec §5).
///
/// Tapping a swatch dims every non-matching berth to 30%; tapping it again
/// clears. That is the entire filtering story for eleven screens' worth of
/// views: no filter screen, no filter sheet, no filter icon to discover,
/// because the control is the thing already on screen explaining the colours.
///
/// Everything rendered here is read off [lens] — the rows, their labels, their
/// swatch colours, their glyphs and the predicate each one filters by all come
/// from `lib/models/board_lens.dart`. No lens is named in this file, so the
/// legend works unchanged for the two shipped lenses and for the three tinted
/// ones whose rows are generated per tour.
///
/// Three rules it enforces structurally rather than by review:
///
///  * **Never a legend without berths** (spec §13). Today's chart shows ten
///    colour codes above an empty bus. This widget takes the [berths] rather
///    than a prebuilt row list precisely so it can refuse: an empty bus renders
///    nothing at all, and a lens row that no berth on this bus matches is
///    dropped by [BoardLens.legendFor] before it is ever laid out.
///  * **An active swatch shows its own state** (spec §11). Dimming the chart to
///    30% is not, on its own, an indication that a filter is on — the handler
///    who set it may not be looking at the chart. The active row carries a
///    tonal fill, an accent hairline, a bolder label and a clear mark, plus
///    `selected: true` for a screen reader.
///  * **Every row is a 44pt target.** Legend entries stopped being decoration
///    the moment they became the filter.
class BoardLegend extends StatelessWidget {
  /// The active lens, already built (with its [BoardTintScale] for the pickup
  /// and group lenses).
  final BoardLens lens;

  /// The berths on the bus currently shown. Drives BOTH which rows exist and
  /// whether the legend renders at all.
  final List<BoardBerth> berths;

  /// The [BoardLegendEntry.id] currently filtering, or null for "show all" —
  /// `BoardController.legendFilter`.
  final String? activeId;

  /// Fires with the tapped row's id. The controller's `toggleLegendFilter`
  /// already turns a second tap on the same id into "clear", so this reports
  /// the tap and does not try to work out the next state itself.
  final ValueChanged<String> onToggle;

  final EdgeInsetsGeometry padding;

  const BoardLegend({
    super.key,
    required this.lens,
    required this.berths,
    required this.onToggle,
    this.activeId,
    this.padding = const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
  });

  @override
  Widget build(BuildContext context) {
    // Spec §13, guard one: no bus, no key. Checked before the palette is even
    // read so the "empty chart with ten colour codes over it" state is
    // unreachable rather than merely unlikely.
    if (berths.isEmpty) return const SizedBox.shrink();

    final c = UgamColors.of(context);
    // Guard two: rows nothing on this bus matches never render. A tour with no
    // ladies aboard does not get a "મહિલા" swatch that filters to zero berths.
    final entries = lens.legendFor(berths, c);
    if (entries.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: tr('board_legend.a11y_group'),
      child: Padding(
        padding: padding,
        child: Wrap(
          // A wrap, not a scroller: up to six rows on the tinted lenses, and a
          // filter control that is off-screen is a filter control nobody finds.
          // Wrapping costs a line of height; hiding a row costs the feature.
          spacing: UgamSpacing.sm,
          runSpacing: UgamSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in entries)
              _LegendChip(
                entry: entry,
                active: entry.id == activeId,
                onTap: () {
                  // Spec §12: choosing a filter is a selection.
                  HapticFeedback.selectionClick();
                  onToggle(entry.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// One legend row: swatch + glyph + label, and the filter toggle behind them.
class _LegendChip extends StatelessWidget {
  final BoardLegendEntry entry;
  final bool active;
  final VoidCallback onTap;

  const _LegendChip({
    required this.entry,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final swatch = UgamScale.px(context, _kSwatch);

    // ONE node per row, declared here rather than left to merge with
    // `UgamTappable`'s own annotation — a merge produced two nodes, and the one
    // carrying `selected` was not the one carrying the tap action, so the row
    // announced as an unselectable button. The wrapper keeps the press
    // animation and the real gesture; its semantics are excluded.
    return Semantics(
      container: true,
      button: true,
      selected: active,
      // The label says what the tap DOES, not just what the colour means — a
      // legend that filters has to announce itself as a control.
      label: tr(
        active ? 'board_legend.a11y_clear' : 'board_legend.a11y_filter',
        namedArgs: {'label': entry.label},
      ),
      onTap: onTap,
      child: ExcludeSemantics(
        child: UgamTappable(
          onTap: onTap,
          // The chip fires its own `selectionClick`; the wrapper's default
          // `lightImpact` would double up on every tap.
          haptic: false,
          pressedScale: 0.93,
          child: ConstrainedBox(
            // Spec: legend entries are touch targets. The `Center` keeps the
            // painted chip at its own height inside the 44pt box.
            constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
            child: Center(
              child: AnimatedContainer(
                duration: UgamMotion.tab,
                curve: UgamMotion.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm,
                  vertical: UgamSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: active ? c.accentFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                  // A transparent hairline when inactive, so switching the
                  // filter on cannot nudge the row's geometry and reflow the
                  // wrap under the handler's thumb.
                  border: Border.all(
                    color: active
                        ? c.accent.withValues(alpha: 0.55)
                        : Colors.transparent,
                    width: active ? 1.4 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: swatch,
                      height: swatch,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: entry.swatch,
                        borderRadius: BorderRadius.circular(UgamSpacing.xs),
                        // The occupancy lens paints "empty" with the page
                        // ground itself, so without a hairline that swatch
                        // would be an invisible hole in the key.
                        border: Border.all(color: c.border),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        // Spec §11: colour is never the only signal. The
                        // chart's glyph is repeated here, so the key still
                        // reads as a key in greyscale or at a large text scale.
                        child: Text(
                          entry.glyph,
                          style: UgamText.caption.copyWith(
                            color: entry.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: _kSwatchGap),
                    Flexible(
                      child: Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.caption.copyWith(
                          color: active
                              ? c.accent
                              // The "+N other stops" bucket is not a sixth
                              // equal colour and must not read as one.
                              : (entry.isOther ? c.ink3 : c.ink2),
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: UgamSpacing.xs),
                      // The one affordance that says a filter can be undone
                      // without hunting for a "clear" button somewhere else.
                      Icon(
                        Icons.close_rounded,
                        size: UgamScale.px(context, _kClearGlyph),
                        color: c.accent,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
