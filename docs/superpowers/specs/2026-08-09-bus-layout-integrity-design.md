# Bus layout integrity + single capacity truth

**Date:** 2026-08-09
**Status:** Implemented — 25 new tests, 1125 passing, no regressions
**Branch:** `feat/money-collection-settlement`

## Problem

A live tour showed three screens reporting three different seat counts for the same two buses:

| Surface | Reported | Reality |
| --- | --- | --- |
| Tour overview meter | `0 / 0` | wrong |
| Tour overview banner | "79 berths wanted, only 74 — ~54 won't fit" | false alarm |
| Chart tab | `36 / 0` + "no seat layout" | numerator right, denominator wrong |
| Requests screen | `72 / 74`, 2 free | correct |

Both buses had lost their `layout` jsonb in Supabase. `total_seats = 37` each (74 total) and all 72 seat
assignments survived, because assignments live in the `passengers` table rather than the bus row.

### Root cause A — writes null the layout

`Bus.toMap()` unconditionally emits `'layout': layout?.toMap()`. Cold start deliberately omits the layout
jsonb (`sync_service.dart` — it is ~71% of bus bytes on a 2G link), so every in-memory `Bus` starts with
`layout == null` until `ensureBusLayoutsForTour` fills it in.

`smartUpdate` sends the whole map as a PostgREST update, so every listed column is overwritten. Any bus
write that fires before the layout fetch resolves therefore persists `layout = NULL` and destroys the
seat map. Confirmed write paths:

- `setBusHandler` / `removeBusHandler` — push the entire bus row to update one pointer column.
- `updateBus` from the bus editor — when capacity is untouched the editor reuses `source.layout`, which is
  `null` if the layout had not loaded yet.

`_updateSeatCell` is the one path that already guards on `layout == null`.

### Root cause B — the fallback exists in only one place

`computeTourCapacity` carries a legacy `total_seats` fallback for layout-less buses. `computeActualCapacity`
and `charts_screen` do not — they derive capacity purely from `bus.layout.grid`, so they read 0 for a bus
whose grid has not arrived (or was wiped). `SeatingEngine.propose` returns early for a layout-less bus, so
it places nobody and every rider becomes an exception — which is what produced the false shortfall banner.

## Decisions

1. **Column-scoped bus writes** — each write sends only the fields it changes.
2. **Database guard** — a trigger refuses to null a non-null layout, protecting live data from app builds
   already installed in the field.
3. **Repair by regeneration** — rebuild the wiped layouts so seat IDs match the surviving assignments.
4. **Legacy count + skeleton** — numbers always fall back to `total_seats`; the chart distinguishes
   "loading" from "genuinely has no layout".

## Design

### 1. `SyncService.updatePatch`

New update-only write. `smartUpdate` falls back to INSERT when an update matches zero rows; with a narrow
map that would create a half-empty row, so `updatePatch` must **not** insert. A patch matching no row is a
bug and surfaces as an error.

Call-site conversion:

| Site | Before | After |
| --- | --- | --- |
| `setBusHandler` | whole row | `{'handler_passenger_id': pid}` |
| `removeBusHandler` | whole row | `{'handler_passenger_id': null}` |
| `updateBus` | whole row | edited fields; `layout` only when regenerated |
| `_updateSeatCell` | whole row | `{'layout': …}` |
| `addBus` | full insert | unchanged — a new row needs every column |

`updateBus` takes an explicit `layoutChanged` signal from the editor rather than inferring intent from a
possibly-unloaded value. This makes the editor's existing contract ("when capacity isn't touched the saved
layout is reused untouched") true by construction: the column is simply absent from the patch.

`Bus.toMap()` is unchanged — inserts still need the whole row.

### 2. One shared fallback

Extract the layout-less fallback into a helper used by **both** `computeTourCapacity` and
`computeActualCapacity`, so the two can no longer diverge. `charts_screen` switches its denominator from
`layout?.totalSeats ?? 0` to `bus.totalSeats`, which already falls back correctly in the model.

The seating engine keeps returning early for a layout-less bus — it genuinely cannot place seats without a
grid. What changes is that the UI stops reporting that as demand overflow.

