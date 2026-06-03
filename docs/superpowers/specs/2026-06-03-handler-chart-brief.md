# Handler Bus Chart — Design Brief

**Date:** 2026-06-03
**Branch:** `feat/money-collection-settlement`
**Area:** The read-only (now read + collect) screen the appointed tour handler uses on travel day.
**Status:** Audit + redesign direction. Not final code.

---

## 1. What this screen is for

Every tour has one mandatory **handler** — a passenger flagged `is_handler = true`
(`tours.handler_id`). The handler runs the group on the ground: they need to find any
seatmate, call them, and (as of the money work) **collect cash per seat** and settle.
The handler is NOT an app user — they arrive through the anonymous "My Requests"
customer flow holding a `booking_request` id, and every privileged read/write is gated
server-side by an `is_handler` check keyed off that request id.

Files in scope:
- Spec (canonical, now stale): `docs/superpowers/specs/2026-06-01-handler-full-bus-chart-design.md`
- Screen: `lib/screens/handler_bus_chart_screen.dart`
- Model: `lib/models/handler_manifest.dart`
- Data layer: `lib/services/customer_requests_store.dart:295-337`
- Server: `supabase/migrations/003_handler_tour_manifest.sql`, `supabase/migrations/004_handler_collections.sql`
- Entry point: `lib/screens/customer_my_requests_screen.dart:44-67, 230-266, 636+`
- Agent twin (read-only): `lib/screens/bus_status_screen.dart`
- Agent twin (money): `lib/screens/collection_screen.dart`
- Grid: `lib/components/combined_seat_grid.dart`
- Pricing source of truth: `lib/models/bus_details.dart:288-301` (`amountDueForSeat`)

---

## 2. Current state (honest)

### 2a. The screen drifted far past its own spec
The approved 2026-06-01 spec describes a **pure read-only twin** of the agent chart:
tap an occupied seat → sheet with name + age + phone + **Call**; "No editing/reassigning
from the handler view" (spec lines 25-29, 87-117). It is explicitly read-only.

The screen as built (`handler_bus_chart_screen.dart`) is **no longer read-only**. It is a
full **cash-collection console**:
- The tap sheet is `_CollectSheet` (lines 770-1049): name + HANDLER chip + age + phone +
  Call, **plus** Received / Returned / Collected-by / Note inputs, a live balance pill,
  and a **Save** button that writes to the DB.
- Each occupied tile is recolored by **collection status** (`_statusColor`, lines 432-441):
  warm = return due, danger = shortfall, good = paid, `ink3` = not collected.
- A per-bus money `_SummaryHeader` (Collected / To return / To collect) sits above the grid.
- Persistence goes through `CustomerRequestsStore.handlerUpsertCollection` →
  `handler_upsert_collection` RPC (migration 004), gated on `is_handler` AND on the
  passenger+bus belonging to the handler's tour.

So the handler can now **write** money rows. This is a real product decision that happened
in code (migration 004 + the rewritten screen) but the canonical spec still says "read-only,
out of scope." **The spec and the build disagree — this brief exists partly to reconcile them.**

### 2b. What works well
- The `CombinedSeatGrid` reuse is clean: same placement engine as the agent, caller owns
  appearance via `tileBuilder` (grid `_SeatGrid`, lines 417-496).
- Privacy boundary is solid: full manifest + writes live behind `SECURITY DEFINER` RPCs
  gated on `is_request_handler`; non-handlers get `null`, never names/phones (003/004).
- The collect sheet faithfully mirrors `collection_screen._openCollectSheet`, so the
  handler's money UX matches the agent's.
- Entry point is gated correctly: `customer_my_requests_screen` caches `isRequestHandler`
  per request id and only renders "View full bus chart" for handlers (lines 44-67, 636+).
- Server-returned collection rows are cached back into `_collections` so ids/timestamps
  stay aligned after an upsert (lines 187-194).

### 2c. Real problems / gaps
1. **Seat tile is overloaded.** Each 56×58 tile (`_SeatTile`, lines 498-701) crams seat id,
   type mark, **name**, **10-digit phone**, AND is tinted by collection status. The phone
   on every tile is privacy-noisy and visually heavy; on a 20-25 bus tour the grid is a wall
   of phone numbers. The seat redesign DNA says the tile should be quiet — "groups/priority
   are just a colored ring on the tile," actions live in a sheet on tap.
