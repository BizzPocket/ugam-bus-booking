import 'package:flutter/material.dart';

/// Design tokens for the Ugam UI system — futuristic-simple rebuild.
///
/// Single source of truth for color, radius, spacing, and motion. The brand
/// is a single **warm copper** accent on **cool graphite** neutrals. The look
/// is futuristic and minimal: soft surfaces that float on near-black, depth
/// from light (a quiet copper `glow`) rather than borders, big calm type, and
/// generous space. Dark is the primary mode; light is a clean mirror.
///
/// Re-skinning the whole app = editing the two [Brand] seeds + the two color
/// sets below. No component references raw colors — they read
/// `UgamColors.of(context)`.

/// Brand seed palette — the ONE place brand color is defined.
class Brand {
  const Brand._();

  /// Primary copper accent (dark mode). Bright enough to glow on graphite and
  /// to carry near-black [UgamColorSet.onAccent] text.
  static const Color copper = Color(0xFFD8966A);

  /// Deeper copper — the bottom stop of the primary-button gradient, and the
  /// accent in light mode (legible on the bright ground).
  static const Color copperDeep = Color(0xFFC07E50);
}

class UgamColors {
  const UgamColors._();

  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0C0D10),          // Cool near-black ground
    card: Color(0xFF15171C),        // Soft floating surface (no border needed)
    cardElev: Color(0xFF1E2128),    // Elevated surface
    border: Color(0x0FFFFFFF),      // White @ ~6% — used sparingly
    ink: Color(0xFFF5F6F8),         // Near-white
    ink2: Color(0xFF9A9DA7),        // Secondary
    ink3: Color(0xFF5C5F69),        // Tertiary / meta
    accent: Brand.copper,           // Warm copper — the one signal color
    accentFill: Color(0x24D8966A),  // ~14% copper, tonal surfaces
    glow: Color(0x4DD8966A),        // ~30% copper — soft halos + button shadow
    good: Color(0xFF4ADE9A),        // Mint — paid / success
    goodFill: Color(0x224ADE9A),
    warm: Color(0xFFE98AB4),        // Rose — attention / ladies (distinct)
    warmFill: Color(0x29E98AB4),
    danger: Color(0xFFFF5247),      // Vivid red
    onAccent: Color(0xFF1A0E07),    // Near-black ink on copper
  );

  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFF6F7F9),          // Clean bright ground
    card: Color(0xFFFFFFFF),        // White surface
    cardElev: Color(0xFFEEF0F4),    // Soft elevated surface
    border: Color(0x0F000000),      // Black @ ~6%
    ink: Color(0xFF14161B),         // Near-black ink
    ink2: Color(0xFF5A5E68),        // Readable secondary
    ink3: Color(0xFF9A9DA7),        // Tertiary / meta
    accent: Brand.copperDeep,       // Deeper copper — legible on white
    accentFill: Color(0xFFF4E7DC),  // Pale copper tint
    glow: Color(0x38B8703F),        // ~22% copper halo
    good: Color(0xFF0E9E73),
    goodFill: Color(0xFFD8F1E7),
    warm: Color(0xFFC24D86),        // Rose — attention / ladies
    warmFill: Color(0xFFF8E2EC),
    danger: Color(0xFFD7362B),
    onAccent: Color(0xFFFFFFFF),    // Light ink on deep copper
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

  /// Soft copper halo — radial glow behind hero figures and the drop-shadow
  /// under the primary button. The signature flourish of the futuristic look.
  final Color glow;
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
    required this.glow,
    required this.good,
    required this.goodFill,
    required this.warm,
    required this.warmFill,
    required this.danger,
    required this.onAccent,
  });
}

/// Radius scale — rounder/softer for the futuristic-simple look.
class UgamRadius {
  const UgamRadius._();

  static const double card = 22;
  static const double photo = 16;
  static const double input = 14;
  static const double button = 16;
  static const double chip = 999; // pill
  static const double iconBtn = 999; // circle when w==h
  static const double sheet = 28;
  static const double stat = 20;
  static const double row = 18;
  static const double seat = 14;
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

  /// Bottom padding for scrollables whose content scrolls under the floating
  /// dock (≈ 80px + safe-area). Use instead of hardcoded 140/120/96.
  static const double dockClearance = 140;
}

/// Motion durations. Curves live alongside them.
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
