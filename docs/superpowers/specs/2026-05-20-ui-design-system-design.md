# Ugam UI Design System — Phase 0 Spec

**Date:** 2026-05-20
**Status:** Draft for user review
**Scope:** Design system, component library, motion + adaptive patterns. Per-screen application is deferred to Phases 1–4 (own specs).

---

## 1. Why this exists

Today's UI carries 21 screens, ~17 K lines, three different stat-chip patterns, six different corner radii (6 / 8 / 12 / 14 / 18 / 22 mixed), ~330 inline `GoogleFonts.inter(...)` call sites, decorative AI-tropes (splash concentric circles, login "FIG. 001 · AUTHENTICATION · SECURE" filler), and no consistent motion or sheet language. It reads as "AI-generated and basic" because the building blocks don't agree with each other.

Phase 0 locks a single design language so the per-screen work in Phases 1–4 can apply it without re-litigating tokens or components.

## 2. Reference DNA

User-supplied reference set: 5 mobile UI images, with image 5 (dark bus-booking app with red accent) called out as **"100% this type of UI, change the theme colors"**. Reference files persist in `.superpowers/brainstorm/16459-1779248948/content/`. The locked DNA — pulled directly from that reference set — is:

- Dark surface as primary mode
- Big rounded geometry (cards 22, photos 16, buttons / dock / chips 999)
- Hero photography on browse cards with gradient overlay + bottom-left title + bottom-right price
- Floating dock bottom nav: capsule, circular icon buttons, active = solid accent circle
- Sticky pill CTA at thumb-zone on every workflow screen
- Image-5 seat grid: 5-column layout including aisle gap, discrete cells, color-coded states, deck toggle pill above, summary bar below
- Single accent color throughout (red in reference, brand-blue in Ugam)
- Bold sans-serif headlines, no serif, no bilingual sub-labels, no decoration

Out-of-scope DNAs that were proposed and rejected during brainstorming, listed so future sessions don't re-propose them: Khatabook-style dense bilingual ledger, Editorial Premium Travel serif, Linear "Operator Pro" terminal aesthetic, Saffron/cream regional warm, light-mode-first.

## 3. Foundations

### 3.1 Mode strategy

- **Dark is primary.** Customer and admin both default to dark on first launch.
- Light mode is a complete mirror, not a fallback. Every dark token has a light counterpart.
- Toggle lives in Settings, persists via `shared_preferences` (existing `ThemeController` keeps its API).
- Optional "Follow system" tri-state (Light / Dark / System) — System ON by default for new installs, but the dark visual is what every mockup, screenshot, and golden test targets.

### 3.2 Color tokens

Defined in `lib/design/tokens.dart` as a single `UgamColors` class with two static structs `dark` and `light`. Re-brand point: swap `accent` and `accentFill` only.

**Dark (primary):**

| Token | Value | Use |
|------|-------|-----|
| `bg` | `#0A0A0A` | Scaffold background |
| `card` | `#161616` | Default card fill |
| `cardElev` | `#1F1F1F` | Nested / elevated card, tab-pill background |
| `border` | `#2A2A2A` | Subtle dividers, input borders |
| `ink` | `#FAFAFA` | Primary text |
| `ink2` | `#A0A0A0` | Secondary text, captions |
| `ink3` | `#5E5E5E` | Tertiary text, inactive icons, ambient meta |
| `accent` | `#3B82F6` | Brand actions, active states, primary CTA |
| `accentFill` | `rgba(59,130,246,0.16)` | Accent badge background, request chip bg |
| `good` | `#34D399` | Available seat, success state |
| `goodFill` | `rgba(52,211,153,0.16)` | Good badge background |
| `warm` | `#FB923C` | Ladies / special seats, attention chips |
| `warmFill` | `rgba(251,146,60,0.18)` | Warm badge background |
| `danger` | `#F87171` | Destructive actions, error states |

**Light (mirror):**

| Token | Value | Use |
|------|-------|-----|
| `bg` | `#FBFAF6` | Scaffold background |
| `card` | `#FFFFFF` | Default card fill |
| `cardElev` | `#F2F1EC` | Nested / elevated card, tab-pill background |
| `border` | `#E8E5DE` | Subtle dividers, input borders |
| `ink` | `#111111` | Primary text |
| `ink2` | `#5A5A57` | Secondary text |
| `ink3` | `#9A9A95` | Tertiary text |
| `accent` | `#1746A2` | Existing brand blue, kept |
| `accentFill` | `#EEF2FF` | Accent badge background |
| `good` | `#16A34A` | Success state |
| `goodFill` | `#E8F6EC` | Good badge background |
| `warm` | `#C2410C` | Attention chips |
| `warmFill` | `#FFF1E7` | Warm badge background |
| `danger` | `#DC2626` | Error states |

