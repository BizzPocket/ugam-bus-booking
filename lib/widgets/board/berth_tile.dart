// The atom of the Board — one berth, painted by whichever lens is active.
//
// Spec: docs/superpowers/specs/2026-08-12-board-interaction-design.md §3 (two
// densities), §7 (tap / long-press), §11 (accessibility), §12 (haptics).
//
// *** WHY THIS IS NOT `ChartSeatTile` OR `SeatChartTile` ***
// The customer tile (`lib/components/chart_seat_tile.dart`) is fed by the
// anonymised availability feed and must never show identity. The admin chart
// tile shows a code. Neither is what a handler needs. The Board's tile shows
// **the occupant's name**, because a chart you can only look at is the reason
// eleven screens exist: today a handler reads `DL3` off a picture and then goes
// hunting through a list for who that is. The name on the tile is the point.
//
// *** WHY IT HAS TO BE CHEAP ***
// A sleeper coach is 36-74 berths and every one of them is one of these, redrawn
// on every lens switch, every filter tap and every collection. So:
//
//   * const constructor, `StatelessWidget`, no per-tile animation controller
//     beyond the one [UgamTappable] already owns for press feedback;
//   * dimming is baked into the COLOURS ([kBerthDimAlpha]) rather than done with
//     an [Opacity] widget — 74 save-layers per frame is what a jank report looks
//     like;
//   * the callbacks are `ValueChanged<BoardBerth>` rather than [VoidCallback] so
//     the canvas can hand the SAME function reference to all 74 tiles instead of
//     allocating 74 closures on every rebuild;
//   * one merged semantics node per tile (`excludeSemantics: true`), not one per
//     `Text` inside it.
//
// Everything about WHAT a berth looks like — its fill, its ink, its glyph, its
// spoken label — comes from `lib/models/board_lens.dart`. This file owns only
// GEOMETRY, PRESS FEEDBACK and the two states a lens knows nothing about
// (multi-selection and the walk cursor). Adding a colour rule here instead of
// there is how the Board grows a twelfth screen.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/board_controller.dart' show BoardDensity;
import '../../design/components/ugam_tappable.dart';
import '../../design/ugam.dart';
import '../../models/board_lens.dart';

/// How far a filtered-out or search-missed berth fades (spec §5: "every other
/// berth dims to 30%").
///
/// Applied by multiplying the paint's own alpha, so a tile that was already
/// translucent (a 22% pickup tint) dims proportionally instead of jumping to a
/// flat 30% and reading as *more* solid than it was.
const double kBerthDimAlpha = 0.3;

/// Fixed geometry for every Board berth tile.
///
/// Same reasoning as `ChartSeatMetrics` on the customer chart: if each tile
/// sized itself to its own text, a bus would render five different footprints
/// and every state change would reflow the row it sits in. The Board is worse
/// than the customer chart in this respect — a lens switch changes the glyph on
/// all 74 tiles at once — so size is decided HERE, once, and the canvas reserves
/// [slotSize] per berth.
///
/// The numbers are component geometry, not spacing: they are the tokens of this
/// component in the same way `UgamRadius.seat` is the token of a seat corner.
/// Padding *inside* the tile still comes from [UgamSpacing].
class BerthTileMetrics {
  const BerthTileMetrics._();

  /// One berth is one COLUMN of a five-column bus grid, so a ~390pt phone
  /// affords roughly 70pt per column. The tile is wide and short rather than
  /// square: the scarce axis is vertical (12-18 rows), never horizontal.
  static const double width = 56;

  /// Spec §3: "~20pt, berth code + state glyph". Deliberately below the 44pt
  /// touch minimum — see [hitInset].
  static const double compactHeight = 22;

  /// Spec §3: "~44pt, code + occupant name + glyph". The working mode.
  static const double comfortableHeight = 46;

