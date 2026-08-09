# Customer chart booking: layout, motion, party gate, multi-bus basket, payment lifecycle

**Date:** 2026-08-09
**Status:** Design approved — not yet implemented
**Branch:** `feat/money-collection-settlement`

> **Scope note.** This spec deliberately covers five workstreams in one document. That was flagged during
> design as a risk (a spec this wide tends to go vague in its largest section) and the decision was taken
> to keep them together anyway, because they share the same screens and the same seat-availability truth.
> The mitigation is §8: each workstream has its own build step, its own tests, and ships standing alone.

## Problem

Three defects surfaced on the same screen, plus two missing features and one unverified invariant.

### Evidence

A live test on `[TEST-A] Chart Booking` (seed `supabase/seeds/test_tours.sql`, sleeper 36) produced three
screens that disagreed:

| Surface | Showed | Correct? |
| --- | --- | --- |
| Customer chart | `DU3` / `DU4` / `DU5` faded (3 whole double sofas = 6 berths) | **Yes** — an active hold |
| Agent chart | `TEST BUS A1 — 0/36` | **Yes** — no passenger row written yet |
| Customer "My requests" | `[TEST-A] Chart Booking — Cancelled, 6 seats` | **No** — the booking was live |

The customer had selected 6 berths on a tour that collects an advance, then dismissed the UPI sheet
without asserting payment.

### Root cause A — a live hold is indistinguishable from a deleted request

On the advance path, `chart_hold_seats` (migration 064) writes **only** a `seat_holds` row. The
`booking_requests` row is created later, by `chart_finalize_hold`, once the advance is confirmed.

`CustomerRequestsStore.refresh()` (`lib/services/customer_requests_store.dart:371`) calls
`booking_request_status_lookup` and treats an empty result as proof the organiser deleted the tour:

```dart
if (rows.isEmpty) {
  if (existing.status == 'rejected') return existing;
  final cancelled = existing.markCancelled(at: DateTime.now());
  await upsert(cancelled);
  return cancelled;
}
```

`markCancelled()` writes `status: 'rejected'`, which `isCancelled` maps to the "Cancelled" chip. Every
held-but-unpaid chart booking therefore self-brands as cancelled on the first refresh. Nothing in the
database is corrupt — the hold expires on schedule and the seats free — but the customer's ticket is
permanently mislabelled.

### Root cause B — the customer payment flow dead-ends

`seat_booking_confirm_screen.dart:281`:

```dart
if (claim == null) return;   // sheet dismissed → silently nothing
```

Dismissing the UPI sheet leaves the hold alive, shows `seat_confirm.success_held`, and pops the screen.
There is then no route back to paying: `customer_my_requests_screen.dart` has no hold surface at all — no
countdown, no retry, no expiry notice. Pay-later exists only for the organiser
(`tour_money_board_screen.dart:244`). An abandoned advance is unrecoverable from the customer's side.

### Root cause C — customer seat tiles have no fixed size

`_WholeTile` (`lib/components/chart_seat_tile.dart:131`) is a `Container` sized by its text.
`_SplitTile` is hardcoded to `34 × 17` berths plus padding (`chart_seat_tile.dart:199`).
`CombinedSeatGrid._slot` wraps both in `FittedBox(fit: BoxFit.scaleDown)` inside a 44 × 46 slot
(`lib/components/combined_seat_grid.dart:317`).

`scaleDown` never scales *up*, so each tile renders at its own natural size. A single (one text line)
becomes a short pill; a double (two lines — seat id plus the `2`) becomes a taller rounded blob. That is
the `SU1`-pill vs `DL1`-blob mismatch on screen.

The same defect causes the poll flicker. `_refreshAvailability` runs every 20s. When a poll turns a free
double into a half-taken one, the tile switches from `_WholeTile` to `_SplitTile` — a *different physical
size* — so the `FittedBox` rescales and the whole row reflows.

### Root cause D — no motion, and no page transition theme