**Re-brand test:** Changing the dark `accent` to `#F97316` (orange) ships an orange variant of the entire app without touching any component code. Spec is acceptable only if this test holds.

### 3.3 Typography

- Inter only (already bundled as variable TTF in `assets/fonts/`).
- Tabular numerics on every price, seat count, ID, timestamp via `fontFeatures: [FontFeature.tabularFigures()]`.
- No serif. No bilingual paired labels in UI surfaces.
- `easy_localization` keeps handling full-string translation (en/gu/hi) — the user picks one language in Settings, the app renders in that one language.

| Style | Size / Weight / Tracking | Use |
|------|---|---|
| `display` | 32 / 700 / -0.6 | Onboarding, splash brand |
| `titleXl` | 26 / 700 / -0.5 | Page titles ("Upcoming trips") |
| `titleL` | 22 / 700 / -0.4 | Sheet titles, hero card titles |
| `titleM` | 18 / 700 / -0.3 | Section headers, route city codes |
| `titleS` | 15 / 700 / -0.2 | Card titles |
| `body` | 14 / 500 | Default body text |
| `bodyStrong` | 14 / 600 | Emphasised body, row names |
| `caption` | 12 / 500 | Captions, metadata |
| `micro` | 10 / 600 / +0.4 | UPPERCASE labels, badges |
| `numLg` | 20 / 700 (tabular) | Stat values |
| `numXl` | 26 / 700 (tabular) | Big numbers (balance, total) |

### 3.4 Spacing scale

`4 / 8 / 12 / 14 / 16 / 20 / 24 / 32 / 40 / 56`. Default screen lateral padding is **14**. Default vertical rhythm between sections is **20**.

### 3.5 Radius scale

| Token | Value | Use |
|------|-------|-----|
| `rCard` | 22 | All cards |
| `rPhoto` | 16 | Photo inside a card |
| `rInput` | 14 | Inputs, tab-pill container |
| `rChip` | 999 | Pill chips, CTA buttons, dock nav, date pills |
| `rIconBtn` | 50 % | Circular icon buttons, avatars |
| `rSheet` | 28 | Bottom sheet top corners |
| `rStat` | 18 | Stat tile |
| `rRow` | 16 | List rows (admin) |
| `rSeat` | 8 | Seat cells in grid |

### 3.6 Elevation

- **Dark mode uses no shadows.** Hierarchy comes from card fills (`card` vs `cardElev`) and borders.
- **Light mode uses one shadow recipe only:** `BoxShadow(color: 0x14000000, offset: (0,3), blur: 14)`. Applied per card. No multi-layer recipes anywhere.
- Sticky CTAs get a fade-from-bg gradient above them instead of a shadow.

### 3.7 Motion + haptics

| Interaction | Behavior |
|------|------|
| Card tap | Scale-to-0.97 (120 ms in / 180 ms out, easeOutCubic) + `HapticFeedback.lightImpact()` |
| Tab change | 200 ms easeOut + `HapticFeedback.selectionClick()` |
| Sheet present | 280 ms easeOutCubic; native iOS sheet on iOS, draggable `BottomSheet` on Android |
| Page push | Cupertino transition (right-to-left slide, back-swipe enabled) on both platforms — already used via `Transition.cupertino` in `Get.to(...)` |
| Skeleton shimmer | 1200 ms linear loop |
| CTA press | Scale-to-0.96 + `HapticFeedback.lightImpact()` |
| Seat select | `HapticFeedback.selectionClick()` |
| Error snackbar | `HapticFeedback.mediumImpact()` |

## 4. Component library

All components live under `lib/design/components/`. Each is `const`-able where possible, theme-aware via `Theme.of(context)`, and has a golden widget test in both modes.

### 4.1 `UgamCard`

Anatomy: rounded container, no border in dark, no border in light (shadow only).
States: default, pressed (0.97 scale).
Variants: `UgamCard.plain` (text only, padding 14), `UgamCard.media` (photo on top, padding 8 outer + 16-radius photo + 10/8 inner content padding).
Don't: stack a card inside a card. Use `cardElev` for nested surfaces.

