# Per-Bus Row-Zone Pricing — Design Spec

**Date:** 2026-06-03
**Branch:** `feat/money-collection-settlement`
**Status:** Approved model, pending written-spec review

## 1. Problem

Pricing is no longer shown to customers — it is an admin-internal value that feeds
money collection and handler settlement. The agent needs richer pricing than a
single per-tour number:

- Each **bus** on a tour can have its own per-seat price (e.g. Bus A ₹20,000,
  Bus B ₹22,000, Bus C ₹21,700).
- Within a bus, the **last N rows** are priced differently from the front rows
  (e.g. last 2 rows cheaper than the front 4–5).

Per-bus pricing already exists (`Bus.pricePerSeat`). What is missing is
**per-row-zone** pricing inside a bus.

## 2. Pricing model (decided)

- Price is **per person (per berth)** and is driven by **row position**.
- A **Double Sofa** seats two people, so its whole-sofa price = 2 × the row's
  per-seat price (each berth is a separate assignment entry, charged once).
- Two price tiers per bus: a **base** price for the whole bus and an optional
  **rear-zone** price for the last N rows.
- The existing **seat-type overrides** (single / double / seater) are **kept** as
  optional tuning for the **front (non-rear) rows**.

### Per-bus fields

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `pricePerSeat` | double | 0 | Base per-person price (existing). |
| `rearRows` | int | 0 | How many of the **last** rows form the rear zone. `0` = no rear zone. |
| `rearPrice` | double? | null | Per-person price for rear-zone rows. Null ⇒ rear rows fall back to base. |
| `singleSofaPrice` | double? | null | Optional per-person override for single-sofa berths (existing). |
| `doubleSofaPrice` | double? | null | Optional **whole-sofa** override for double sofas (existing). |
| `seaterPrice` | double? | null | Optional per-person override for seater seats (existing). |

### Rear-zone definition

Rows are indexed `0` (front) … `layout.rows - 1` (back). The rear zone is the set
of rows with index in `[layout.rows - rearRows, layout.rows - 1]` — i.e. the last
`rearRows` rows. `rearRows` is clamped to `[0, layout.rows]`.

> Note on the lane layout: a "row" is one cross-section of the bus (single-sofa
> lane + aisle + double-sofa lane). Because lanes can differ in length, the back
> rows may contain only one lane's seats — that is fine; pricing keys purely off
> the seat's `row` index.

### Price resolution (per berth = one person)

Precedence, evaluated per assigned seat:

1. **Rear zone wins for rear rows.** If the seat's row is in the rear zone **and**
   `rearPrice` is set → `rearPrice` (per person, all seat types; a whole double in
   the rear zone = 2 × `rearPrice`).
2. **Front rows** (or rear zone with no `rearPrice`): apply the seat-type override
   if set for that type, else `pricePerSeat`.
   - single / seater override → per-person value as-is.
   - double override → whole-sofa value; one berth = override / 2.
3. Multiply the resolved berth price by the **trip factor**
   (`roundTrip = 1.0`, single-leg = `0.5`) — unchanged from today.

This keeps "the last 2 rows are ₹X" literal, while front rows retain seat-type
override flexibility.

> **Behavioural change — double-sofa base semantics.** Today, with no
> `doubleSofaPrice` set, a *whole* double sofa costs `pricePerSeat` (one berth =
> `pricePerSeat / 2`). Under the per-person model this changes: a berth = the row's
> per-seat price, so a *whole* double sofa = **2 × the row price**. This is the
> decided model (a double sofa seats two people). The `doubleSofaPrice` override
> path still treats its value as the *whole-sofa* price (berth = override / 2), so
> agents who want the old "whole = one seat price" behaviour can set that override.

### Worked example

Bus base price **₹10/seat**, rear zone = **last 2 rows at ₹8/seat**, no per-type
overrides:

| Seat | Where | Whole price | One shared berth |
|------|-------|-------------|------------------|
| Single sofa | front | ₹10 | — (1 person) |
| Double sofa | front | **₹20** (2 × ₹10) | ₹10 |
| Seater | front | ₹10 | — |
| Single sofa | rear (last 2 rows) | ₹8 | — |
| Double sofa | rear | **₹16** (2 × ₹8) | ₹8 |

A one-way leg (outbound-only / return-only) halves every figure above.