  /// Transparent margin around the painted face that STILL TAKES THE TAP.
  ///
  /// This is the compact mode's answer to being under the touch minimum
  /// (spec §3: "in compact mode a tap targets the nearest berth with an expanded
  /// hit area"). It is not padding — the canvas packs slots edge to edge and
  /// this margin doubles as the visual gutter between berths, so the gap between
  /// two tiles is live on both sides rather than dead space that eats mis-taps.
  ///
  /// Fixed, never scaled: it exists to compensate for a small target, so
  /// shrinking it on a small phone would remove it exactly where it is needed.
  /// It also gives the selection badge somewhere to sit that is not on top of
  /// the glyph.
  static const double hitInset = 6;

  /// Diameter of the multi-select check badge, which sits in the [hitInset]
  /// margin at the tile's top-right corner.
  static const double selectionBadge = 12;

  /// Hairline at rest.
  static const double borderWidth = 1;

  /// Selected / walk-cursor ring. Doubling the border is a SHAPE signal, so the
  /// two emphasis states are distinguishable without seeing their colours.
  static const double ringWidth = 2;

  /// Soft amber halo under the walk cursor.
  static const double glowBlur = 8;

  /// Gap between the code/glyph row and the name line in comfortable mode.
  static const double lineGap = 2;

  /// How the code/glyph row splits its width. The glyph gets the larger share
  /// because it is the one whose length is not under our control: `✓` under the
  /// occupancy lens, `₹1.4L` under the money one.
  static const int codeFlex = 3;
  static const int glyphFlex = 4;

  /// The painted face's height for [density].
  ///
  /// Comfortable goes through [UgamScale.tap], so it is never smaller than the
  /// 44pt touch minimum on any device. Compact goes through [UgamScale.px]
  /// because it is *supposed* to be smaller than that; [hitInset] is what makes
  /// it tappable anyway.
  static double heightOf(BuildContext context, BoardDensity density) =>
      density == BoardDensity.compact
      ? UgamScale.px(context, compactHeight)
      : UgamScale.tap(context, comfortableHeight);

  static double widthOf(BuildContext context) => UgamScale.px(context, width);

  /// What the canvas reserves per berth: the face plus its live margin.
  static Size slotSize(BuildContext context, BoardDensity density) => Size(
    widthOf(context) + hitInset * 2,
    heightOf(context, density) + hitInset * 2,
  );
}

/// The Board's haptic vocabulary (spec §12), in one place.
///
/// The app already has ~100 haptic call sites and no agreement between them, so
/// the same gesture buzzes differently depending on which screen you are on.
/// The Board gets ONE table, and it lives next to the widget that fires most of
/// it, so a drag implemented by the canvas and a tap implemented by the tile
/// cannot drift apart.
class BerthHaptics {
  const BerthHaptics._();

  /// Berth tap, and the auto-advance to the next outstanding berth. The
  /// lightest thing in the set, because on a collection round it fires dozens of
  /// times a minute — anything heavier turns into a rattle.
  static void tap() => HapticFeedback.selectionClick();

  /// A drag has picked a passenger up.
  static void pickUp() => HapticFeedback.mediumImpact();

  /// A drop landed, cash was taken, a head was counted.
  static void success() => HapticFeedback.lightImpact();

  /// The "no" pattern: two heavy knocks. Deliberately the only DOUBLE haptic in
  /// the app — a rejected drop must be unmistakable through a pocket, because
  /// spec §7 forbids a silent failure and the snackbar explaining why may be
  /// behind the handler's thumb.
  ///
  /// Awaitable so a test (and a caller sequencing an animation against it) can
  /// wait for the second knock. The gap is [UgamMotion.tapOut] — long enough to
  /// read as two events, short enough to still be one gesture.
  static Future<void> reject() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(UgamMotion.tapOut);
    await HapticFeedback.heavyImpact();
  }
}