### 4.2 `UgamCTA`

Sticky bottom button. Full-width minus 28 px lateral. Height 56. Radius 999. `accent` fill, white text (`titleS` weight).
Slots: optional leading icon (left), optional trailing value chip + 26-circle arrow (right). Right cluster style: tabular-num value at 13/600 + circle in `rgba(white,0.18)`.
Sticks to bottom of `Scaffold.bottomNavigationBar` slot with `Container` gradient above (`bg → transparent`, 24 px).

### 4.3 `UgamDockNav`

Replaces today's `_PillBottomNav` in `lib/screens/main_shell.dart`.
Floats 12 px from bottom (over `extendBody: true`). Lateral 12 px padding.
Container: `cardElev` fill, radius 999, padding 8. Holds 4–5 children.
Each item: 44 px circle. Active = `accent` fill + white icon. Inactive = transparent + `ink3` icon.
Active state animates on tap (140 ms scale + colour cross-fade). `HapticFeedback.selectionClick()` on tap.

### 4.4 `UgamDatePill`

Horizontal scroll row, 8 px gap, padded 4 px lateral.
Each pill: min-width 54, padding 10/0, radius 22.
Active = `accent` fill (squircle shape from large radius), white num + white day-label. Inactive = transparent.
On select, scroll-to-center the picked pill (`Scrollable.ensureVisible`).

### 4.5 `UgamTabPills` (segmented)

Container: `cardElev` fill, radius 14, padding 3, height ~36.
3-segment max for visual balance. Each segment: equal flex, padding 8, radius 11, body weight.
Active = `card` (dark) / `card` (light) fill + inset border + `ink` text + tiny shadow `0 1px 4px 0,0,0,0.06`.
Optional count badge per segment: `caption tabular` in `accent` colour.

### 4.6 `UgamSeatGrid`

Container: `UgamCard.plain`, padding 14/12, flex-1 in column.
Layout:
- Legend row (4 swatches, 4 labels) padding 4/6.
- Grid: 5 columns, 7 px gap. Aisle column (index 2) is fixed empty.
- Each cell: aspect-1, radius 8, font 10/700, centred label.
- Driver corner: last column of first row, transparent, steering-wheel icon.

States:
| State | Dark fill | Dark text | Light fill | Light text |
|------|---|---|---|---|
| Available | `cardElev` | `ink2` | `cardElev` | `ink2` |
| Selected | `accent` | white + glow `accentFill` shadow | `accent` | white + glow |
| Taken | `ink3` | `bg` | `ink3` | `bg` |
| Ladies | `warm` | white | `warm` | white |
| Aisle | transparent | — | transparent | — |
| Driver | transparent | `ink3` (steering icon) | transparent | `ink3` (steering icon) |

Tap-to-select on Available → selected. Tap own selected → released. Tap Taken → toast with current holder name (admin only). Tap Ladies (customer) → "Reserved for women" toast.

Deck toggle (`UgamTabPills` with 2 segments, "Lower deck" / "Upper deck") sits above the grid.

Summary bar below: `UgamCard.plain` with left-aligned `numLg` tabular total + caption row of selected seat IDs + right-aligned `UgamCTA` (Continue).

### 4.7 `UgamStatTile`

Anatomy: `UgamCard.plain` radius `rStat`, padding 14.
Top: 32 px icon-in-rounded-square (radius 10) with tinted background.
Middle: `numLg` value, optional grey `/total` suffix in body weight.
Bottom: caption label, `ink2`.

API: `UgamStatTile({IconData icon, String value, String label, String? ofTotal, Variant variant = Variant.accent})`. `Variant` is one of `accent` (default — `accentFill` icon bg), `good` (`goodFill`), `warm` (`warmFill`), `neutral` (`cardElev`).

Used in 2-column grids on admin cockpits (dashboard, per-tour view).

### 4.8 `UgamRequestRow`

Anatomy: `UgamCard.plain` radius `rRow`, padding 12/12. Row layout: 38 px avatar circle (`cardElev` fill, 2-letter initials) | name + meta chips inline | trailing 32 px accent-fill arrow circle.

