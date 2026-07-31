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
        (leading == null ? null : Icon(leading, size: 10, color: fg));

    final text = Text(
      label,
      style: UgamText.micro.copyWith(
        color: fg,
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    );

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
                      ...chips.expand(
                        (chip) => [chip, const SizedBox(width: 5)],
                      ),
                      if (timeAgo != null) ...[
                        const Spacer(),
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