## 3. Code changes

### `lib/models/bus_details.dart`
- Add `rearRows` (int, default 0) and `rearPrice` (double?) to fields,
  constructor, `toMap`, `fromMap`, `copyWith`.
- Add helper `double perSeatPriceForRow(int row, {required SeatType type})`
  implementing the precedence above (without the trip factor).
- Rewrite `amountDueForSeat(passenger, seatId)` and `amountDueFor(passenger)` to
  resolve via row + type instead of type only. Both already iterate `layout.grid`,
  so the seat's `row` is available; build a `{seatId: (row, type)}` lookup.
- `berthPriceForType` / `priceForType` stay for the front-row override path.

### `lib/models/seat_layout.dart`
- No structural change. `BusLayout.rows` already gives the row count and each
  `SeatCell` carries `row`. Optionally add a small helper
  `bool isRearRow(int row, int rearRows)` for reuse by the UI highlight.

### Admin UI — `lib/screens/add_bus_screen.dart` (Step 3 "price")
- Keep the base **"Price per seat"** input.
- Add a **"Rear-zone pricing"** group: a number input
  *"Last how many rows priced differently?"* (0 = none) and a
  *"Rear-row price (per seat)"* input shown when count > 0.
- Move the three seat-type override inputs under a collapsed
  **"Per-type overrides (optional)"** section to reduce clutter; they apply to the
  front rows.
- The seat-grid preview **highlights the rear-zone rows** so the agent sees exactly
  which seats are affected before saving.

### DB migration — `supabase/migrations/005_bus_rear_zone_pricing.sql`
```sql
ALTER TABLE buses
  ADD COLUMN IF NOT EXISTS rear_rows  integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rear_price numeric NULL;
```
Old seat-type price columns are left in place (no destructive drop).

## 4. Settlement / collection impact

No changes required in `collection_screen.dart` or `handler_bus_chart_screen.dart`
— they already call `Bus.amountDueForSeat()` per assignment entry, so they pick up
the new resolution automatically. Each `Collection.amountDue` is still computed and
stored at collection time, so settlement math stays correct.

**One server-side exception (handler manifest).** The handler app builds its `Bus`
objects from the `handler_tour_manifest()` RPC's per-bus JSON, which did **not**
include the new columns — so handlers would have priced every rear-zone seat at the
base price. Migration `006_handler_manifest_rear_zone.sql` re-creates the function
with `rear_rows` / `rear_price` added to the buses payload (mirrored in
`database.sql`). `Bus.fromMap` already parses the fields, so no Dart change is
needed on the handler side.

> **Implementation check — whole double sofas.** A whole double sofa is two
> assignment entries on the same `seatId`. `amountDueForSeat()` returns the
> *per-berth* price, so the two entries must each contribute (2 × per-person total)
> wherever `Collection.amountDue` is persisted. Verify `MoneyController` stores the
> berth price per entry (not one row per unique `seatId`) so whole doubles are not
> undercharged. This is an existing concern surfaced by the per-person change, not
> new scope — confirm during planning.

## 5. Back-compatibility & migration

- Existing buses load with `rearRows = 0` → every row stays at base price; any
  existing seat-type overrides keep working exactly as before. No behaviour change
  for already-created buses.
- New buses default to `rearRows = 0` until the agent sets a rear zone.

## 6. Out of scope

- Dashboard / settings **revenue estimates** keep using the rough
  `tour.pricePerSeat × seats`. Precise revenue already comes from actual
  collections, not the estimate.
- No per-individual-seat pricing (row granularity is sufficient — YAGNI).

## 7. Testing

Unit tests on `Bus` fare resolution (`test/` mirrors `lib/`):

- Base price only (no rear zone, no overrides) → every berth = `pricePerSeat`.
- Rear zone set → seats in last `rearRows` rows = `rearPrice`; front rows = base.
- Rear zone + double sofa → whole sofa in rear zone = 2 × `rearPrice`;
  one shared berth = `rearPrice`.
- Seat-type override on a front row → override wins over base.
- Seat-type override on a rear-zone row → `rearPrice` wins (rear zone precedence).
- Trip factor: single-leg = half of round-trip for each case.
- `rearRows` greater than total rows → clamped (whole bus becomes rear zone).
- `rearRows > 0` but `rearPrice == null` → rear rows fall back to base.