### 3. Loading state

`TourController.layoutsLoadedFor(tourId)` derives from the `_layoutFetchedBusIds` set already maintained.

- Numbers always use the legacy fallback — no surface renders `0/0` for a 37-seat bus.
- The capacity/shortfall banner is suppressed until layouts are loaded, killing the false shortfall.
- The chart gets three distinct states: skeleton (loading) → grid (loaded) → "no layout yet" (loaded, null).

### 4. Performance

`capacityFor` memoizes the engine run, but five call sites bypass it and call `computeTourCapacity`
directly inside `Obx`: `manage_buses_screen`, `requests_screen`, `tour_detail_screen`,
`tour_overview_screen`, `seating_exceptions_screen`. All are routed through the memo, and a matching
`actualCapacityFor` memo is added for the currently uncached `computeActualCapacity` calls.

**Load-bearing:** `_capacitySignature` must fold `b.totalSeatsLegacy`. It folds grid cells today, which
suffices while capacity comes only from grids; once the fallback reads `total_seats`, a change there must
invalidate the cache or the meters go stale.

`TourCapacity` now carries the `decisions` LIST rather than just a count, with `needsDecision` derived from
it. The "needs your decision" screen was running a second, identical engine pass through
`seatingDecisionExceptions` purely to get the list the count was already computed from; it now reads the
memoized snapshot, so the badge and the cards are literally the same run instead of two runs that agree.

Net effect: fewer engine runs than today, and a handler-pointer write drops from the entire seat map to a
single field on 2G.

### 5. Migration `065_protect_bus_layout.sql`

`BEFORE UPDATE` trigger on `buses`: when `NEW.layout IS NULL AND OLD.layout IS NOT NULL`, restore
`OLD.layout`. Nothing in the app legitimately clears a layout — it regenerates them — so there are no false
positives. Deployed by hand, as with the other migrations.

### 6. Repairing the wiped buses

`BusLayout.generate` is deterministic and seat IDs are `prefix + row-major index`, so regenerating with the
original inputs reproduces the original IDs exactly.

`recoverBusLayout` (`lib/utils/bus_layout_recovery.dart`) generates every layout the bus could plausibly
have had and keeps those able to host all surviving IDs. It returns a layout **only** when exactly one
candidate survives; otherwise it reports. `TourController.recoverBusLayoutFor` drives it end to end and
patches only the `layout` column, refusing to touch a bus that still has a grid.

Two things the implementation established that the design assumed:

- **Berths are not tiles.** A 37-berth sleeper is 25 seat IDs (13 single sofas + 12 doubles), because a
  double sofa is ONE tile carrying two berths. With 36 of 37 berths assigned, effectively every tile is
  occupied — so the live evidence is the complete ID set and recovery is unambiguous. Verified by
  round-trip test.
- **`hasBalcony` is a documented no-op** on the generator, so the candidate space is only
  `singleSofaCount` × `allDoubleBackRow`.

Where a tile is unoccupied the result can be ambiguous — for a 37-berth bus, two layouts differing solely
in whether the last seat is the upper or lower berth. By construction every candidate re-attaches every
surviving assignment identically, so `LayoutRecovery.candidates` exposes the shortlist for a human to pick
from rather than the tool inventing one. The fallback remains a Supabase backup restore.

## Testing

Written before the fix, one per fault:

- `computeActualCapacity` with a null layout uses `total_seats` (the missing twin of the existing
  `computeTourCapacity` test).
- Handler assign/remove patches contain only the handler column.
- `updateBus` omits `layout` when capacity was untouched, includes it when regenerated.
- `updatePatch` never inserts when the row is missing.
- `_capacitySignature` folds `totalSeatsLegacy`.
- Chart denominator falls back to `bus.totalSeats`.
- Shortfall banner stays quiet while layouts are unloaded.
- Round trip: drop a known layout, infer it from surviving IDs, regenerate identical IDs.

## Out of scope

Live-DB drift surfaced in the runtime logs (missing `customer_memory` table, `tour_pending_seat_holds` RPC,
`payment_claims.seat_hold_id` column) is unrelated to this fault and tracked separately.