2. **No group / priority context.** The manifest carries no `group_id`, no `priority_status`.
   The seat redesign makes these first-class (named groups on one bus; approved priority seated
   in front). The handler — the person physically loading the bus — is exactly who needs to
   see "these 6 are one family" and "this elder must be up front," yet the chart can't show it.
3. **`seatOccupant` is a linear scan, run per cell.** `HandlerManifest.seatOccupant`
   (`handler_manifest.dart:58-64`) loops every passenger and does
   `assignedSeats.contains(target)` (itself O(seats-per-passenger)) for **every tile** the
   grid builds. Per bus that is O(cells × passengers). Across 20-25 buses and the whole
   tour's passenger list (~1000 people), each pill switch re-renders the grid and re-scans.
   It works today but is the obvious scaling cliff the task flagged.
4. **No offline / no-signal handling.** `_load()` (lines 99-127) is a single RPC; failure →
   generic error card, no cache. On the bus, with no signal, the handler sees nothing — and
   a `Save` failure just throws a snackbar and keeps the unsaved cash in a text field. There
   is no pending-ops queue here, unlike the rest of the app's offline-first writes.
5. **`age_group` is shown but is being deprecated.** The collect sheet prints
   `passenger.ageGroup.displayName` (line 922) and the manifest returns `age_group`
   (003/004). The seat redesign explicitly **drops gender and de-emphasizes age** (priority is
   an approved request, not derived from age). Showing age group here is mild dead weight.
6. **Stale data after collect.** The chart recolors locally on save, but two handlers on the
   same bus (or the agent on `collection_screen` simultaneously) won't see each other's writes
   — no realtime, no re-fetch. The unique index `(passenger_id, bus_id, seat_id)` means
   last-write-wins silently overwrites.
7. **Whole-double-sofa charging is fragile.** `amountDueForSeat` returns the **per-berth**
   price (`bus_details.dart:291-301`); a whole double sofa is two assignment entries on the
   same `seatId`. The collect flow is keyed per `(passenger, bus, seatId)`, so a single
   passenger holding both berths of a double could be undercharged if the two entries collapse
   to one collection row. The per-bus-pricing spec (section 4) flags this exact risk as
   "verify during planning." It is unverified here.

---

## 3. Proposed direction (consistent with seat redesign + DNA)

Keep the handler chart as a **read-first, collect-on-tap** screen — one screen, one job — but
calm the tile, add group/priority context, and make it survive a bus with no signal.

**Tiles go quiet.** Drop the inline phone from the tile. Show only: seat id + type mark +
**short name** + a **collection-status fill** + a **group/priority ring** (per the seat
redesign: "groups/priority are just a colored ring on the tile"). Phone, Call, and the
collect form live in the tap sheet — where they already are. This matches the agent chart's
own direction and de-clutters the 20-25 bus wall.

**Surface group + priority.** When the planned `passenger_groups` / `group_id` and
`priority_status` land, extend `handler_tour_manifest` to return them and render: a colored
ring for grouped passengers (one color per group, or a single "grouped" ring), and the warm
attention color reserved by DNA for **approved** priority. The tap sheet shows the group name
("Patel family — 6") and a PRIORITY chip. The handler loading the bus is the primary consumer
of "who travels together."

**Fix the scan.** Precompute a `Map<(busId, seatId) → Passenger>` once when the manifest
loads (and a `Map<busId → List<Passenger>>` for the per-bus money summary), instead of scanning
per tile. This collapses each render from O(cells × passengers) to O(cells) lookups and makes
pill-switching instant at 25 buses.

**Make it work on the bus.** Cache the last successful manifest to disk (the app is already
offline-first with a SQLite cache + pending-ops queue — reuse that pattern, don't invent a new
one). On `Save` without signal, queue the collection as a pending op and reflect it optimistically
in the local `_collections` cache; flush when connectivity returns. Show a clear "saved on device,
will sync" vs "synced" state so the handler trusts what they entered.

**Reconcile the spec.** The screen is a money tool now; update the canonical spec to say so
(or split: read-only chart vs. handler-collect mode behind a flag — see open questions). Drop
`age_group` from the manifest + sheet to match the redesign, unless the agent still wants it.

**Stay inside the DNA.** Status fill + ring, big rounded geometry, tabular figures on all
money, sticky `Save` CTA in the thumb zone, Gujarati-default strings. Reserve `c.warm` strictly
for the one attention case (approved priority and/or "return change to customer").

