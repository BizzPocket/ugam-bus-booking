import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';

enum UgamCaveatTone { warm, danger }

/// Contained caveat strip — one short sentence qualifying the figure directly
/// above it ("this is a forecast", "a cost is missing, so this reads high").
///
/// Exists because three money surfaces were each hand-rolling an
/// `Icon + Text` row in warm ink under a headline number. Loose coloured prose
/// at the foot of a stack of grey meta lines is the easiest thing on the card
/// to skim past — which is precisely wrong when the sentence is saying the
/// number cannot be trusted. Giving it a fill and a radius makes it read as a
/// deliberate element with a boundary, and makes every surface state the same
/// kind of thing the same way.
///
/// Deliberately NOT a card: cards never nest (see [UgamCard]), and this always
/// sits inside one.
class UgamCaveat extends StatelessWidget {
  final String message;
  final UgamCaveatTone tone;
  final IconData icon;

  const UgamCaveat({
    super.key,
    required this.message,
    this.tone = UgamCaveatTone.warm,
    this.icon = Icons.warning_amber_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (Color ink, Color fill) = switch (tone) {
      UgamCaveatTone.warm => (c.warm, c.warmFill),
      UgamCaveatTone.danger => (c.danger, c.dangerFill),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: UgamSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nudged down a hair: the glyph's optical centre sits above its box,
          // so a flush top edge reads as floating above the first text line.
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: ink),
          ),
          const SizedBox(width: UgamSpacing.xs + 2),
          Expanded(
            child: Text(
              message,
              // Body ink, not the tone colour: `warm` on `warmFill` is ~4.4:1
              // in Daylight, under AA for text this size, and a fully tinted
              // strip shouted over the very figure it is qualifying. The fill
              // and the glyph carry the signal; the sentence just has to read.
              style: UgamText.micro.copyWith(color: c.ink2, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