`seat_selection_screen.dart` contains no `AnimatedContainer`, no `UgamMotion`, no transition of any kind.
The leg pills at `seat_selection_screen.dart:324` are hand-rolled `GestureDetector` + `Container`, while
the design system already ships an animated `UgamSelectorPills`. Separately, the app defines **no**
`pageTransitionsTheme` anywhere, so Android falls back to the default zoom transition while the chart
lays out ~24 `FittedBox` tiles and swaps a spinner for content on the same frame.

### Missing — party intent, and multi-bus booking

A customer cannot state how many people they are before opening the chart, so the chart cannot filter
buses that could never seat the party. And `claim` / `hold` both take a single `p_bus_id`
(`lib/services/seat_chart_booking_service.dart:140`), with `_picks` cleared on every bus switch, so a
party that is willing to split across buses has no way to book in one transaction.

### Unverified — the shared-sofa invariant

Half-double selling is implemented three times: `berthsOfCell` (`lib/utils/chart_seat_availability.dart:81`),
the tap-cycle `1 → 2 → off` (`seat_selection_screen.dart:149`), and `chart_claim_seats` in migration 048.
They currently agree, but no test asserts the Dart/SQL parity, so a future edit to one can silently
diverge from the others.

---

## §0 Foundations

### Data model for a party split across buses

**Decision: one `passengers` row and one `booking_requests` row per bus**, created inside a single
advisory-locked transaction, all-or-nothing across every bus. They are linked by a new nullable
`party_id` used **for customer display only**.

Two alternatives were rejected on evidence:

- **One passenger row spanning buses.** Five call sites treat `assignedSeats.first.busId` as *the* bus
  for a passenger — including billing (`lib/controllers/money_controller.dart:966`), the WhatsApp ticket
  (`lib/services/whatsapp_outbound.dart:198`), tour detail (`lib/screens/tour_detail_screen.dart:1781`)
  and seat assignment (`lib/screens/tour_seat_assignment_screen.dart:242`). A split party would be billed
  entirely to one bus and vanish from the other's manifest.
- **Multiple rows linked by `groupId`.** `lib/services/seating_engine.dart:419` raises `groupWontFit` with
  *"Group is locked across multiple buses"*. A deliberately split party would sit on the organiser's
  seating-exceptions screen permanently.

The chosen model keeps every passenger row's seats inside exactly one bus, so **no downstream consumer
changes at all**. `party_id` lives on `booking_requests` and `seat_holds` only — never on `passengers`,
so the seating engine cannot see it and cannot act on it.

### Berth counting

The party gate asks in **people**; fit is explained in **sofas** ("Bus A1 fits your 4 — 2 whole sofas").
One berth is one person. A double sofa is two berths, everything else one — matching `berthsOfCell` and
`case when seatType = 'doubleSofa' then 2 else 1` in 048.

**Cap correction.** Migration 048 caps `jsonb_array_length(p_seats) > 6` — that counts *cells*, not
berths, so a direct RPC call could book 12 berths as 6 doubles. The app cannot reach it (the client caps
berths at 6, `seat_selection_screen.dart:58`), so this is a hardening fix rather than a live bug. The new
multi-bus RPCs count berths and cap at 6 for the whole party.

---

## §1 Chart tile geometry

Give `_WholeTile` and `_SplitTile` one shared fixed size, exported as a small `ChartSeatMetrics` const
class so the two cannot drift apart again. `FittedBox` then stops being the layout mechanism and becomes
only a safety net for unusually wide bench rows.

- Both tiles occupy an identical footprint, so `SU1` and `DU1` read as the same object.
- The berth-count `2` becomes a corner badge rather than a second text line, so it no longer changes the
  box height.
- A free → half-taken transition no longer changes the tile's size, which removes the row reflow and
  therefore the poll flicker (root cause C, second symptom).
- Tile scale, the dashed empty-seat treatment and the chassis outline follow the agent chart for
  consistency — minus any occupant identity, which the customer must never see.

Per the recorded density preference, this is a geometry correction, not a re-widening: the shared size is
chosen to match the current cockpit density, not to inflate it.