---

## 4. Concrete data-model / DB changes

1. **Manifest: add group + priority fields** (when the seat redesign lands them).
   - `passengers`: `group_id uuid null` (+ a `passenger_groups` table: `id, tour_id, name`),
     `priority_status text` (`none|requested|approved|declined`), `priority_reason text null`.
   - Extend `handler_tour_manifest` (migration 006+) to emit `group_id`, `group_name`,
     `priority_status` per passenger so the ring/chip can render. Add to
     `Passenger.fromMap` / `HandlerManifest`.
2. **Manifest: add reserved/blocked + locked seat flags.** The seat redesign puts a per-seat
   `reserved/blocked` flag in the layout and a "locked" flag on manual placements. The handler
   should at least *see* reserved seats (the handler's own front/door seat) distinctly. If
   these live in `BusLayout`'s jsonb cells, no migration is needed — just render them; confirm
   `SeatCell` carries them.
3. **Precompute indices in `HandlerManifest`** (Dart-only, no DB): build
   `Map<String, Passenger> _occupantBySeatKey` (key `"$busId|$seatId"`) and
   `Map<String, List<Passenger>> _passengersByBus` in the constructor/factory; replace the
   linear `seatOccupant` scan. Pure refactor of `handler_manifest.dart:58-77`.
4. **Drop `age_group` from the manifest + sheet** (003/004 SQL + `_CollectSheet` line 922) to
   match the redesign — pending the open question on whether the agent still wants it.
5. **Offline write path.** Either route `handler_upsert_collection` through the existing
   pending-ops queue/SQLite cache, or add a handler-scoped local journal mirroring
   `CustomerRequestsStore`'s SharedPreferences pattern. No new server objects required;
   migration 004's upsert is idempotent on `(passenger_id, bus_id, seat_id)`, which is
   queue-safe.
6. **Whole-double-sofa charge integrity.** Verify (and add a unit test) that a passenger holding
   both berths of a double generates two collection contributions, not one — per the per-bus
   pricing spec section 4 caveat. May need a composite seat key (e.g. `seatId#berth`) in the
   collect key, which `amountDueForSeat` already half-anticipates via its `split('#')` on
   `bus_details.dart:294`.

---

## 5. Dependencies

- **Seat-assignment redesign (hard dependency).** Group rings and priority chips on the
  handler chart are meaningless until `passenger_groups` + `group_id` + `priority_status` exist.
  The handler chart should render whatever the new manifest exposes — so it must ship *after*
  (or alongside) the seat-model migration, and the manifest RPC must be extended in lockstep.
  Buses being interchangeable (single pickup) is already true here — the handler sees all buses.
- **Money / collection design (already entangled).** This screen is now the handler's leg of
  `2026-06-01-money-collection-settlement-design.md`. It shares the `Collection` model,
  `amountDueForSeat`, and the collect sheet shape with the agent's `collection_screen.dart`.
  Any change to pricing math (`2026-06-03-per-bus-row-zone-pricing-design.md`) flows through
  automatically because both call `Bus.amountDueForSeat()` — but the whole-double caveat
  (section 4.6) must be resolved in the money work, not just here.
- **The agent twins.** `bus_status_screen.dart` (read-only chart) and `collection_screen.dart`
  (money) are the agent-side mirrors. The handler chart should stay visually and behaviorally
  consistent with both: same `CombinedSeatGrid`, same status colors, same collect sheet. If the
  agent chart adopts quiet tiles + rings, the handler chart must follow, and vice-versa.
- **Privacy RPCs.** Any new field added to the manifest widens what an anonymous (gated) handler
  can read. Every manifest extension must stay behind `is_request_handler` and return `null`
  for non-handlers.

---

## 6. Risks

- **Spec/build divergence shipping silently.** The canonical spec says read-only; the build
  collects cash. If not reconciled, the next person trusts the wrong document.
- **Two writers, last-write-wins.** Handler + agent (or two handlers) editing the same
  `(passenger, bus, seat)` collection silently overwrite via the unique index. No conflict
  surfaced.
- **Cash entered, not saved.** No offline queue today: a `Save` failure on the bus loses the
  entry (it stays in a text field that's gone on navigation). Real-money correctness risk.
- **Tile overload hurts the core read job.** Phone-on-every-tile + status tint makes the
  "find a seatmate fast" job slower, not faster, especially across many buses.
- **Performance cliff at scale.** The per-tile linear scan is fine at demo size, ugly at
  ~1000 passengers × 25 buses, and gets worse each pill switch.
- **Whole-double undercharge.** If the collect key collapses a whole double sofa to one row,
  the tour loses real money and it won't be obvious.
- **Showing phone numbers of the whole tour to a handler.** Even gated, putting every
  passenger's phone on a visible grid (vs. on tap) is a wider exposure than the spec's
  tap-to-reveal intent.

---

## 7. Open questions (need the agent's decision)

These are the hidden rules only you can settle; each has candidate options.

1. **Can the handler EDIT anything, or is it read + collect only?**
   The build already lets the handler write `collections` (cash). Is that the intended ceiling,
   or should they also (re)assign seats, mark no-shows, swap passengers between buses on the day?
   - **Options:** (a) Read + collect cash only (current build; lock everything else).
     (b) Read + collect + mark attendance/no-show (a lightweight boarding flag).
     (c) Full seat reassignment on the day (handler can move a passenger to another bus).
   - *Why it matters:* defines the entire write surface, the RLS RPCs needed, and whether the
     "read-only twin" framing in the canonical spec is dead.

2. **Should the handler see money owed per seat at all — and how much detail?**
   The chart currently tints every seat by collection status and shows a per-bus money summary.
   - **Options:** (a) Full money (current: due, received, balance, summary).
     (b) Collect-only — show "to collect ₹X" on tap but hide the tour-wide totals/summary
     from the on-bus handler. (c) No money on the chart; collection lives on a separate handler
     screen, chart stays a pure seat/contact view.
   - *Why it matters:* determines how sensitive the manifest is and whether the chart stays a
     "find people" tool or becomes a "settle money" tool.

3. **What should the handler do with no signal on the bus?**
   Today: blank error on load, lost entry on save.
   - **Options:** (a) Cache last manifest + queue collections in the existing offline pending-ops
     pipeline; flush on reconnect (most consistent with the app). (b) Read-only offline (show
     cached chart, disable Save until online). (c) Require connectivity (status quo; simplest,
     riskiest for real cash).
   - *Why it matters:* yatra routes routinely lose signal; this decides whether cash entries are
     ever lost.

4. **How much should a tile show vs. the tap sheet?**
   - **Options:** (a) Quiet tile: seat id + short name + status fill + group/priority ring;
     phone/Call/collect in the sheet (recommended, matches DNA). (b) Keep name + phone on the
     tile (current). (c) Name only, no status color (pure occupancy), money entirely in the sheet.
   - *Why it matters:* drives legibility across 25 buses and how much passenger PII is exposed at
     a glance.

5. **How should groups and approved priority appear to the handler?**
   (Once `group_id` / `priority_status` exist.)
   - **Options:** (a) One ring color = "grouped" + warm ring = "approved priority"; group name
     in the sheet. (b) A distinct ring color per group (rainbow) so families read at a glance —
     risks clashing with the single-accent DNA. (c) No rings; a separate "Groups" list/tab that
     names each group and its seats.
   - *Why it matters:* the handler physically loads families together; this is their key context,
     but rainbow rings fight the locked single-accent palette.

6. **Drop `age_group` from the handler view?**
   The redesign de-emphasizes age (priority is an approved request, not derived).
   - **Options:** (a) Drop it from manifest + sheet. (b) Keep it (handler still finds it useful
     for elders/kids on the ground). (c) Replace it with the priority chip only.
   - *Why it matters:* leaner data + consistency with the seat redesign vs. on-the-ground utility.

7. **Multiple handlers per bus, or one handler for the whole tour?**
   The money spec says "one handler per bus"; the chart spec implies one tour-level handler
   (`tours.handler_id`). The collections unique index is per `(passenger, bus, seat)`, not
   per handler.
   - **Options:** (a) One tour handler sees/collects across all buses (current chart model).
     (b) One handler per bus, each scoped to their own bus (matches the money spec; needs
     per-bus handler identity + scoping in the RPC). (c) Multiple handlers, shared collect with
     conflict detection.
   - *Why it matters:* changes the gating model, who-collected-what attribution, and whether the
     last-write-wins overwrite is acceptable.
