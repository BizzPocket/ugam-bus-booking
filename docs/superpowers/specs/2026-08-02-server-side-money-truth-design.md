# Server-side money truth — design

**Status:** implementation-ready design. Written 2026-08-02 against `feat/money-collection-settlement` @ `318b511`.

**Provenance legend used throughout:**
- **[V]** — verified by me directly in this session (file read or grep executed).
- **[R]** — asserted by a discovery report, consistent across reports, not independently re-read by me.
- **[UNVERIFIED-LIVE]** — a claim about the *production database*. The repo cannot settle it. Must be resolved by querying production before the dependent work starts.

---

## Problem

Three surfaces compute the same money from the same four tables and disagree, because each folds a **different set of rows** and each derives billed revenue from **present seating** rather than from a persisted fact.

The three computations:

1. **Handler** — `HandlerBusMoney.compute` called from `lib/screens/handler_bus_chart_screen.dart:299` (`_summaryForBus`) **[V]**, over the `HandlerManifest` RPC payload plus local caches (`_collections` :139, `_expenses`, `_income`, `_handovers`).
2. **Admin per-tour** — `MoneyController.summaryForBus` / `tourSummary` / `summariesForBuses` / `handlerSummaries` (`lib/controllers/money_controller.dart:633`, `:645`, `:708`, `:738`) **[V]**, over four obs lists it fetched itself.
3. **Admin cross-tour** — `FinanceController.load()` (`lib/controllers/finance_controller.dart:85-160`) **[V]**, which pages through `collections`, `expenses`, `buses.bus_price` and `incomes` across the entire account with its own cursor.

### Root cause 1 — billed revenue is a function of *present seating*, not a persisted fact (CALC-1)

`MoneyController._billedRevenues()` folds `b.amountDueFor(p)` over `tour.passengers` (`lib/controllers/money_controller.dart:604-606`) **[V]**. `Bus.amountDueFor` iterates `passenger.assignedSeats` (`lib/models/bus_details.dart:501`) **[V]** and returns 0 for an empty list.

`TourController.completeOutboundLeg` sets `assignedSeats: const []` for every outbound-only rider (`lib/controllers/tour_controller.dart:762`) **[V]**. Its server twin `handler_complete_outbound_leg` does the same per-bus (`supabase/migrations/046_handler_settlement_and_leg.sql:492-497`) **[R]**.

So the instant the GO leg is completed, every one-way rider's fare **vanishes from `revenueBilled`** — the tour's accrual profit collapses by exactly the one-way riders' half-fares, their cash simultaneously reclassifies as `detachedCash` (`lib/controllers/money_controller.dart:689-702` **[R]**, `lib/models/money_summary.dart:141-153` **[V]**), and the per-seat collection roster empties.

### Root cause 2 — duplicate collection rows, from three independent producers

- `seat_id` was **added later** with `default ''` and the old `(passenger_id, bus_id)` unique index was **dropped** in the same migration: `supabase/migrations/004_money_collection.sql:67-69` **[V]**. Every pre-migration collection survives as a `seat_id = ''` row *alongside* newer per-seat rows and is summed twice.
- The handler cache key is `'$pid|$bid|$seatId'` and "existing" is resolved by seat (`lib/screens/handler_bus_chart_screen.dart:139` cache decl **[V]**; seat-keyed lookup and collect sheet **[R]**). A rider who moves seat gets a brand-new row. The RPC's `on conflict (passenger_id, bus_id, seat_id)` (`database.sql:1059`, index at `database.sql:779`) **[V]** does not fire.
- `CollectionReconciler` is explicitly forbidden from deleting rows and only re-homes onto a *free* seat (`lib/services/collection_reconciler.dart:94-98`, `:173-182`) **[R]**; and `MoneyController.reconcileAfterSeatMove` (`lib/controllers/money_controller.dart:347` **[V]**) early-returns on a same-bus move when the money tables are not loaded — which is the normal state of the seat-assignment workspace.

### Root cause 3 — `collections.amount_due` drifts from the live fare

`amount_due` is stamped at collect time from the live Dart fare in three independent places (admin collection screen, handler collect sheet, reconciler) **[R]**. A bulk "apply price sheet to all buses" (`lib/screens/edit_tour_screen.dart:333-344`) **[R]** rewrites seven pricing columns on every other bus and touches zero collection rows. The code already distrusts the stored value: `lib/utils/seat_money_state.dart:126` recomputes from `bus.amountDueForSeat` while `Collection.balance` (`lib/models/collection.dart:52`) **[V]** uses the stale stored one. That split is itself a fourth disagreeing figure.

### Root cause 4 — legacy `busOwner` expense rows double-count rent

`buses.bus_price` is implicitly added to the expense total by the summaries (`lib/models/money_summary.dart:162-165` **[V]** — `busExpenses.fold(...) + busRent`). `ExpenseCategory.busOwner` still exists and both sheets merely stopped *offering* it **[R]**; nothing removed existing rows and nothing at the DB layer rejects the category. Worse: `HandlerBusMoney.spent` is `base.expensesTotal` computed with `busRent: 0` (`lib/models/handler_bus_money.dart:91-98`) **[V]**, so a legacy `busOwner` row silently *reduces the handler's `inHand`* and therefore reduces what they physically hand over.

### Root cause 5 — orphan money and client-supplied fleet lists

`TourMoneySummary` classifies orphans against a **client-supplied** `knownBusIds` (`lib/models/money_summary.dart:288-305` **[V]**, filled from the hydrated tour at `lib/controllers/money_controller.dart:665-666` **[V]**). A partially hydrated tour produces *phantom* orphans on screen that do not exist in the data. Meanwhile real orphans do exist: `buses.tour_id` is nullable with `on delete set null` (`database.sql:196`) **[R]**, so a bus's `tour_id` can drift away from the money rows that point at it. And orphaned **handovers** are invisible entirely — `TourMoneySummary` breaks out orphan expenses/collections/income but not handovers (`lib/models/money_summary.dart:302-304`) **[V]**.

---

## Approach

**Approach A: one server-side aggregation, over persisted rows.**

Two structural moves, in this order:

**A1 — Persist the OUTPUT of the Dart pricing engine into a new `seat_billing` table.**

The fare authority is `Bus.amountDueForSeat` (`lib/models/bus_details.dart:531`) **[V]**. Its inputs are the layout cell's `seatType`/`row`, seven pricing columns on `buses`, the per-berth `SeatAssignment.leg` multiset, `Passenger.legForSeatType`, the trip factor, and a final `roundToDouble()` at the per-seat level. This logic is **not ported**. Only its numeric result is written to `seat_billing`, by Dart, through an idempotent tour-scoped reprice pass.

Persisting it fixes CALC-1 structurally: the billed fact outlives the seat.

**A2 — One shared SQL aggregation function over persisted rows, with three gated wrappers.**

`money_agg(p_tour_id, p_bus_ids uuid[])` is pure `sum()`/join over `seat_billing`, `collections`, `expenses`, `incomes`, `bus_handovers` and `buses.bus_price`. Three wrappers call it:
- `tour_money(p_tour_id)` — authenticated admin, all buses on the tour.
- `handler_money(p_request_id)` — anonymous handler, only buses where `handler_owns_bus` is true.
- `tours_money_rollup(p_tour_ids)` — batch, one row per tour, for the dashboard settlement strip and `FinanceController`.

### Why pricing is persisted, NOT ported — and the one place the premise is already false

**CORRECTION TO THE PLAN'S PREMISE. Pricing has already been ported to SQL, in `main`.** `supabase/migrations/049_online_advance_payment.sql:66` defines `bus_berth_price_paise(bus_id, seat_type, row)` and its own header (`049:57-58`) calls it an *"EXACT mirror of `Bus.berthPriceFor`"* **[V]**. `049:59` claims *"A parity test pins them together"*. **That parity test does not exist** — `grep -rn "bus_berth_price_paise" test/ tool/ scripts/` returns **zero hits**, and `berthPriceFor` appears in `test/` only inside `test/models/fare_calculation_test.dart` (pure Dart, no SQL) **[V]**.

So there are already two fare implementations, and the SQL one is what charges the customer's advance. Resolution adopted here:

1. **`seat_billing` is written by Dart only, in Phase 1–2.** The Dart engine remains the single documented authority for what a rider is billed. `bus_berth_price_paise` stays where it is, used only for the advance-payment path, and is *not* wired into `seat_billing` in the initial build.
2. **The parity test that 049 claims exists is a hard prerequisite** for ever letting SQL price a `seat_billing` row (Phase 8). Until it exists and is green, SQL must never write an authoritative billed amount.
3. **The customer self-booking hole is closed without SQL pricing** in the initial build — see *Data model → chart-mode claims*.

Two divergences that must be stated because they cost real money if the two engines are ever unified carelessly:
- `amountDueForSeat` rounds the **final per-seat** due to whole rupees (`lib/models/bus_details.dart:576` **[V]**); `booking_amount_paise` rounds **per berth to paise** (`049`) **[R]**. Half-leg and half-sofa fares can differ by up to ₹1/seat.
- `TourFinance.revenue` is **net cash collected**; `TourMoneySummary.totalRevenueBilled` is **accrual billed revenue**. Both are labelled "revenue" in the UI. They must remain two distinct fields in the payload and must never be served from the same expression.

---

## Data model

### Migration numbering and deploy rules

Number the money migration **`052_server_side_money.sql`**. Do **not** reuse 045 — three ordinals are already duplicated (`004`, `006`, `045`) **[V]**.

Hard deploy rules, all sourced from migration headers **[R]**:
- **Never run `supabase db push`.** `047:5-7` records that the remote migration-history table is empty, so a push replays `001..051` over live data, starting with `001_initial_schema.sql` (which declares a `bus_details` table and pg ENUMs that `database.sql` explicitly drops) and `database.sql`'s `drop table … cascade` on every money table. That destroys the ledger.
- **Never run `045_handler_handover.sql`.** `046:16-18` states it writes `bus_handovers.source` which did not exist in production; and on a DB where 046 *has* run, 045 succeeds and silently downgrades three handover RPCs from `handler_owns_bus` ownership checks back to bus-on-tour.
- **Never run `039_handler_lock_gate.sql`.** `042:47-50` rebuilt both of its functions with the lock filter preserved; re-running 039 would overwrite them and lock out every manually-added handler.
- Run `052` **alone in the Supabase SQL editor**, wrapped in `begin/commit`, idempotent throughout.

### Verify-before-use block (first statement in 052)

Three facts are **[UNVERIFIED-LIVE]** and each is a landmine. Assert them and abort loudly:

```sql
do $$
begin
  -- 046 added this. If missing, 045_handler_handover was run instead of 046,
  -- or neither ran. Building money on an assumed schema is not acceptable.
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='bus_handovers'
                    and column_name='source') then
    raise exception 'PRECONDITION: bus_handovers.source missing — deploy 046 first';
  end if;

  -- 031 declares id uuid; 046 declares id text; the client writes the composite
  -- '<tourId>_outbound'. If 031 ever ran, 046's `create table if not exists` was
  -- a silent no-op and handler_complete_outbound_leg throws 22P02 on every call.
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='tour_seat_snapshots'
                and column_name='id' and data_type <> 'text') then
    raise exception 'PRECONDITION: tour_seat_snapshots.id is not text — 031 drift';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='buses'
                    and column_name='bus_price') then
    raise exception 'PRECONDITION: buses.bus_price missing';
  end if;
end $$;
```

### `seat_billing`

Two schemas were proposed by the discovery pass and they conflict. **I take the richer one** (status lifecycle + berth-leg counts), because the simpler `leg text` variant cannot express "this seat was cleared by leg completion but its GO revenue still counts" without either double-counting a resold return seat or over-billing a demoted round-trip rider. `price_sig` is dropped — it exists only to alert on Dart↔SQL divergence, and no SQL writes prices in this build.

```sql
create table if not exists public.seat_billing (
  id            uuid primary key default gen_random_uuid(),
  tour_id       uuid not null references public.tours(id)      on delete cascade,
  bus_id        uuid not null references public.buses(id)      on delete cascade,
  passenger_id  uuid not null references public.passengers(id) on delete cascade,
  seat_id       text not null,          -- BASE id; '#' suffix stripped (bus_details.dart:534)

  -- ── frozen OUTPUT of Bus.amountDueForSeat ──
  amount        numeric(10,2) not null default 0,   -- already roundToDouble'd (bus_details.dart:576)
  unit_price    numeric(10,2) not null default 0,   -- berthPriceFor (bus_details.dart:466), audit only
  seat_type     text not null,                      -- singleSofa | doubleSofa | seater
  seat_row      int  not null,

  -- ── the berth-leg multiset that PRODUCED `amount` (bus_details.dart:550-567) ──
  go_berths     int not null default 0,   -- berths whose leg ∈ {roundTrip, outboundOnly}
  ret_berths    int not null default 0,   -- berths whose leg ∈ {roundTrip, returnOnly}

  -- ── lifecycle ──
  status        text not null default 'active'
                  check (status in ('active','travelled','void')),
  travelled_leg text check (travelled_leg in ('outbound','return')),
  travelled_at  timestamptz,
  voided_at     timestamptz,

  -- ── provenance ──
  priced_by     text not null default 'reprice'
                  check (priced_by in ('reprice','leg_complete','chart_claim_pending')),
  priced_at     timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists seat_billing_pax_bus_seat_uniq
  on public.seat_billing(passenger_id, bus_id, seat_id);
create index if not exists seat_billing_tour_idx on public.seat_billing(tour_id);
create index if not exists seat_billing_bus_idx  on public.seat_billing(bus_id);

drop trigger if exists seat_billing_set_updated_at on public.seat_billing;
create trigger seat_billing_set_updated_at before update on public.seat_billing
  for each row execute function public.set_updated_at();

alter table public.seat_billing enable row level security;

-- Identical shape to collections/expenses/incomes/bus_handovers (*_owner_all).
-- NO anon policy, ever: handlers reach this only through SECURITY DEFINER RPCs.
drop policy if exists "seat_billing_owner_all" on public.seat_billing;
create policy "seat_billing_owner_all" on public.seat_billing
  for all to authenticated
  using      (exists (select 1 from public.tours t
                       where t.id = seat_billing.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                       where t.id = seat_billing.tour_id and t.owner_id = auth.uid()));
```