Meta chips render as `UgamReqChip(text, variant)` — micro-style font, padding 2/6, radius 6, `accentFill` or `warmFill` background. Time-ago renders as caption `ink3`, right-aligned within the meta row.

Whole row is tappable; arrow is visual confirmation only.

### 4.9 `UgamInput`

Filled style. Fill = `cardElev`. Radius `rInput`. Padding 14/16.
Focus border: 1.5 px `accent`. Error border: 1.5 px `danger`.
Label above input in `micro` caps style (`ink2`).
Phone variant: 90 × 54 country-code pill on the left, separate touch target.

### 4.10 `UgamSheet`

Wrapper around `showModalBottomSheet` that enforces:
- Radius `rSheet` (top only)
- Drag handle: 36 × 4, `ink3`, 8 px from top
- 20 px lateral padding
- `isScrollControlled: true`, `useSafeArea: true`
- iOS variant: uses `CupertinoSheetRoute`-style appearance (rounded corners, slight peek of underlying screen at top)
- Android variant: standard Material 3 sheet shape

Usage: `UgamSheet.show(context, child: ...)`. Replaces every direct `showModalBottomSheet` call site.

### 4.11 `UgamEmpty`

Empty state for lists and zero-data screens.
- 56 px icon (single line stroke, `ink3`)
- `titleM` title centred
- 2-line `body ink2` description max
- Optional `UgamCTA` below

**Do not** add illustrations. Illustrations read as AI-generated in this aesthetic.

### 4.12 `UgamSkeleton`

Shimmering placeholder shapes for loading lists.
- Rectangle variants: `card` (h: 124, r: rCard), `row` (h: 64, r: rRow), `chip` (h: 28, r: rChip), `text` (h: 14, r: 4)
- 1200 ms linear shimmer, base `cardElev`, highlight `card` (dark) / lighter (light)

Replaces every `CircularProgressIndicator` on list-initial-load. Spinner only stays for pull-to-refresh and inline submit buttons.

### 4.13 `UgamSnackbar`

Bottom-floating toast (overrides `AppSnackBar` in `lib/utils/app_snackbar.dart`).
Anatomy: `UgamCard.plain` radius 14, padding 12/16, floats 16 px above dock nav.
Variants: `success` (good icon + `goodFill` bg + `good` text), `error` (danger icon + danger-tinted bg), `info` (accent icon + `accentFill` bg).
Auto-dismiss 3.2 s. Tap to dismiss early. Swipe right to dismiss.

### 4.14 `UgamStatusDot`

`6 × 6` dot + `body 11/600` text inline, no pill wrapper.
Variants by colour: `accent`, `good`, `warm`, `ink3` (ambient).
Used for ambient state (`● Collecting`, `● 8 left`, `● Sync 2s ago`) instead of pill badges, which are reserved for "headline" state that needs to dominate.

### 4.15 `UgamRouteHeader`

City-to-city header for trip detail and seat-select screens.
Layout: left-aligned `titleM` city code (3 letters: `AMD`) + `caption ink2` city name + time | centre `28` circle bus icon in `accentFill` + duration caption | right-aligned mirror of left.

## 5. Patterns

### 5.1 Sheet-first flows

