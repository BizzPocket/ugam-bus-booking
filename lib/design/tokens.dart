import 'package:flutter/material.dart';

/// Design tokens for the Ugam UI system — Phase 0.
///
/// Single source of truth for color, radius, spacing, and motion values.
/// Per the design system spec, the entire app can be re-branded by
/// changing one value: `UgamColors.dark.accent` (and the matching
/// `accentFill` derivation).
///
/// Colors are exposed as two static structs — `UgamColors.dark` (primary)
/// and `UgamColors.light` (mirror). Call `UgamColors.of(context)` to get
/// the active set without manually checking brightness.

class UgamColors {
  const UgamColors._();

  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0A0A0A),
    card: Color(0xFF161616),
    cardElev: Color(0xFF1F1F1F),
    border: Color(0xFF2A2A2A),
    ink: Color(0xFFFAFAFA),
    ink2: Color(0xFFA0A0A0),
    ink3: Color(0xFF5E5E5E),
    accent: Color(0xFF3B82F6),
    accentFill: Color(0x293B82F6), // 16% alpha
    good: Color(0xFF34D399),
    goodFill: Color(0x2934D399),
    warm: Color(0xFFFB923C),
    warmFill: Color(0x2EFB923C), // 18% alpha
    danger: Color(0xFFF87171),
    onAccent: Color(0xFFFFFFFF),
  );

  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFBFAF6),
    card: Color(0xFFFFFFFF),
    cardElev: Color(0xFFF2F1EC),
    border: Color(0xFFE8E5DE),
    ink: Color(0xFF111111),
    ink2: Color(0xFF5A5A57),
    ink3: Color(0xFF9A9A95),
    accent: Color(0xFF1746A2),
    accentFill: Color(0xFFEEF2FF),
    good: Color(0xFF16A34A),
    goodFill: Color(0xFFE8F6EC),
    warm: Color(0xFFC2410C),
    warmFill: Color(0xFFFFF1E7),
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

  static const Duration tapIn = Duration(milliseconds: 120);
  static const Duration tapOut = Duration(milliseconds: 180);
  static const Duration tab = Duration(milliseconds: 200);
  static const Duration sheet = Duration(milliseconds: 280);
  static const Duration dock = Duration(milliseconds: 140);
  static const Duration shimmer = Duration(milliseconds: 1200);
  static const Duration snackbar = Duration(milliseconds: 3200);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeIn = Curves.easeInCubic;
}
