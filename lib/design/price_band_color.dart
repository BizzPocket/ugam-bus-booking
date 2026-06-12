import 'package:flutter/material.dart';

/// Stable, visually-distinct colours for a bus's PRICE BANDS.
///
/// A bus splits its rows into named fare bands (front premium, standard, rear
/// discount, or any explicit row range — see `Bus.priceBands` /
/// `Bus.effectiveBands`). The handler seat chart paints each seat with a faint
/// wash in its band's colour so the rows read as horizontal price stripes, and a
/// band KEY below the grid shows the same colour at full strength next to the
/// band's label and per-person price.
///
/// Bands are indexed by their position in `effectiveBands` (0-based, precedence
/// order), so a given band keeps the same colour across rebuilds and across the
/// grid + key. The palette is a small curated set of hues deliberately spread
/// AWAY from the two trip tints — GO cyan (`kOneWayTint`, ~190°) and RET violet
/// (`kReturnTint`, ~284°) — so a band wash is never mistaken for a trip leg. The
/// wash lives in a different visual channel (a full-tile background) from the
/// thin group/priority RING, so a band colour and a group ring coexist cleanly
/// on the same tile even when their hues are close.
class PriceBandColor {
  const PriceBandColor._();

  /// Curated band hues, ordered so the most common bands (front premium, then
  /// standard) get the most legible colours first. Cycles for unusually many
  /// bands. None sit on the GO-cyan or RET-violet trip hues.
  static const List<Color> _palette = [
    Color(0xFF4F8DF0), // blue       ~215°
    Color(0xFF46C28A), // green      ~155°
    Color(0xFFE86BA6), // pink       ~330°
    Color(0xFFD9A93A), // gold       ~46°
    Color(0xFFE0664F), // coral      ~9°
    Color(0xFF9BC24A), // lime       ~80°
  ];

  /// Full-strength colour for the band at [index] (0-based). Used for the band
  /// KEY swatch. Stable for a given index.
  static Color forIndex(int index) {
    if (_palette.isEmpty) return const Color(0xFF4F8DF0);
    final i = index % _palette.length;
    return _palette[i < 0 ? i + _palette.length : i];
  }
}

/// Full-strength price-band colour for the band at [index]; see [PriceBandColor].
Color priceBandColor(int index) => PriceBandColor.forIndex(index);

/// Alpha used to paint the per-tile band WASH (the faint full-tile background).
/// Kept low so the seat's name, group ring and trip tint stay legible on top.
const double kPriceBandWashAlpha = 0.16;

/// The faint per-tile wash colour for the band at [index] — the full band colour
/// dropped to [kPriceBandWashAlpha]. The seat tile composites this over its card
/// fill so the row reads as a price stripe.
Color priceBandWash(int index) =>
    PriceBandColor.forIndex(index).withValues(alpha: kPriceBandWashAlpha);
