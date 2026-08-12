import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

enum UgamChipVariant { accent, warm, good, neutral, danger }

/// Compact chip — used in dense admin rows for seat-type tags, badges,
/// short labels. Differs from a Pill CTA in fontsize, padding, and intent.
///
/// This is THE badge for the whole app. Screens that need a small icon in
/// front of the label (a priority star, a group dot) pass [leading] or
/// [leadingWidget] rather than hand-rolling a competing pill geometry.
class UgamReqChip extends StatelessWidget {
  final String label;
  final UgamChipVariant variant;

  /// Optional glyph before the label, inked to match the variant.
  /// Ignored when [leadingWidget] is supplied.
  final IconData? leading;

  /// Optional arbitrary widget before the label (a coloured group dot, an
  /// avatar). Wins over [leading]; the caller owns its colour and size.
  final Widget? leadingWidget;

  const UgamReqChip({
    super.key,
    required this.label,
    this.variant = UgamChipVariant.accent,
    this.leading,
    this.leadingWidget,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (bg, fg) = switch (variant) {
      UgamChipVariant.accent => (c.accentFill, c.accent),
      UgamChipVariant.warm => (c.warmFill, c.warm),
      UgamChipVariant.good => (c.goodFill, c.good),
      UgamChipVariant.neutral => (c.cardElev, c.ink2),
      UgamChipVariant.danger => (c.dangerFill, c.danger),
    };

    final Widget? lead =
        leadingWidget ??
        // 12, not 10 — matches the larger cap height of `captionStrong` below.
        (leading == null ? null : Icon(leading, size: 12, color: fg));

    // `captionStrong` (Inter 12 / w600), NOT a forked `micro`.
    //
    // This was `UgamText.micro.copyWith(fontSize: 9.5, w700, letterSpacing: 0.3)`
    // — three separate violations of the ladder in one call:
    //   * 9.5 is under the Inter floor of 12. With UgamScale's 0.85 small-phone
    //     factor that renders at ~8pt, below legibility for Gujarati conjuncts.
    //   * `micro` is Sora, uppercase-only and Latin-only by documentation; chip
    //     labels here are translated (`chip_due`, `chip_paid`, `upi_pending_chip`).
    //   * letterSpacing pulls apart conjuncts that are supposed to join.
    //
    // `caption` (w500) was rejected over `captionStrong` (w600): the two are
    // within ~1.5pt in width, so weight is the deciding factor, and the chip was
    // w700 deliberately — at w500 a badge reads as body copy.
    //
    // COST: the chip box grows ~15pt -> ~20pt tall. That is absorbed because the
    // strip below is a `Wrap`, which reflows rather than overflowing. If anyone
    // reverts that Wrap to a Row, this height becomes an overflow — see the
    // guard case in test/overflow/components_overflow_test.dart.
    final text = Text(label, style: UgamText.captionStrong.copyWith(color: fg));

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.badgeH,
        vertical: UgamSpacing.badgeV,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      // No leading -> the bare Text, exactly as before. Wrapping every chip
      // in a Row would let a long label overflow (a Row child does not wrap)
      // where today it soft-wraps, so the 20+ existing call sites keep the
      // original single-child path.
      child: lead == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [lead, const SizedBox(width: 3), Flexible(child: text)],
            ),
    );
  }
}

/// Dense admin request row. Avatar + name + chips + time + arrow.
class UgamRequestRow extends StatelessWidget {
  final String initials;
  final String name;

  /// Any number of chips. They lay out in a [Wrap], so a set too wide for the
  /// row runs onto a second line instead of overflowing — see the note on the
  /// chip strip in [build] for why wrapping and not scrolling or ellipsising.
  final List<UgamReqChip> chips;
  final String? timeAgo;
  final VoidCallback? onTap;

  const UgamRequestRow({
    super.key,
    required this.initials,
    required this.name,
    this.chips = const [],
    this.timeAgo,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: UgamText.bodyStrong.copyWith(
                color: c.ink,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md - 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 2 lines, app-wide rule: a person's name must READ, and a
                // clipped one ("U Jana…") can't be called out, searched for, or
                // matched against a WhatsApp contact. Chrome yields to the
                // name, never the other way round. Still ellipsised past 2
                // lines so a pasted paragraph can't blow the row open.
                Text(
                  name,
                  style: UgamText.bodyStrong.copyWith(
                    color: c.ink,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (chips.isNotEmpty || timeAgo != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      // A `Wrap`, not a `Row`. This was a bare Row of chips
                      // plus a `Spacer`, which is unbounded in the main axis:
                      // one chip fits, three real Gujarati chips overflowed
                      // the RenderFlex by 167px at 375pt and painted the
                      // timestamp 103pt off the right edge. `chips` is a
                      // public `List` with no documented bound, so the only
                      // caller passing one chip today was luck, not a
                      // contract.
                      //
                      // Wrap over the two alternatives, for a row in a list:
                      //   * horizontal scroll — a nested horizontal scrollable
                      //     inside a tappable row inside a vertical list eats
                      //     the row's own drag gestures (these rows sit under
                      //     `UgamSwipeAction` elsewhere), and content parked
                      //     off the right edge of a 20pt-tall strip is
                      //     undiscoverable;
                      //   * Flexible + ellipsis — a chip IS its label. "મોકલ…"
                      //     is not a shorter status, it is no status. The name
                      //     above may ellipsise because a partial name is
                      //     still a name; a partial badge is noise.
                      // Wrapping costs one line of height in the rare case and
                      // keeps every chip readable, which is the whole job.
                      Expanded(
                        child: Wrap(
                          spacing: 5,
                          runSpacing: UgamSpacing.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: chips,
                        ),
                      ),
                      // The row's right anchor: natural width, never flexed,
                      // so it keeps its position no matter how the chips fall.
                      // The `Expanded` above is what yields to it.
                      if (timeAgo != null) ...[
                        const SizedBox(width: UgamSpacing.sm),
                        Text(
                          timeAgo!,
                          style: UgamText.caption.copyWith(
                            color: c.ink3,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.accentFill,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.arrow_forward_rounded, size: 14, color: c.accent),
          ),
        ],
      ),
    );
  }
}
