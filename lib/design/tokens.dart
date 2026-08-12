import 'package:flutter/material.dart';

/// Design tokens for the Ugam UI system — futuristic-simple rebuild.
///
/// Single source of truth for color, radius, spacing, and motion. The brand
/// is a single **cabin-lamp amber** accent on **warm charcoal** neutrals. The
/// look is futuristic and minimal: soft surfaces that float on near-black,
/// depth from light (a quiet amber `glow`) rather than borders. Dark is the
/// primary mode; light is a clean mirror.
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
  /// [UgamColorSet.onAccent] text on the warm charcoal ground.
  static const Color amber = Color(0xFFFFC24B);

  /// Deeper amber — the accent in light mode, where the bright cut would fail
  /// contrast as ink on white.
  ///
  /// Darkened from `B07100` to clear AA in BOTH of its roles, which the old
  /// value did in neither: as ink on `accentFill` it measured 3.67:1, and as
  /// the solid button ground under white it measured 4.03:1. Now 4.57:1 and
  /// 5.03:1 respectively. Guarded by test/design/color_contrast_test.dart.
  static const Color amberDeep = Color(0xFF9B6300);
}

class UgamColors {
  const UgamColors._();

  /// **Midnight** — the dark ground: a WARM charcoal, not a blue one.
  ///
  /// The ground is brown-black (the coach cabin's dark), so the cabin-lamp
  /// [Brand.amber] reads as the same family rather than an alien hue dropped on
  /// navy. Every neutral below sits on the same warm axis; the semantic colours
  /// (mint/rose/red) stay as they were, because they must NOT blend in.
  ///
  /// HISTORY: this was a deep indigo `#0C111F` (2026-08-01, seeded from the
  /// Ola/Uber tokens). Rejected on device — the blue ground competed with the
  /// amber, so the accent stopped reading as "this is yours". Re-grounded warm
  /// against Rapido. The luminance ladder was matched to the old one on
  /// purpose, so every existing ink/ground contrast ratio carries over.
  static const UgamColorSet dark = UgamColorSet(
    bg: Color(0xFF12100E), // Warm charcoal ground — never pure black
    // TONAL ELEVATION. In Midnight these two steps ARE the depth — the shadow
    // scale is deliberately almost nothing there (see [UgamElevation]). Lifted
    // from #1C1917 / #272220, which sat 1.09:1 and 1.16:1 on the ground: too
    // close to separate on their own, which is what drove the first attempt to
    // fake depth with heavy black shadows and pool a smudge around every card.
    // Now 1.16:1 and 1.32:1 — a card reads as lifted with no shadow at all.
    card: Color(0xFF221E1B), // Floating surface — 1.16:1 on bg
    cardElev: Color(0xFF2E2925), // Elevated surface — 1.32:1 on bg
    border: Color(0x24FFFFFF), // White @ 14% — the real edge in Midnight
    ink: Color(0xFFF7F3EE), // Near-white with a warm cast
    ink2: Color(0xFFA19A93), // Secondary — 7.2:1 on bg
    // Lifted with `card`/`cardElev`: the tonal-elevation change made every
    // surface lighter, which quietly cost tertiary text 3.07:1 -> 2.90:1 on a
    // card. Back to 3.22:1 on card / 3.69:1 on bg.
    ink3: Color(0xFF756C64), // Tertiary / meta
    accent: Brand.amber, // "Yours" — the berth you picked. Nothing else.
    accentFill: Color(0x24FFC24B), // ~14% amber, tonal surfaces
    glow: Color(0x4DFFC24B), // ~30% amber — soft halos
    action: Color(0xFFF7F3EE), // The button: max contrast, no brand hue
    onAction: Color(0xFF12100E), // Ground-coloured ink on the button
    good: Color(0xFF4ADE9A), // Mint — money received
    goodFill: Color(0x224ADE9A),
    warm: Color(0xFFF58BB8), // Rose — a lady is seated here
    // 16% -> 14%. The fill composites over `card`, so lifting the card lifted
    // this too and pushed `ink2` on it to 4.42:1, just under AA. At 14% it is
    // 4.62:1 and the rose still reads at 5.66:1.
    warmFill: Color(0x24F58BB8),
    danger: Color(0xFFFF6B60), // Red — something needs you
    dangerFill: Color(0x29FF6B60),
    onAccent: Color(0xFF1A1200), // Near-black ink on amber
  );

