import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

enum UgamStatusTone { accent, good, warm, neutral }

/// Inline status indicator: 6 px dot + label. Reserved for ambient
/// state (e.g. `● Collecting`, `● 8 left`). For headline / dominant
/// state, use a chip pill instead.
class UgamStatusDot extends StatelessWidget {
  final String label;
  final UgamStatusTone tone;

  const UgamStatusDot({
    super.key,
    required this.label,
    this.tone = UgamStatusTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final color = switch (tone) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink3,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: UgamText.caption.copyWith(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
