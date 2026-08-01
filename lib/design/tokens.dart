import 'package:flutter/material.dart';

/// Design tokens for the Ugam UI system — futuristic-simple rebuild.
///
/// Single source of truth for color, radius, spacing, and motion. The brand
/// is a single **warm copper** accent on **cool graphite** neutrals. The look
/// is futuristic and minimal: soft surfaces that float on near-black, depth
/// from light (a quiet copper `glow`) rather than borders. Dark is the primary
/// mode; light is a clean mirror.
///
/// Density: this is an operational tool — an agent scans status across many
/// tours and acts fast, so the app is tuned for a **glanceable cockpit**, not a
/// spacious showroom. The spacing scale's top steps are compressed and corners
/// are crisp (16, not 22) so more of what needs action fits above the fold.
/// Hierarchy comes from contrast + the rationed copper accent, not from air.
///
/// Re-skinning the whole app = editing the two [Brand] seeds + the two color
/// sets below. No component references raw colors — they read
/// `UgamColors.of(context)`.

/// Brand seed palette — the ONE place brand color is defined.
///
/// The accent is a **cabin-lamp amber**, and it has exactly one job: it means
/// **"this is yours"** — the berth you picked, the leg you chose, your row in a
/// list. It is deliberately NOT the button colour. Every reference app checked
/// (Uber's `buttonPrimaryFill` is literally `#000000`; Ola's brand is green and
/// its booking button is still black) spends the brand hue on meaning, not on
/// the primary control. See [UgamColorSet.action].
class Brand {
  const Brand._();

  /// Cabin-lamp amber (dark mode). Bright enough to carry near-black
  /// [UgamColorSet.onAccent] text on the indigo ground.
  static const Color amber = Color(0xFFFFC24B);

  /// Deeper amber — the accent in light mode, where the bright cut would fail
  /// contrast as ink on white.
  static const Color amberDeep = Color(0xFFB07100);
}

class UgamColors {
  const UgamColors._();

  /// **Midnight** — the dark ground. Indigo is the coach window at night;
  /// amber is the cabin lamp. Readable at 2am without the glare a white chart
  /// throws.
  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF0C111F), // Deep indigo ground — never pure black
    card: Color(0xFF141A2B), // Floating surface
    cardElev: Color(0xFF1F2740), // Elevated surface
    border: Color(0x1AFFFFFF), // White @ 10% — hairline, not shadow
    ink: Color(0xFFEDF1FA), // Near-white with a cool cast
    ink2: Color(0xFF959EBA), // Secondary
    ink3: Color(0xFF5C6584), // Tertiary / meta
    accent: Brand.amber, // "Yours" — the berth you picked. Nothing else.
    accentFill: Color(0x24FFC24B), // ~14% amber, tonal surfaces
    glow: Color(0x4DFFC24B), // ~30% amber — soft halos
    action: Color(0xFFEDF1FA), // The button: max contrast, no brand hue
    onAction: Color(0xFF0C111F), // Ground-coloured ink on the button
    good: Color(0xFF4ADE9A), // Mint — money received
    goodFill: Color(0x224ADE9A),
    warm: Color(0xFFF58BB8), // Rose — a lady is seated here
    warmFill: Color(0x29F58BB8),
    danger: Color(0xFFFF6B60), // Red — something needs you
    dangerFill: Color(0x29FF6B60),
    onAccent: Color(0xFF1A1200), // Near-black ink on amber
  );

  /// **Daylight** — the light ground. White page with grey surfaces sitting ON
  /// it (the Uber/Ola arrangement), not white cards floating on grey. Holds up
  /// on a phone in Gujarat sun.
  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFFFFFF), // White page
    card: Color(0xFFFAFAFA), // Surface sits on the page, slightly darker
    cardElev: Color(0xFFF1F2F3), // Elevated surface
    border: Color(0x1C000000), // Black @ 11% — hairline, not shadow
    ink: Color(0xFF111214), // Near-black ink
    ink2: Color(0xFF5E6169), // Readable secondary
    ink3: Color(0xFF8E939B), // Tertiary / meta
    accent: Brand.amberDeep, // Deep amber — legible as ink on white
    accentFill: Color(0xFFFFF3DC), // Pale amber tint
    glow: Color(0x33B07100), // ~20% amber halo
    action: Color(0xFF111214), // The button: near-black, no brand hue
    onAction: Color(0xFFFFFFFF), // White ink on the button
    good: Color(0xFF16A34A),
    goodFill: Color(0xFFDCF5E5),
    warm: Color(0xFFC24D86), // Rose — a lady is seated here
    warmFill: Color(0xFFF8E2EC),
    danger: Color(0xFFC81E1E),
    dangerFill: Color(0xFFF9E3E1),
    onAccent: Color(0xFFFFFFFF), // White ink on deep amber
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
  /// The one signal colour: **"this is yours."** The berth you picked, the leg
  /// you chose, your row in a list. It is NOT the button — see [action].
  final Color accent;
  final Color accentFill;

  /// The primary control fill — always maximum contrast against [bg] and
  /// deliberately carrying NO brand hue.
  ///
  /// This is the mechanism that makes the reference apps read premium rather
  /// than any particular colour: Uber's `buttonPrimaryFill` is `#000000`, and
  /// Ola ships a black booking button despite a green brand. Spending the
  /// accent on the button is what makes a UI read cheap, because then nothing
  /// on screen is left to carry meaning.
  final Color action;

  /// Ink on [action].
  final Color onAction;

  /// Soft copper halo — radial glow behind hero figures and the drop-shadow
  /// under the primary button. The signature flourish of the futuristic look.
  final Color glow;
  final Color good;
  final Color goodFill;
  final Color warm;
  final Color warmFill;
  final Color danger;

  /// Tonal danger surface — the background under danger-inked text/badges.
  /// Use instead of `danger.withValues(alpha: …)`, which drifts per call site.
  final Color dangerFill;
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
    required this.action,
    required this.onAction,
    required this.glow,
    required this.good,
    required this.goodFill,
    required this.warm,
    required this.warmFill,
    required this.danger,
    required this.dangerFill,
    required this.onAccent,
  });
}

