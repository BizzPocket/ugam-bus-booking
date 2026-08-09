# Money & Ledger Audit — 2026-08-09

> **This document is the WHY.** For the deploy sequence, the acceptance gate and
> what comes next, read
> [`docs/superpowers/specs/2026-08-09-ledger-authoritative-design.md`](superpowers/specs/2026-08-09-ledger-authoritative-design.md).
> Per-finding status is in the table below and on each finding's heading.

Triggered by: the Profit & Loss screen reporting `₹0` net / `₹0` income / `₹0`
expense for a running tour with 2 buses.

Method: static trace of every money path from the Postgres ledger up through the
sources, controllers and screens. Nothing was executed against the live
database — network access is sandboxed here — so each finding below is paired
with a query in [`supabase/diagnostics/finance_audit_checks.sql`](../supabase/diagnostics/finance_audit_checks.sql)
that confirms or refutes it on the real data. **Findings marked *Needs DB
confirmation* are code-certain but data-dependent.**

Test baseline at time of audit: `flutter test` → **1120 passing, 3 failing**.
All three failures were in another agent's in-flight work, not the money logic.

---

## Status

| # | Finding | Status |
|---|---|---|
| C1 | Online UPI advance credited twice | **fixed** — migration `069`, *not yet applied* |
| C2/D1–D4 | Three fare formulas | **fixed** — migration `070`, *not yet applied* |
| A1 | Silent ₹0 when the ledger is empty | **fixed** — `FinanceController.ledgerEmpty` + banner |
| A2 | "Revenue" is cash, unlabelled | **fixed** — relabelled + basis note |
| A3 | Rent missing for pre-062 buses | **needs the migrations applied** (058 → 062 → 063) |
| B1 | Four bottom lines | **fixed** — all four now name their basis (`money.basis_cash` / `money.basis_billed`); the figures still differ, by design |
| E1 | Orphan money dropped | **fixed** — `MoneyController.tourSummary` |
| E2 | Empty ledger zeroes real money | **fixed** — `MoneyController.summaryForBus` |
| F1 | Per-bus AR by first seat | **fixed** — `MoneyController._arShareByBus` |
| F2 | Stale "can never disagree" contract | **fixed** — scope documented at the source |
| G1 | Dead advance-netting helpers | **fixed** — deleted |
| H1 | Backfill can't reverse cancelled fares | **fixed** — migration `069`, *not yet applied* |

After the fixes: `flutter test` → **1160 passing, 2 failing**; both remaining
failures are the other agent's in-flight files (`ChartSeatSkeleton` undefined,
and a handler-chart test that was already red before this work started).

> **The two migrations have NOT been run.** Network access is sandboxed in the
> environment this work was done in, and no local Postgres was available, so
> `069` and `070` are **unexecuted SQL**. Read them before applying, apply them
> one at a time as this project always does, and use the diagnostic pack to
> verify each one. The Dart fixes are all covered by tests that were watched to
> fail first.

---

## The shape of the problem

There are **two complete money engines** in this app, and the screens are split
across both.

| | Engine 1 — legacy recompute | Engine 2 — double-entry ledger |
|---|---|---|
| Source | `collections` / `expenses` / `incomes` / `bus_handovers` + `buses.bus_price` | `finance_entries` + `finance_lines` → `finance_bus_summary` |
| Fare formula | Dart `Bus.amountDueForSeat` | PG `baseline_seat_due_paise` |
| Read by | `BusMoneySummary.compute`, `HandlerBusMoney.compute`, dashboard snapshots | `MoneyController` (when the ledger loads), `FinanceController` (always) |