These actions are sheets, never new screens:
- Edit booking request (today's `EditRequestSheet` already is — keep, restyle)
- Filter list
- Status change (move tour to next phase)
- Contact (call / WhatsApp)
- Language pick (today's `LanguagePickerSheet` already is — keep, restyle)
- Confirm destructive (logout, delete, etc.)

### 5.2 Thumb-zone bottom CTAs

Every workflow screen ends with a sticky `UgamCTA`. No CTAs in headers. No FloatingActionButtons (today's screens use `FloatingActionButton.extended` on Tours, Requests — replace with sticky `UgamCTA`).

### 5.3 Hero photo on browse cards

Each tour gets a photo:
- Source priority: agent-uploaded → route-seeded stock photo from `assets/images/bus-photos/` → brand-gradient fallback with bus icon
- Stock set: ship 8 destination photos covering common Gujarat-Maharashtra routes (Saputara, Statue of Unity, Diu, Dwarka, Ambaji, Shirdi, Lonavala, Mahabaleshwar)
- Agent upload UX is deferred to Phase 4 (CreateTour). Phase 0 only ships the fallback machinery + 8 stock photos.

### 5.4 Two-mode per audience default

Customer = dark. Admin = dark. Toggle in Settings under "Appearance" → "Theme" (Light / Dark / System). The existing `ThemeController.toggleTheme()` remains as the API surface — only its default value changes.

### 5.5 iOS-adaptive

- Cupertino page transitions on both platforms (already configured via GetX `Transition.cupertino` in routes — verify all `Get.to(...)` use this).
- `UgamSheet` switches to a Cupertino-style sheet on iOS.
- Status bar overlay style follows surface: dark mode → light status icons.
- Back-swipe enabled on every page that isn't the root tab.

### 5.6 No decoration

Splash, login, and empty states drop their decorative noise. Brand wordmark only on splash. Login is form-only, no "FIG. 001 / AUTHENTICATION / SECURE" footer labels. Empty states are icon + text + optional CTA only.

## 6. Migration map (today → new)

| Today | New |
|------|------|
| `_PillBottomNav` (5-tab pill at bottom) | `UgamDockNav` (4-icon floating capsule, white-circle active) |
| ~330 inline `GoogleFonts.inter(...)` / `TextStyle(fontFamily: 'Inter', ...)` call sites | Replace with `UgamText.*` styles from `lib/design/text_styles.dart` |
| Mixed radii 6 / 8 / 12 / 14 / 18 / 22 | Single scale (22 / 16 / 999 / 14 / 8) from `UgamRadius` |
| Light-first theme with bolted-on dark | Dark-first theme, light is a complete mirror |
| Brand `#1746A2` everywhere | `accent` resolves to `#3B82F6` in dark, `#1746A2` in light |
| `cardShadow` two-layer recipe | Single shadow (light only), zero shadow (dark) |
| Decorative ellipses on splash | Brand wordmark only |
| "FIG. 001 · AUTHENTICATION · SECURE" on login | Removed |
| Customer-side Gujarati sub-labels (`Ugam · યાત્રા` style) | Removed — full-string translation only |
| 3 different stat-chip styles | Single `UgamStatTile` component |
| `CircularProgressIndicator` for list initial-load | `UgamSkeleton` shimmer |
| Direct `showModalBottomSheet(...)` | `UgamSheet.show(...)` wrapper |
| `FloatingActionButton.extended` on Tours / Requests | Sticky `UgamCTA` instead |
| `AppSnackBar` (current `lib/utils/app_snackbar.dart`) | Reskinned as `UgamSnackbar`, same call sites |
| `lib/components/platform_*.dart` | Removed; replaced by `Ugam*` components |

## 7. Files

### 7.1 To create

- `lib/design/tokens.dart` — `UgamColors`, `UgamRadius`, `UgamSpacing`, `UgamDuration`
- `lib/design/text_styles.dart` — full `UgamText` scale
- `lib/design/theme.dart` — exposes `darkTheme` / `lightTheme` `ThemeData` built from tokens; replaces current `AppTheme.darkTheme` / `AppTheme.lightTheme` exports
- `lib/design/components/ugam_card.dart`
- `lib/design/components/ugam_cta.dart`
- `lib/design/components/ugam_dock_nav.dart`
- `lib/design/components/ugam_date_pill.dart`
- `lib/design/components/ugam_tab_pills.dart`
- `lib/design/components/ugam_seat_grid.dart`
- `lib/design/components/ugam_stat_tile.dart`
- `lib/design/components/ugam_request_row.dart`
- `lib/design/components/ugam_input.dart`
- `lib/design/components/ugam_sheet.dart`
- `lib/design/components/ugam_empty.dart`
- `lib/design/components/ugam_skeleton.dart`
- `lib/design/components/ugam_snackbar.dart`
- `lib/design/components/ugam_status_dot.dart`
- `lib/design/components/ugam_route_header.dart`
- `lib/design/README.md` — how to extend, token table, component examples
- `test/design/golden/` — golden widget tests for each `Ugam*` component in dark + light
- `assets/images/bus-photos/` — 8 stock destination photos (`saputara.jpg`, `statue-of-unity.jpg`, `diu.jpg`, `dwarka.jpg`, `ambaji.jpg`, `shirdi.jpg`, `lonavala.jpg`, `mahabaleshwar.jpg`)

### 7.2 To modify

- `lib/config/theme.dart` — keep file as compatibility shim that re-exports from `lib/design/`, so existing imports don't break. Mark as deprecated.
- `lib/screens/main_shell.dart` — swap `_PillBottomNav` usage to `UgamDockNav`. Default each tab's body bg to dark.
- `lib/controllers/theme_controller.dart` — default value flips to `true` (dark) for fresh installs. Existing users keep their current setting.
- `lib/utils/app_snackbar.dart` — re-implement against `UgamSnackbar`. Call-site API unchanged.

### 7.3 To remove (after Phase 0 lands)

- `lib/components/platform_button.dart`, `platform_card.dart`, `platform_dialog.dart`, `platform_text_field.dart`, `platform_icons.dart`, `platform_detector.dart` — superseded by `Ugam*` + Cupertino/Material auto-switching in `UgamSheet` / `UgamCTA` etc.

### 7.4 To leave alone in Phase 0

The 21 screen files (`lib/screens/*.dart`) themselves. Phase 0 ships components and tokens; the existing screens continue to compile against the compatibility shim and look identical. Each subsequent phase rewrites its screens.

## 8. Out of scope for Phase 0

- Per-screen redesigns (Phases 1–4)
- New backend fields (none required for the system itself)
- Logic / controller changes
- Photo upload UX (deferred to Phase 4)
- The 8 stock destination photos themselves (Phase 0 lands the directory + manifest; photos sourced in Phase 1 alongside customer-flow rewrite)
- Animation polish beyond the durations listed in §3.7

## 9. Per-phase application order (downstream specs)

1. **Phase 1 — Customer flow** (splash, login, customer-home, customer-tour-detail, customer-booking-request, customer-my-requests)
2. **Phase 2 — Admin shell + Dashboard + Tours**
3. **Phase 3 — Requests + Seat Assignment + Notify** (the dense workbench)
4. **Phase 4 — Tour/Bus CRUD + Settings + Admin Setup**

Each phase = its own discuss → spec → plan → execute cycle.

## 10. Acceptance criteria

Phase 0 is done when all of these are true:

- [ ] `lib/design/tokens.dart` exists with `UgamColors.dark` and `UgamColors.light` matching §3.2 exactly
- [ ] `lib/design/text_styles.dart` exists with the §3.3 scale
- [ ] All 15 `Ugam*` components from §4 exist under `lib/design/components/`
- [ ] Golden-test dependency added (`alchemist` preferred; fall back to `golden_toolkit` if alchemist won't pin to Flutter 3.10)
- [ ] Each `Ugam*` component has at least one golden widget test in both modes (`test/design/golden/`)
- [ ] `lib/design/theme.dart` exports `darkTheme` + `lightTheme` derived from tokens; `lib/config/theme.dart` becomes a deprecated shim
- [ ] `main_shell.dart` uses `UgamDockNav`; existing tabs unchanged in content
- [ ] Settings screen shows working Light / Dark / System tri-state, persisting via `ThemeController`
- [ ] **Re-brand test:** With one line changed in `tokens.dart` (`UgamColors.dark.accent` from `#3B82F6` to `#F97316`), `flutter test --update-goldens` followed by `git diff` on the regenerated goldens shows ONLY colour-channel changes — no layout shifts, no token leaks. This proves the system has exactly one accent token.
- [ ] `assets/images/bus-photos/` directory exists with a `README.md` listing the 8 expected filenames (actual photos land in Phase 1)
- [ ] `flutter analyze` returns zero warnings
- [ ] `flutter test` passes including new golden tests
- [ ] All 21 existing screens still compile and render against the shim
- [ ] `lib/design/README.md` documents tokens, components, and how to add a new component

## 11. Risks

- **330 inline `GoogleFonts.inter(...)` call sites won't migrate in Phase 0.** They keep working via the compatibility shim. They migrate per-phase as each screen is rewritten. Acceptable because the shim resolves to the bundled Inter (no network fetch), so visual + perf is unchanged.
- **Stock photo licensing.** Sourcing 8 destination photos that are royalty-free + commercially usable. Plan: Unsplash + Pexels (both have permissive licences). Backup: agent-uploaded photos render through the same code path, so we can ship Phase 1 with the gradient fallback if photos slip.
- **Existing `AppTheme.brand` / `AppTheme.cardShadow` are referenced in ~150 call sites.** The shim must re-export every constant used today, even if it's no longer the recommended token. Scope: ~30 minutes of grep + re-export.
- **GetX `Transition.cupertino` is set per `Get.to` call.** Some sites may use the default. Audit pass in Phase 0; fix any that aren't.
