# Chart screen refresh + app-wide status-bar theming — Design

**Date:** 2026-07-20
**Branch:** feat/money-collection-settlement
**Status:** Approved (design), pending implementation plan

## Problem

Two issues, one app-wide and one screen-local:

1. **Status bar ("system info") is not theme-aware.** On the dark theme (the app
   default), the OS status-bar glyphs — clock, battery, signal — are invisible.
   Root cause: `MainShell.initState` hardcodes `SystemUiOverlayStyle.dark`
   (which means *dark icons*, meant for a light background) exactly once, so on a
   dark ground the icons disappear. It never reacts to a theme switch, and it
   never runs on the customer routes at all. The theme's
   `AppBarTheme.systemOverlayStyle` is correct but never applies, because screens
   use the custom `UgamAppBar` (a plain widget, not a Material `AppBar`).

2. **The Chart screen (admin `ChartsScreen`) is visually cluttered.** Between the
   title and the seat grid sit three stacked chrome bands (tour pills → bus pills
   → a full `13/36` tally card whose bus name duplicates the selected bus pill),
   and the footer carries a ragged, center-wrapped **9-item legend**.

## Goals

- Status-bar glyphs are legible in both themes, react to theme/"System" changes,
  and are correct across the entire app (admin + customer + pushed screens).
- The Chart screen reads calmer: fewer stacked chrome rows, a tidy grouped
  legend, and general spacing polish. The seat grid keeps its current size (it
  gains headroom for free from the decluttering).

## Non-goals

- No change to seat-grid sizing, the seat tiles, the expand/full-screen view, or
  the "Edit seats" hand-off.
- The legend stays **visible inline** (explicitly chosen over hiding it behind a
  tap-to-open sheet).
- No redesign of the tour/bus data model or selection logic.

## Approach (chosen)

Targeted declutter that reuses existing components, plus one app-wide status-bar
fix. Rejected alternatives:

- **Chart-local legend** — avoids touching other charts but forks the shared
  `UgamSeatChartLegend`, inviting drift. Rejected in favor of retidying the
  shared component once.
- **Bigger "one rich context header" rework** — more modern but higher risk, and
  unnecessary given the seat grid is fine and the legend stays visible.

---

## Part A — App-wide status-bar theming

**Change:** Wrap the app in a single theme-aware
`AnnotatedRegion<SystemUiOverlayStyle>` inside `GetMaterialApp.builder`
(`lib/app.dart`), derived from `Theme.of(context).brightness`:

- Dark theme → **light** status-bar icons; light theme → **dark** icons.
- `statusBarColor: Colors.transparent` so content shows through.
- Also set the Android system **navigation bar** color to the theme `bg` and its
  icon brightness to match (polish; keeps the bottom system bar theme-consistent).

Because the builder sits *under* the `MaterialApp`'s `Theme`, and the whole
`GetMaterialApp` already rebuilds inside the `ThemeController` `Obx`, this reacts
automatically to:
- explicit light/dark toggle, and
- "System" mode platform-brightness flips (MaterialApp rebuilds → `Theme.of`
  updates → `AnnotatedRegion` updates).

It applies everywhere with no per-screen work, and overrides any stale global
state because `AnnotatedRegion` at the top of the tree wins for screens that
don't set their own (ours don't — no Material `AppBar`).

**Also:** delete the now-redundant, buggy imperative call in
`MainShell.initState` (`lib/screens/main_shell.dart`, the
`SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark…)` block). The
pre-init splash (`splash_screen.dart`, `SystemUiOverlayStyle.light` on the dark
splash) stays as-is; the `AnnotatedRegion` takes over once `GetMaterialApp`
mounts.

**Files:** `lib/app.dart` (add builder + AnnotatedRegion),
`lib/screens/main_shell.dart` (remove stale call + now-unused `services` import
if it becomes unused).

### Data flow (A)

```
ThemeController.themeMode (Obx)
        │
        ▼
GetMaterialApp(theme/darkTheme/themeMode)
        │  builder(context, child)
        ▼
Theme.of(context).brightness  ──►  SystemUiOverlayStyle (light/dark icons)
        │
        ▼
AnnotatedRegion<SystemUiOverlayStyle>  ──►  OS status bar + nav bar
```

---

## Part B — Chart screen refresh (`lib/screens/charts_screen.dart` + shared legend)

### B1. Merge bus selector + tally into one "bus bar"

