# Ugam UI Design System

Single source of truth for color, typography, spacing, motion, and the
15 `Ugam*` components that every screen is built from. Specced in
[docs/superpowers/specs/2026-05-20-ui-design-system-design.md](../../docs/superpowers/specs/2026-05-20-ui-design-system-design.md).

## Quick start

```dart
import 'package:occubusbooking/design/ugam.dart';

// Tokens
final c = UgamColors.of(context);   // active set (dark or light)
final radius = UgamRadius.card;     // 16 — cockpit density, was 22
final gap = UgamSpacing.lg;         // 16

// Text
Text('Upcoming trips', style: UgamText.titleXl.copyWith(color: c.ink));

// Component
UgamCTA(
  label: 'Open seat map',
  trailingValue: '12 free',
  onPressed: () { /* ... */ },
);
```

## Files

```
lib/design/
├── README.md           — this file
├── ugam.dart           — barrel export, import everything from here
├── tokens.dart         — UgamColors, UgamRadius, UgamSpacing, UgamMotion
├── text_styles.dart    — UgamText scale
├── theme.dart          — UgamTheme.dark() / .light()  (Material ThemeData)
└── components/
    ├── ugam_card.dart           — .plain / .media base card
    ├── ugam_cta.dart            — sticky pill CTA + sticky wrapper
    ├── ugam_date_pill.dart      — horizontal date selector
    ├── ugam_dock_nav.dart       — floating capsule bottom nav
    ├── ugam_empty.dart          — empty state (icon + text + optional CTA)
    ├── ugam_input.dart          — labelled input + phone input
    ├── ugam_request_row.dart    — dense admin row + UgamReqChip
    ├── ugam_route_header.dart   — city-to-city journey header
    ├── ugam_sheet.dart          — bottom sheet wrapper (iOS / Android)
    ├── ugam_skeleton.dart       — shimmer loading placeholder
    ├── ugam_snackbar.dart       — toast content widget
    ├── ugam_stat_tile.dart      — admin stat tile (icon + value + label)
    ├── ugam_status_dot.dart     — ambient status indicator
    └── ugam_tab_pills.dart      — 2-4 segment pill tabs
```

## Re-branding

The entire app's accent flows from **one** token. To ship an orange
variant:

```dart
// tokens.dart — edit the Brand seeds, everything downstream follows
class Brand {
  static const Color amber     = Color(0xFFF97316); // was 0xFFFFC24B (dark accent)
  static const Color amberDeep = Color(0xFFC2410C); // was 0xFFB07100 (light accent)
}
```

Note the accent is **not** the button colour — buttons use `action`
(max contrast, no brand hue). The accent means one thing only:
*"this is yours."*

Run `flutter test --update-goldens` and `git diff test/design/golden/` —
the diff should be colour-only, no layout shifts. That's the proof the
system holds together.

## Adding a new component

1. Create `lib/design/components/ugam_<name>.dart`
2. Import only `../tokens.dart`, `../text_styles.dart`, and other
   components from this directory — never reach into app-level code
3. Consume tokens via `UgamColors.of(context)`, never hardcode hex
4. Use `UgamText.*` styles via `.copyWith(color: ...)` — never inline a
   raw `TextStyle(...)`
5. Add to the barrel in `ugam.dart`
6. Add a golden test under `test/design/golden/ugam_<name>_test.dart` in
   both dark and light

## Migration from the legacy `lib/config/theme.dart`

`AppTheme` / `AppText` / `AppColors` in `lib/config/theme.dart` are
**deprecated** but kept compiling so existing screens still work. Each
phase (1–4) of the redesign migrates a group of screens off the legacy
tokens onto `UgamColors` / `UgamText`. Don't add NEW call sites to the
legacy tokens.

| Legacy | New |
|--------|-----|
| `AppTheme.brand` | `UgamColors.of(context).accent` |
| `AppTheme.cardLight` / `AppTheme.cardDark` | `UgamColors.of(context).card` |
| `AppTheme.bgLight` / `AppTheme.bgDark` | `UgamColors.of(context).bg` |
| `AppTheme.borderLight` / `AppTheme.borderDark` | `UgamColors.of(context).border` |
| `AppTheme.textPrimary` | `UgamColors.of(context).ink` |
| `AppTheme.textSecondary` | `UgamColors.of(context).ink2` |
| `AppTheme.textMuted` | `UgamColors.of(context).ink3` |
| `AppTheme.success` / `.successLight` | `UgamColors.of(context).good` / `.goodFill` |
| `AppTheme.warning` / `.warningLight` | `UgamColors.of(context).warm` / `.warmFill` |
| `AppTheme.danger` / `.dangerLight` | `UgamColors.of(context).danger` |
| `AppText.pageTitle` | `UgamText.titleXl` |
| `AppText.sectionTitle` | `UgamText.titleM` |
| `AppText.cardTitle` | `UgamText.titleS` |
| `AppText.bodyMd` / `bodySm` | `UgamText.body` / `UgamText.caption` |
| `AppText.labelCaps` | `UgamText.micro` |
| `GoogleFonts.inter(...)` | `UgamText.<style>.copyWith(...)` |
| `showModalBottomSheet(...)` | `UgamSheet.show(context, builder: ...)` |
| `_PillBottomNav` | `UgamDockNav` |
