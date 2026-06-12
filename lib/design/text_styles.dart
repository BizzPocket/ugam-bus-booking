import 'package:flutter/material.dart';

/// Typography scale for the Ugam UI system — Phase 0.
///
/// Inter is bundled as a variable TTF in `assets/fonts/Inter-Variable.ttf`
/// (registered in pubspec.yaml under `fonts:`), so weights resolve
/// instantly from local storage — no `google_fonts` runtime fetch.
///
/// Numeric styles set `FontFeature.tabularFigures()` so columns of
/// prices, seat counts, and IDs line up vertically. Apply colour at the
/// call site via `.copyWith(color: ...)`; this keeps the styles pure-
/// const and theme-independent.
class UgamText {
  const UgamText._();

  static const String _family = 'Inter';

  // ── Display / page titles ──────────────────────────────────────────
  // Bold-Transit DNA: headings are HEAVY (w800) and tightly tracked for the
  // utilitarian, high-impact transit look. Inter (variable) resolves w800 from
  // the bundled TTF, so no extra font asset is needed.
  static const TextStyle display = TextStyle(
    fontFamily: _family,
    fontSize: 32,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.0,
    height: 1.05,
  );

  static const TextStyle titleXl = TextStyle(
    fontFamily: _family,
    fontSize: 26,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    height: 1.1,
  );

  static const TextStyle titleL = TextStyle(
    fontFamily: _family,
    fontSize: 22,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
    height: 1.15,
  );

  static const TextStyle titleM = TextStyle(
    fontFamily: _family,
    fontSize: 18,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    height: 1.2,
  );

  static const TextStyle titleS = TextStyle(
    fontFamily: _family,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.3,
  );

  // ── Body ───────────────────────────────────────────────────────────
  static const TextStyle body = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: _family,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.4,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: _family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// UPPERCASE labels — section eyebrows, badge text. Wider tracking gives the
  /// "transit signage" feel.
  static const TextStyle micro = TextStyle(
    fontFamily: _family,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    height: 1.2,
  );

  // ── Numeric (tabular figures) — big, heavy hero numbers are core to the
  // Bold-Transit look (departures, counts, money). ───────────────────────────
  static const TextStyle numLg = TextStyle(
    fontFamily: _family,
    fontSize: 20,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
    height: 1.05,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle numXl = TextStyle(
    fontFamily: _family,
    fontSize: 26,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Use to convert any non-numeric style to tabular-figures while
  /// keeping its size and weight (e.g. price + currency in a body row).
  static TextStyle tabular(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
