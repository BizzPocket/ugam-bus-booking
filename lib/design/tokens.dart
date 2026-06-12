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

  /// Dark-mode accent — soft champagne gold. Reads premium on graphite and
  /// is light enough to carry near-black text (see [UgamColorSet.onAccent]).
  static const Color champagne = Color(0xFFC9A86A);

  /// Light-mode accent — deeper champagne, for contrast on the near-white
  /// ground; also carries near-black text.
  static const Color champagneDeep = Color(0xFFA8854A);
}

class UgamColors {
  const UgamColors._();

  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0B0B0C),          // Graphite near-black — neutral, faintly cool
    card: Color(0xFF161618),        // Graphite tile, lifted so cards read as distinct
    cardElev: Color(0xFF1F1F22),    // Elevated graphite surface
    border: Color(0xFF2C2C30),      // Crisp neutral hairline = defined edges
    ink: Color(0xFFFAF9F7),         // Clean near-white
    ink2: Color(0xFFA8A29E),        // Secondary text
    ink3: Color(0xFF78716C),        // Tertiary / meta
    accent: Brand.champagne,        // Soft champagne gold — glows on graphite
    accentFill: Color(0x29C9A86A),  // 16% alpha of champagne
    good: Color(0xFF10B981),        // Vibrant Emerald
    goodFill: Color(0x2910B981),
    warm: Color(0xFFF59E0B),        // Vibrant Amber — attention / ladies
    warmFill: Color(0x2EF59E0B),    // 18% alpha
    danger: Color(0xFFEF4444),      // Vibrant Red
    onAccent: Color(0xFF1A1408),    // Near-black ink on champagne (premium, AA contrast)
  );

  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFAFAF8),          // Near-white graphite-tinted ground
    card: Color(0xFFFFFFFF),        // White cards
    cardElev: Color(0xFFF5F4F0),    // Soft elevated surface
    border: Color(0xFFE7E5DF),      // Neutral hairline
    ink: Color(0xFF1C1A17),         // Near-black ink — ~15:1 on the ground
    ink2: Color(0xFF57534E),        // Readable secondary (AA)
    ink3: Color(0xFFA8A29E),        // Tertiary / meta
    accent: Brand.champagneDeep,    // Deeper champagne — brand primary on near-white
    accentFill: Color(0xFFF3ECDD),  // Pale champagne tint behind accent icons/chips
    good: Color(0xFF059669),
    goodFill: Color(0xFFD1FAE5),
    warm: Color(0xFFD97706),        // Amber — attention / ladies
    warmFill: Color(0xFFFEF3C7),
    danger: Color(0xFFDC2626),
    onAccent: Color(0xFF241C12),    // Near-black ink on deep champagne (premium, AA contrast)
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
