# Money Collection & Handler Settlement — Design

**Date:** 2026-06-01
**Status:** Approved (design); pending spec review
**Author:** brainstormed with the agent (zeel)

## Problem

The app tracks bookings but only a binary `payment_status` (paid / notPaid) per
passenger. There is no record of:

- how much each customer actually owes, based on the seat type they hold;
- how much cash the handler collected from each customer, and the resulting
  **change owed back** when the customer overpaid (e.g. handed ₹1600 for a
  ₹1550 sofa because they had no change) — or the **shortfall** still to collect;
- the **expenses** of running each bus (driver pay, fuel, food, tolls…);
- the **handover** from the on-bus handler to the agent/admin
  (`collected − expenses = expected handover`), and what is still outstanding.

The agent needs a money view: per bus and per tour — how much was collected, how
much it cost, the net, how much has been handed over, and what is still owed
(both to customers and from handler to admin).

## Decisions (locked during brainstorming)

1. **Pricing is per seat type.** Each bus has a price for Single Sofa, Double
   Sofa, and Seater.
2. **Double Sofa price is the WHOLE-sofa price** (both berths together). The
   per-berth share is `double_sofa_price ÷ 2`.
3. **Overpayment is owed back to the customer.** Tracked as a positive balance
   ("change to return") until the agent returns it or marks it kept.
4. **One handler per bus.** Each bus's collection settles against that bus's
   expenses; the handler hands the net to the admin.
5. **Expenses attach per bus.** Both admin and handler (conceptually) can log
   them; in v1 the agent records all of them.
6. **Trip type halves the fare.** The stored seat-type price is the
   **round-trip** price. A passenger travelling a single leg — `outboundOnly`
   ("one way") or `returnOnly` ("only return") — pays **half** (`price ÷ 2`).
   `tripType` already exists on `passengers` (`lib/models/trip_type.dart`,
   with `isOneWay` true for both single-leg cases).
7. **Agent-records model (v1).** The app stays single-login (the agent/admin).
   The handler is a labelled passenger (`passengers.is_handler`), not an app
   user. The schema is designed so a handler login/role can be added later
   without reshaping the money tables.

## Money math

For a passenger, **amount due** is the sum over the berths they hold:

| Holding | Berths | Price contribution |
|---|---|---|
| Single Sofa | 1 | `single_sofa_price` |
| Seater | 1 | `seater_price` |
| Double Sofa — whole (one person, both berths) | 2 | `double_sofa_price` (= 2 × per-berth) |
| Double Sofa — shared (one of two occupants) | 1 | `double_sofa_price ÷ 2` |

Per-berth price helper (prices are the **round-trip** prices):

```
berthPrice(seatType) =
  seatType == doubleSofa ? double_sofa_price / 2
                         : (seatType == singleSofa ? single_sofa_price
                                                   : seater_price)

tripFactor(tripType) = tripType == roundTrip ? 1.0 : 0.5   // outboundOnly / returnOnly → half

amountDueComputed(passenger, bus) =
  tripFactor(passenger.tripType) × Σ berthPrice(seatType of each held berth on bus)
```

The trip factor applies at the passenger level (one `tripType` per passenger),
so for a shared double each occupant halves their own ₹775.

| Holding × trip | Round trip | One-way / only-return |
|---|---|---|
| Whole Double Sofa (1550) | 1550 | 775 |
| Shared Double Sofa (per person) | 775 | 387.50 |
| Single Sofa (1200) | 1200 | 600 |
| Seater (900) | 900 | 450 |

`amount_due` is seeded from `amountDueComputed` but is **editable** by the agent
(handles waitlist, negotiated fares, partial parties).

Per-collection **balance**:

```
balance = amount_received − amount_refunded − amount_due
  balance > 0  → agent owes the customer this much change  ("Return to customer")
  balance < 0  → customer still owes this much             ("Still to collect")
  balance = 0  → square
```

Worked example (bus prices: Double 1550, Single 1200, Seater 900):

- Ramesh holds whole Double Sofa `DL3` → due **1550**. Hands over 1600, no change
  given → received 1600, refunded 0 → **balance +50**, Ramesh appears in
  "Return to customer". Agent later hands back 50 → refunded 50 → balance 0.
- Sita + Gita *share* Double Sofa `DL4` → due **775 each**.
- Mukesh holds Single Sofa → due **1200**, pays 1200 → square.

## Architecture (Approach A — dedicated tables)

New/changed Postgres objects (additive migration; no destructive changes to
existing tables). RLS on every new table reuses the existing pattern:
`exists (select 1 from public.tours t where t.id = <tbl>.tour_id and t.owner_id = auth.uid())`.

### `buses` — add per-seat-type prices

Three nullable columns, each falling back to the existing `price_per_seat` when
null:

```sql
alter table public.buses
  add column if not exists single_sofa_price numeric(10,2),
  add column if not exists double_sofa_price numeric(10,2),
  add column if not exists seater_price      numeric(10,2);
```

Resolved price (Dart + SQL): `coalesce(<type>_price, price_per_seat)`.

### `collections` — one row per (passenger, bus)

```sql
create table public.collections (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id)      on delete cascade,
  bus_id          uuid not null references public.buses(id)      on delete cascade,
  passenger_id    uuid not null references public.passengers(id) on delete cascade,
  amount_due      numeric(10,2) not null default 0,
  amount_received numeric(10,2) not null default 0,
  amount_refunded numeric(10,2) not null default 0,
  note            text,
  collected_by    text,                       -- handler/agent label, free text in v1
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index collections_passenger_bus_unique on public.collections(passenger_id, bus_id);
create index collections_tour_idx on public.collections(tour_id);
create index collections_bus_idx  on public.collections(bus_id);
```

