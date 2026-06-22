import 'package:flutter/material.dart';

/// Typography for the Ugam UI — futuristic-simple rebuild.
///
/// Two families, both bundled as variable TTFs (no `google_fonts` runtime
/// fetch): **Sora** carries the display voice — big calm hero figures, section
/// titles, numerals and micro-labels — and **Inter** carries body / small UI
/// text where its tighter metrics read better at size. Numeric styles set
/// `FontFeature.tabularFigures()` so counts and prices line up. Apply colour
/// at the call site via `.copyWith(color: ...)`.
class UgamText {
  const UgamText._();

  static const String _display = 'Sora';
  static const String _body = 'Inter';

  // ── Hero figure — the dashboard centrepiece. Sora Light, very large; set
  //    the size at the call site (e.g. 56–60). Calm, futuristic. ──
  static const TextStyle hero = TextStyle(
    fontFamily: _display,
    fontSize: 56,
    fontWeight: FontWeight.w300,
    letterSpacing: -2.0,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // ── Display / page titles — Sora, medium weight, clean and wide. ──
  static const TextStyle display = TextStyle(
    fontFamily: _display,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.06,
  );

  static const TextStyle titleXl = TextStyle(
    fontFamily: _display,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.12,
  );

  static const TextStyle titleL = TextStyle(
    fontFamily: _display,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.16,
  );

  static const TextStyle titleM = TextStyle(
    fontFamily: _display,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.22,
  );

  static const TextStyle titleS = TextStyle(
    fontFamily: _display,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  // ── Body — Inter. ──
  static const TextStyle body = TextStyle(
    fontFamily: _body,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: _body,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.45,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: _body,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// UPPERCASE labels — section eyebrows / micro-labels, in clean Sora caps.
  static const TextStyle micro = TextStyle(
    fontFamily: _display,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    height: 1.2,
  );

  // ── Numeric (tabular figures) — Sora. ──
  static const TextStyle numLg = TextStyle(
    fontFamily: _display,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.05,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle numXl = TextStyle(
    fontFamily: _display,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Convert any style to tabular figures while keeping size/weight.
  static TextStyle tabular(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