**`tour_id` is NOT NULL because it is the RLS anchor** — the four existing money tables all anchor their policy on it (`database.sql:788-793`, `:822-827`, `:1103-1108`; `029_handler_income.sql:69-74`) **[R]**. A nullable anchor silently admits nothing.

**Cascades match `collections` exactly** (`004_money_collection.sql:52-53`) **[R]** — `removeBus` hard-deletes a bus (`lib/controllers/tour_controller.dart:2540-2549`) **[R]**, and without `on delete cascade` on `bus_id` the aggregate would keep summing revenue for a bus that no longer exists.

**The aggregation rule — the entire CALC-1 fix, one predicate:**

```sql
sum(amount) filter (where status in ('active','travelled'))
```

**Why this cannot double-count.** The unique key is `(passenger_id, bus_id, seat_id)` — one row per key forever; `status` transitions **in place**, a retire never inserts. A physical seat resold on the return leg belongs to a **different `passenger_id`** (`chart_claim_seats` mints `gen_random_uuid()` per booking **[R]**; the admin's return-only booking goes through `addPassenger` **[R]**), so the outgoing rider's frozen `travelled` row and the incoming rider's `active` row are distinct keys and sum to exactly one seat's revenue.

**Self-verifying invariant** (worth a check constraint or a nightly assertion): a `travelled_leg='outbound'` row must have `ret_berths = 0`. That is the property proving a frozen GO row is not carrying return revenue.

**Status transition rules — get these wrong and the ledger is permanently wrong:**

| Trigger | Action | Why |
|---|---|---|
| Reprice pass sees the seat still held | upsert `amount`, keep `status='active'` | ordinary |
| Reprice pass: key exists, seat no longer held, `status='active'` | `status='void', voided_at=now()` | genuine unseat/cancel — revenue must leave |
| Reprice pass: key exists, `status='travelled'` | **never touch** | the CALC-1 survival rule |
| `completeOutboundLeg` (Dart, `tour_controller.dart:743-780` **[V]**) | for every rider in `changed`: `active → travelled, travelled_leg='outbound'` | freeze before the seat clear commits |
| `handler_complete_outbound_leg` (SQL, `046:492`) | same status flip, scoped `bus_id = p_bus_id` | handler is anonymous, no Dart in the loop |
| `cancelReturnSeat` (`tour_controller.dart:898-923` **[R]**) | **reprice-then-freeze**: recompute `amount` from the post-transform (outbound-only, `ret_berths=0`) passenger, *then* set `travelled` | a pure freeze keeps the full round-trip fare on a rider who took one leg |
| `setWaitlisted(true)` (`tour_controller.dart:2117-2143` **[R]**, silently clears seats) | `void` — **not** `travelled` | waitlisting is not travel |
| `removePassenger`, `removeBus` | FK cascade deletes the rows | matches `collections` |

**The void-vs-freeze decision must be driven by the calling path, never by "seats went empty".** Three paths empty `assigned_seats` and only one of them is travel.

### Chart-mode customer claims — closing the hole without SQL pricing

`chart_claim_seats` (`supabase/migrations/048_customer_seat_chart_booking.sql:221`) **[R]** inserts a passenger with `assigned_seats` built entirely in SQL, inside `pg_advisory_xact_lock`. No Dart runs. If `seat_billing` were written by Dart only, a self-booked seat would be **unbilled until an admin next opens that tour**, while `handler_money` reads a ledger missing that revenue.

**Chosen fix for the initial build (no SQL pricing):** inside `chart_claim_seats`, in the same transaction as the claim, insert a **pending** row per claimed seat:

```sql
insert into public.seat_billing
  (tour_id, bus_id, passenger_id, seat_id, amount, unit_price,
   seat_type, seat_row, go_berths, ret_berths, priced_by)
select p_tour_id, p_bus_id, v_passenger_id, c->>'seatId',
       0, 0, c->>'type', (c->>'row')::int,
       case when v_wants_go  then (c->>'berths')::int else 0 end,
       case when v_wants_ret then (c->>'berths')::int else 0 end,
       'chart_claim_pending'
from jsonb_array_elements(v_claims) c
on conflict (passenger_id, bus_id, seat_id) do nothing;
```

`amount = 0` and `priced_by = 'chart_claim_pending'`. The aggregation function counts a `unpriced_seats` figure (`count(*) filter (where priced_by='chart_claim_pending')`) which every money surface renders as an explicit warning line. **The revenue is visibly missing rather than silently missing** — that is the whole point. The next Dart reprice overwrites the row with the real amount and flips `priced_by` to `'reprice'`.

Phase 8 may upgrade this to a real SQL price via `bus_berth_price_paise`, **only after** the parity test exists (see *Testing*).

> **[UNVERIFIED-LIVE]** Whether migrations 048/049/050 are deployed at all. `lib/controllers/tour_controller.dart:3058-3066` **[R]** explicitly designs around them being absent. If 048 is not live, chart mode is unreachable and this whole sub-section is inert — but it must still ship, because the migration order cannot be relied upon.

### `source` provenance on `expenses` and `incomes`

```sql
alter table public.expenses add column if not exists source text not null default 'admin';
alter table public.incomes  add column if not exists source text not null default 'admin';

do $$ begin
  if not exists (select 1 from pg_constraint where conname='expenses_source_chk') then
    alter table public.expenses add constraint expenses_source_chk
      check (source in ('admin','handler'));
  end if;
  if not exists (select 1 from pg_constraint where conname='incomes_source_chk') then
    alter table public.incomes add constraint incomes_source_chk
      check (source in ('admin','handler'));
  end if;
end $$;
```

`handler_upsert_expense` and `handler_upsert_income` must be re-created in 052 to set `source = 'handler'` server-side (never from the client payload). Every historical row becomes `'admin'` by default — **which is a lie for rows a handler actually entered**, and must be stated on the ledger's provenance filter ("rows before <deploy date> are unattributed").

**Harden the write path in the same migration** or root cause 4 regenerates:

```sql
alter table public.expenses
  add constraint expenses_no_bus_owner_chk check (category <> 'busOwner') not valid;
```

`not valid` so existing legacy rows survive for the cleanup pass; `validate constraint` runs at the end of Phase 6.

### Two known live security defects to fix in the same migration

Both were found in the migration files and are **[UNVERIFIED-LIVE]** as to their current production state, but the code pattern is unambiguous:

1. **`handler_delete_expense` / `handler_delete_income` have no bus predicate at all** — `042:576-577` and `042:746-747` delete `where id = … and tour_id = v_tour_id` **[R]**. Any handler on a multi-bus tour can delete any expense or income on the whole tour, including the admin's. Once money is presented as server-authoritative this produces a *confidently wrong* number instead of an obviously inconsistent one. Rewrite both with `handler_owns_bus`, following `046:277`.
2. **`handler_owns_bus` is probably anon-callable.** `046:127` uses only `revoke all … from public`, which `043:9-13` proves is insufficient against Supabase's default role grants **[R]**. Add the explicit `revoke execute … from anon` / `from authenticated` that 043 established. Verify with `select has_function_privilege('anon','public.handler_owns_bus(uuid,uuid)','execute')`.

### The `collections` uniqueness change — RESOLVED AGAINST the plan's literal wording

The plan says "unique index moves from `(passenger_id,bus_id,seat_id)` to `(passenger_id,bus_id)`". Two reports disagree on how:

- `live_schema` gives an ordering (dedupe → new index → replace RPC → drop old index) and warns that dropping the old index before replacing `handler_upsert_collection` raises `42P10` on **every handler cash entry, mid-trip** — because `042:471` / `database.sql:1059` conflict-target the triple **[V]**.
- `dirty_data` points out that a **plain** `unique(passenger_id, bus_id)` index simply **will not create** while any unresolved duplicate group survives — and some groups (rider holds no seat on that bus any more) are *not* machine-resolvable.

**Resolution — do not swap the index in the initial build.** Split it:

**Phase 5 (ships early, fully reversible, zero index change):** make collection reads and writes **seat-agnostic**.
- Client: the handler's "existing collection" lookup keys on `(passengerId, busId)` instead of `(passengerId, busId, seatId)`.
- `handler_upsert_collection` (rewritten in 052): resolve an existing row by `(passenger_id, bus_id)` **ordered deterministically** (`order by created_at, id limit 1`), then `update … where id = v_existing_id`; insert only when none exists. This uses **no** `on conflict` clause and therefore does not depend on any index. The old triple index stays in place and keeps working.
- Same change to the admin collect path.

This stops **new** duplicates without a single schema-order hazard. It satisfies `dirty_data`'s R0 ("the code fix must ship before the data merge") by construction.

**Phase 8 (optional hardening, after cleanup):** add a tombstone and a *partial* unique index, so the guard exists without requiring every historical group to be human-resolved first:

```sql
alter table public.collections add column if not exists superseded_at timestamptz;
create unique index if not exists collections_passenger_bus_unique
  on public.collections(passenger_id, bus_id) where superseded_at is null;
drop index if exists public.collections_passenger_bus_seat_unique;
```

Cost, stated honestly: every read of `collections` must then filter `superseded_at is null` — including the aggregation function, `MoneyController`, and the legacy handler manifest RPCs which select collection rows (`004_handler_collections.sql:95`, `006:82`, `007:100` **[R]**). That is why it is Phase 8 and optional.

### `collections.amount_due` — RESOLVED between two conflicting recommendations

`billing_writepoints` recommends maintaining `amount_due` as a stored projection of `seat_billing`. `dirty_data` argues forcefully against ever bulk-rewriting it, because it is the number the rider was quoted and the handler settled against, and rewriting it flips squared-up riders into phantom shortfall via `Collection.balance` (`lib/models/collection.dart:52` **[V]**) across both surfaces at once.

**Chosen resolution — a third option that satisfies both:**

1. **The aggregator never reads `amount_due`.** To-collect and to-return are derived from `seat_billing` versus cash:
   - `billed(pax,bus)   = Σ seat_billing.amount where status in ('active','travelled')`
   - `cash(pax,bus)     = Σ (amount_received − amount_refunded)` over that passenger's collection rows on that bus
   - `to_collect += greatest(0, billed − cash)` when `abs(billed − cash) > 0.005`
   - `to_return  += greatest(0, cash − billed)` when `abs(billed − cash) > 0.005`
2. **`amount_due` is frozen as a historical quote.** Not bulk-rewritten, not deleted. The three UI write paths **stop writing it** (they pass through whatever is already there on update, and write `0` on insert).
3. `Collection.balance` and its `stillToCollect`/`changeToReturn` getters (`lib/models/collection.dart:52-59` **[V]**) stay on the model for row-level display, but **no aggregate depends on them any more**.
4. Drift between the frozen quote and the live fare surfaces as an explicit per-rider "re-quote" affordance in the collect sheet, reusing the existing `SeatMoveMoneyDelta` vocabulary (`lib/services/collection_reconciler.dart:17-51` **[R]**).

**Bonus:** this deletes the special-case "seated rider with no collection row still owes their full fare" pass that exists in *both* `BusMoneySummary.compute` (`lib/models/money_summary.dart:120-139` **[V]**) and `HandlerBusMoney.compute` (`lib/models/handler_bus_money.dart:100-118` **[R]**) and had to be kept byte-identical in two places. A `seat_billing` row exists for every seated rider whether or not cash was taken, so the case is no longer special.

---

## Server API

### `money_agg(p_tour_id uuid, p_bus_ids uuid[])` — the shared engine

`stable`, `security definer`, `set search_path = public`. **Internal only.** Because it is DEFINER, it bypasses RLS; the *wrappers* carry the entire authorization burden.

```sql
revoke all     on function public.money_agg(uuid, uuid[]) from public;
revoke execute on function public.money_agg(uuid, uuid[]) from anon;
revoke execute on function public.money_agg(uuid, uuid[]) from authenticated;
```

Both revokes are mandatory — `043:9-13` proves `revoke … from public` alone does not drop Supabase's default role grants **[R]**. A money aggregator left on the PostgREST surface is a direct financial-data leak to `anon`.

**Structural requirements, each of which is a known failure mode:**

1. **`coalesce` every aggregate.** `sum()` over zero rows returns `NULL` in Postgres; a bus with no collections would deserialise `collected: null` and propagate through every getter. Non-negotiable.
2. **`bus_price` folds in ONCE PER BUS, from its own CTE.** `database.sql:207-209` **[R]** documents that rent is never an `expenses` row. A single query joining `buses` to `collections` and doing `sum(b.bus_price)` multiplies rent by the collection-row count. Aggregate scalars per bus, then join.
3. **The "still seated" scope for detached cash is exactly `p_bus_ids`.** This is the key simplification: the three different detached-cash scopes the client maintains today (per-bus `lib/models/money_summary.dart:141-153` **[V]**; handler-scoped `lib/controllers/money_controller.dart:774-781` **[R]**; tour-level `:675-678` **[R]**) collapse into one expression parameterised by the bus set. Per-bus = a one-element array; handler = the handler's buses; tour = all buses.
4. **Detached is defined against `seat_billing`, not against `assigned_seats`.** A payer is *detached* when they hold **no `seat_billing` row with `status in ('active','travelled')`** on any bus in the set. This is a deliberate behaviour change: a one-way rider whose seats were cleared by leg completion **stops** looking like stranded cash, because their frozen obligation is back. Genuinely cancelled/unseated riders (rows `void`) still show detached. See *Blocking decisions*.
5. **Orphans are computed from `p_bus_ids`, server-side.** Any row carrying `tour_id = p_tour_id` whose `bus_id` is not in the set is orphaned. This kills the phantom-orphan class (root cause 5) permanently, because the bus set is now resolved by the server, not supplied by a half-hydrated client. **Add `orphan_handed_over`** — the fourth channel the current model does not surface.
6. **Epsilon.** Apply the `0.005` band inside SQL wherever the client does (`Collection.kMoneyEpsilon` **[V]**), so `to_collect`/`to_return` classification matches. Do the comparison in `numeric`, then cast to `float8` on output.
7. **Handler ordering.** The null-handler bucket must come **LAST**, non-null handlers in first-seen bus order (`lib/controllers/money_controller.dart:761-765` **[R]**). SQL `group by` with a null key gives no such guarantee — emit an explicit `sort_key` and order by it, or re-impose the order client-side. Getting it wrong either drops unassigned buses from the trip total or reorders the P&L cards on every fetch.

### `tour_money(p_tour_id uuid) → jsonb` — authenticated admin

`stable`, **SECURITY INVOKER** (the default). The five `*_owner_all` policies already scope every underlying row. But because it calls DEFINER `money_agg`, the ownership check inside `tour_money` is **load-bearing, not decorative**:

```sql
create or replace function public.tour_money(p_tour_id uuid)
returns jsonb language sql stable set search_path = public
as $$
  select public.money_agg(
           p_tour_id,
           array(select b.id from public.buses b where b.tour_id = p_tour_id))
   where exists (select 1 from public.tours t
                  where t.id = p_tour_id and t.owner_id = auth.uid());
$$;
revoke all     on function public.tour_money(uuid) from public;
revoke execute on function public.tour_money(uuid) from anon;
grant  execute on function public.tour_money(uuid) to authenticated;
```

Returns `NULL` (not an error) for a tour the caller does not own.

### `handler_money(p_request_id uuid) → jsonb` — anonymous handler

**SECURITY DEFINER is mandatory** — `anon` holds no policy on any money table, and `047:18-21` **[R]** states the doctrine: handlers never touch these tables directly, so there is no anon policy and there must never be one.

```sql
create or replace function public.handler_money(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare v_tour_id uuid; v_buses uuid[];
begin
  -- 039 lock gate (tour status in locked/completed) + is_handler, in one.
  if not public.is_request_handler(p_request_id) then
    return '{"buses":[]}'::jsonb;          -- degrade quietly, never raise (046:132-133)
  end if;

  -- Server-resolved tour. NEVER trust a client-supplied tour_id (029:23-24).
  select ctx.tour_id into v_tour_id from public.handler_ctx(p_request_id) ctx;

  -- OWNERSHIP, not bus-on-tour. This is the whole point of 046:27-30.
  select array_agg(b.id) into v_buses
    from public.buses b
   where b.tour_id = v_tour_id
     and public.handler_owns_bus(p_request_id, b.id);

  if v_buses is null then return '{"buses":[]}'::jsonb; end if;
  return public.money_agg(v_tour_id, v_buses) - 'tour' - 'handlers';
end;
$$;
revoke all on function public.handler_money(uuid) from public;
grant execute on function public.handler_money(uuid) to anon, authenticated;
```

The `- 'tour' - 'handlers'` strip is belt-and-braces; the per-bus objects the handler receives must additionally be **projected to the handler shape** (see below) so `bus_rent` and `revenue_billed` cannot leak. Do the projection inside `handler_money`, explicitly, field by field — not by deleting keys from the admin object, which is one refactor away from leaking.

### `tours_money_rollup(p_tour_ids uuid[] default null) → jsonb`

One call, replaces `MoneyController.loadSettlementSnapshots` (`lib/controllers/money_controller.dart:209` **[V]**, currently a 4-table fetch **per tour**) and the whole of `FinanceController.load()` (`lib/controllers/finance_controller.dart:85-160` **[V]**, currently four full-account paged scans).

`stable`, **SECURITY INVOKER**, scoped by `tours.owner_id = auth.uid()`. `p_tour_ids = null` means "all of the caller's tours".

```json
[{
  "tour_id":              "uuid",
  "outstanding_handover": 0.0,
  "cash_revenue":         0.0,
  "expenses":             0.0,
  "income":               0.0,
  "net_billed":           0.0
}]
```

- `cash_revenue` = `Σ(received − refunded)` — **net cash**, the basis `TourFinance.revenue` uses (`lib/controllers/finance_controller.dart:100-101` **[V]**). It is **not** `revenue_billed`.
- `expenses` already includes `Σ buses.bus_price` (`lib/controllers/finance_controller.dart:115-127` **[V]** carries an explicit comment that omitting it overstates profit).
- **A tour absent from the result must stay `null` client-side, never 0.** `lib/screens/dashboard_screen.dart:249` **[R]** treats null as *unknown*, never as *settled*.

### Full `tour_money` payload — every field, and who needs it

```json
{
  "tour": {
    "tour_id": "uuid",
    "total_collected": 0.0, "total_revenue_billed": 0.0, "total_expenses": 0.0,
    "total_bus_rent": 0.0, "total_income": 0.0, "total_handed_over": 0.0,
    "total_to_return": 0.0, "total_to_collect": 0.0, "total_detached_cash": 0.0,
    "orphan_expenses": 0.0, "orphan_collected": 0.0, "orphan_income": 0.0,
    "orphan_handed_over": 0.0, "unpriced_seats": 0
  },
  "buses": [{
    "bus_id": "uuid",
    "collected": 0.0, "revenue_billed": 0.0, "expenses_total": 0.0,
    "bus_rent": 0.0, "income": 0.0, "handed_over": 0.0,
    "to_return_total": 0.0, "to_collect_total": 0.0, "detached_cash": 0.0,
    "detached_payer_ids": ["uuid"], "unpriced_seats": 0,
    "expenses_by_source": {"admin": 0.0, "handler": 0.0},
    "income_by_source":   {"admin": 0.0, "handler": 0.0}
  }],
  "handlers": [{
    "handler_passenger_id": "uuid|null", "sort_key": 0,
    "bus_ids": ["uuid"],
    "revenue_billed": 0.0, "collected": 0.0, "expenses_total": 0.0,
    "bus_rent": 0.0, "income": 0.0, "handed_over": 0.0,
    "to_collect_total": 0.0, "to_return_total": 0.0, "detached_cash": 0.0
  }]
}
```

Per-bus consumers (line numbers **[R]**, verify by symbol):

| field | consumers |
|---|---|
| `bus_id` | join key: `tour_money_board_screen.dart:513/526` (name/type from the `Tour` model), `trip_pnl_screen.dart:182-190` |
| `collected` | `bus_money_screen.dart:180`, `collection_screen.dart:153`, `tour_money_board_screen.dart:495/598/603`, `trip_pnl_screen.dart:195`, `stateForBusSummary` |
| `revenue_billed` | `trip_pnl_screen.dart:194`; `stateForBusSummary` (`revenueBilled − collected`, `money_controller.dart:802`) |
| `expenses_total` (rent **included**) | `bus_money_screen.dart:201`, `trip_pnl_screen.dart:196` |
| `bus_rent` | **must be transmitted even though it is inside `expenses_total`** — it is the only way to derive `groundExpenses → expectedHandover`. Omit it and every handover figure across `bus_money_screen.dart:161/380`, `tour_money_board_screen.dart:461/687` and `dashboard_screen.dart:248` shifts by exactly the rent |
| `income` | `bus_money_screen.dart:186/190`, `tour_money_board_screen.dart:576/598`, `trip_pnl_screen.dart:197` |
| `handed_over` | `tour_money_board_screen.dart:598/610` and the whole outstanding chain |
| `to_return_total` | `collection_screen.dart:154`, `stateForBusSummary` |
| `to_collect_total` | `collection_screen.dart:155`, `tour_money_board_screen.dart:487/495`, `stateForBusSummary` |
| `detached_cash` | `bus_money_screen.dart:224/227`, `trip_pnl_screen.dart:198` |
| `detached_payer_ids` | **new.** `bus_money_screen.dart:77-94` derives the payer NAME list client-side by walking `collections × tour.passengers`. Once `MoneyController` stops holding rows that pass has no input. Server returns ids; client joins names off the roster. The two must use the identical seated-here rule or the amount and the names disagree |
| `unpriced_seats` | **new.** Chart-mode pending rows; renders an explicit warning line |
| `expenses_by_source` / `income_by_source` | **new.** Needed by the Phase-7 ledgers to show "you spent ₹X, the handler spent ₹Y" |

Per-tour fields map to: `tour_money_board_screen.dart:308/687/754/762`, `trip_pnl_screen.dart:226-308`, `trip_hero.dart:262-276/331`, `bus_money_screen.dart:1347-1376`. `total_to_collect` has no direct render found in `lib/` **[R]**, but keep it: `money_controller.dart:650-656/672` **[V]** goes to real trouble to keep it equal to the sum of the per-bus figures, and the SQL must reproduce that choice or the bus rows stop adding up to the capsule above them.

Per-handler object: only consumer is `trip_pnl_screen.dart:155-167` **[R]**. **`detached_cash` here is NOT the sum of the per-bus figures** — a rider moved between two buses the same handler runs is not detached (`lib/models/money_summary.dart:236-240` says so explicitly **[R]**). It comes from a second `money_agg` call scoped to that handler's bus set.

### Handler payload (`handler_money`) — the strict subset

```json
{ "buses": [{
    "bus_id": "uuid",
    "collected": 0.0, "to_return": 0.0, "to_collect": 0.0,
    "spent": 0.0, "income": 0.0, "handed_over": 0.0, "unpriced_seats": 0
}] }
```

**No `bus_rent`. No `revenue_billed`. Ever.** `lib/models/handler_bus_money.dart:14-19` **[V]** states rent is admin-only. Leaking it makes the handler's "to admin" line wrong *and* breaks the `admin.expectedHandover == handler.inHand` invariant.

`spent` is ground expenses only — i.e. `expenses_total` computed with `bus_rent` excluded. **`handler_money` must derive `spent` from the *same expression* `tour_money` uses for `expenses_total − bus_rent`**, not independently, or invariant I1 diverges and no Dart test can catch it.

`inHand`, `outstanding`, `isSettled` stay as Dart getters (`lib/models/handler_bus_money.dart:60-72` **[V]**).

---

## Client changes

### Models become deserialisers; every derived getter stays

| file | change | untouched |
|---|---|---|
| `lib/models/money_summary.dart` | `BusMoneySummary.compute` (:101 **[V]**), `HandlerMoneySummary.fromBuses` (:241 **[V]**), `TourMoneySummary.compute` (:356 **[V]**) gain sibling `fromRpc(Map<String,dynamic>)` factories. The `.compute` factories are **kept, marked `@visibleForTesting`**, through Phase 8 | every getter: `groundExpenses` :68, `expectedHandover` :76, `outstandingHandover` :79, `netBilled` :84, `netCollected` :89, `totalNet` :328, `totalNetBilled` :332, `totalGroundExpenses` :336, `totalExpectedHandover` :341, `totalOutstandingHandover` :345, `hasOrphanMoney` :307 — all **[V]** |
| `lib/models/handler_bus_money.dart` | `compute` (:77 **[V]**) gains `HandlerBusMoney.fromRpc` | `inHand` :60, `outstanding` :67, `isSettled` :72 — all **[V]** |
| `lib/models/tour_finance.dart` | `TourFinance.from` keeps its `Tour` argument (it needs title/route/dates/status/counts); only the three doubles arrive from `tours_money_rollup` | `FinanceTotals` entirely |

**New fields to add:** `BusMoneySummary.detachedPayerIds`, `.unpricedSeats`, `.expensesBySource`, `.incomeBySource`; `TourMoneySummary.orphanHandedOver`, `.unpricedSeats`.

**A tolerant numeric parser is mandatory.** Postgres `numeric` can arrive over PostgREST as a JSON **string** or as a `num` depending on client configuration — **[UNVERIFIED]** which this project gets, because no existing RPC in `lib/services/customer_requests_store.dart` returns a bare aggregate to compare against. Write one helper and use it everywhere:

```dart
double _money(Object? v) => switch (v) {
  null      => 0.0,
  final num n    => n.toDouble(),
  final String s => double.tryParse(s) ?? 0.0,
  _         => 0.0,
};
```

Missing keys default to **0**, never `null`, never a throw.

### `MoneyController` rework — `lib/controllers/money_controller.dart`

**Delete:** `_busRents()` (:582 **[V]**), `_billedRevenues()` (:597 **[V]**), `_detachedCash()` (:689 **[R]**), `settlementByTour` (:191 **[V]**), `loadSettlementSnapshots` (:209 **[V]**).

**Rewrite as payload lookups:** `summaryForBus` (:633 **[V]**), `summariesForBuses` (:708 **[V]**), `tourSummary` (:645 **[V]**), `handlerSummaries` (:738 **[V]**), `outstandingHandoverFor` (:196 **[V]**, now reads a rollup map).

**Keep unchanged:** `stateForBusSummary` (:795 **[V]**) — it is a classifier over derived figures with a 0.005 epsilon, already takes a `BusMoneySummary`, and survives verbatim. `_busById()` and `_tourPassengers()` stay, because `reconcileAfterSeatMove` (:347 **[V]**) and the detached-payer name join still need them.

**Keep the raw row lists.** `collections` / `expenses` / `handovers` / `incomes` (`money_controller.dart:33-36` **[R]**) are **not** replaced. Every money screen renders and CRUDs individual rows (`bus_money_screen.dart:271-310/338-372/394-432`; `handler_bus_chart_screen.dart` expense/income/handover sections **[R]**). The RPC replaces **aggregates only**.

**Two retry/loading guards that must not silently break.** Five screens gate their retry state on `loadFailed && lists.isEmpty` (`bus_money_screen.dart:56-61`, `trip_pnl_screen.dart:43-48`, `tour_money_board_screen.dart:44` **[R]**). If the aggregate load can fail independently of the row load, add an explicit `summaryLoadFailed` flag and gate on it — otherwise a failed aggregate renders an **all-zero, settled-looking cockpit**, which is the exact bug those guards were added to fix.

**Optimistic writes must keep moving the number.** `upsertCollection`/`upsertExpense`/`upsertIncome`/`recordHandover` (`money_controller.dart:276/409/468/525` **[R]**) currently patch locally and the summary recomputes instantly. With server aggregates, an optimistic write no longer moves the total until a refetch lands — the money board appears **frozen right after the agent saves**. Required pattern:

```dart
/// Server-truth summary, overlaid with the local delta of any write that has
/// not yet been confirmed by a refetch. The board moves instantly; the server
/// number wins the moment it arrives.
BusMoneySummary summaryForBus(String busId) =>
    _payloadBus(busId).withPendingDelta(_pendingDeltaFor(busId));
```

Maintain `_pendingDeltaFor` as a small per-bus struct (`collectedΔ`, `incomeΔ`, `expensesΔ`, `handedOverΔ`) cleared on each successful aggregate refetch. This is the single most likely source of a "the app feels broken" regression.

**Dashboard settlement (`HARD-1`).** `lib/screens/dashboard_screen.dart:86-87` fires `loadSettlementSnapshots` post-frame from inside an `Obx`, with a documented no-feedback-loop argument resting on that `Obx` reading only `tourCtrl` state **[R]**. Swapping in a reactive rollup that the same `Obx` reads **re-introduces the loop**. Load the rollup from `onReady`/an explicit refresh, not from inside that `Obx`.

### `FinanceController` rework — `lib/controllers/finance_controller.dart`

`load()` (:85 **[V]**) and `_pageThrough` (:173 **[R]**) collapse to a single `tours_money_rollup()` call. `financesFor` / `totalsFor` / `lifetimeNet` / `_inPeriod` unchanged.

`lifetimeRealisedNet` (:237-238 **[R]**) has **no consumer in `lib/`**. Confirm nothing in `test/` reads it, then delete it in the same commit — carrying a second, unused lifetime figure through this change is how the two "revenue" bases got confused in the first place.

The `markStale` machinery (`money_controller.dart:74-77`, consumed at `settings_screen.dart:241` **[R]**) exists because `MoneyController` and `FinanceController` hold independent copies. Once both read the server it can be deleted — **only if both call the same endpoint**.

### `seat_billing` writer — new service

New file `lib/services/seat_billing_writer.dart`:

```dart
/// One persisted billing row per DISTINCT seat a passenger holds on a bus.
/// Pure: no IO, no controller lookups — so it is trivially unit-testable.
class SeatBillingRow {
  final String tourId, busId, passengerId, seatId, seatType;
  final int seatRow, goBerths, retBerths;
  final double amount, unitPrice;
}

/// The ONLY producer of authoritative billed fares. Reads Bus.amountDueForSeat.
List<SeatBillingRow> rowsForTour(Tour tour);
List<SeatBillingRow> rowsForPassenger(Tour tour, Bus bus, Passenger p);
```

`rowsForPassenger` mirrors `Bus.amountDueFor`'s distinct-seat `seen` set (`lib/models/bus_details.dart:501-519` **[V]**) so a whole double sofa yields **one** row at the full sofa price, matching the collection key.

New RPC `reprice_tour(p_tour_id uuid, p_rows jsonb)` — SECURITY DEFINER, ownership-checked, taking `pg_advisory_xact_lock(hashtext(p_tour_id::text))` (the same lock `chart_claim_seats` already uses **[R]**, so a reprice and a customer claim serialise for free). One `insert … on conflict (passenger_id, bus_id, seat_id) do update`, plus one `update … set status='void'` for keys present in the table but absent from the payload **and** whose `status = 'active'`.

**It must hard-fail, not void, when the tour is not fully hydrated.** `ensureTourHydrated` (`tour_controller.dart:2659` **[R]**) is lazy; repricing a partial tour would void the billing rows of every passenger that simply was not loaded. Pass an explicit `p_expect_passenger_count` and have the RPC `raise exception` on mismatch.

### Reprice triggering — one debounced tour-scoped pass, NOT eager per-mutation

**This is the decisive design call, and the evidence is unambiguous.** There are 12+ Dart methods that mutate `passengers.assigned_seats`, and only **three** call `_reconcileMoneyAfterMove` today (`tour_controller.dart:1246`, `:1708`, `:2107`) **[R]**. `moveSharedPair` (:1720), `swapSeatContents` (:1787), `unassignSeats` (:1369), `unassignBus` (:1393), `cancelOneSeat` (:1437), `consolidateOntoDouble` (:1515) and `setWaitlisted` (:2117) have **no money hook at all** **[R]**. An eager scheme inherits exactly that forgetting failure — and this time the forgotten write is accrual revenue, which nobody notices until settlement.

Add `void _scheduleReprice(String tourId)` — coalescing and debounced, following the existing `_scheduleRefresh` (`tour_controller.dart:227` **[R]**) / `_scheduleNotify` (`:183` **[R]**) idiom. Call it at the end of **every** path in these three inventories:

- **Seat mutations:** `assignSeats` :1078, `moveGroupToBus` :1159, `fillTour` :1262, `unassignSeats` :1369, `unassignBus` :1393, `cancelOneSeat` :1437, `consolidateOntoDouble` :1515, `moveSeat` :1627, `moveSharedPair` :1720, `swapSeatContents` :1787, `swapSeats` :1880, `setWaitlisted` :2117.
- **Bus price/layout edits:** `updateBus` :2528 (the single funnel for the Add/Edit Bus form and the price-sheet copy), `addBus` :2504, `removeBus` :2540.
- **Passenger lifecycle:** `removePassenger` :967, `updatePassenger` :979, `updatePassengerFromRequestEdit` :999, `cancelReturnSeat` :898.
- Unconditionally on `ensureTourHydrated` :2659, and before `lockTour` :717 and `completeTour` :730.

(All line numbers **[R]** from the discovery pass; locate by symbol.)

**Three paths must NOT trigger a reprice:**
- `setSeatForward` (:2855) and `setSeatReserved` (:2868) — they rewrite `buses.layout` but change no pricing input. `SeatCell.forward`'s doc comment at `lib/models/seat_layout.dart:49-54` claims it "drives PRICING only"; it does not — `grep forward lib/models/bus_details.dart` finds no pricing use **[R]**. Fix the comment.
- Tour-level `pricePerSeat` edits — `editTour` rebuilds the `Tour` passing `buses: t.buses` untouched (`tour_controller.dart:660` **[R]**), so `tours.price_per_seat` is only a *default for a new bus*. It cascades to nothing.
- `bus_price` (rent) edits — rent never touches `amountDueForSeat` **[V]**.

**The price-sheet loop is the sharpest edge.** `lib/screens/edit_tour_screen.dart:333-344` **[R]** awaits `updateBus` per bus with no transaction. Trigger the reprice **once after the loop completes**, not inside it, or a mid-loop failure leaves half the fleet repriced against a partially-copied price sheet.

### Handler screen — **[V] CORRECTION: the refresh work is ALREADY DONE**

The `handler_ui` discovery report states that `RefreshIndicator` and `WidgetsBindingObserver` are net-new on `lib/screens/handler_bus_chart_screen.dart`. **That is stale.** I verified the current file directly:

- `enum _LoadKind { initial, pull, silent }` at **:91** **[V]** — with documented spinner and failure semantics per kind.
- `with WidgetsBindingObserver` at **:110**, `dispose` removing the observer at **:334**, `didChangeAppLifecycleState` at **:340** calling `_reconcile()` on resume **[V]**.
- `RefreshIndicator(onRefresh: () => _load(kind: _LoadKind.pull))` at **:1106-1107** **[V]**.
- `_load` has a `_loadToken` re-entrancy guard (:359), resets `_error = null` (:424), and `_busIdAfterReload(manifest)` at **:420/:457** is exactly the bus-selection guard the report asks for **[V]**.
- `_reconcile()` is already called after **every** money write — nine call sites at :285, :346, :521, :551, :721, :758, :800, :840, :882 **[V]**.

**Therefore: strike "handler screen gets pull-to-refresh / refetch-on-resume" from plan step 4.** The remaining handler work is the `handler_money` cutover and the tab restructure only. The report's line numbers for this file are systematically ~60–160 lines low (the file is **3892** lines, not 3730; `_summaryForBus` is at **:299**, not :236) **[V]** — locate every symbol by name, not by the report's line numbers.

The only change to `_load` is that it must additionally call `handler_money(requestId)` and populate `_money` (a `Map<String, HandlerBusMoney>` keyed by bus id), best-effort, in the style of the existing `_safeHandovers`/`_safeLegState` helpers — a money-RPC failure must never take the seat chart down.

**`customer_requests_store.dart` uses raw `client.rpc(...)` throughout and gets no deploy-failure protection.** Only `sync_service.dart:576-599` translates `PGRST202`/`42883` into `RpcUnavailableException` **[R]**. `handler_money` must be called through that translation, or the handler Money tab throws instead of degrading when the migration is not yet deployed.

---

## Live data cleanup

**Ground rules.**

**R0 — the code fix ships before the data merge.** With the current seat-keyed handler lookup, a single tap on a seat re-creates a duplicate minutes after you merge it. Phase 5 gates Phase 6.

**R1 — nothing is deleted, everything is archived.** The codebase already takes this position (`lib/services/collection_reconciler.dart:94-98`: money is never deleted, so cash stays visible as `detachedCash` rather than silently vanishing **[R]**). Do not break it during cleanup.

```sql
create schema if not exists money_cleanup;
create table money_cleanup.snap_collections   as select * from public.collections;
create table money_cleanup.snap_expenses      as select * from public.expenses;
create table money_cleanup.snap_incomes       as select * from public.incomes;
create table money_cleanup.snap_bus_handovers as select * from public.bus_handovers;
create table money_cleanup.snap_passengers    as select * from public.passengers;
create table money_cleanup.snap_buses         as select * from public.buses;

create table money_cleanup.collections_archive
  as select c.*, now() as archived_at, ''::text as reason, null::uuid as merged_into
       from public.collections c where false;
create table money_cleanup.expenses_archive
  as select e.*, now() as archived_at, ''::text as reason
       from public.expenses e where false;
```

**R2 — report, confirm, repair. Never a silent mass UPDATE.** All four money tables are in the realtime publication (`database.sql:1247-1249`; `incomes` at `029:387-391`) **[R]**. A mass UPDATE fans out live to every connected admin and handler device *mid-trip*, rewriting what a handler is looking at while they hold cash. Maintenance window, batched, per-tour operator sign-off.

**Shared helper views** (used by several classes):

```sql
create or replace view money_cleanup.v_held_seats as
select p.id as passenger_id, p.tour_id,
       e->>'busId' as bus_id_text,
       split_part(e->>'seatId','#',1) as seat_base
  from public.passengers p
  cross join lateral jsonb_array_elements(coalesce(p.assigned_seats,'[]'::jsonb)) e
 where p.cancelled_at is null
 group by 1,2,3,4;

-- Berths actually BOUGHT — mirrors Passenger.seatBerths (passenger.dart:145-152):
-- a doubleSofa line counts 2, everything else 1.
create or replace view money_cleanup.v_berths_bought as
select p.id as passenger_id,
       coalesce(sum((l->>'qty')::int
                    * case when l->>'seatType'='doubleSofa' then 2 else 1 end),0) as berths
  from public.passengers p
  left join lateral jsonb_array_elements(coalesce(p.request_lines,'[]'::jsonb)) l on true
 group by 1;
```

### Class 1 — duplicate collection rows

**Detection.**

```sql
create or replace view money_cleanup.v_collection_groups as
select c.passenger_id, c.bus_id, min(c.tour_id) as tour_id,
       count(*)                                          as row_count,
       count(*) filter (where c.seat_id = '')             as blank_seat_rows,
       count(*) filter (where c.amount_received <> 0
                           or c.amount_refunded <> 0)     as cash_rows,
       sum(c.amount_received - c.amount_refunded)         as net_cash,
       array_agg(c.id      order by c.created_at)         as row_ids,
       array_agg(c.seat_id order by c.created_at)         as seat_ids
  from public.collections c
 group by c.passenger_id, c.bus_id
having count(*) > 1;

create or replace view money_cleanup.rpt_collection_dupes as
select g.*, p.name, p.phone, p.journey_done,
       (p.cancelled_at is not null) as is_cancelled,
       b.name as bus_name, bb.berths as berths_bought,
       (select count(*) from money_cleanup.v_held_seats h
         where h.passenger_id=g.passenger_id and h.bus_id_text=g.bus_id::text) as seats_held_now,
       case
         when g.blank_seat_rows > 0 then 'BLANK_SEAT_LEGACY'
         when (select count(*) from money_cleanup.v_held_seats h
                where h.passenger_id=g.passenger_id
                  and h.bus_id_text=g.bus_id::text) = 0 then 'UNRESOLVED_NO_SEATS'
         when (select count(*) from money_cleanup.v_held_seats h
                where h.passenger_id=g.passenger_id
                  and h.bus_id_text=g.bus_id::text) >= g.row_count
              and bb.berths >= g.row_count           then 'GENUINE_MULTISEAT'
         when g.cash_rows <= 1                       then 'SEAT_MOVE_DUP'
         else                                             'AMBIGUOUS'
       end as verdict
  from money_cleanup.v_collection_groups g
  join public.passengers p on p.id = g.passenger_id
  join public.buses      b on b.id = g.bus_id
  left join money_cleanup.v_berths_bought bb on bb.passenger_id = g.passenger_id;
```

**A whole double sofa is NOT a duplicate.** It is two entries in `assigned_seats` on the *same* `seatId` but exactly ONE collection row (`lib/models/bus_details.dart:521-531` **[V]**). `v_held_seats` groups on the base seat id, so it already collapses a whole double to one seat — do not change that.

**Merge rule.** Group = `(passenger_id, bus_id)`.
1. Survivor = the row whose base `seat_id` is currently held; ties broken by (a) most net cash, then (b) latest `updated_at`.
2. Survivor takes `amount_received = SUM(received)`, `amount_refunded = SUM(refunded)`. **Cash is only ever summed, never dropped** — dropping an "empty" duplicate silently *understates* to-collect, because the shortfall pass is keyed by passenger id, not by seat (`lib/models/money_summary.dart:120-139` **[V]**).
3. Survivor `seat_id` normalised to the base held seat.
4. **`amount_due` is not rewritten** (see *Data model*). It is a historical quote.
5. Non-survivors → archive with `merged_into`, then delete, **in the same transaction**.

**Automate only `BLANK_SEAT_LEGACY` and `SEAT_MOVE_DUP`.** `UNRESOLVED_NO_SEATS` and `AMBIGUOUS` go to an admin review queue and are **left exactly as they are**. Two duplicate rows overstate cash, which the new ledgers make visible; a wrong merge silently destroys the only record of who paid what. **Overstating loudly beats destroying quietly.**

The review UI should surface `tour_seat_snapshots` (`046:38-49`, written at `:469-479` **[R]**) as evidence — it holds the frozen pre-wipe GO chart. It carries **name + phone, not `passenger_id`** **[R]**, so it is good enough for a human to read and **not** a safe automatic join key.

**Hard gate — run inside the transaction, roll back unless it returns 0:**

```sql
select (select coalesce(sum(amount_received-amount_refunded),0) from public.collections)
     + (select coalesce(sum(amount_received-amount_refunded),0)
          from money_cleanup.collections_archive where reason='class1_merge')
     - (select coalesce(sum(amount_received-amount_refunded),0)
          from money_cleanup.snap_collections) as must_be_zero;
```

### Class 2 — orphan money

An orphan can only ever be **a bus that still exists whose `tour_id` drifted** — all four money tables FK `bus_id` with `on delete cascade` (`004_money_collection.sql:52`; `029:53`) **[R]**, so a row can never point at a missing bus.

```sql
create or replace view money_cleanup.rpt_orphans as
select 'collections' t, c.id, c.tour_id row_tour, b.tour_id bus_tour, c.bus_id, b.name,
       (c.amount_received-c.amount_refunded) amount
  from public.collections c join public.buses b on b.id=c.bus_id
 where b.tour_id is distinct from c.tour_id
union all select 'expenses', e.id, e.tour_id, b.tour_id, e.bus_id, b.name, e.amount
  from public.expenses e join public.buses b on b.id=e.bus_id
 where b.tour_id is distinct from e.tour_id
union all select 'incomes', i.id, i.tour_id, b.tour_id, i.bus_id, b.name, i.amount
  from public.incomes i join public.buses b on b.id=i.bus_id
 where b.tour_id is distinct from i.tour_id
union all select 'bus_handovers', h.id, h.tour_id, b.tour_id, h.bus_id, b.name,
       h.handed_over_amount
  from public.bus_handovers h join public.buses b on b.id=h.bus_id
 where b.tour_id is distinct from h.tour_id;
```

**Review only, three offers, never delete:** (1) re-home the tour pointer to the bus's tour; (2) reassign to a bus on this tour; (3) leave it and let the ledger carry an explicit "off-fleet" line. Option 3 is the model's existing stated position (`lib/models/money_summary.dart:288-301` **[V]**) and should stay the default.

**Confirm every orphan against this SQL before offering a repair** — a partially hydrated tour produces *phantom* orphans on screen (root cause 5). Repairing off the screen instead of off the SQL would corrupt correct rows.

### Class 3 — legacy `busOwner` expense rows

```sql
select e.id, e.tour_id, e.bus_id, b.name bus_name, e.label, e.amount, b.bus_price,
       case when b.bus_price = 0                  then 'PROMOTE_TO_BUS_PRICE'
            when abs(e.amount - b.bus_price) <= 1 then 'AUTO_DELETE_DUPLICATE'
            else                                       'REVIEW_AMOUNT_MISMATCH' end verdict
  from public.expenses e join public.buses b on b.id = e.bus_id
 where e.category = 'busOwner' order by e.amount desc;

-- Report only. Never auto-act: rent logged under another category.
select e.id, e.tour_id, e.bus_id, e.category, e.label, e.amount, b.bus_price
  from public.expenses e join public.buses b on b.id=e.bus_id
 where e.category <> 'busOwner'
   and (e.label ilike '%rent%' or e.label ilike '%owner%' or e.label ilike '%bus price%'
        or e.label ilike '%भाड%' or e.label ilike '%ભાડ%');
```

- `AUTO_DELETE_DUPLICATE` — **automate** after archiving. `bus_price` already carries the cost.
- `PROMOTE_TO_BUS_PRICE` — the expense row **is** the rent; deleting it destroys a real cost. Set `buses.bus_price = e.amount`, then archive+delete. **Per-bus admin confirmation** — a bus with `bus_price = 0` may be genuinely owned, not rented. Never collapse this branch into the auto-delete branch.
- `REVIEW_AMOUNT_MISMATCH` — review.

**Also re-check already-settled handovers on affected buses.** A legacy `busOwner` row reduced `HandlerBusMoney.spent → inHand` **[V]**, so fixing the admin-side double-count without re-checking settlements leaves a real cash shortfall that now has no explanation on either screen.

### Class 4 — stale `amount_due` vs live fare

**Not detectable in SQL until `seat_billing` exists** — the fare engine is Dart-only. This pass is *gated on* the Phase-1/2 backfill.

```sql
select c.id, c.tour_id, c.bus_id, c.passenger_id, c.seat_id,
       c.amount_due as quoted, sb.amount as live_fare,
       c.amount_due - sb.amount as drift,
       (c.amount_received - c.amount_refunded) as cash_taken, p.name, p.phone
  from public.collections c
  join public.seat_billing sb
    on sb.tour_id=c.tour_id and sb.bus_id=c.bus_id and sb.passenger_id=c.passenger_id
   and split_part(sb.seat_id,'#',1) = split_part(c.seat_id,'#',1)
   and sb.status in ('active','travelled')
  join public.passengers p on p.id=c.passenger_id
 where abs(c.amount_due - sb.amount) > 0.005
 order by abs(c.amount_due - sb.amount) desc;
```

**Report only. Do not mass-rewrite.** Under the chosen design `amount_due` no longer feeds any aggregate, so drift is cosmetic. Surface it as a per-rider "quoted ₹1,500 · fare is now ₹2,000 · collect ₹500 / re-quote" affordance.

### Class 5 — the remainder

**5a — `seat_id` that resolves to no layout cell.** `_cellsById` is an exact-string map and `amountDueForSeat` returns **0** for a missing cell (`lib/models/bus_details.dart:534-536` **[V]**) — a stray space or a seat id from a reshaped layout produces a **silent zero fare**. This is more likely than the `#`-suffix case (**no code path writes a `#` suffix** — the `split('#')` calls are defensive **[R]**; run the detection anyway, it is cheap).

```sql
select c.id, c.seat_id, b.name bus_name, c.amount_due,
       (c.amount_received-c.amount_refunded) cash
  from public.collections c join public.buses b on b.id=c.bus_id
 where c.seat_id <> '' and b.layout is not null
   and jsonb_array_length(coalesce(b.layout->'grid','[]'::jsonb)) > 0
   and not exists (select 1 from jsonb_array_elements(b.layout->'grid') g
                    where g->>'seatId' = split_part(c.seat_id,'#',1));
```

Normalisation (trim/case) is **automate-safe where the normalised value resolves to a real cell**, and must run **inside** the Class 1 merge transaction (normalising `'A1#2'`→`'A1'` violates the current triple index if `'A1'` already exists).

**5b — blank `seat_id` legacy rows.** Root cause 2. Handled by Class 1's `BLANK_SEAT_LEGACY` verdict — the highest-confidence auto-merge in the whole cleanup. Headline query:

```sql
select count(*) blank_rows, sum(amount_received-amount_refunded) blank_cash,
       count(*) filter (where exists (select 1 from public.collections c2
         where c2.passenger_id=c.passenger_id and c2.bus_id=c.bus_id and c2.seat_id<>''))
         as blank_rows_with_a_seated_twin
  from public.collections c where c.seat_id = '';
```

**5c — duplicate handover rows.** Both sheets mint a fresh uuid on every save and the RPC conflicts only on `id` **[R]** — a retry after a write that landed produces two identical settlements, `handedOver` sums them (`lib/models/money_summary.dart:166` **[V]**) and `outstandingHandover` goes negative.

```sql
select h.bus_id, b.name, h.handed_over_amount, count(*) copies, array_agg(h.id),
       min(h.settled_at), max(h.settled_at)
  from public.bus_handovers h join public.buses b on b.id=h.bus_id
 group by h.bus_id, b.name, h.handed_over_amount, h.note
having count(*) > 1 and max(h.settled_at)-min(h.settled_at) < interval '10 minutes';
```

**Review only** — a genuine repeat handover of a round number is plausible. Fix forward with a client-supplied idempotency key on the RPC.

**5d/5e — cash held for riders no longer on the roster.**

```sql
select case when p.cancelled_at is not null then 'CANCELLED'
            when p.journey_done             then 'GO_LEG_CLEARED'
            else 'UNSEATED' end why,
       count(*) rows, sum(c.amount_received-c.amount_refunded) cash_held
  from public.collections c join public.passengers p on p.id=c.passenger_id
 where not exists (select 1 from jsonb_array_elements(coalesce(p.assigned_seats,'[]'::jsonb)) e
                    where e->>'busId' = c.bus_id::text)
 group by 1;
```

**Report only.** `GO_LEG_CLEARED` is *fixed by the seat_billing backfill itself* and needs no data surgery. `CANCELLED` cash is a business decision — a blocking question.

**5f — money collected outside the books.** `payment_attempts` (`049:188-210` **[R]**) is read by **nothing** in `lib/`, and `lib/widgets/upi_payment_sheet.dart` shows a payee QR and **writes no collection row** **[R]**. Run `select count(*) from public.payment_attempts;` and **ask the operator directly**. If money is taken this way, no table cleanup reconciles the books.

**5g — `removeBus` destroys a ledger.** `tour_controller.dart:2540-2549` **[R]** hard-deletes; all four money tables cascade. Settled cash, expenses, incomes and handovers vanish with no archive. Add a confirm dialog that names the amount about to be destroyed, in Phase 5.

### Cleanup run order

| # | Step | Automate? | Gate |
|---|---|---|---|
| 0 | Phase 5 code fix shipped (seat-agnostic lookup + upsert) | code | **Blocks everything** |
| 1 | `money_cleanup` schema + full snapshots | yes | — |
| 2 | Detection-only pass, all classes, **zero writes** | yes | Operator signs off the totals |
| 3 | Class 3 `busOwner`: auto-delete the matching subset; review the rest; `validate constraint expenses_no_bus_owner_chk` | partly | Archive first |
| 4 | Class 2 orphans: per-row admin decision | **no** | Admin per row |
| 5 | `seat_billing` backfill (Phase 1–2 already shipped) | yes | Must precede 6 and 7 |
| 6 | Class 1 merge + 5a normalisation, auto-safe verdicts only, one transaction | partly | `must_be_zero = 0` or roll back |
| 7 | Class 4 drift report; Class 5c/5d/5e review queues | **no** | Admin |
| 8 | *(Phase 8, optional)* `superseded_at` + partial unique index; drop the triple index | yes | After 6 |
| 9 | Re-run step 2; publish per-tour before/after ledger diff | yes | Operator sign-off |

**The three things genuinely safe to automate:** Class 3 rows matching `bus_price` within ₹1; Class 1 `BLANK_SEAT_LEGACY` groups with a per-seat twin; Class 5a normalisation that resolves to a real layout cell. Everything else is a judgement about someone's money.

**The human gate that matters most:** pick **one** tour the operator remembers the real numbers for, run the whole sequence on it alone, and have them confirm the figures before touching the rest.

---

## Handler UI

**Correction first:** the refresh/lifecycle work is done (**[V]**, see *Client changes*). What remains is the tab restructure, the pinned strip, the ledger, and the file split.

### Design system constraints — non-negotiable

The design system is **`lib/design/`** (there is no `lib/theme/`), behind the barrel `lib/design/ugam.dart`, which the handler screen already imports **[R]**. `lib/design/tokens.dart:9-15` states the top spacing steps are **deliberately compressed** for a "glanceable cockpit, not a spacious showroom", and `:181-183` warns that `xl == lg == 16` is intentional **[R]**. This matches the recorded project memory (*density overhaul: cockpit, do not re-widen*).

**The restructure must not introduce a single new spacing value, must not widen any `md`→`lg`, and must not raise any radius.** Reuse `UgamTabPills`, `UgamSelectorPills`, `UgamHeroStat`, `UgamCard.plain`, `UgamCTA`, `UgamButton`, `UgamSectionLabel`, `UgamStickyCTA` verbatim.

### Three tabs

Replace `enum _ViewMode { grid, attendance }` (`handler_bus_chart_screen.dart:43` **[V]**) with `enum HandlerTab { seats, money, boarding }`.

**Behaviour change to guard:** `canExpand` currently requires `_viewMode == _ViewMode.grid` **[R]**. It must become `_tab == HandlerTab.seats`, or the fullscreen-chart action either disappears or appears on the Money tab.

**Behaviour change for the user:** Expenses and Income today render only inside the `if (grid)` branch of `_body` **[R]** — i.e. below the seat chart. Moving them to Money is a real muscle-memory change; a handler will scroll the grid looking for "Add expense". Ship a one-release affordance (an inline "Expenses moved to the Money tab →" row at the bottom of Seats).

### Pinned in-hand strip

Sits **outside** the scroll view, directly under the tab pills, on **all three tabs**. One `UgamCard.plain(padding: EdgeInsets.symmetric(horizontal: UgamSpacing.md, vertical: UgamSpacing.sm), radius: UgamRadius.row)` containing a single `Row`: wallet icon (18px, `settled ? c.good : c.accent`) · `Expanded` label · trailing `Formatters.formatMoneyInr(summary.outstanding)`.

**Headline is `outstanding`, not `collected` or `inHand`.** `_SummaryHeader`'s own comment establishes the rule: once they settle on the roadside the number they are looking at must actually go down **[R]**. Tapping the strip on a non-Money tab switches to Money.

Do **not** use `UgamHeroStat` here — that is the ~76px hero and it belongs inside the Money tab.

### The Money ledger — the thing that visibly adds up

One `UgamCard.plain(padding: EdgeInsets.all(UgamSpacing.lg))`, a `Column` of fixed-height rows `[sign] [label Expanded caption ink2] [amount bodyStrong]`, separated by `SizedBox(UgamSpacing.tight)`, with **two `Divider(height:1, color:c.border)` rules** marking the subtotals. The rules are the only structural addition and are what make it read as arithmetic:

| Row | Source (`lib/models/handler_bus_money.dart`) | Sign | Tone |
|---|---|---|---|
| Collected | `collected` :27 **[V]** | + | `c.good` |
| Income | `income` :37 **[V]** | + | `c.good` |
| Spent | `spent` :34 **[V]** | − | `c.warm` |
| — rule — | | | `c.border` |
| **To hand over** | `inHand` :60 **[V]** | = | `c.ink`, `bodyStrong` |
| Already handed | `handedOver` :42 **[V]** | − | `c.good` |
| — rule — | | | `c.border` |
| **Still to hand over** | `outstanding` :67 **[V]** | = | `settled ? c.good : c.accent` |

Render the last two rows only when `handedOver.abs() > Collection.kMoneyEpsilon` — an always-on ₹0 line is noise, matching the existing `hasHandover` guard **[R]**.

`toCollect` (:29) and `toReturn` (:28) are **not** in the add-up — they are not cash the handler holds. Keep them as `HeroStatLine`s on the hero or as a caption beneath the ledger. Putting them into the vertical column is the single easiest way to break the arithmetic.

**Bus rent stays absent.** Deliberate **[V]**.

**New:** when `unpriced_seats > 0`, render a warm caption row *above* the ledger: "N seat(s) not yet priced — ask the organiser to open this trip." Never fold an unpriced seat into the totals as ₹0 silently.

Money tab body order (seams lifted verbatim from today's `_body`): hero (`breakdown: null` — the ledger is now the sole breakdown; `UgamHeroStat` already accepts a null breakdown **[R]**) → `md` → ledger → `md` → settlement card → `xl` → expenses section → `xl` → income section.

The settlement card (`_SettlementCard`, :2753 **[V]**) already *is* the handover ledger — outstanding in the header, one line per `BusHandover`, delete gated on `h.byHandler`, settle CTA hidden once settled **[R]**. **Move it, do not rewrite it.**

### File split — target tree and precedent

Precedent exists: `lib/widgets/dashboard/` holds `attention_section.dart`, `trip_hero.dart`, `dashboard_models.dart`, `loading_shimmer.dart` for `dashboard_screen.dart` **[R]**. Follow it exactly. **The screen file must stay at `lib/screens/handler_bus_chart_screen.dart`** — `customer_my_requests_screen.dart:17` and `find_my_seat_screen.dart:15` import that path **[R]**, and `test/screens/handler_bus_chart_screen_test.dart` imports the public widget **[R]**.

```
lib/widgets/handler/
  handler_models.dart          HandlerTab, HandlerAttendanceCounts, HandlerAttendanceEntry
  handler_shared_bits.dart     HandlerCallButton, HandlerDeleteGlyph, HandlerCategoryChip
  handler_bus_header.dart      HandlerBusDeparture, HandlerDriverContact
  handler_loading_skeleton.dart
  handler_seats_tab.dart       HandlerSeatsTab, HandlerSeatGrid, HandlerPriceBandKey
  handler_seat_sheets.dart     HandlerOccupantChooserSheet, HandlerCollectSheet
  handler_money_tab.dart       HandlerMoneyTab
  handler_money_ledger.dart    HandlerInHandStrip, HandlerMoneyLedger, HandlerMoneyHero
  handler_expenses_section.dart
  handler_income_section.dart
  handler_settlement_card.dart
  handler_money_sheets.dart    Expense / Income / Handover sheets
  handler_boarding_tab.dart    HandlerBoardingTab, BoardedSummary, LegCompletionCard, AttendanceView
  handler_bus_message_sheet.dart
```

**Corrected source line numbers [V]** (the discovery report's are ~60–160 low): `_LoadingSkeleton` :1211 · `_SeatGrid` :1265 · `_CallButton` :1378 · `_PriceBandKey` :1405 · `_PriceBandRow` :1447 · `_TripBadge` :1525 · `_OccupantChooserSheet` :1581 · `_LegSharedTile` :1683 · `_BusDeparture` :1756 · `_DriverContact` :1811 · `_AttendanceCounts` :1927 · `_AttendanceEntry` :1938 · `_SummaryHeader` :1945 · `_CollectSheet` :2056 · `_ReadOnlyLine` :2379 · `_ExpensesSection` :2408 · `_HandlerExpenseRow` :2506 · `_DeleteGlyph` :2593 · `_ExpenseSheet` :2615 · `_SettlementCard` :2753 · `_HandoverSheet` :2855 · `_LegCompletionCard` :2955 · `_CategoryChip` :3027 · `_IncomeSection` :3080 · `_HandlerIncomeRow` :3178 · `_IncomeSheet` :3267 · `_HandlerBusMessageSheet` :3400 · `_BoardedSummary` :3508 · `_BoardedChip` :3541 · `_AttendanceView` :3599 · `_AttendanceRow` :3757 · `_PickupChip` :3868.

**What blocks the split:** exactly three private types crossing a prospective file boundary (`_ViewMode` :43, `_AttendanceCounts` :1927, `_AttendanceEntry` :1938 — Dart privacy is per-library) and three multi-caller leaf widgets (`_CallButton`, `_DeleteGlyph`, `_CategoryChip`). Everything else is already props-in/callbacks-out with no ancestor lookups **[R]**. **No state is lifted** — every map stays on `_HandlerBusChartScreenState`; tabs receive derived plain values and callbacks.

**Commit sequence (each independently compilable):**
1. `handler_models.dart` + `handler_shared_bits.dart` — rename-only.
2. Move the sheets — ~1,000 lines out, zero layout change.
3. Move the sections — still rendered by the *old flat* `_body`. **Checkpoint: `flutter test` green and a visual diff showing zero change.** That is the proof the move was mechanical.
4. *Only then* swap to three tabs + the pinned strip. One small behaviour-changing commit.

**Do not merge 3 and 4.** 3,892 lines moving *and* the layout changing makes any visual regression indistinguishable from a bad move.

**One landmine when moving `_AttendanceView`:** its roster builder wraps a list in `Obx` and carries a comment about a GetX "improper use" crash when zero observables are registered **[R]**. Moving the method is safe; any incidental refactor of the `Obx` body can re-introduce a crash that only manifests on a roster where nobody has a pickup location.

---

## Admin UI

### The vertical ledger, and the rent line that explains the handler/admin difference

The single most-asked question this design must answer on screen is *"why does the handler's number differ from mine?"* The answer is exactly one line: **the bus owner's rent**.

`expectedHandover − netCollected == busRent` (`lib/models/money_summary.dart:76` and `:89` **[V]**) is the invariant. Make it visible.

Add `HandlerAgnosticMoneyLedger` to `lib/widgets/money/money_ledger.dart`, rendered on `bus_money_screen.dart` between the hero and the stat tiles:

| Row | Source | Sign | Note |
|---|---|---|---|
| Collected | `BusMoneySummary.collected` | + | |
| Income | `.income` | + | hidden when `abs() ≤ 0.005` |
| Ground expenses | `.groundExpenses` :68 **[V]** | − | tappable → the expense list, filtered to non-rent |
| — rule — | | | |
| **Expected handover** | `.expectedHandover` :76 **[V]** | = | **"this is the handler's figure"** — labelled explicitly |
| Already handed over | `.handedOver` | − | |
| — rule — | | | |
| **Outstanding from handler** | `.outstandingHandover` :79 **[V]** | = | the hero figure |
| Bus owner rent | `.busRent` | − | **"paid by you, never by the handler"** |
| — rule — | | | |
| **Cash profit** | `.netCollected` :89 **[V]** | = | |
| *(muted)* Still to collect | `.toCollectTotal` | | not in the add-up |
| *(muted)* To return | `.toReturnTotal` | | not in the add-up |
| *(muted)* Detached cash | `.detachedCash` | | display-only, changes no net **[V]** |

The rent row sitting *between* "outstanding from handler" and "cash profit" is the whole point: it is placed exactly where the two figures diverge, with a one-line explanation. The existing non-deletable "Bus owner rent" ledger row (`bus_money_screen.dart:249/262/268` **[R]**, which deliberately re-resolves `_liveBus.busPrice` from `TourController`) stays in the expense list and links to this line.

**Tour-level ledger** on `tour_money_board_screen.dart`, same shape over `TourMoneySummary`: `totalCollected` + `totalIncome` − `totalGroundExpenses` = `totalExpectedHandover` − `totalHandedOver` = `totalOutstandingHandover` − `totalBusRent` = `totalNet`. Plus, when `hasOrphanMoney` **[V]**, an explicit **"off-fleet money"** row carrying `orphanCollected` / `orphanExpenses` / `orphanIncome` / **`orphanHandedOver`** (the new fourth channel), labelled "on buses no longer on this trip — included in the totals above". That row is what makes the five bus cards add up to the capsule, which is the exact complaint `test/models/five_bus_expense_audit_test.dart` documents.

**Also render `unpriced_seats`** as a warm banner on both the tour board and each bus cockpit.

**Do not re-widen any spacing.** Reuse `UgamSpacing.tight` between rows, `UgamSpacing.lg` card padding, `UgamRadius.card`.

---

## Testing

### The honest headline

**All 53 currently-green money tests are coupled to the `.compute()` factories, and the repo has ZERO SQL/RPC test infrastructure** — no `supabase/tests/`, no pgTAP or `pg_prove` reference anywhere, no `[db]` section in `supabase/config.toml` **[R]** (I verified `supabase/` contains only `config.toml`, `functions/`, `migrations/` **[V]**). So the move deletes the only guards that exist for the logic being moved, unless the parity phase below is done first.

### Invariants that must keep holding

Stated over the post-rewrite payload. `B(b)` = admin per-bus, `H(b)` = handler per-bus, `T` = tour.

**I1 — admin/handler agreement (the ₹23k-vs-₹30k class).**
`B(b).expectedHandover == H(b).inHand`; and `collected`, `toCollect`/`to_collect`, `toReturn`/`to_return`, `handedOver`, `outstandingHandover`/`outstanding` pairwise equal, for every bus. Holds today only because `HandlerBusMoney.compute` passes `busRent: 0` (`lib/models/handler_bus_money.dart:97` **[V]**). Post-move it becomes a property of the SQL: **`handler_money.spent` must use the identical expression `tour_money` uses for `expenses_total − bus_rent`.** Asserted today at `test/integration/cross_system_invariants_test.dart:283-287` and `test/models/handler_handover_test.dart:198-200` **[R]**.

**I2 — rent is the exact wedge.** `B(b).expectedHandover − B(b).netCollected == B(b).busRent`; `T.totalExpectedHandover == T.totalNet + T.totalBusRent`. Pure getter algebra (`money_summary.dart:76/89/341` **[V]**) — **survives untouched**.

**I3 — per-bus sums == tour total.** For `expensesTotal`, `collected`, `income` the identity is `Σ_b == T.total − T.orphan_*`; for `handedOver`, `netCollected`, `expectedHandover`, `outstandingHandover`, `toCollectTotal` it is a plain `Σ_b ==`. **The `to_collect` roll-up is a deliberate override today** (`money_controller.dart:650-656/672` **[V]**) and the SQL must reproduce that choice or the bus rows stop adding up to the capsule.

**I4 — FinanceController agrees with the money board.** `TourFinance.net == T.totalNet`. Today "asserted" at `five_bus_expense_audit_test.dart:248-259` by **replaying the fold by hand inside the test** — `FinanceController` is never invoked **[R]**. That is a fake and must be fixed, not ported.

**I5 — whole == sum of parts, at the seat level.** `bus.amountDueFor(p) == Σ_{distinct seats} bus.amountDueForSeat(p, s)` (`cross_system_invariants_test.dart:188` **[R]**; implemented `bus_details.dart:501-519` **[V]**). Becomes: `Σ seat_billing rows for (tour,bus,passenger) == amountDueFor(passenger)`.

**I6 — handovers move `outstanding`, never `inHand`** (`handler_bus_money.dart:60/67` **[V]**). Survives.

**I7 — NEW, currently guarded by nothing: billed revenue is monotone across leg completion.** `T.totalRevenueBilled` must not fall when `completeOutboundLeg` runs. Today it does. **[V]**

### Test fates

| File | Fate |
|---|---|
| `test/models/money_summary_test.dart` (4) | 2 **KEEP** verbatim, re-driven from the existing const ctor (`money_summary.dart:53`) — the rent-wedge tests at :101 and :120 **[R]**. 2 **REWRITE** against a captured payload (bus-scoping and cross-bus summing move to SQL). |
| `test/models/handler_bus_money_test.dart` (6) | Group `seat moves never orphan collected cash` (:32-117, the raj-bus ₹23k-vs-₹30k regression) **MIGRATES TO SQL** — port the exact 10-row ₹30,000 fixture into the SQL fixture. `inHand` algebra **KEEPS**. The two to-collect tests **MIGRATE**. |
| `test/models/handler_handover_test.dart` (10) | **Highest-value survivor.** 8 tests are `outstanding`/`isSettled` getter algebra — **KEEP**, re-pointed to the const ctor. Bus-scoping and multi-handover-sum tests **MIGRATE**. The admin/handler seam group **REWRITES** onto one fixture payload. |
| `test/models/five_bus_expense_audit_test.dart` (10) | **REWRITE the producer only** — see below. |
| `test/integration/cross_system_invariants_test.dart` (9) | Seam 2 (`amountDueFor == Σ amountDueForSeat`, the `1163` mixed-berth case) **KEEP VERBATIM** — the pricing engine is not being ported and this is exactly what proves the values written into `seat_billing` are right. Seam 3 **REWRITE** onto one fixture. Seams 1/1b/4/5 untouched. |
| `test/models/detached_cash_test.dart` (11) | **REWRITE.** Detection moves to SQL. The "display-only, changes no net" assertions **KEEP**. ⚠ Several will need updating for the intentional semantics change (travelled riders stop counting as detached). |
| `test/screens/bus_money_screen_test.dart` (5) | 2 **REWRITE** (seed a deserialised summary instead of an `IncomeEntry` row). 3 skeleton/refresh tests **KEEP**. |
| `test/screens/tour_money_board_screen_test.dart` (7) | 4 **REWRITE seeding only** — the rendered-string assertions (`₹1,500`/`₹1,300`/`₹800`) stay identical, which makes them a genuine end-to-end check that the payload reaches the pixels. Better: extract the two `stateForBusSummary` classifier tests into a pure unit test over const summaries. |
| `test/controllers/money_settlement_snapshot_test.dart` | **REWRITE the `_ScriptedSync` double** to script the rollup RPC; **KEEP** both assertions. |
| `test/controllers/finance_controller_test.dart` (8) | **KEEP** — all scope/period/staleness; none exercise the fold being replaced. |
| `test/models/collection_balance_test.dart`, `collection_epsilon_test.dart` | **KEEP.** `Collection` stays a row model, and SQL must reproduce the same 0.005 band. |
| `test/screens/handler_bus_chart_screen_test.dart` (2) | **KEEP** — neither touches money. The file's own comment admits the tab toggle is verified *by eye* **[R]**, which is why §new-tests adds coverage. |

### `five_bus_expense_audit_test.dart` — how it must evolve

It is the only test written *as the user's complaint* ("I added five buses… the expenses are not calculated as per the things") **[R]**, and **it passes today**. That is its point: the pure math was never the bug. After the change it must become evidence that the change worked.

**The trap:** re-pointing it at hand-written payload objects makes it a tautology. Its value is that `groundExpectedByBus`, `totalRents = 216000`, `totalGround = 36200` were computed by hand and are known-correct.

**Keep the fixture. Change only what produces the summaries.**
1. Move the rows into `test/fixtures/five_bus_fixture.dart`; have the capture script seed **exactly these rows** into staging.
2. `summarise()` / `tourSummary()` become loaders reading `test/fixtures/five_bus_money_payload.json`. **Every assertion body stays byte-for-byte identical** — and `expect(s.groundExpenses, groundExpectedByBus[s.busId])` now means "the server isolated bus N's expenses correctly", a far stronger statement.
3. **Add the handler dimension**: one handler owning bus1+bus2, another owning bus3. Assert I1 per bus and the `HandlerMoneySummary` roll-up. The fixture is already uneven enough that a cross-handler bleed cannot cancel out.
4. **Fix the fake I4 test.** Call the real `FinanceController` with a scripted RPC double (style of `money_settlement_snapshot_test.dart:63` **[R]**), and have the double return a `totalNet` **sentinel** that no client-side fold could produce — the only way to prove I4 is structural rather than coincidental.
5. **Keep the orphan group** (:160-242). If the SQL does not implement orphan detection, this group must be deleted and the "five rows don't add up to the capsule" failure re-opens. It *is* implemented here, so keep it — and extend it with `orphanHandedOver`.
6. **Add a sixth scenario: CALC-1.** Mark bus3's riders outbound-only, apply the exact `copyWith(assignedSeats: const [], journeyDone: true)` mutation from `tour_controller.dart:762` **[V]**, and assert `totalRevenueBilled` is **unchanged**. Put it in this file, because this is the file a maintainer opens when the user next says "the money is wrong."

### New tests

**`test/models/seat_billing_test.dart`** — over the pure `rowsForPassenger`:
- one row per **distinct seat**, not per berth (whole double sofa → **1** row);
- whole double sofa at the full sofa price; shared double at half;
- mixed-leg berths on one double → the `1163` fixture from `cross_system_invariants_test.dart:192-212` reused verbatim;
- mixed same-type booking (SL1 GO-only 600 / SL2 RET-only 600, two rows);
- **every persisted amount is integral** (`row.amount == row.amount.roundToDouble()`) for a fractionally-derived fare;
- **I5**: `Σ rows(p,bus).amount == bus.amountDueFor(p)`;
- **CALC-1 positive**: build rows, apply the `assignedSeats: []` + `journeyDone: true` mutation, freeze → amount unchanged, row present;
- **CALC-1 negative control**: assert `bus.amountDueFor(clearedRider) == 0` — proves the test would have caught it;
- **re-price on leg edit**: after the Seam-4 re-stamp (half 450 → full 900), regenerating rows produces 900 — the writer is idempotent and re-priceable;
- **unseat vs travel**: a rider unseated *without* `journeyDone` gets `void`, not `travelled`. This is the boundary most likely to produce a new bug, and it is silent and cumulative if wrong;
- **`cancelReturnSeat`**: reprice-then-freeze — a demoted round-trip rider's frozen amount is the **half** fare, with `ret_berths = 0`.

**`test/services/collection_dedupe_test.dart`** — over a pure `Collection mergeRows(List<Collection>)`:
- received/refunded **summed**, never max, never last-write-wins;
- surviving `seat_id` is one the passenger still holds;
- idempotence: `mergeRows(mergeRows(x)) == mergeRows(x)`;
- **epsilon**: 3 rows each +0.004 merge to +0.012 — outside the 0.005 band. Merging can flip a bus from "settled" to "action needed" with no data change. Not covered by any current test.

**`test/models/money_payload_test.dart`** — round-trip over checked-in `test/fixtures/tour_money_payload.json` and `handler_money_payload.json`:
- every field populates; **missing keys default to 0, never null, never throw** — test all fields independently;
- **numeric type tolerance**: `1500`, `1500.0` and `"1500"` all yield `1500.0`. This is the highest-probability silent failure of the whole change;
- negatives survive (`expectedHandover` legitimately goes negative — `money_summary_test.dart:80` expects `−5900` **[R]**);
- derived getters compute on a deserialised object.

**`test/integration/money_one_fixture_agreement_test.dart`** — I1 from **ONE** fixture containing both payloads for the same tour/bus, captured in the same transaction. **The fixture must be one file.** Two hand-authored files would prove only that two deserialisers agree on numbers a human typed twice.

**`test/screens/handler_money_tab_test.dart`** — tab labels render; switching preserves state; the pinned strip shows `outstanding` formatted; **the ledger's rendered row strings sum on screen to the headline** (assert the strings, the way `tour_money_board_screen_test.dart:156-160` does). "Visibly adds up" is a testable claim.

**`test/controllers/finance_controller_rollup_test.dart`** — the controller maps the rollup payload into `TourFinance` with `revenue`/`income`/`expenses` in the right slots. A transposition is invisible until `net` is wrong by exactly `income − expenses`.

### SQL coverage — three tiers, in cost order

**Tier 0 — the parity phase. Do this FIRST; it costs almost nothing and it is the single highest-leverage recommendation in this whole spec.**

**Do not delete `.compute()` when the deserialisers land.** Keep all three for one full release, marked `@visibleForTesting`, as the **reference implementation**. Add `test/integration/money_parity_test.dart`: for each row-level fixture (the 5-bus fixture, the raj-bus 10-row fixture, the detached-cash fixtures), feed the rows to the old `.compute()` and the **captured RPC payload for the same rows** to the new deserialiser, and assert field-by-field equality. This converts the entire existing suite into a **differential oracle for the SQL** for the price of one loader. Delete `.compute()` only after parity is green against real staging output.

**Tier 1 — captured golden payloads. The minimum you must ship.** `scripts/capture_money_fixtures.dart` seeds the known five-bus fixture into **staging**, calls `tour_money` / `handler_money` / `tours_money_rollup`, writes `test/fixtures/*.json`. Run manually, commit the output. Every payload test then runs in plain `flutter test` with no database.

**Tier 2 — pgTAP (`supabase/tests/money.sql`, `supabase test db`). Worth it for exactly four things Tier 1 cannot reach:**
1. **the raj-bus invariant** (cash summed by `bus_id`, never matched to current seat) — the regression that produced ₹23,000-vs-₹30,000, otherwise untestable in Dart after the move;
2. **the `handler_money` gate** — that a hostile `p_request_id` returns only that handler's buses. This is a **security** property; no Dart test can see it;
3. the duplicate-collection merge on real duplicate data;
4. **NULL handling** — `sum()` over zero rows returns NULL; assert `coalesce` on every aggregate.

**Three obstacles to a local harness, stated honestly [R]:** the repo's migrations do **not** reconstruct production (some RPCs exist only live); duplicate migration ordinals mean lexicographic replay may not match the applied order; and Docker/local Supabase is not currently in anyone's loop. A harness nobody runs is worse than none.

**What remains unverified even with all three tiers:** RLS on `handler_money` against a hostile request id (unless Tier 2 lands); `seat_billing` staleness relative to `assigned_seats`; the `seat_billing` **write** path under concurrent seat edits by two admins. **If Tier 2 is deferred, put the handler-gate check into `RELEASE.md` as a manual pre-release step.**

---

## Build order

Each phase is independently shippable and independently revertible. **The app is never in a half-migrated state**: aggregates keep coming from the client until Phase 4, and Phase 4 is a single atomic cutover behind a parity test that is already green.

### Phase 0 — Verify the live schema (no code)

Run against production and record the answers in `docs/live-schema-2026-08.md`:

```sql
select data_type from information_schema.columns
 where table_name='tour_seat_snapshots' and column_name='id';                       -- must be text
select 1 from information_schema.columns
 where table_name='bus_handovers' and column_name='source';                          -- must exist
select has_function_privilege('anon','public.handler_owns_bus(uuid,uuid)','execute');
select proname from pg_proc
 where proname in ('bus_berth_price_paise','chart_claim_seats','booking_amount_paise',
                   'bus_roster_for_request','handler_complete_outbound_leg');
select count(*) from public.payment_attempts;
select count(*) from public.tours where booking_mode = 'chart';
select count(*) from (select passenger_id,bus_id from public.collections
                       group by 1,2 having count(*)>1) q;                            -- dup groups
select count(*) from public.collections where seat_id = '';                          -- legacy blanks
select count(*) from public.expenses where category = 'busOwner';
```

**Exit:** every `[UNVERIFIED-LIVE]` item in this spec has a recorded yes/no, and the duplicate/blank/busOwner counts are known so the cleanup can be sized.
**Dependencies:** none. **Blocks:** everything.

### Phase 1 — `seat_billing` table + Dart writer + reprice pass (no consumer)

Migration `052a` (verify-block + `seat_billing` + RLS + `reprice_tour` RPC). New `lib/services/seat_billing_writer.dart`. `_scheduleReprice` wired to every mutation path listed in *Client changes*. Nothing reads `seat_billing` yet.

**Exit:** for three real tours (one running, one locked, one completed), `Σ seat_billing.amount where status='active'` per `(bus, passenger)` equals `bus.amountDueFor(passenger)` computed in-app, to the rupee. `test/models/seat_billing_test.dart` green.
**Dependencies:** Phase 0. **Risk if it fails:** none — nothing consumes the table.

### Phase 2 — status lifecycle + the CALC-1 freeze

Add the `travelled`/`void` transitions to `reprice_tour`; add the status flip inside `TourController.completeOutboundLeg`'s **guarded `persist` block** (`tour_controller.dart:768-776` **[V]**) — *not* in the best-effort snapshot try/catch, which swallows all failures **[R]**; add the same flip inside `handler_complete_outbound_leg` (migration `052b`), scoped `bus_id = p_bus_id`, in the same transaction as the seat clear. Add the `chart_claim_seats` pending-row insert.

**Exit:** on a staging tour, run `completeOutboundLeg`; `Σ seat_billing.amount where status in ('active','travelled')` is **unchanged**, while `Σ where status='active'` falls. The CALC-1 test in `five_bus_expense_audit_test.dart` is green.
**Dependencies:** Phase 1.

### Phase 3 — Aggregation SQL, shipped DARK

Migration `052c`: `money_agg`, `tour_money`, `handler_money`, `tours_money_rollup`, plus the two security fixes (`handler_delete_expense`/`handler_delete_income` ownership; `handler_owns_bus` grants). Client calls the RPCs but **renders nothing from them** — it logs a field-by-field diff against the existing `.compute()` result.

Ship `scripts/capture_money_fixtures.dart` and the Tier-0 parity test.

**Exit:** the parity test is green on the captured staging fixtures **and** the in-app diff logs zero mismatches across at least five real tours over one week, including one tour mid-trip with an active handler.
**Dependencies:** Phase 2 (billed revenue must be persisted before an aggregate reads it).
**This is the phase that must not be rushed.** It is the only place the SQL is validated against a known-good oracle.

### Phase 4 — Client cutover

`fromRpc` factories on all five models. `MoneyController` and `FinanceController` reworked. `_pendingDeltaFor` optimistic overlay. `summaryLoadFailed` gate. Handler screen reads `handler_money`. `.compute()` kept `@visibleForTesting`.

**Exit:** every money screen renders from the RPC; the parity test still green; the seven rewritten widget tests green; a manual pass on one real tour confirms the numbers are identical to the pre-cutover build (screenshot diff).
**Dependencies:** Phase 3 exit. **Rollback:** a single feature flag flipping `summaryForBus` back to `.compute()`.

### Phase 5 — Duplicate defence + provenance + write-path hardening

Seat-agnostic collection lookup (client) and seat-agnostic `handler_upsert_collection` (migration `052d`, **no index change**). `source` columns + server-set provenance. `expenses_no_bus_owner_chk not valid`. `removeBus` confirm dialog naming the amount about to be destroyed.

**Exit:** move a rider's seat on staging, collect cash on the new seat, confirm **one** collection row exists. `select count(*)` of duplicate groups does not grow over one week in production.
**Dependencies:** Phase 4 (so the aggregates already ignore `amount_due`). **Blocks:** Phase 6, absolutely.

### Phase 6 — Live data cleanup

Follow the cleanup run order verbatim. Detection-only first, operator sign-off, then the three automated classes, then the review queues.

**Exit:** `collections_cash_delta = 0` and `expenses_delta = 0`; the per-tour before/after ledger diff signed off by the operator; and the one remembered tour reconciles to the operator's own figures.
**Dependencies:** Phase 5 (R0) and Phase 1–2 (the `seat_billing` backfill gates Class 4).

### Phase 7 — UI: handler three tabs + both ledgers

Handler file split in the four-commit sequence (checkpoint after commit 3: byte-identical render). Then the tabs, the pinned strip, `HandlerMoneyLedger`. Admin `money_ledger.dart` with the rent line, on `bus_money_screen` and `tour_money_board_screen`. New translation keys in **all three** of `assets/translations/en.json`, `gu.json`, `hi.json`.

**Exit:** `test/screens/handler_money_tab_test.dart` green, asserting the ledger's rendered rows sum to the headline; a visual pass on the handler screen at three widths.
**Dependencies:** Phase 4 (the ledger reads payload fields). Can run in parallel with Phase 6.

### Phase 8 — Optional hardening (each item independently shippable)

- `collections.superseded_at` + the partial unique index; drop the triple index; add the `superseded_at is null` filter to every reader including the legacy manifest RPCs.
- **Write the parity test `049` claims exists** — a golden table of `(price_bands, rear_rows, rear_price, per-type overrides, price_per_seat, seat_type, row) → expected paise`, asserted against `Bus.berthPriceFor` in Dart and against `bus_berth_price_paise` via a live-DB integration test. **This is a hard prerequisite for the next item.**
- Upgrade `chart_claim_seats` from a pending row to a real SQL-priced provisional row, `on conflict do nothing`, with Dart authoritative on overwrite and `priced_by` making divergence visible.
- Delete `.compute()` and `lifetimeRealisedNet`.
- Tier-2 pgTAP suite.

**Exit per item:** stated above. **Dependencies:** Phases 4 and 6.

**phase_count: 9** (Phases 0–8).

---

## Risks and open questions

### Highest-severity risks

1. **CATASTROPHIC — `supabase db push`.** The remote history table is empty **[R]**; a push replays `001..051` against live data, starting with drops. Add a pre-commit or CI guard that fails on any `db push` in a script.
2. **CATASTROPHIC — running `045_handler_handover.sql` or `039_handler_lock_gate.sql`.** Both are superseded; both do real damage if run (045 silently downgrades three handover RPCs to bus-on-tour; 039 locks out every manually-added handler). The duplicate `045` ordinal makes running the wrong file a realistic mistake.
3. **HIGH — building `handler_money` on `b.tour_id = ctx.tour_id` instead of `handler_owns_bus`.** On a multi-bus tour every handler would see and settle against the whole tour's cash. Trivially reproduced by copying the `my_buses` CTE from the wrong migration.
4. **HIGH — `sum()` over zero rows returns NULL.** Propagates silently through every getter. `coalesce` on every aggregate, asserted in the payload test.
5. **HIGH — the raj-bus regression becomes untestable in Dart.** Cash summed by `bus_id`, never matched to current seat (`lib/models/handler_bus_money.dart:21-25` **[V]**) is the exact bug that produced ₹23,000-vs-₹30,000. After the move nothing in CI guards it unless Tier 2 lands.
6. **HIGH — deleting `.compute()` in the same commit as the deserialisers.** Destroys the only oracle for the SQL. Tier-0 parity phase is the mitigation and it is not optional.
7. **HIGH — `seat_billing` frozen for genuinely cancelled riders.** Fixing CALC-1 risks the opposite error: revenue over-reported permanently, silently and cumulatively — worse than the current collapse, which is at least visible. The void-vs-freeze decision must be driven by the calling path.
8. **HIGH — merging duplicates before the code fix ships.** Undone by the next handler tap. Phase 5 gates Phase 6.
9. **MEDIUM-HIGH — double-counting `buses.bus_price`** by joining `buses` to `collections` and summing. Shipping a fourth wrong figure server-side is worse than the status quo.
10. **MEDIUM-HIGH — optimistic writes stop moving the number.** Without `_pendingDeltaFor`, the money board appears frozen right after the agent saves — a visible regression the operator will report as a crash.
11. **MEDIUM — a helper protected only by `revoke all … from public`** lands on the PostgREST surface. For `money_agg` that is a direct financial-data leak to `anon`.
12. **MEDIUM — retry guards silently become always-false.** `loadFailed && lists.isEmpty` renders an all-zero settled-looking cockpit on a failed aggregate load.
13. **MEDIUM — dashboard `Obx` feedback loop** re-introduced by a reactive rollup read inside the same `Obx` that fires the load.
14. **MEDIUM — epsilon flips at the boundary.** Postgres `numeric` vs Dart `double` rounding can flip a bus between settled and action-needed. Also: merging N rows each within the 0.005 band pushes the merged row outside it.
15. **MEDIUM — the handler tab restructure lands on a surface verified by eye** (`handler_bus_chart_screen_test.dart:22` **[R]**), shipped alongside a money-engine rewrite. Mitigated by the four-commit sequence and the new widget test.
16. **MEDIUM — `_AttendanceView`'s `Obx`** carries a documented GetX crash when zero observables are registered; it only manifests on a roster where nobody has a pickup location.

### Open questions that are NOT blocking (defaults chosen, stated here for the record)

- **`FinanceController.lifetimeRealisedNet`** has no consumer in `lib/` **[R]**. Default: confirm nothing in `test/` reads it, then delete in Phase 4.
- **`TourMoneySummary.totalToCollect`** has no direct render **[R]** but the controller works hard to keep it consistent. Default: keep it in the payload.
- **`seaterPrice`** has no UI writer anywhere in `lib/screens/` **[R]** — settable only by direct DB edit. Default: leave as-is; note it in the model doc.
- **`SeatCell.forward`'s doc comment** claims it "drives PRICING only"; it does not **[R]**. Default: fix the comment, do not add a premium term.
- **`incomes.amount` is bare `numeric`** while every other money column is `numeric(10,2)` **[R]**, and `incomes` has an `updated_at` column with **no trigger** (only `042:711` sets it by hand). Default: leave the type; add the missing trigger in 052.
- **`bus_roster_for_request` (migration 041)** is called unguarded at `customer_requests_store.dart:543` with no `RpcUnavailableException` wrapper **[R]** and nothing corroborates its deployment. Default: wrap it in the same translation `handler_money` uses. Out of scope for money, but a one-line fix worth taking.

### Blocking questions

See `blocking_decisions`.