## §2 Motion

| Element | Change |
| --- | --- |
| Leg pills | Replace the hand-rolled pills with the existing animated `UgamSelectorPills` |
| Seat tap | `AnimatedContainer` on fill/border at `UgamMotion.tapOut`, plus the press-scale pattern from `lib/design/components/ugam_card.dart` |
| Footer | Animate in on the first pick instead of appearing instantly |
| Split halves | Animate the half fill rather than snapping |
| Page push | Add a `pageTransitionsTheme` to the app theme (currently absent app-wide) |
| First frame | Replace the bare `CircularProgressIndicator` with a chart skeleton, so spinner → content is not a second layout jump |
| Poll | Skip `setState` when the availability map is unchanged |

The page-transition change is app-wide, not chart-only. It must be checked against the customer and agent
shells for regressions before merge.

## §3 Party gate

A new screen pushed **before** `SeatSelectionScreen`.

- **"How many people?"** — 1–6 chips.
- **"Same bus, or can you split?"** — rendered **only when the tour has more than one bus**. Single-bus
  tours skip the question entirely, since it has no meaning there.
- Result is a `PartyIntent { people, mustBeTogether }` passed to the chart.

Fit logic goes in a new pure-Dart `lib/utils/party_fit.dart` — no Flutter imports, so it is unit-testable
without a widget pump:

```
busFit(layout, availability, leg, people) → { freeBerths, wholeSofas, fitsWholeParty }
```

On the chart: a "4 of 4" progress meter, and per-bus fit explained in sofas. When `mustBeTogether` is set,
buses that cannot seat the whole party are shown disabled with the reason stated rather than hidden, so
the customer understands why an option is missing.

## §4 Multi-bus basket

### Client

`_picks` (a flat `Map<String,int>`) becomes a `ChartBasket` keyed by bus id. Switching bus tabs stops
clearing the selection (`seat_selection_screen.dart:387`). Totals sum across buses using the existing
`Bus.berthPriceFor` × `Bus.tripFactor`, so the quote still cannot drift from the invoice.

### Server — migration `068_multi_bus_chart_claim.sql`

- `alter table booking_requests add column party_id uuid` (nullable, indexed).
- `alter table seat_holds add column party_id uuid` (nullable, indexed).
- `chart_claim_seats_multi(p_party_id, p_tour_id, p_phone, p_name, p_leg, p_buses jsonb, …)` where
  `p_buses = [{busId, requestId, seats:[{seatId, berths}]}, …]`.
- One `pg_advisory_xact_lock` on the tour, exactly as 048. Loop the buses, re-validate every seat against
  the bus's own layout (never trust the client for seat type, capacity or the reserved flag), accumulate
  conflicts, and **abort the entire claim if any single seat across any bus is lost**.
- Insert one passenger + one booking_request per bus, each carrying `party_id`.
- `chart_hold_seats_multi` mirrors this, producing N holds that share a `party_id` and finalize together.
- Berth-based cap (§0), replacing the cell-based one.

048's single-bus `chart_claim_seats` / `chart_hold_seats` stay in place untouched — they remain the path
for single-bus bookings and for any client that has not updated.

Per the recorded live-only-RPC rule, migrations are applied **by hand, one file at a time**, and nothing
here replaces an existing live function.

## §5 Payment lifecycle

### Status resolution

`refresh()` stops equating "not found" with "cancelled". New resolution order:

