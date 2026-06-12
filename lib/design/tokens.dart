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
/// Brand: **Ugam Foj / DEVAM — Bhedapipaliya Dham** (devam.org). The look
/// is premium and minimal: graphite-neutral surfaces with a single refined
/// **champagne gold** accent — flat, no gradients. Dark mode is the primary
/// mode and lifts the accent to a soft champagne so it glows on graphite;
/// light mode uses a deeper champagne for contrast on the near-white ground.
/// The accent is the only brand-bearing token — neutrals are pure graphite,
/// and `onAccent` is near-black ink (dark-on-gold reads premium and passes
/// contrast where white-on-gold would not).
///
/// Colors are exposed as two static structs — `UgamColors.dark` (primary)
/// and `UgamColors.light` (mirror). Call `UgamColors.of(context)` to get
/// the active set without manually checking brightness.

/// Brand seed palette — the ONE place brand color is defined. Everything
/// downstream (the two color sets, the Material theme, every component)
/// resolves from these. The brand is carried by a single refined
/// **champagne gold** accent on graphite neutrals. To re-brand the whole
/// app, edit these two values.
class Brand {
  const Brand._();

  /// Dark-mode accent — electric lime. The single high-energy SIGNAL color of
  /// the Bold-Transit DNA; bright enough to carry BLACK text
  /// (see [UgamColorSet.onAccent]) for the signature lime-on-black look.
  static const Color signal = Color(0xFFC6F432);

  /// Light-mode accent — deeper lime, for legibility as text/icons on the
  /// white ground; also carries black text on its fills.
  static const Color signalDeep = Color(0xFF65A30D);
}

class UgamColors {
  const UgamColors._();

  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0A0A0A),          // True near-black — stark transit ground
    card: Color(0xFF141414),        // Lifted black tile, reads as a distinct card
    cardElev: Color(0xFF1E1E1E),    // Elevated surface
    border: Color(0xFF2A2A2A),      // Crisp neutral hairline = defined edges
    ink: Color(0xFFFFFFFF),         // Pure white — maximum contrast
    ink2: Color(0xFFA1A1AA),        // Secondary (cool gray)
    ink3: Color(0xFF6B6B72),        // Tertiary / meta
    accent: Brand.signal,           // Electric lime — the one signal color
    accentFill: Color(0x24C6F432),  // ~14% lime, for tonal surfaces
    good: Color(0xFF34D399),        // Emerald — paid / success
    goodFill: Color(0x2934D399),
    warm: Color(0xFFFFB020),        // Amber — attention / ladies
    warmFill: Color(0x2EFFB020),
    danger: Color(0xFFFF453A),      // Vivid red
    onAccent: Color(0xFF0A0A0A),    // BLACK ink on lime — the signature look
  );

  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFFFFFF),          // Stark white ground
    card: Color(0xFFFFFFFF),        // White cards
    cardElev: Color(0xFFF4F4F5),    // Soft elevated surface
    border: Color(0xFFE4E4E7),      // Neutral hairline
    ink: Color(0xFF0A0A0A),         // Near-black ink — max contrast on white
    ink2: Color(0xFF52525B),        // Readable secondary (AA)
    ink3: Color(0xFFA1A1AA),        // Tertiary / meta
    accent: Brand.signalDeep,       // Deeper lime — legible as text/icons on white
    accentFill: Color(0x1F84CC16),  // Pale lime tint behind accent chips/icons
    good: Color(0xFF059669),
    goodFill: Color(0xFFD1FAE5),
    warm: Color(0xFFB45309),        // Amber — attention / ladies
    warmFill: Color(0xFFFEF3C7),
    danger: Color(0xFFDC2626),
    onAccent: Color(0xFF0A0A0A),    // Black ink on lime fills
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

  static const double card = 16;
  static const double photo = 12;
  static const double input = 10;
  static const double chip = 999; // pill
  static const double iconBtn = 999; // circle when w==h
  static const double sheet = 20;
  static const double stat = 12;
  static const double row = 12;
  static const double seat = 6;
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