/// One berth on the Board.
///
/// [lens] decides the colours, the glyph and the spoken state; this widget
/// decides the size, the press feedback and the two states no lens knows about:
///
///  * [isSelected] — in the multi-select bulk-action set (spec §7),
///  * [isCurrent] — the amber "this is yours" state: the berth the aisle walk is
///    parked on, or the one just tapped.
///
/// Those two must never be confusable, so they differ in HUE (neutral
/// [UgamColorSet.action] vs the cabin-lamp [UgamColorSet.accent]) *and* in
/// whether a check badge is present. A colourblind handler bulk-moving a family
/// can still tell which four berths they have picked.
class BerthTile extends StatelessWidget {
  /// The painted face, for tests that need to read its decoration.
  static const Key faceKey = Key('berth_tile.face');

  /// The multi-select check badge.
  static const Key selectionBadgeKey = Key('berth_tile.selected_badge');

  final BoardBerth berth;

  /// The active lens. Its [BoardLens.paint] is a pure function, so calling it in
  /// `build` costs nothing worth caching.
  final BoardLens lens;

  final BoardDensity density;

  /// In the multi-select set.
  final bool isSelected;

  /// The walk cursor / "this is yours" berth.
  final bool isCurrent;

  /// Filtered out by a legend swatch, or missed by the search (spec §5, §10).
  final bool isDimmed;

  /// A drag is over this berth and releasing here will work.
  ///
  /// Two plain booleans rather than the canvas's `BoardDropState`, so neither
  /// file has to import the other: the canvas hands the tile a builder, and a
  /// tile that reached back into the canvas for an enum would make that
  /// one-way dependency circular. The builder maps the enum onto these.
  ///
  /// Unlike every other state here these carry no glyph, and deliberately: they
  /// last only as long as a finger is held over the berth, they are already
  /// announced by spec §12's haptics (a light tap for valid, the double "no"
  /// knock for invalid), and painting a glyph over the state glyph would cost
  /// the permanent signal to mark a momentary one.
  final bool isDropTarget;

  /// A drag is over this berth and it will be refused — occupied, blocked,
  /// wrong seat type, gender rule. Spec §7: the berth flashes danger, never a
  /// silent failure.
  final bool isDropRejected;

  /// Shared across every tile on the canvas — hence [BoardBerth] as an argument
  /// rather than a closure per tile.
  final ValueChanged<BoardBerth>? onTap;

  /// Long-press starts multi-select (spec §7).
  final ValueChanged<BoardBerth>? onLongPress;

  const BerthTile({
    super.key,
    required this.berth,
    required this.lens,
    required this.density,
    this.isSelected = false,
    this.isCurrent = false,
    this.isDimmed = false,
    this.isDropTarget = false,
    this.isDropRejected = false,
    this.onTap,
    this.onLongPress,
  });

  bool get _isCompact => density == BoardDensity.compact;

  /// Fades a colour by multiplying its OWN alpha, so a translucent tint dims to
  /// 30% of what it was rather than up to a flat 30%.
  static Color _fade(Color color, bool dimmed) =>
      dimmed ? color.withValues(alpha: color.a * kBerthDimAlpha) : color;

  /// Spec §11: *"DL3, Priti Patel, paid, double sofa, boarding at Adajan"*.
  ///
  /// The passenger part is [BoardLens.semanticLabel]'s job — it is the same
  /// sentence the legend and the sheet speak. Only the two view states this
  /// widget owns are appended, because a screen-reader user otherwise has no way
  /// at all to know a berth is in their selection.
  String semanticsLabel() {
    final base = lens.semanticLabel(berth);
    final extras = <String>[
      if (isCurrent) tr('board_berth.a11y_current'),
      if (isSelected) tr('board_berth.a11y_selected'),
    ];
    return extras.isEmpty ? base : '$base, ${extras.join(', ')}';
  }

  /// The second line in comfortable mode. A name when there is one; the lens's
  /// own word for the berth when there is not — "Empty" on a free berth is
  /// useful, and an anonymised occupant (a stranger-share berth the agent has
  /// not de-anonymised) is honestly labelled rather than left blank.
  String _nameLine() {
    final name = berth.occupantName?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (berth.isOccupied) return tr('board_berth.unnamed');
    return lens.stateLabel(berth);
  }