Replace the current *bus-pills row* **and** the separate `_Tally` **card** with a
single row:

- **Left:** the bus selector.
  - `> 1` bus → the existing `UgamSelectorPills` (scrolls horizontally within an
    `Expanded`).
  - exactly `1` bus → the bus **name** as a compact label (so the name never
    disappears — it currently lives only in the tally card).
- **Right:** a compact fill indicator — the `13/36` tabular count plus a slim
  (~44–60px) neutral-ink fill bar. No card chrome, no duplicated bus name.

This removes one full stacked row and the tally card's box, giving the seat grid
more vertical headroom while keeping the placed/total signal.

Target layout:

```
 Chart
 [ TEST — money audit ]  [ Poonam… ]      ← tour pills (only if >1 eligible tour)
 [ Bus 1 ][ Bus 2 ]            13/36 ▓▓▓░  ← bus selector + inline fill (was 2 rows)
 ┌─────────────────────────────────────┐
 │              seat grid              │  ← unchanged size, gains headroom
 │                         ✎ Edit seats│
 └─────────────────────────────────────┘
```

The old private `_Tally` widget is removed; a new private `_BusBar` (or inline
`Row`) replaces it. `_EditSeatsFab`, `_SeatChartCard`, `_Header`, and the empty
state are unchanged.

### B2. Tidy the shared legend (`lib/design/components/ugam_seat_chart_legend.dart`)

Replace the ragged center-wrapped `Wrap` with an **aligned 3-column grid grouped
by meaning**, smaller consistent swatches, same labels and swatch painters (the
single source of truth is preserved):

```
 ◻ Empty    ▪ Booked   ◈ Priority
 ● Paid     ○ Due      ½ Half-fare
 ▸ Go-only  ◂ Return   ⊘ Held
```

- Columns align (fixed-width legend items so the grid is tidy, not ragged).
- Groups: **State** (Empty, Booked, Priority, Held), **Leg** (Go, Return),
  **Money** (½ Half-fare, Paid, Due). Exact per-row placement can follow the grid
  above; grouping is by adjacency, no new labels introduced.
- Because this is the shared component, the tidy layout propagates uniformly to
  every seat chart (charts, handler, manual assignment, bus-status). This is the
  intended, approved outcome.
- Keep the `SeatMoneyStateColor` extension and all swatch painters
  (`_DashedBorderPainter`, `_Dot`, etc.) intact — only the top-level arrangement
  in `build()` changes.

### B3. Polish

- Consistent token-based spacing between the title, bus bar, grid, and legend.
- Optional: a muted `subtitle` on the `_Header` `UgamAppBar` showing the selected
  tour's date for context (low-risk, additive).
- Grid card and copper "Edit seats" FAB unchanged.

---

## Testing

- Existing seat-chart/legend/tile tests must still pass:
  `test/components/seat_chart_tile*_test.dart`,
  `test/screens/handler_bus_chart_screen_test.dart`, and the charts tab tests.
- Add/adjust a widget test asserting the Chart screen renders the merged bus bar
  (count `n/total` present; single-bus shows the bus name; multi-bus shows pills)
  and that the tidy legend still renders all nine keys.
- Manual verification: toggle light/dark (and System) and confirm status-bar
  glyphs are legible in both, on an admin screen *and* a customer screen; confirm
  the Chart screen on a 1-bus and a multi-bus tour.

## Files touched

| File | Change |
|------|--------|
| `lib/app.dart` | Add `builder:` with theme-aware `AnnotatedRegion<SystemUiOverlayStyle>` |
| `lib/screens/main_shell.dart` | Remove stale hardcoded `setSystemUIOverlayStyle`; drop now-unused import if applicable |
| `lib/screens/charts_screen.dart` | Merge bus selector + fill into one `_BusBar`; remove `_Tally` card |
| `lib/design/components/ugam_seat_chart_legend.dart` | Retidy `build()` into an aligned grouped 3-column grid |
| `test/...` | Update/add chart + legend widget tests |

## Risks

- **Legend blast radius:** the shared legend changes on four charts. Mitigated by
  keeping swatches/labels identical and running the existing tests.
- **Bus-bar width on narrow phones with many long bus names:** the pills scroll
  inside `Expanded`; the fill indicator is fixed-width on the right, and the count
  alone still communicates if the bar is dropped under pressure.
- **`AnnotatedRegion` vs. any inner overlay setters:** verified none of our
  screens use a Material `AppBar`, so nothing competes with the app-level region.
