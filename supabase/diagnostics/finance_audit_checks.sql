-- ============================================================
-- finance_audit_checks.sql   —   READ-ONLY money/ledger diagnostics
-- ------------------------------------------------------------
-- Every statement here is a SELECT. Nothing is created, altered or deleted.
-- Run the blocks ONE AT A TIME in the Supabase SQL editor and keep the output;
-- each block confirms or refutes one finding in
-- docs/2026-08-09-money-ledger-audit.md.
--
-- Read the "EXPECT" line under each heading before you read the result.
-- ============================================================


-- ── CHECK 1 · Is the ledger actually deployed? ───────────────
-- Findings A1 / A3 / J hinge entirely on this.
-- EXPECT: all rows present = true. Any false explains a ₹0 report on its own.
select 'view finance_bus_summary'   as object,
       to_regclass('public.finance_bus_summary')   is not null as present
union all
select 'view finance_rider_balance',
       to_regclass('public.finance_rider_balance') is not null
union all
select 'table finance_entries',
       to_regclass('public.finance_entries')       is not null
union all
select 'table finance_lines',
       to_regclass('public.finance_lines')         is not null
union all
select 'fn baseline_seat_due_paise',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'baseline_seat_due_paise')
union all
select 'fn booking_amount_paise',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'booking_amount_paise')
union all
select 'fn finance_resync_passenger_fare',
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'finance_resync_passenger_fare');


-- ── CHECK 2 · Are the write-through triggers (062) live? ─────
-- Without these the ledger froze at backfill time and every tour created since
-- reads ₹0 on the Finance report. Finding A1.
-- EXPECT: 6 rows. A missing row = that table's money never reaches the ledger.
select c.relname as on_table, t.tgname as trigger_name, t.tgenabled as enabled
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and not t.tgisinternal
   and t.tgname in ('collections_ledger_sync','expenses_ledger_sync',
                    'incomes_ledger_sync','bus_handovers_ledger_sync',
                    'passengers_ledger_sync','buses_ledger_sync')
 order by 1;


-- ── CHECK 3 · What is actually IN the ledger? ────────────────
-- EXPECT: non-zero counts for fare_charge, owner_rent and (if you have taken
-- cash) cash_receipt. All-zero, or a `last_posted` far in the past, means the
-- ledger is stale and the Finance report will read ₹0 no matter what the money
-- board shows. Finding A1 / J.
select e.kind,
       count(*)                                as entries,
       sum(abs(l.amount_minor)) / 2 / 100.0    as rupees,
       max(e.occurred_at)                      as last_posted
  from public.finance_entries e
  join public.finance_lines   l on l.entry_id = e.id
 group by e.kind
 order by 1;


-- ── CHECK 4 · Ledger vs legacy tables, per tour ──────────────
-- The core reconciliation. Finding A1 / A3 / E.
-- EXPECT: every *_delta column = 0. A non-zero delta is money the Finance
-- report and the per-tour money board disagree about, in rupees.
--   collected_delta > 0  → ledger thinks MORE cash came in than collections say
--   rent_delta      < 0  → bus rent never reached the ledger (finding A3)
with legacy as (
  select t.id as tour_id, t.title,
         coalesce((select sum(c.amount_received - c.amount_refunded)
                     from public.collections c
                    where c.tour_id = t.id and c.deleted_at is null), 0) as collected,
         coalesce((select sum(x.amount) from public.expenses x
                    where x.tour_id = t.id and x.deleted_at is null), 0)  as ground_exp,
         coalesce((select sum(i.amount) from public.incomes i
                    where i.tour_id = t.id and i.deleted_at is null), 0)  as income,
         coalesce((select sum(b.bus_price) from public.buses b
                    where b.tour_id = t.id and b.deleted_at is null), 0)  as rent,
         coalesce((select sum(h.handed_over_amount) from public.bus_handovers h
                    where h.tour_id = t.id and h.deleted_at is null), 0)  as handed
    from public.tours t
   where t.deleted_at is null
),
ledger as (
  select tour_id,
         sum(collected_minor)        / 100.0 as collected,
         sum(ground_expenses_minor)  / 100.0 as ground_exp,
         sum(income_minor)           / 100.0 as income,
         sum(rent_minor)             / 100.0 as rent,
         sum(handed_over_minor)      / 100.0 as handed,
         sum(billed_minor)           / 100.0 as billed
    from public.finance_bus_summary
   group by tour_id
)
select g.title,
       coalesce(d.collected, 0)  - g.collected  as collected_delta,
       coalesce(d.ground_exp, 0) - g.ground_exp as ground_exp_delta,
       coalesce(d.income, 0)     - g.income     as income_delta,
       coalesce(d.rent, 0)       - g.rent       as rent_delta,
       coalesce(d.handed, 0)     - g.handed     as handed_delta,
       coalesce(d.billed, 0)                    as ledger_billed,
       g.tour_id
  from legacy g
  left join ledger d on d.tour_id = g.tour_id
 order by g.title;


