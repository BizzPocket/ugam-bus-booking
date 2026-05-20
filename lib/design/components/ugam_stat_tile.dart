import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

enum UgamStatVariant { accent, good, warm, neutral }

/// Stat tile for admin cockpits. 32 px icon-in-rounded-square + numeric
/// value (tabular) + small caption label. Use in a 2-column grid.
class UgamStatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final String? ofTotal;
  final UgamStatVariant variant;

  const UgamStatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.ofTotal,
    this.variant = UgamStatVariant.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (iconBg, iconFg) = switch (variant) {
      UgamStatVariant.accent => (c.accentFill, c.accent),
      UgamStatVariant.good => (c.goodFill, c.good),
      UgamStatVariant.warm => (c.warmFill, c.warm),
      UgamStatVariant.neutral => (c.cardElev, c.ink2),
    };

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      radius: UgamRadius.stat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: iconFg),
          ),
          const SizedBox(height: UgamSpacing.sm),
          RichText(
            text: TextSpan(
              style: UgamText.numLg.copyWith(color: c.ink),
              children: [
                TextSpan(text: value),
                if (ofTotal != null)
                  TextSpan(
                    text: ofTotal,
                    style: UgamText.body.copyWith(
                      color: c.ink2,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
        ],
      ),
    );
  }
}
