# Ugam UI Rebuild — Futuristic · Simple (Charcoal Copper)

**Date:** 2026-06-22
**Status:** Approved direction — building
**Reference mock:** `docs/superpowers/specs/theme-concepts/futuristic.html`

## Direction (locked through live iteration)
A full visual rebuild of the Ugam app to a **futuristic, simple, easy-to-use** language. Space over decoration; one big figure + one clear action per screen; a single quiet copper glow as the only flourish. Calm geometric type. Dark-first with a clean light mirror.

- **Rejected along the way:** champagne refinement, saffron, 5 generic recolors, the boarding-pass/ticket aesthetic (too busy), the basic component set.
- **Kept:** the **Charcoal Copper** palette family (copper accent on cool graphite).

## 1. Tokens (`lib/design/tokens.dart`)
Rework `UgamColorSet` values; add a `glow` slot.

**Dark (primary)**
| token | value |
|---|---|
| bg | `#0C0D10` (cool near-black) |
| card | `#15171C` (soft surface, **no hairline needed**) |
| cardElev | `#1E2128` |
| border | `rgba(255,255,255,0.06)` — used rarely; depth comes from fill, not lines |
| ink | `#F5F6F8` |
| ink2 | `#9A9DA7` |
| ink3 | `#5C5F69` |
| accent | `#D8966A` (copper) |
| accentFill | `rgba(216,150,106,0.14)` |
| **glow** *(new)* | `rgba(216,150,106,0.30)` — soft radial behind hero figures + primary button shadow |
| onAccent | `#1A0E07` |
| good / goodFill | `#4ADE9A` / `rgba(74,222,154,0.13)` |
| warm / warmFill | `#E98AB4` (rose — ladies/attention, distinct from copper) / `rgba(233,138,180,0.16)` |
| danger | `#FF5247` |

**Light (mirror)** — clean, bright: bg `#F6F7F9`, card `#FFFFFF`, cardElev `#EEF0F4`, border `rgba(0,0,0,0.06)`, ink `#14161B`, ink2 `#5A5E68`, ink3 `#9A9DA7`, accent `#B8703F` (deeper copper), accentFill `#F4E7DC`, glow `rgba(184,112,63,0.22)`, onAccent `#FFFFFF`, good `#0E9E73`, warm `#C24D86`, danger `#D7362B`.

**Radii** (rounder, softer): card 22 · stat 20 · input 14 · sheet 28 · seat 14 · row 18 · chip 999 · button 16.
**Add** a `copperDeep` Brand seed for gradient buttons. Primary button fill = `linear gradient(135°, accent → copperDeep)` + `glow` shadow.

## 2. Type (`lib/design/text_styles.dart` + bundle font)
- **Display / numbers:** **Sora** (weights 300/400/500/600/700). Big figures use Sora **Light/300** at large sizes (e.g. 56–60) with tight tracking — the calm, futuristic feel.
- **Body / small UI:** keep **Inter**.
- Bundle Sora (variable TTF) under `assets/fonts/`, declare in `pubspec.yaml`, set as the display family. Keep `google_fonts` runtime-fetch disabled.
- Scale stays, but `display`/`titleXl`/`titleL` switch to Sora; body/caption/micro stay Inter. Numerics keep tabular figures.

## 3. Components (rebuild in the new language)
Quiet surfaces, soft depth, big tap targets (buttons/inputs ≥ 52px), generous padding.
- **UgamCTA / buttons** — 52px, radius 16; primary = copper gradient + glow shadow; secondary = `card` fill; ghost/danger quiet.
- **UgamCard** — `card` fill, radius 22, generous padding, **no border in dark** (depth via fill); soft shadow in light.
- **Hero stat (new `UgamHeroStat`)** — big Sora-300 figure + soft `glow` halo + small label. The dashboard centerpiece.
- **UgamStatTile** — soft pill, Sora number, small label.
- **UgamInput** — `card` fill, radius 14, copper **glow focus ring** (`box-shadow` equivalent).
- **UgamSelectorPills / segmented** — soft, elevated active thumb.
- **UgamTabPills** — minimal.
- **UgamDockNav** — floating, simplified icons, copper active with a small glow dot.
- **UgamReqChip / status** — soft pills (rose/good/copper/neutral); drop the ticket stamp.
- **UgamSeatGrid** — rounded-14 tiles; selected = copper gradient + glow; free = subtle outline.
- **Progress** — thin rounded copper-gradient bar; optional `UgamProgressRing` for compact spots.
- **New `UgamTourSelector`** — surface pill (bus icon + tour name + sub + copper chevron) opening a tour picker sheet.
- **UgamEmpty / Skeleton / Snackbar / Sheet / Dialog** — restyle to soft/quiet; Sora titles.

## 4. Dashboard (first build — the proof)
Per the approved mock:
1. Greeting + avatar (gradient).
2. **`UgamTourSelector`** — defaults to the **nearest upcoming tour**; opens a sheet to pick another.
3. **Hero = Passengers** for the selected tour (big Sora figure + glow), sub: `N of M seats left`.
4. **Nearest-trip card** — route (City → City), departs date, seats-filled bar, status, one primary CTA (the tour's next action).
5. Floating dock nav.

"Nearest tour" = the soonest upcoming non-completed tour by departure date; selector lists all upcoming tours.

## 5. Build order
1. **Foundation:** tokens (+ glow, radii, copperDeep), bundle Sora, text_styles. Verify app boots in new palette/type.
2. **Core components:** buttons/CTA, card, hero stat, input, dock nav, chips, tour selector.
3. **Dashboard** rebuilt → review live on emulator.
4. **Screen-by-screen** roll-out: Tours, Seats/chart, Requests, Tour detail, Settings, then customer + handler screens.
5. **Light mode** parity pass + Gujarati string check each step.

## 6. Verify
Run live on the Pixel_9 emulator (admin session "zeel" + test tour) after each phase; check dark + light and Gujarati. Keep the 503-test suite green; add/adjust widget tests for new shared components (`UgamHeroStat`, `UgamTourSelector`).

## 7. Out of scope
Backend/logic changes, navigation re-architecture, new features (beyond the dashboard tour-selector + passenger hero). Visual/structural only.
