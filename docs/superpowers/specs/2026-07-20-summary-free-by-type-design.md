# Summary screen: per-bus free-by-type breakdown

**Date:** 2026-07-20
**Branch:** feat/money-collection-settlement
**Status:** Approved design — ready for implementation plan

## Context

The tour Summary (the `SeatsScreen` "Summary" mode, which embeds
[`TourOverviewScreen`](../../../lib/screens/tour_overview_screen.dart)) shows one
compact row per bus: name · type, a status dot, and a two-leg capacity meter
(`33/37 · 4 ખાલી`).

A prior fix already switched every "how full?" surface on this screen from the
engine's *would-fill* plan to the **actual** persisted `assignedSeats`
(`computeActualCapacity` in
[`tour_capacity.dart`](../../../lib/utils/tour_capacity.dart)), so the Summary
can no longer read "full" while the grid has empty seats.

Two gaps remain in how the **free** count is presented on that bus row:

1. **Berth-vs-seat ambiguity.** "4 ખાલી" counts *berths*. A Double Sofa is one
   physical seat worth two berths, so "4 free berths" can be "2 singles + 1
   double" — three seats, not four. The lumped berth number hides that.
2. **One-leg availability is invisible.** A berth can be free on only one leg
   (taken going, empty returning, or vice-versa). The bus-row meter's single
   "N ખાલી" only counts berths free on *both* legs, so a return-only opening
   isn't shown at all on the Summary.

The app already solves both — on the **Requests** screen. Its capacity banner
renders a per-type breakdown with directional leg badges
([`_TypeFreePill`](../../../lib/screens/requests_screen.dart), fed by
`TourCapacity.freeByType`: `SeatTypeFree { round, goOnly, retOnly }` per
`SeatType`). This design brings that breakdown to the Summary's bus rows, fed
from **actual** assignments so it stays consistent with the fix.

## Goals

- Under each Summary bus row's meter, always show a compact type line: one pill
  per seat type the bus still has openings on.
- Round-trip-free is the primary number per type (in **tiles** — a Double Sofa =
  1 tile). A going-only surplus shows a cyan `→ N` badge; a return-only surplus a
  violet `← N` badge — identical semantics and visuals to the Requests screen.
- Compute the breakdown from real `assignedSeats` (leg-aware via
  `SeatAssignment.leg`), never the engine plan.
- The Requests screen's behavior and appearance are unchanged (pure extraction
  of the shared widget).

## Non-goals

- No change to the capacity meter, the "needs decision" / shortfall banner, or
  the engine-plan `computeTourCapacity` path.
- No change to the seat grid or the assignment flow.
- No new tap/expand interaction — the type line is always visible (accepted
  trade-off: bus rows get slightly taller).

## Design

### 1. Data — extend `computeActualCapacity`

`computeActualCapacity(Tour)` currently returns `ActualCapacity` with tour-wide
`capacity`/`goOccupied`/`retOccupied` and a per-bus `byBus: Map<String,
BusCapacity>` (meter data). Extend it with a **per-bus, leg-aware free-by-type**
breakdown built from actual `assignedSeats`:

- New field: `freeByType: Map<String, Map<SeatType, SeatTypeFree>>` keyed by bus
  id (reuses the existing `SeatTypeFree { round, goOnly, retOnly }` value type).
- Per-seat leg occupancy comes from each `SeatAssignment.leg`
  (`TripType?`), falling back to the holder's `Passenger.derivedTripType` when a
  row carries no recorded leg (legacy data) — the same technique
  `SeatingPlan.legOccupancy` already uses. This is more precise than the
  passenger-level `min(seatsOnBus, goBerths)` approximation and is required
  because a per-*type* tile breakdown needs to know which leg each *seat* is
  taken on.
- Bucketing per non-reserved cell mirrors `computeTourCapacity`'s existing
  `freeByType` logic: a tile is free on a leg only when **zero** berths are
  placed on it that leg (a Double Sofa needs BOTH berths free); `goOpen &&
  retOpen → round`, else `goOpen → goOnly`, else `retOpen → retOnly`. Counted in
  tiles (a Double Sofa = 1).
- The meter's berth totals (`byBus` `BusCapacity`) are left exactly as they are,
  so the meter and the earlier fix are untouched.

`ActualCapacity` gains a small getter or the caller iterates
`freeByType[busId]`; only seat types the bus actually has appear (empty map entry
otherwise).

### 2. UI — extract a shared `UgamFreeByType` component

Move the three private widgets out of
[`requests_screen.dart`](../../../lib/screens/requests_screen.dart) into a new
`lib/design/components/ugam_free_by_type.dart`:

- `UgamTypeFreePill` (was `_TypeFreePill`) — one "Label N → M ← K" pill.
- `UgamLegBadge` (was `_LegBadge`) — the small tinted `→ N` / `← N` badge.
- `UgamLegCaption` (was `_LegCaption`) — the go/return colour key.

The leg tints (`kOneWayTint` / `kReturnTint`) move or are re-exported alongside
them. The Requests screen imports and uses these unchanged — a pure refactor with
no behavior change. This guarantees the Summary and Requests pills render
identically.

### 3. Summary bus row

In [`tour_overview_screen.dart`](../../../lib/screens/tour_overview_screen.dart)
`_BusRow`:

- Pass the per-bus `Map<SeatType, SeatTypeFree>` (from `actual.freeByType[busId]`)
  into the row alongside the existing `busCap`.
- Under the meter, render a `Wrap` of `UgamTypeFreePill`s — one per seat type
  whose `SeatTypeFree.total > 0` (skip types with nothing free). Order:
  singleSofa, doubleSofa, seater (matching Requests).
- If the bus is full (nothing free), render no line — the meter already reads
  "ભરાઈ ગઈ / full".
- Show the leg colour caption (`UgamLegCaption`) only when some pill has a
  one-way surplus, keeping the common round-trip case clean.

**Worked example (VANTARA).** Meter unchanged: `33/37 · 4 ખાલી` (4 berths).
New line: `Single 2 · Double 1` — three seats, and the Double being two berths is
exactly why 3 seats = 4 free berths. A berth free only on the return leg would
appear as `Single 1 ← 1`.

### 4. Testing

- **Unit** (`test/utils/tour_capacity_test.dart`): a mixed-type bus with some
  seats actually assigned round-trip and some one-way → assert `freeByType[bus]`
  gives the expected `round` / `goOnly` / `retOnly` per `SeatType`; a fully-empty
  bus → all capacity is `round`-free; a fully-assigned bus → all zero.
- **Widget** (`test/screens/tour_overview_screen_test.dart`): a bus with free
  seats of two types renders the type pills; a full bus renders none.
- **Regression:** existing `requests_screen` tests (if any) still pass after the
  widget extraction; the earlier `computeActualCapacity` occupancy tests are
  untouched.

## Files touched

| File | Change |
|------|--------|
| `lib/utils/tour_capacity.dart` | Extend `ActualCapacity` + `computeActualCapacity` with per-bus leg-aware `freeByType` from `assignedSeats`. |
| `lib/design/components/ugam_free_by_type.dart` | **New** — shared `UgamTypeFreePill` / `UgamLegBadge` / `UgamLegCaption` (+ leg tints). |
| `lib/screens/requests_screen.dart` | Delete the three private widgets; import the shared component (pure refactor). |
| `lib/screens/tour_overview_screen.dart` | `_BusRow` renders the compact type line from `actual.freeByType[busId]`. |
| `test/utils/tour_capacity_test.dart` | Unit tests for actual free-by-type. |
| `test/screens/tour_overview_screen_test.dart` | Widget test for the type line. |