-- ── CHECK 5 · Online advance double-count ────────────────────
-- Finding C. `confirm_payment_claim` posts an online_payment entry AND writes a
-- collections row, whose own trigger posts a second credit to the same rider.
-- EXPECT: zero rows. Every row returned is a rider whose balance is wrong by
-- `double_counted_rupees`, and a handler being asked to hand over that much
-- cash they never held.
select pc.id                          as claim_id,
       pc.passenger_id,
       p.name                         as rider,
       pc.amount_paise / 100.0        as double_counted_rupees,
       t.title                        as tour
  from public.payment_claims pc
  join public.tours t      on t.id = pc.tour_id
  left join public.passengers p on p.id = pc.passenger_id
 where pc.status = 'confirmed'
   -- the ledger holds the 060-posted online_payment entry …
   and exists (select 1 from public.finance_entries e
                where e.source_table = 'payment_claims' and e.source_row_id = pc.id)
   -- … AND a trigger-posted cash_receipt from the collections row 060 wrote.
   and exists (select 1
                 from public.collections c
                 join public.finance_entries e2
                   on e2.source_table = 'collections' and e2.source_row_id = c.id
                where c.passenger_id = pc.passenger_id
                  and c.tour_id      = pc.tour_id
                  and c.collected_by = 'online'
                  and e2.client_request_id like 'row:%')
 order by pc.amount_paise desc;


-- ── CHECK 6 · Bus rent missing from the ledger ───────────────
-- Finding A3. A bus priced before 062 went live, never edited since, has no
-- expense.rent line — so the Finance report shows ₹0 expenses.
-- EXPECT: zero rows.
select b.id as bus_id, b.name, t.title as tour, b.bus_price as rent_not_in_ledger
  from public.buses b
  join public.tours t on t.id = b.tour_id
 where b.deleted_at is null
   and coalesce(b.bus_price, 0) > 0
   and not exists (
     select 1 from public.finance_lines l
      where l.bus_id = b.id and l.account_code = 'expense.rent')
 order by b.bus_price desc;


-- ── CHECK 7 · Fare formula divergence, per seat ──────────────
-- Finding D. Compares what the LEDGER charged a rider for a seat against what
-- `baseline_seat_due_paise` says that seat costs right now.
-- EXPECT: zero rows. Any row is a rider whose on-screen fare and ledger fare
-- disagree — the phantom "still owes ₹X" / "refund ₹X" that never clears.
with seated as (
  select distinct
         p.id                                as passenger_id,
         p.name,
         (s->>'busId')::uuid                 as bus_id,
         split_part(s->>'seatId', '#', 1)    as seat_id
    from public.passengers p
    cross join lateral jsonb_array_elements(coalesce(p.assigned_seats, '[]'::jsonb)) s
   where p.cancelled_at is null and p.deleted_at is null
     and coalesce(s->>'busId', '')  <> ''
     and coalesce(s->>'seatId', '') <> ''
),
target as (
  select passenger_id, name, bus_id,
         sum(public.baseline_seat_due_paise(passenger_id, bus_id, seat_id)) as should_be
    from seated group by 1, 2, 3
),
posted as (
  select en.source_row_id as passenger_id, l.bus_id,
         coalesce(-sum(l.amount_minor), 0) as charged
    from public.finance_lines l
    join public.finance_entries en on en.id = l.entry_id
   where l.account_code = 'revenue.fare'
     and en.source_table = 'passengers'
     and l.bus_id is not null
   group by 1, 2
)
select t.name as rider,
       t.should_be / 100.0                        as app_says_rupees,
       coalesce(p.charged, 0) / 100.0             as ledger_says_rupees,
       (coalesce(p.charged, 0) - t.should_be) / 100.0 as drift_rupees,
       t.bus_id
  from target t
  left join posted p on p.passenger_id = t.passenger_id and p.bus_id = t.bus_id
 where coalesce(p.charged, 0) <> t.should_be
 order by abs(coalesce(p.charged, 0) - t.should_be) desc
 limit 100;


