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
        // Long labels (e.g. a full status description) must ellipsize within
        // the available width rather than overflow the row. All call sites pass
        // bounded width, so Flexible is safe here.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            // Ladder step: [UgamText.caption] (Inter 12/w500), taken up to
            // w600 for the semibold status voice.
            //
            // This carried a raw `fontSize: 11` — an off-ladder size, inside
            // the design system itself. There is no Inter step at 11: the
            // ladder runs caption 12 → micro 10, and micro is Sora UPPERCASE
            // with 1.4 tracking, which is a section-eyebrow voice, not a
            // sentence-case status label. So caption (one px up, same family,
            // same voice) is the only defensible step; 10 would have changed
            // the typeface and the casing to save one pixel.
            //
            // The +1px is safe at every call site: the label is [Flexible]
            // with `overflow: ellipsis`, so it re-fits rather than overflows.
            // When the wanted `captionStrong` step lands in the typography
            // pass, this becomes `UgamText.captionStrong.copyWith(color:)`.
            style: UgamText.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