  void _handleTap() {
    BerthHaptics.tap();
    onTap!(berth);
  }

  void _handleLongPress() {
    // Same weight as a drag pick-up: a long-press IS the gesture that picks a
    // berth up into a bulk action.
    BerthHaptics.pickUp();
    onLongPress!(berth);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final paint = lens.paint(berth, c);

    final fill = _fade(paint.fill, isDimmed);
    final ink = _fade(paint.ink, isDimmed);

    // Emphasis rings are never dimmed: a berth you have selected, or the one the
    // collection round is parked on, must stay findable while everything else
    // fades behind a filter.
    //
    // A live drag outranks both. While a finger is over the berth the only
    // question on screen is whether letting go will work, and the answer has to
    // beat "you selected this one four taps ago".
    final Color borderColor;
    final double borderWidth;
    if (isDropRejected) {
      borderColor = c.danger;
      borderWidth = BerthTileMetrics.ringWidth;
    } else if (isDropTarget) {
      borderColor = c.good;
      borderWidth = BerthTileMetrics.ringWidth;
    } else if (isSelected) {
      borderColor = c.action;
      borderWidth = BerthTileMetrics.ringWidth;
    } else if (isCurrent) {
      borderColor = c.accent;
      borderWidth = BerthTileMetrics.ringWidth;
    } else {
      borderColor = _fade(c.border, isDimmed);
      borderWidth = BerthTileMetrics.borderWidth;
    }

    final face = DecoratedBox(
      key: faceKey,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.seat),
        border: Border.all(color: borderColor, width: borderWidth),
        // The amber halo, and only the amber halo: the selection ring is a
        // neutral, so giving it a glow too would collapse the one difference
        // that stops the two states being read as the same thing.
        boxShadow: isCurrent
            ? [
                BoxShadow(
                  color: c.glow,
                  blurRadius: BerthTileMetrics.glowBlur,
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.xs),
        child: _isCompact
            ? _CompactFace(code: berth.code, glyph: paint.glyph, ink: ink)
            : _ComfortableFace(
                code: berth.code,
                glyph: paint.glyph,
                name: _nameLine(),
                ink: ink,
              ),
      ),
    );

    final slot = BerthTileMetrics.slotSize(context, density);

    return Semantics(
      container: true,
      // One node per berth instead of one per Text inside it — and the label is
      // the lens's full sentence, so a screen reader never reads out a bare
      // "DL3" the way the chart it replaces does.
      excludeSemantics: true,
      button: onTap != null || onLongPress != null,
      selected: isSelected,
      label: semanticsLabel(),
      child: UgamTappable(
        onTap: onTap == null ? null : _handleTap,
        onLongPress: onLongPress == null ? null : _handleLongPress,
        // The app-wide default is lightImpact on tap-down; the Board's table
        // (spec §12) says selectionClick on tap and mediumImpact on pick-up, so
        // the haptics are fired by the handlers above instead.
        haptic: false,
        // Small chrome needs more travel than a card to read as pressed at all,
        // and a compact tile is very small chrome.
        pressedScale: _isCompact ? 0.90 : 0.95,
        child: SizedBox(
          width: slot.width,
          height: slot.height,
          child: Stack(
            // Tight, not loose. A shrink-wrapping stack would let the face size
            // itself to its own text, which is exactly the per-tile-footprint
            // bug `ChartSeatMetrics` exists to prevent: a lens switch changes
            // the glyph on all 74 tiles at once, and every row would reflow.
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.all(BerthTileMetrics.hitInset),
                child: face,
              ),
              if (isSelected)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _SelectionBadge(colors: c),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact: `DL3` and its state glyph on one line. Whole-bus scanning.
///
/// One line rather than two because 22pt cannot hold two, and the tile is wide
/// (a bus grid column is ~70pt) so a code and a glyph fit side by side with room
/// to spare. Both halves scale down independently, which is what keeps a `₹1.2K`
/// glyph from shrinking the berth code along with it.
class _CompactFace extends StatelessWidget {
  final String code;
  final String glyph;
  final Color ink;

  const _CompactFace({
    required this.code,
    required this.glyph,
    required this.ink,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 3:4, not 1:1. A berth code is 2-4 characters and barely varies; a
        // glyph is one character under most lenses but `₹1.4L` under the money
        // one. An even split would scale a three-letter code down to nothing to
        // reserve room the occupancy lens never uses.
        Flexible(
          flex: BerthTileMetrics.codeFlex,
          child: _Shrink(text: code, style: _codeStyle(ink)),
        ),
        const SizedBox(width: BerthTileMetrics.lineGap),
        Flexible(
          flex: BerthTileMetrics.glyphFlex,
          child: _Shrink(
            text: glyph,
            style: _glyphStyle(ink),
            alignment: Alignment.centerRight,
          ),
        ),
      ],
    );
  }
}

/// Comfortable: code + glyph, and under them the occupant.
///
/// The name is the reason this mode exists. It ellipsizes rather than shrinking
/// — a first name at a readable size beats a full name at 6pt, and Gujarati
/// names run long.
class _ComfortableFace extends StatelessWidget {
  final String code;
  final String glyph;
  final String name;
  final Color ink;

  const _ComfortableFace({
    required this.code,
    required this.glyph,
    required this.name,
    required this.ink,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(child: _Shrink(text: code, style: _codeStyle(ink))),
            const SizedBox(width: BerthTileMetrics.lineGap),
            Flexible(
              child: _Shrink(
                text: glyph,
                style: _glyphStyle(ink),
                alignment: Alignment.centerRight,
              ),
            ),
          ],
        ),
        const SizedBox(height: BerthTileMetrics.lineGap),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: UgamText.caption.copyWith(color: ink),
        ),
      ],
    );
  }
}