-- ── CHECK 8 · Money on buses no longer on their tour ─────────
-- Finding E. Once the app reads the ledger these amounts vanish from the trip
-- total and no warning can fire, because the orphan fields are hard-coded to 0.
-- EXPECT: zero rows.
select fbs.tour_id, t.title, fbs.bus_id,
       fbs.collected_minor / 100.0 as stranded_collected,
       (fbs.ground_expenses_minor + fbs.rent_minor) / 100.0 as stranded_expenses
  from public.finance_bus_summary fbs
  join public.tours t on t.id = fbs.tour_id
  left join public.buses b
    on b.id = fbs.bus_id and b.tour_id = fbs.tour_id and b.deleted_at is null
 where b.id is null
   and (fbs.collected_minor <> 0 or fbs.ground_expenses_minor <> 0
        or fbs.rent_minor <> 0 or fbs.income_minor <> 0);


-- ── CHECK 9 · Riders whose stored trip_type contradicts their lines ──
-- Finding D1. Dart prices from `request_lines`; both SQL fare functions price
-- from the stored `trip_type` column. Where they disagree the app and the
-- ledger charge different amounts — up to 2x on the same rider.
-- EXPECT: zero rows.
select p.id, p.name, t.title as tour,
       p.trip_type                          as stored_trip_type,
       array_agg(distinct l->>'leg')        as legs_on_request_lines
  from public.passengers p
  join public.tours t on t.id = p.tour_id
  cross join lateral jsonb_array_elements(coalesce(p.request_lines, '[]'::jsonb)) l
 where p.cancelled_at is null and p.deleted_at is null
   and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
 group by p.id, p.name, t.title, p.trip_type
having not (array_agg(distinct l->>'leg') = array[p.trip_type])
 limit 100;


-- ── CHECK 10 · Seat ids carrying a '#' suffix ────────────────
-- Finding D3. `booking_amount_paise` (the ONLINE charge) does not strip the
-- suffix, so any berth stored this way is billed ₹0 to the customer.
-- EXPECT: zero rows.
select p.id, p.name, s->>'seatId' as suffixed_seat_id
  from public.passengers p
  cross join lateral jsonb_array_elements(coalesce(p.assigned_seats, '[]'::jsonb)) s
 where s->>'seatId' like '%#%'
 limit 50;


-- ── CHECK 11 · Reconcile ONE bus against the physical cash ───
-- Not a bug hunt — the tool for "the app says ₹55,800 but I counted ₹54,600".
-- Every check above proves the books agree with THEMSELVES; only this one lets
-- you put them next to the money in your hand and find the row that differs.
--
-- Replace the bus name, then read down the `cash` column. `cash` is what the
-- handler is holding for that row (received − online − refunded) and is exactly
-- what the ledger's `collected_minor` counts, so the total at the bottom is the
-- figure the app prints on the bus money screen.
--
-- WHAT TO LOOK FOR
--   * two rows for the same rider on the same physical seat (`seat` equal once
--     the '#n' berth suffix is stripped) — one payment recorded twice. This is
--     the "defect #2" signature that public.finance_integrity_alerts watches.
--   * a row whose `seated_here` is false — cash from somebody who no longer
--     holds a seat on this bus. It is real money and it stays in the total; the
--     app names it separately as "detached cash".
--   * `online` > 0 — a UPI advance. It reached the organiser's bank, never the
--     handler's pocket, which is why it is excluded from `cash`.
with target as (
  select b.id, b.name, b.tour_id
    from public.buses b
   where b.name = 'Momai Krupa 2'          -- ← the bus you are counting
     and b.deleted_at is null
)
select p.name                                        as rider,
       split_part(c.seat_id, '#', 1)                 as seat,
       c.amount_due                                  as due,
       c.amount_received                             as received,
       c.amount_online                               as online,
       c.amount_refunded                             as refunded,
       c.amount_received - c.amount_online - c.amount_refunded as cash,
       exists (
         select 1
           from jsonb_array_elements(
                  coalesce(p.assigned_seats, '[]'::jsonb)) s
          where (nullif(s->>'busId',''))::uuid = c.bus_id
       )                                             as seated_here,
       c.collected_by, c.note, c.created_at
  from public.collections c
  join target t          on t.id = c.bus_id
  left join public.passengers p on p.id = c.passenger_id
 where c.deleted_at is null
 order by 1, 2;

-- …and the one number to compare against your cash box:
with target as (
  select b.id from public.buses b
   where b.name = 'Momai Krupa 2' and b.deleted_at is null
)
select count(*)                                                    as rows,
       sum(c.amount_received)                                      as received,
       sum(c.amount_online)                                        as online_not_in_hand,
       sum(c.amount_refunded)                                      as refunded,
       sum(c.amount_received - c.amount_online - c.amount_refunded) as cash_app_shows
  from public.collections c
  join target t on t.id = c.bus_id
 where c.deleted_at is null;