The ledger was designed to *replace* engine 1 (056's header says so explicitly),
but the cutover is half-done. Every finding below is a seam between the two.

---

## Findings

Ranked by cash impact.

### C1 · Confirmed online UPI advances are credited to the ledger twice — SEVERE
**CLOSED** by `069_online_payment_single_post.sql` — not yet applied.

*Needs DB confirmation — [check 5](../supabase/diagnostics/finance_audit_checks.sql)*

`confirm_payment_claim` does two things in one transaction:

1. posts an `online_payment` entry: DR `bank.gateway` / CR `ar.rider`
   — [`060_upi_advance_claims.sql:276-284`](../supabase/migrations/060_upi_advance_claims.sql#L276)
2. inserts/updates a legacy `collections` row with `amount_received += v_apply`
   — [`060_upi_advance_claims.sql:305-330`](../supabase/migrations/060_upi_advance_claims.sql#L305)

Step 2 fires `collections_ledger_sync`
([`062_ledger_write_through.sql:216-234`](../supabase/migrations/062_ledger_write_through.sql#L216)),
which posts a **second** credit to the same `ar.rider` account.

Per confirmed advance of ₹X:

- the rider's `finance_rider_balance.owes_minor` is **₹X too low**, so
  `_arForBus` ([`money_controller.dart:951`](../lib/controllers/money_controller.dart#L951))
  under-reports to-collect → **the handler is told to collect ₹X less than the
  rider actually owes.** Straight cash loss.
- `cash.handler` is inflated by ₹X, so `outstanding_handover_minor` is too high
  → **the handler is asked to hand over ₹X they never physically held.**

060 predates 062. 062's own header lists "the UPI claim confirmation in 060" as
a write route it intends to cover with triggers — it just never removed 060's
own hand-rolled posting.

**Fix direction:** delete the `backfill_post(... 'online_payment' ...)` call from
`confirm_payment_claim` and let the collections trigger be the only poster — but
then the money is classified as `cash.handler` when it actually landed in a bank
account. The correct fix is the reverse: keep the `online_payment` entry, and
have the trigger skip rows whose `collected_by = 'online'`.

---

### C2 · Three independent implementations of the same fare
**CLOSED** by `070_one_fare_formula.sql` — not yet applied.

*Needs DB confirmation — [checks 7, 9, 10](../supabase/diagnostics/finance_audit_checks.sql)*

| # | Implementation | Governs |
|---|---|---|
| 1 | Dart [`Bus.amountDueForSeat`](../lib/models/bus_details.dart#L580) | what every screen shows |
| 2 | PG [`baseline_seat_due_paise`](../supabase/migrations/053_finance_baseline.sql#L143) | what the **ledger** bills |
| 3 | PG [`booking_amount_paise`](../supabase/migrations/049_online_advance_payment.sql#L141) | what the **customer pays online** |

Known divergences:

- **Leg fallback.** Dart falls back to `legForSeatType(…)` → `derivedTripType`,
  computed from `request_lines`
  ([`passenger.dart:222-244`](../lib/models/passenger.dart#L222)). Both SQL
  functions fall back to the stored `passengers.trip_type` column. A rider whose
  stored `trip_type` is `roundTrip` but whose request lines are all one-way is
  charged **half** by the app and **full** by the ledger. A 2× gap on that
  rider, showing up forever as a phantom "still owes".
- **Rounding.** 049 rounds each *berth*; 053 rounds the per-*seat* total. On
  one-leg berths they differ by up to ₹1 per berth. 053's own comment
  ([lines 131-139](../supabase/migrations/053_finance_baseline.sql#L131)) records
  this as an unresolved finding for a later phase. It was never collapsed.
- **`#` suffix.** Dart and 053 both strip the `#leg` suffix from a seat id.
  049 does **not** — it matches `cell->>'seatId' = berth.seat_id` on the raw
  value ([`049:164-176`](../supabase/migrations/049_online_advance_payment.sql#L164)).
  Any berth stored with a suffix is dropped from the join entirely, so the
  customer is charged **₹0** for it.
- **Berth cap.** Dart caps berth-legs at `berthsPerUnit * 2`
  ([`bus_details.dart:611`](../lib/models/bus_details.dart#L611)); neither SQL
  function does.

**Fix direction:** one formula, in one place. Since the ledger is the thing that
must be authoritative, `baseline_seat_due_paise` should become the single
implementation, `booking_amount_paise` should call it, and Dart should read the
posted `revenue.fare` rather than re-deriving.

---

### A1 · The Finance report reads a ledger nothing may have written to
**CLOSED** — `FinanceController.ledgerEmpty` separates "ledger never deployed"
from a genuine zero, and `finance_screen` renders an explanatory banner.

*Needs DB confirmation — [checks 1, 2, 3, 4](../supabase/diagnostics/finance_audit_checks.sql)*

**This is the most likely direct cause of your `₹0` screenshot.**

`FinanceController` is fed exclusively by `finance_bus_summary`
([`finance_controller.dart:82`](../lib/controllers/finance_controller.dart#L82)),
a view over `finance_lines`
([`063_finance_bus_summary_display.sql:24-59`](../supabase/migrations/063_finance_bus_summary_display.sql#L24)).
Those lines exist only if:

- migration **062** (write-through triggers) is applied, **and**
- migration **058** (backfill) was run for anything written before 062.

If either is missing on the live database, every column reads 0 and the report
renders a perfectly healthy-looking "1 પ્રવાસમાંથી" badge over ₹0 — because there
is no *ledger unavailable* state. `loadFailed` is set only when the query
**throws**; an empty result set is indistinguishable from a genuinely zero tour
([`finance_controller.dart:82-110`](../lib/controllers/finance_controller.dart#L82)).

Per memory, migrations on this project are applied by hand one file at a time,
and 039/040/041 were already known to be pending. 062/063 are the newest finance
migrations in the tree.

---

### A2 · "Revenue" on the Finance report is cash, not what was billed
**CLOSED** — the report carries a `money.basis_cash` caption. See B1.

`revenue[tid] = … + r.collected`
([`finance_controller.dart:87`](../lib/controllers/finance_controller.dart#L87)).

So a tour that has sold ₹2,00,000 of seats but collected nothing yet reports
revenue ₹0 — exactly your running-tour case. The per-trip P&L one tap away
headlines `totalNetBilled`
([`trip_pnl_screen.dart:226`](../lib/screens/trip_pnl_screen.dart#L226)), which
*is* accrual. Same tour, two different profits, no label saying which is which.

---

### A3 · Bus rent never reaches the ledger for pre-062 buses
**CLOSED** by running `select * from public.backfill_finance_ledger();` (058
§3f). Operational — not yet run. Idempotent: it keys on `backfill:rent:<bus id>`.

*Needs DB confirmation — [check 6](../supabase/diagnostics/finance_audit_checks.sql)*

Rent is a real cost that exists as **no expense row anywhere** — it lives on
`buses.bus_price`. It enters the ledger only via `buses_ledger_sync`
([`062 §7`](../supabase/migrations/062_ledger_write_through.sql#L438)) firing on
INSERT/UPDATE, or via 058's rent backfill. A bus created before 062 whose price
has not been touched since has no `expense.rent` line at all.

Result: the Finance report shows ₹0 expenses while the money board — which folds
`busRent` in at [`money_summary.dart:164-165`](../lib/models/money_summary.dart#L164)
— shows the full rent. Your screenshot's 2 buses with ₹0 expenses fits this
exactly.

---

### B1 · Four different "bottom line" figures across four screens
**CLOSED** — the figures still differ (they answer different questions and were
deliberately not collapsed); every headline now names its basis via the shared
`money.basis_cash` / `money.basis_billed` keys, and the tour money board's
sticky pill reads "NET (CASH)" because it sits on the same screen as a BILLED
headline.

| Screen | Headline | Formula |
|---|---|---|
| Finance (cross-tour) | `FinanceTotals.net` | collected + income − expenses (**cash**) |
| Trip P&L | `totalNetBilled` ([`trip_pnl_screen.dart:226`](../lib/screens/trip_pnl_screen.dart#L226)) | **billed** + income − expenses |
| Tour money board | `totalNet` ([`tour_money_board_screen.dart:963`](../lib/screens/tour_money_board_screen.dart#L963)) | cash |
| Bus money | `totalNet` ([`bus_money_screen.dart:1347`](../lib/screens/bus_money_screen.dart#L1347)) | cash |

Plus `expectedHandover`, which is deliberately rent-free
([`money_summary.dart:76`](../lib/models/money_summary.dart#L76)) and so differs
from cash-net by exactly the rent.

Each is individually defensible. Together, with nothing on screen naming the
basis, any two compared side by side look broken — which is what "the
calculation is not correct in each tour" feels like from the outside.

---

### E1 · Orphan money vanishes from the trip total once the ledger is live
**CLOSED** — `tourSummary()` walks the union of the tour's buses and the
ledger's, so stranded cash stays in the total and populates the orphan fields.

*Needs DB confirmation — [check 8](../supabase/diagnostics/finance_audit_checks.sql)*

The legacy path keeps money sitting on buses no longer on the tour **inside**
the totals and breaks it out as `orphanExpenses` / `orphanCollected` /
`orphanIncome` precisely so the UI can explain the gap
([`money_summary.dart:288-382`](../lib/models/money_summary.dart#L288)).

The ledger path iterates only `busById.keys`
([`money_controller.dart:974`](../lib/controllers/money_controller.dart#L974))
and builds `TourMoneySummary` through the default constructor with the orphan
fields left at 0
([`money_controller.dart:989-1002`](../lib/controllers/money_controller.dart#L989)).

So that money is **dropped from the trip total outright**, and `hasOrphanMoney`
can never be true — the warning built for this exact situation cannot fire.

---

### E2 · An empty ledger hard-zeroes every money screen
**CLOSED** — `summaryForBus` falls through to the legacy recompute when the
ledger holds no lines for a bus, instead of returning hard zeros.

`_loadLedgerForTour` returns `true` on an empty result and sets
`_ledgerReady = true`
([`money_controller.dart:256-285`](../lib/controllers/money_controller.dart#L256)).
After that, `summaryForBus` returns hard zeros for any bus with no ledger rows
and **explicitly refuses** to fall back to the legacy recompute
([`money_controller.dart:923-934`](../lib/controllers/money_controller.dart#L923)
— "Ledger loaded but no lines for this bus yet — zeros, not legacy recompute").

So the moment the ledger is reachable but unpopulated, every money screen reads
₹0 collected — with the legacy tables sitting right there in memory, already
loaded, holding the real numbers. Same root as A1, but this one is a design
choice in the client rather than a missing migration.

Measured (report §4, legacy tables holding ₹2,600 collected + ₹4,000 ground
expense, bus rent ₹30,000):

| figure | computed | should be |
|---|---|---|
| `summaryForBus.collected` | ₹0 | ₹2,600 |
| `summaryForBus.expensesTotal` | ₹30,000 | ₹34,000 |
| `tourSummary.totalCollected` | ₹0 | ₹2,600 |
| `tourSummary.totalNet` | −₹30,000 | −₹31,400 |
| `loadFailed` | `false` | — no error surfaces |

Note the partial survival: the fallback at
[`money_controller.dart:927-933`](../lib/controllers/money_controller.dart#L927)
still reads rent and billed revenue from the in-memory tour, so **rent survives
while collected cash and logged ground expenses are zeroed**. That is worse than
an all-zero board — the tour reads as a pure ₹30,000 loss rather than as
obviously broken.

---

### F1 · Per-bus to-collect is attributed to one bus by guesswork
**CLOSED** — `_arShareByBus` apportions a rider's AR across the buses that
billed them; the shares sum to 1, so the trip total is unchanged.

`_arForBus` assigns a rider's **entire** ledger AR to `assignedSeats.first.busId`
([`money_controller.dart:966-969`](../lib/controllers/money_controller.dart#L966)).

A rider on bus 1 outbound and bus 2 return has all their to-collect dumped on
bus 1. Bus 2's handler reads "₹0 to collect" for a rider they are carrying.

---

### F2 · Handler and admin to-collect now use different engines
**CLOSED** — the contract comment now states the true scope of the agreement
and names 070 (plus check 7) as what guarantees it.

`HandlerBusMoney.compute` prices seated-but-uncollected riders with the Dart
`dueForSeat` ([`handler_bus_money.dart:109-118`](../lib/models/handler_bus_money.dart#L109)).
The admin's ledger path uses `finance_rider_balance` via `_arForBus`.

The contract comment at
[`money_summary.dart:94-100`](../lib/models/money_summary.dart#L94) still asserts
the two "can never disagree". That held for the legacy path only; the ledger
cutover broke it and the comment was not updated.

---

### G1 · Confirmed advances are not netted off anywhere in Dart
**CLOSED** — the two dead helpers were removed; the `collections` row written by
`confirm_payment_claim` is the single place an advance nets off a balance.

`dueAfterAdvances` and `confirmedAdvanceForPassenger`
([`money_controller.dart:355-371`](../lib/controllers/money_controller.dart#L355))
have **zero call sites** in `lib/`. The only thing that nets an advance off a
rider's balance is the `collections` row that `confirm_payment_claim` writes —
so if 060 is not deployed, or its `v_remaining` runs out partway across a
rider's seats, the chart keeps showing them owing the full fare.

---

### H1 · The backfill cannot reverse a cancelled rider's fare
**CLOSED** by `069` §5 `finance_repair_cancelled_fares()` — not yet applied.

058's fare loop filters cancelled/deleted riders out of its `SELECT`, then has an
**empty** `if v_entry is not null then … end if;` block where sections 3b–3e all
call `backfill_reverse`
([`058_finance_backfill.sql:243-250`](../supabase/migrations/058_finance_backfill.sql#L243)).

A rider cancelled *after* an earlier backfill keeps their `fare_charge` forever
on a re-run. The 062 trigger path handles this correctly via
`finance_resync_passenger_fare`, so this only bites when the backfill is re-run —
which is exactly what you would do to repair A1/A3.

---

## Executable companion

[`test/diagnostics/money_miscalculation_report_test.dart`](../test/diagnostics/money_miscalculation_report_test.dart)
reproduces findings C1, D1, B1, E1, E2 and F1 by driving the **real** fare engine
and the **real** `MoneyController` with the seeded bus data, printing computed vs
correct side by side. It passes today (the defects are asserted as open), so it
doubles as the trip-wire: each `expect` flips to red the moment its bug is fixed.

```
flutter test test/diagnostics/money_miscalculation_report_test.dart -r expanded
```

Confirmed by that run: the seeded buses price to **₹48,000** (Tour A) and
**₹30,400** (Tour B) at full round-trip occupancy, and `amountDueFor` equals the
sum of its per-seat records on both — so the fare engine itself is sound. Every
defect below is a seam *around* it.

## What to run, in order

1. `supabase/diagnostics/finance_audit_checks.sql` — checks 1→10, one block at a
   time. This turns every *Needs DB confirmation* above into a yes or a no, and
   check 4 gives you the exact rupee gap per tour.
2. If checks 1/2 come back with anything missing, apply **058 → 062 → 063** in
   that order (058 first, or the trigger-owned rows guard in 062 §0 has nothing
   to protect against). This is what closes A1 and A3.
3. Apply **069** (`069_online_payment_single_post.sql`), then run its two repair
   functions in report mode, read the output, then in apply mode:
   ```sql
   select * from public.finance_repair_online_double_post();      -- report
   select * from public.finance_repair_cancelled_fares();         -- report
   select * from public.finance_repair_online_double_post(true);  -- apply
   select * from public.finance_repair_cancelled_fares(true);     -- apply
   ```
4. Apply **070** (`070_one_fare_formula.sql`), then re-price the ledger against
   the unified formula:
   ```sql
   select * from public.finance_resync_all_fares();
   ```
5. Re-run the diagnostics. Check 4's deltas must all be 0, and checks 5 and 7
   must return zero rows.

## Test tours

`supabase/seeds/test_tours.sql` creates two disposable tours, each with one bus
carrying a real generated layout, a price structure, an owner rent, one ground
expense and one extra income:

- **`[TEST-A] Chart Booking`** — `booking_mode = 'chart'`, sleeper 36, a front
  price **band** (rows 0-1 @ ₹1,600/berth), per-type overrides behind it, ₹30,000
  rent, ₹500/berth online advance with a VPA set. Exercises the customer
  self-select chart, the band pricing path, and the UPI advance path where C1
  lives.
- **`[TEST-B] Legacy Request`** — `booking_mode = 'request'`, seater 40, the
  **legacy rear zone** (last 2 rows @ ₹600) rather than a band, ₹22,000 rent.
  Exercises the request → assign flow and the rear-zone→synthesized-band path.

Expected books immediately after seeding, before anyone books:

| | Tour A | Tour B |
|---|---|---|
| rent | ₹30,000 | ₹22,000 |
| ground expenses | ₹4,000 | ₹3,200 |
| **total expenses** | **₹34,000** | **₹25,200** |
| extra income | ₹1,500 | ₹900 |
| billed | ₹0 | ₹0 |
| **net** | **−₹32,500** | **−₹24,300** |

Fully sold, Tour A bills ₹48,000 and Tour B bills ₹30,400.

If the Finance report shows ₹0 expenses for these two brand-new tours, A1/A3 are
confirmed on the spot — these buses were created *after* 062, so their rent
should post immediately.

Teardown is at the bottom of the seed file.