/// Sora, tabular — the same face every seat code in the app already uses, so a
/// Board code and a printed ticket read alike.
///
/// The tracking is dropped to zero. [UgamText.micro] carries 1.4 because it is
/// the style of an UPPERCASE section eyebrow, where letterspacing is the whole
/// look; on a 56pt tile it adds ~5pt to `ST40` and the [_Shrink] around it pays
/// for that by scaling the code down. A berth code is an identifier, not an
/// eyebrow.
TextStyle _codeStyle(Color ink) => UgamText.tabular(
  UgamText.micro,
).copyWith(color: ink, fontWeight: FontWeight.w700, letterSpacing: 0);

/// Inter for the glyph: `✓ ₹550 ½ — ● ○ ♀ ✕ ↩` need broader coverage than the
/// display face has, and a money glyph wants tabular figures.
TextStyle _glyphStyle(Color ink) => UgamText.tabular(
  UgamText.caption,
).copyWith(color: ink, fontWeight: FontWeight.w700);

/// Scale-to-fit for the two pieces whose length is not under our control: a
/// berth code can be `DL3` or `ST40`, and a due glyph can be `₹1.2L`.
class _Shrink extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Alignment alignment;

  const _Shrink({
    required this.text,
    required this.style,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(text, maxLines: 1, softWrap: false, style: style),
    );
  }
}

/// The multi-select marker.
///
/// It sits in the tile's live margin rather than on its face, so it never covers
/// the state glyph — which would trade one accessibility rule for another. It is
/// painted in the neutral [UgamColorSet.action], never the accent, because the
/// accent already means "this is yours" on the walk cursor.
class _SelectionBadge extends StatelessWidget {
  final UgamColorSet colors;

  const _SelectionBadge({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: BerthTile.selectionBadgeKey,
      width: BerthTileMetrics.selectionBadge,
      height: BerthTileMetrics.selectionBadge,
      decoration: BoxDecoration(
        color: colors.action,
        shape: BoxShape.circle,
        // Rings the badge against whatever fill is behind it so it reads as a
        // badge and not as a hole punched in the tile.
        border: Border.all(color: colors.bg, width: BerthTileMetrics.borderWidth),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '✓',
          style: UgamText.micro.copyWith(
            color: colors.onAction,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