`balance` is **derived in the app**, not stored. (Optional: a generated column
or view later; not needed for v1.)

### `expenses` — per bus

```sql
create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  bus_id      uuid not null references public.buses(id) on delete cascade,
  category    text not null default 'other',   -- driver | fuel | food | toll | other
  label       text not null,
  amount      numeric(10,2) not null default 0,
  paid_by     text,                            -- who fronted the cash (label)
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index expenses_tour_idx on public.expenses(tour_id);
create index expenses_bus_idx  on public.expenses(bus_id);
```

### `bus_handovers` — handler → admin

Supports more than one (partial) handover per bus.

```sql
create table public.bus_handovers (
  id                 uuid primary key default gen_random_uuid(),
  tour_id            uuid not null references public.tours(id) on delete cascade,
  bus_id             uuid not null references public.buses(id) on delete cascade,
  expected_amount    numeric(10,2) not null default 0, -- snapshot of collected − expenses at time of handover
  handed_over_amount numeric(10,2) not null default 0,
  note               text,
  settled_at         timestamptz not null default now(),
  created_at         timestamptz not null default now()
);
create index bus_handovers_tour_idx on public.bus_handovers(tour_id);
create index bus_handovers_bus_idx  on public.bus_handovers(bus_id);
```

Each new table: `enable row level security`, an `owner_all` policy via the
tour-owner join, an `updated_at` trigger (where the column exists), and
(optionally) `alter publication supabase_realtime add table …` for live refresh.

### Derived totals (computed in app / optional SQL view)

Per bus:
- `collected = Σ (received − refunded)` over the bus's collections
- `expenses_total = Σ amount` over the bus's expenses
- `expected_handover = collected − expenses_total`
- `handed_over = Σ handed_over_amount` over the bus's handovers
- `outstanding_handover = expected_handover − handed_over`
- `to_return_total = Σ max(0, balance)` (change owed to customers)
- `to_collect_total = Σ max(0, −balance)` (shortfalls)

Per tour: sums of the per-bus figures.

## Dart model & controller layer

New models (mirroring `toMap`/`fromMap` conventions already in `lib/models/`):

- `Collection` (`lib/models/collection.dart`) — fields above + computed
  `balance`, `isReturnDue`, `isShortfall`, `isSquare`.
- `Expense` (`lib/models/expense.dart`) + `ExpenseCategory` enum.
- `BusHandover` (`lib/models/bus_handover.dart`).
- `BusPricing` helper (could live on the existing `Bus` model in
  `bus_details.dart`): resolved per-type prices + `berthPrice(seatType)` +
  `amountDueFor(passenger)` using the berth-counting rules from
  `seat_layout.dart` / the double-sofa pair semantics, and applying
  `tripFactor(passenger.tripType)` (half for `outboundOnly` / `returnOnly`).

Controller work (extend `TourController` or a new `MoneyController`):

- Load collections / expenses / handovers for a tour (and per bus).
- `upsertCollection`, `recordRefund`, `upsertExpense`, `deleteExpense`,
  `recordHandover`.
- Compute the derived per-bus and per-tour totals.
- Seed a collection's `amount_due` from `amountDueFor(passenger)` when first
  opened; keep it editable.

## UI

- **Add/Edit Bus screen** (`add_bus_screen.dart`): three optional price fields
  (Single Sofa / Double Sofa / Seater), each showing the `price_per_seat`
  fallback as placeholder. (Per memory: keep the existing live-preview style.)
- **Collection screen** (new), reached per bus from the bus status / seat
  screens: list of passengers on that bus with due / received / balance chips;
  tapping a passenger opens a sheet to enter received cash and (if overpaid)
  return change. A "Return to customer" filter shows everyone with `balance > 0`.
- **Expenses section** (per bus): add/edit/delete expense lines with category.
- **Handover / Money summary** (admin, per bus + tour rollup): collected, costs,
  net, expected handover, handed over, outstanding; a button to record a
  handover. This is the "how much it cost and how much is done" view.

All money UI follows the locked Phase-0 UI DNA (dark-first, brand accent — see
project memory). Currency: ₹ (INR), integer rupees by default, `numeric(10,2)`
storage allows paise if ever needed.

## Out of scope (v1 / YAGNI)

- Handler login / handler role / per-handler RLS (designed-for, not built).
- Online/UPI payment capture — cash only.
- Multi-currency.
- Refund/expense approval workflows.
- Reconciliation reports / export (PDF, CSV) — can be added once totals exist.

## Edge cases

- **Passenger seated on two buses** (rare): one `collections` row per
  (passenger, bus); each bus collects for its own berths. Totals stay correct.
- **Unassigned / waitlisted passenger**: no computed due; agent may still create
  a collection with a manually entered `amount_due`.
- **Bus deleted**: cascades remove its collections/expenses/handovers.
- **Price changed after collection recorded**: `amount_due` is a stored snapshot
  on the collection row, so past collections are not retroactively altered.
- **Shared double, only one half sold**: the sold occupant owes
  `double_sofa_price ÷ 2`; the empty half contributes nothing.

## Testing

- Unit tests for `berthPrice` and `amountDueFor` across all four holdings
  (single, seater, whole double, shared double) × all three trip types
  (round trip = full, outbound-only = half, return-only = half), mirroring the
  berth rules in `test/models/seat_layout_test.dart`.
- Unit tests for collection `balance` sign (overpay / shortfall / square /
  with refund).
- Unit tests for per-bus and per-tour total aggregation, including the worked
  example above.
- Controller tests for upsert idempotency on `(passenger_id, bus_id)`.
```