1. `booking_requests` row exists → use its status (today's behaviour).
2. Else a **pending, unexpired** hold exists → `held`, carrying `holdExpiresAt`.
3. Else a hold exists but is expired or released → `expired`.
4. Else → `cancelled`.

`booking_request_status_lookup` exists **only in the live database, not in this repo**. Per the recorded
rule, it must not be blind-replaced. Step 2 therefore uses a **new** RPC —
`chart_hold_status_lookup(p_request_ids uuid[])`, returning `{request_id, status, expires_at, bus_id,
seats}` — and the two results are merged client-side.

### Client

- `CustomerRequestEntry` gains `holdExpiresAt` and the `held` / `expired` states.
- My Requests renders a live countdown chip and a **Pay ₹X advance** button for a held booking.
- On expiry: "Hold expired — book again", linking back into the chart.
- Dismissing the UPI sheet **keeps the hold** (decided during design) and surfaces it with the countdown,
  rather than releasing the seats or prompting.
- `_offerAdvance` is lifted out of `seat_booking_confirm_screen` into a shared service so the confirm
  screen and My Requests drive the identical payment path.

### Organiser

`tour_money_board_screen`'s pending-holds list already exists and already wires pay-later. Finish it: show
who, which seats, and time remaining, so an organiser can confirm a customer who paid by cash or another
channel.

## §6 Shared-sofa audit

Establish and lock the Dart ↔ SQL parity that currently holds by convention only.

Test matrix:

| Case | Asserts |
| --- | --- |
| Solo takes 1 of 2 on a double | Half-sale works; tile splits |
| Second stranger takes the other half | `partlyTaken` → `taken`; no double-sale |
| Go-only + return-only on one berth | Disjoint legs share a berth (`freeBerths` leg arithmetic) |
| Round-trip against a half-taken double | Limited by the busier leg, `capacity - max(usedGo, usedRet)` |
| Lady marker on a shared half | Marker shows without blocking the booking |
| Berth-vs-cell cap | 6 doubles is rejected as 12 berths, not accepted as 6 cells |
| Multi-bus all-or-nothing | One lost seat in bus B rolls back bus A entirely |

Existing coverage to extend rather than duplicate: `test/utils/chart_seat_booking_test.dart`,
`test/utils/seat_leg_capacity_test.dart`, `test/utils/stranger_share_seat_test.dart`,
`test/components/seat_chart_tile_half_double_test.dart`.

---

## §7 Testing strategy

- **Pure Dart** — `party_fit.dart`, `ChartBasket`, the status-resolution order, `freeBerths` parity.
  No Flutter imports, so these stay fast.
- **Widget** — party gate flow, tile geometry (assert both tile types report the *same* size), countdown
  and Pay-advance button in My Requests.
- **SQL** — a diagnostic script under `supabase/diagnostics/` exercising `chart_claim_seats_multi`
  conflict rollback against the seeded test tours.
- **Regression guard** — a test asserting a live hold never renders as cancelled. This is the failing
  test that must be written *first*, since it reproduces the reported defect directly.

Note for widget tests: `plural()` throws `LateInitializationError` unless a locale is loaded in
`setUpAll`; `tr()` is safe. Any countdown copy using plurals needs that setup.

## §8 Build order

1. **Tiles + motion** (§1, §2) — client only, no migration, immediately visible, and it removes the poll
   flicker as a side effect.
2. **Shared-sofa audit** (§6) — cheap, and it is the safety net §4 depends on.
3. **Payment lifecycle** (§5) — unblocks live testing. Migration `067_chart_hold_status_lookup.sql`.
4. **Party gate** (§3) — client only, depends on nothing above but reads better after §1.
5. **Multi-bus basket** (§4) — largest, and built on all of the above. Migration `068`.

Payments is third rather than last so that end-to-end testing is unblocked before the two large features
land.

## §9 Risks

- **App-wide page transition** (§2) touches every screen, not just the chart. Verify the customer and
  agent shells before merge.
- **`party_id` must never reach `passengers`.** If it does, a future engine change could start treating a
  split party as a group and re-raise `groupWontFit`.
- **Migrations 067 and 068 must be applied by hand**, one file at a time, and must not replace any
  live-only RPC. 065 and 066 are the latest in the repo, so these are the next two numbers.
- **Another agent edits this working tree concurrently.** Re-run any failing analyze/test before treating
  it as a real failure.
- **Hold TTL is 5 minutes.** The countdown makes that visible to customers for the first time; if it
  proves too short in practice, the TTL is a 064 constant and changing it is a separate decision.