  /// **Daylight** — the light ground. White page with grey surfaces sitting ON
  /// it (the Uber/Ola arrangement), not white cards floating on grey. Holds up
  /// on a phone in Gujarat sun.
  ///
  /// SURFACE SEPARATION (2026-08-12): `card` was `#FAFAFA` and measured
  /// **1.04:1** against the white page — functionally invisible, so every
  /// screen read as one flat plane and light mode looked like a wireframe next
  /// to dark (which fakes depth with the amber glow + a visible hairline).
  /// The two surfaces were re-cut on the warm neutral axis the dark set already
  /// uses — no new hue, just the same brown-black cast the cabin-lamp amber
  /// lives in — and now measure:
  ///
  /// * `card` vs `bg`      — 1.04:1 → **1.13:1**
  /// * `cardElev` vs `card`— 1.07:1 → **1.12:1**
  /// * `cardElev` vs `bg`  — 1.12:1 → **1.27:1**
  ///
  /// Ink stays well clear of AA on both (`ink` 16.6:1 / 14.8:1, `ink2`
  /// 5.50:1 / 4.90:1) — guarded by test/design/color_contrast_test.dart. The
  /// rest of the depth comes from [UgamElevation], not from darkening further.
  static const UgamColorSet light = UgamColorSet(
    bg: Color(0xFFFFFFFF), // White page
    card: Color(0xFFF4F1EC), // Warm off-white surface — 1.13:1 on the page
    cardElev: Color(0xFFE9E4DC), // Elevated surface — 1.12:1 on `card`
    border: Color(0x1C000000), // Black @ 11% — hairline, not shadow
    ink: Color(0xFF111214), // Near-black ink
    ink2: Color(0xFF5E6169), // Readable secondary
    // Darkened with `card`/`cardElev`, exactly as the Midnight `ink3` was. The
    // surface lift cost tertiary text contrast on the very surfaces it sits on:
    // #8E939B measured 2.96:1 on the OLD #FAFAFA card (already marginal), then
    // 2.74:1 on the new card and 2.44:1 on cardElev — under the 3:1 floor for
    // meta text. Now 3.48:1 on card, 3.10:1 on cardElev, 3.92:1 on the page.
    //
    // NOTE FOR ANY FUTURE SURFACE CHANGE: `ink3` is the first thing that breaks
    // when a light surface darkens, because it is the closest ink to the ground.
    // Re-measure it on card AND cardElev, not just on bg — bg is the most
    // forgiving of the three and passing there proves nothing.
    ink3: Color(0xFF7C8189), // Tertiary / meta — 3.48:1 on card
    accent: Brand.amberDeep, // Deep amber — legible as ink on white
    accentFill: Color(0xFFFFF3DC), // Pale amber tint
    glow: Color(0x33B07100), // ~20% amber halo
    action: Color(0xFF111214), // The button: near-black, no brand hue
    onAction: Color(0xFFFFFFFF), // White ink on the button
    // Both inks darkened to clear AA when painted on their OWN tonal fill —
    // the shape the app actually uses them in (money pills, status strips,
    // caveats). Was 2.86:1 (good) and 3.63:1 (warm); now 4.60:1 and 4.56:1.
    good: Color(0xFF117C38),
    goodFill: Color(0xFFDCF5E5),
    warm: Color(0xFFA94375), // Rose — a lady is seated here
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

/// Elevation scale — the app's **depth**, resolved per theme exactly like
/// [UgamColors].
///
/// Before this existed the entire app carried eleven hand-rolled [BoxShadow]s
/// across 42k lines, so every surface sat at the same optical height and the
/// UI read as a wireframe: a flat plane of rounded rectangles. Depth is what
/// separates a wireframe from an interface.
///
/// Three levels only. Resist adding a fourth — an elevation scale stops
/// communicating hierarchy the moment it has more steps than the eye can rank:
///
/// * [UgamElevationSet.flat] — flush with the page. Rows, strips, inline
///   chips: things that ARE the page, not things ON it.
/// * [UgamElevationSet.rest] — a card at rest, lifted just off the page.
///   Applied for the whole app by [UgamCard].
/// * [UgamElevationSet.raised] — a sheet, modal or dialog floating clearly
///   above everything, paired with [UgamElevationSet.scrim]. Applied by
///   `UgamSheet`.
///
/// The two themes need genuinely different shadows, which is why this is a
/// resolved set and not a constant. On **Daylight** the shadow is the only
/// depth cue there is, so it is soft, low-alpha and tinted warm (a neutral
/// grey-blue shadow would fight the warm neutrals). On **Midnight** black
/// alpha barely registers against a near-black ground, so the shadows are
/// deeper and much larger — they read as a vignette that separates the lighter
/// card from the darker page, reinforcing the hairline [UgamColorSet.border]
/// that already does half this job.
///
/// Usage mirrors colours, so call sites stay one line:
/// ```dart
/// final e = UgamElevation.of(context);
/// BoxDecoration(color: c.card, boxShadow: e.rest);
/// ```
class UgamElevation {
  const UgamElevation._();

  // Every Daylight shadow is tinted `1A1200` — the warm near-black already in
  // the palette as the dark set's `onAccent`. A neutral grey shadow under a
  // warm neutral surface reads as dirt; this one reads as shade.
  //
  // Level 1 — Daylight. Two layers: a 1px contact edge that defines the shape,
  // and a soft ambient lift that gives it height.
  static const List<BoxShadow> _restLight = [
    BoxShadow(
      color: Color(0x0F1A1200), // warm black @ 6%
      offset: Offset(0, 1),
      blurRadius: 2,
    ),
    BoxShadow(
      color: Color(0x1A1A1200), // warm black @ 10%
      offset: Offset(0, 4),
      blurRadius: 12,
      spreadRadius: -2,
    ),
  ];

  // Level 2 — Daylight. The wide layer is deliberately offset-free so a bottom
  // sheet, whose only visible edge is its TOP, still casts upward. A purely
  // downward shadow would fall off the bottom of the screen and the sheet
  // would look pasted on.
  static const List<BoxShadow> _raisedLight = [
    BoxShadow(
      color: Color(0x1F1A1200), // warm black @ 12%
      offset: Offset(0, 2),
      blurRadius: 8,
      spreadRadius: -1,
    ),
    BoxShadow(
      color: Color(0x2E1A1200), // warm black @ 18%
      offset: Offset(0, 0),
      blurRadius: 34,
      spreadRadius: -6,
    ),
  ];

  // Level 1 — Midnight. Pure black, heavier and wider: on a #12100E ground a
  // 10% shadow is invisible, so these carry 3-4x the alpha of their Daylight
  // counterparts.
  // Level 1 — Midnight.
  //
  // DELIBERATELY ALMOST NOTHING. Depth in dark mode comes from the surface
  // being LIGHTER than the ground (tonal elevation), not from a darker shadow.
  // This is the one rule that separates a dark theme from an inverted light
  // theme: on a near-black page a drop shadow is either invisible, or — pushed
  // hard enough to see — a dirty halo pooling around every card.
  //
  // HISTORY: this shipped at 36% + 28% black and did exactly that. Every card
  // on the dashboard sat in a visible smudge. The fault was compensating for
  // weak tonal separation with shadow instead of fixing the separation, so the
  // `card`/`cardElev` steps in [UgamColors.dark] were lifted at the same time
  // this was cut. If depth ever looks insufficient in Midnight, lift the
  // surface token — do NOT bring the alpha back.
  static const List<BoxShadow> _restDark = [
    BoxShadow(
      color: Color(0x1F000000), // black @ 12% — softens the edge, nothing more
      offset: Offset(0, 1),
      blurRadius: 3,
      spreadRadius: -1,
    ),
  ];

  // Level 2 — Midnight. A sheet genuinely floats above the page, so it earns a
  // real shadow — but it is a soft ambient pool, not a hard cast, and it is
  // still far below what a light-mode sheet needs.
  static const List<BoxShadow> _raisedDark = [
    BoxShadow(
      color: Color(0x3D000000), // black @ 24%
      offset: Offset(0, 2),
      blurRadius: 10,
      spreadRadius: -2,
    ),
    BoxShadow(
      color: Color(0x2E000000), // black @ 18%
      offset: Offset(0, 0),
      blurRadius: 30,
      spreadRadius: -10,
    ),
  ];

  static const List<BoxShadow> _flat = <BoxShadow>[];

  static const UgamElevationSet dark = UgamElevationSet(
    flat: _flat,
    rest: _restDark,
    raised: _raisedDark,
    // 60% black. The old scrim was the Cupertino/Material default (20-32%),
    // which left the page behind an open sheet fully bright and legible — the
    // sheet read as another card rather than as a layer above everything.
    scrim: Color(0x99000000),
  );

  static const UgamElevationSet light = UgamElevationSet(
    flat: _flat,
    rest: _restLight,
    raised: _raisedLight,
    scrim: Color(0x8C000000), // 55% black
  );

  static UgamElevationSet of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

@immutable
class UgamElevationSet {
  /// Level 0 — no shadow. Named so "this is deliberately flush" is expressible
  /// rather than being an unexplained `null`.
  final List<BoxShadow> flat;

  /// Level 1 — a card at rest on the page.
  final List<BoxShadow> rest;

  /// Level 2 — a sheet / modal / dialog above the page.
  final List<BoxShadow> raised;

  /// The modal barrier painted under a level-2 surface. Platform guidance puts
  /// this at 40-60% black; anything lighter and the page behind stays legible,
  /// which is what made sheets read as flat.
  final Color scrim;

  const UgamElevationSet({
    required this.flat,
    required this.rest,
    required this.raised,
    required this.scrim,
  });
}

/// Over-photo scrims and ink — the ONE token group that is deliberately
/// **theme-independent**.
///
/// The customer tour list and tour detail screens lay text and chrome directly
/// on ARBITRARY USER-UPLOADED PHOTOS. Contrast there cannot come from
/// [UgamColors], because the surface underneath is not a surface the app
/// chose: it may be a white marble lobby or a night sky, and the app finds out
/// at runtime. The only thing that makes white ink legible on an unknown image
/// is a scrim the app paints itself.
///
/// **Why these do not resolve per theme.** Every other colour here is a
/// [UgamColorSet] field because the ground changes between Daylight and
/// Midnight. A photograph does not: it is exactly as bright in light mode as
/// in dark. Darkening the scrim in dark mode would be compensating for a
/// change that did not happen, and lightening it in light mode would destroy
/// the contrast the scrim exists to create. So these are plain constants — the
/// static shape IS the documentation.
///
/// **Not [UgamElevationSet.scrim].** That is the modal barrier: the veil under
/// a sheet or dialog, sized to kill legibility of the page behind it, and it
/// resolves per theme (55% / 60%). These are the opposite job — a gradient
/// that must PRESERVE the photo while rescuing the ink on top of it. Reaching
/// for the barrier token over a photo is the mistake this group exists to
/// prevent.
///
/// ```dart
/// // gradient wash over a hero image
/// LinearGradient(colors: [UgamOnPhoto.scrim, UgamOnPhoto.scrimNone])
/// // pill/badge sitting on the image
/// BoxDecoration(color: UgamOnPhoto.chip)
/// Text(label, style: UgamText.caption.copyWith(color: UgamOnPhoto.ink))
/// ```
class UgamOnPhoto {
  const UgamOnPhoto._();

  /// Black @ 55% — the dense end of a gradient wash, under the heaviest ink
  /// (a title, a back button) at the top of an image.
  static const Color scrim = Color(0x8C000000);

  /// Black @ 40% — the lighter end of a two-sided wash, under the ink at the
  /// BOTTOM of an image where less type sits.
  static const Color scrimSoft = Color(0x66000000);

  /// The fade stop of any of the above. Identical in value to
  /// `Colors.transparent`; it exists so a scrim gradient reads as one token
  /// family end-to-end instead of half tokens and half framework constant.
  static const Color scrimNone = Color(0x00000000);

  /// Black @ 60% — a solid pill/badge fill on the image. Stronger than
  /// [scrim] because it is a small opaque-looking shape carrying its own
  /// ink, not a wash that must let the photo through.
  static const Color chip = Color(0x99000000);

  /// Black @ 45% — the circular chrome control (back / share / favourite)
  /// floating on the image. Lighter than [chip]: it holds a single glyph, and
  /// its round shape reads at a lower fill.
  static const Color chrome = Color(0x73000000);

  /// The ONLY ink for anything sitting on the above. Pure white, never a
  /// theme ink: `c.ink` inverts between themes and would go near-black on a
  /// photo in Daylight.
  static const Color ink = Color(0xFFFFFFFF);
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
  /// Page transitions. Was 140ms, which is below the threshold where a
  /// push/pop reads as spatial movement at all — it registered as a web-style
  /// fade cut, not as a screen arriving. 260ms is inside the native band
  /// (iOS ≈ 350ms, Material ≈ 300ms) while staying fast enough for an
  /// operational tool where an agent pushes a dozen screens a minute.
  static const Duration route = Duration(milliseconds: 260);
  static const Duration shimmer = Duration(milliseconds: 900);
  static const Duration snackbar = Duration(milliseconds: 3200);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeIn = Curves.easeInCubic;
}
