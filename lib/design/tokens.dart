import 'package:flutter/material.dart';

/// Design tokens for the Ugam UI system — Phase 0.
///
/// Single source of truth for color, radius, spacing, and motion values.
/// The brand lives in one place: the [Brand] seed constants below. Both
/// the `dark` and `light` color sets reference those seeds by name, so a
/// full re-brand is a matter of editing `Brand` — no component code is
/// ever touched. Per the design system spec, the only brand-bearing
/// token is `accent` (+ its derived `accentFill`).
///
/// Brand: **Ugam Foj / DEVAM — Bhedapipaliya Dham** (devam.org). The
/// brand primary is a dark coffee / espresso brown. Light mode uses the
/// coffee at full strength (white text reads ~13:1); dark mode — the
/// primary mode — uses a lifted mocha of the same brown family so CTAs
/// stay legible on the near-black ground.
///
/// Colors are exposed as two static structs — `UgamColors.dark` (primary)
/// and `UgamColors.light` (mirror). Call `UgamColors.of(context)` to get
/// the active set without manually checking brightness.

/// Brand seed palette — the ONE place brand color is defined. Everything
/// downstream (the two color sets, the Material theme, every component)
/// resolves from these. To re-brand the whole app, edit these values.
class Brand {
  const Brand._();

  /// DEVAM primary — dark coffee / espresso brown. The brand-bearing
  /// accent. Used at full strength as the light-mode accent (white text
  /// on it reads at ~13:1).
  static const Color coffee = Color(0xFF3B2A20);

  /// Lifted mocha/caramel for the dark-mode accent. Pure [coffee] is
  /// near-invisible on the near-black dark background; this raises CTAs to
  /// a legible value while staying unmistakably the same brown family.
  static const Color coffeeBright = Color(0xFFB07A52);

  /// Light-mode accent tint (pale latte) — the soft background behind
  /// accent-coloured icons/chips on the white ground.
  static const Color coffeeFillLight = Color(0xFFEADFD6);

  /// Dark-mode accent tint — 16% alpha of [coffeeBright], a faint warm
  /// wash on near-black.
  static const Color coffeeFillDark = Color(0x29B07A52);

  /// Legacy clay/terracotta seeds — retained for reference; the live accent
  /// is now [coffee] / [coffeeBright].
  static const Color terracotta = Color(0xFFC56A3F);
  static const Color terracottaBright = Color(0xFFE07A4F);

  /// Cream — the light-mode scaffold background (devam.org section ground).
  static const Color cream = Color(0xFFFBF3EC);

  /// Warmer cream for light-mode elevated surfaces / tab-pill backgrounds.
  static const Color creamElev = Color(0xFFF3E8DD);

  /// Warm hairline / border on cream.
  static const Color creamBorder = Color(0xFFE7DACE);

  /// Dark-brown — the light-mode primary ink (footer/text on devam.org).
  static const Color brown = Color(0xFF4A2F25);

  /// Muted brown — light-mode secondary text.
  static const Color brownMuted = Color(0xFF8A6F5F);

  /// Faint brown — light-mode tertiary text / inactive meta.
  static const Color brownFaint = Color(0xFFB29A8C);
}

class UgamColors {
  const UgamColors._();

  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0A0A0A),          // Deep premium dark, not pure black
    card: Color(0xFF1A1A1A),        // Lifted so cards read as distinct, crisp tiles
    cardElev: Color(0xFF2A2A2A),    // More elevated
    border: Color(0xFF404040),      // Brighter hairline = crisp, defined edges
    ink: Color(0xFFFAFAFA),
    ink2: Color(0xFFC4C4C4),        // Clearer secondary text (was muddy #A3A3A3)
    ink3: Color(0xFF969696),        // Clearer tertiary/meta (was dim #737373)
    accent: Brand.coffeeBright,     // Lifted mocha — legible coffee on near-black, holds white text
    accentFill: Brand.coffeeFillDark, // 16% alpha of the mocha primary
    good: Color(0xFF10B981),        // Vibrant Emerald
    goodFill: Color(0x2910B981),
    warm: Color(0xFFF59E0B),        // Vibrant Amber — attention / ladies
    warmFill: Color(0x2EF59E0B),    // 18% alpha
    danger: Color(0xFFEF4444),      // Vibrant Red
    onAccent: Color(0xFFFFFFFF),
  );

  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFFFFFF),          // Pure white ground — no warm cream wash
    card: Color(0xFFFFFFFF),        // White cards (separated by border + shadow)
    cardElev: Color(0xFFF5F5F4),    // Neutral stone-100 elevation (no orange tint)
    border: Color(0xFFE7E5E4),      // Neutral stone-200 hairline
    ink: Brand.brown,               // Dark-brown primary text (brand, near-black)
    ink2: Color(0xFF78716C),        // Neutral stone-500 secondary (was warm tan)
    ink3: Color(0xFFA8A29E),        // Neutral stone-400 tertiary (was warm tan)
    accent: Brand.coffee,           // Dark coffee — the true brand primary, strong on white
    accentFill: Brand.coffeeFillLight, // Pale latte tint
    good: Color(0xFF059669),
    goodFill: Color(0xFFD1FAE5),
    warm: Color(0xFFD97706),        // Amber — attention / ladies
    warmFill: Color(0xFFFEF3C7),
    danger: Color(0xFFDC2626),
    onAccent: Color(0xFFFFFFFF),
  );

  static UgamColorSet of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

@immutable
class UgamColorSet {
  final Color bg;
  final Color card;
  final Color cardElev;
  final Color border;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color accent;
  final Color accentFill;
  final Color good;
  final Color goodFill;
  final Color warm;
  final Color warmFill;
  final Color danger;
  final Color onAccent;

  const UgamColorSet({
    required this.bg,
    required this.card,
    required this.cardElev,
    required this.border,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentFill,
    required this.good,
    required this.goodFill,
    required this.warm,
    required this.warmFill,
    required this.danger,
    required this.onAccent,
  });
}

/// Radius scale. Every rounded surface in the app picks one of these.
class UgamRadius {
  const UgamRadius._();

  static const double card = 22;
  static const double photo = 16;
  static const double input = 14;
  static const double chip = 999; // pill
  static const double iconBtn = 999; // circle when w==h
  static const double sheet = 28;
  static const double stat = 18;
  static const double row = 16;
  static const double seat = 8;
}

/// Spacing scale. Default lateral gutter is 14; default vertical rhythm 20.
class UgamSpacing {
  const UgamSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double gutter = 14;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double huge = 32;
  static const double huge2 = 40;
  static const double huge3 = 56;
}

/// Motion durations. Curves live alongside them so callers don't have to
/// guess which curve goes with which timing.
class UgamMotion {
  const UgamMotion._();

  static const Duration tapIn = Duration(milliseconds: 70);
  static const Duration tapOut = Duration(milliseconds: 100);
  static const Duration tab = Duration(milliseconds: 110);
  static const Duration sheet = Duration(milliseconds: 180);
  static const Duration dock = Duration(milliseconds: 90);
  static const Duration route = Duration(milliseconds: 140);
  static const Duration shimmer = Duration(milliseconds: 900);
  static const Duration snackbar = Duration(milliseconds: 3200);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeIn = Curves.easeInCubic;
}
