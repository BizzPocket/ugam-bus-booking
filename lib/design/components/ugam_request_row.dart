import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

enum UgamChipVariant { accent, warm, good, neutral }

/// Compact chip — used in dense admin rows for seat-type tags, badges,
/// short labels. Differs from a Pill CTA in fontsize, padding, and intent.
class UgamReqChip extends StatelessWidget {
  final String label;
  final UgamChipVariant variant;

  const UgamReqChip({
    super.key,
    required this.label,
    this.variant = UgamChipVariant.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (bg, fg) = switch (variant) {
      UgamChipVariant.accent => (c.accentFill, c.accent),
      UgamChipVariant.warm => (c.warmFill, c.warm),
      UgamChipVariant.good => (c.goodFill, c.good),
      UgamChipVariant.neutral => (c.cardElev, c.ink2),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          color: fg,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
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
                Text(
                  name,
                  style: UgamText.bodyStrong.copyWith(
                    color: c.ink,
                    fontSize: 13,
                  ),
                  maxLines: 1,
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