/// Radius scale — crisp/precise for the operational look. Corners read as a
/// tool (16), not a toy (22). Reshaped app-wide from here: every [UgamCard],
/// sheet, stat tile and row derives its radius from these tokens.
class UgamRadius {
  const UgamRadius._();

  static const double card = 16; // was 22 — precise, not soft
  static const double photo = 16;
  static const double input = 14;
  static const double button = 16;
  static const double chip = 999; // pill
  static const double iconBtn = 999; // circle when w==h
  static const double sheet = 22; // was 28
  static const double stat = 16; // was 20
  static const double row = 14; // was 18
  static const double seat = 14;
}

/// Spacing scale. Default lateral gutter is 14; default section rhythm 16.
///
/// The lower half (xs..lg) is the fine detail inside components and is left
/// untouched. The upper half (xl..huge3) — section seams, card padding, hero
/// spacing — was compressed in the density pass so screens stop feeling like a
/// showroom: `xl` now equals `lg` (16) rather than 20, and the very-large steps
/// shrink proportionally. Where a screen wants a truly tight 12px seam it uses
/// [md] directly.
class UgamSpacing {
  const UgamSpacing._();

  static const double xs = 4;
  static const double sm = 8;

  /// The `sm + 2` idiom, named. Appears 15+ times across 6 screens as an
  /// ad-hoc "slightly looser than sm" step — use this instead of the sum.
  static const double tight = 10;
  static const double md = 12;
  static const double gutter = 14;
  static const double lg = 16;

  // NOTE: xl == lg (16); prefer lg. This is deliberate (the density pass
  // compressed xl from 20 down to 16), NOT a distinct scale step. Correcting
  // it would shift every `xl` call site app-wide, so it stays as-is.
  static const double xl = 16; // was 20 — section seams / card padding
  static const double xxl = 20; // was 24
  static const double huge = 26; // was 32
  static const double huge2 = 32; // was 40
  static const double huge3 = 44; // was 56

  /// Badge / micro-chip padding — the 6×2 geometry `UgamReqChip` already
  /// ships, named so the ~12 hand-rolled badges across 8 screens stop
  /// inventing their own.
  static const double badgeH = 6;
  static const double badgeV = 2;

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
