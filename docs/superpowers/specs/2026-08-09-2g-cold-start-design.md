# 2G / slow-network cold-start engineering

**Date:** 2026-08-09  
**Scope:** Admin Home + seating/chart surfaces. Not a claim that every product
feature is “perfect” — this is the production data-loading path for weak radios.

## Measured problem (live admin probe)

- Bus `layout` jsonb ≈ **71%** of owner-wide bus payload.
- Full roster hydration on every launch grows without bound as archive grows.
- EDGE-class links need **~28s** per-page headroom; a 12s wifi budget blanks Home.

## Production design (shipped)

1. **Progressive cold start** (`TourController._loadTours`)
   - Phase 1: tour headers → paint Home (leave spinner).
   - Phase 2: passengers + bus **metadata** for running tours only (no layout).
   - Phase 3: layout jsonb background prefetch / on-demand via
     `ensureTourReadyForSeating` / `ensureBusLayoutsForTour`.
2. **Narrow selects** (`SyncReadProjections`) — never `select *` on cold path.
3. **Cellular-aware timeouts** — 12s wifi / 28s cellular per page.
4. **Read concurrency gate** — max 2 concurrent live reads on cellular, 6 on wifi.
5. **Non-critical deferral** — customer_memory + settlement snapshots start after
   Home’s critical path (~2.2s / 1.2s).
6. **Missing-table soft-fail** — `customer_memory` PGRST205 does not retry forever
   or blank tours.
7. **Seating entry wiring** — detail, seats, overview, charts, manage buses,
   bus status, exceptions, fillTour all call `ensureTourReadyForSeating`.

## Explicit non-goals (still open)

- Full offline write-queue / SQLite cache was removed intentionally (stale-data
  risk). Slow **online** is the target; true airplane-mode booking is not.
- Handler chart uses `CustomerRequestsStore` (separate path) — not yet on the
  progressive layout API.
- Customer public booking RPCs are independent of admin cold start.

## Verification

- `test/controllers/tour_progressive_load_test.dart`
- `test/services/sync_cellular_timeout_test.dart`
- `test/services/sync_read_projections_test.dart`
- `test/controllers/tour_controller_test.dart` (load-isolation + fillTour)
