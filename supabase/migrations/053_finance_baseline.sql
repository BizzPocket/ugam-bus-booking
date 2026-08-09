-- ============================================================
-- 053_finance_baseline.sql   —   P0 of the finance rebuild
-- ------------------------------------------------------------
-- Captures a COMPLETE, immutable snapshot of what the money system says
-- TODAY, before a single row of the new ledger exists.
--
-- Why this must exist first: the ledger backfill (P3) has to be provable.
-- Without a "before" that was taken while the old system was still the only
-- system, "the numbers match" is an opinion. This file turns it into a query.
--
-- Everything is captured in PAISE (bigint), using exactly the conversion the
-- backfill will use — `round(rupees * 100)`. So this snapshot also proves the
-- decimal→integer conversion itself is lossless.
--
-- IDEMPOTENT + RE-RUNNABLE BY DESIGN. Pressing it a second time does NOT
-- clobber: each press inserts a NEW run (a new generation), so you can capture
-- 'pre-ledger' now and 'post-backfill' later and diff the two in SQL. Tables
-- use `create table if not exists`; nothing is ever dropped or updated.
--
-- Reads only. Writes only to its own three tables. Safe on live data.
--
-- Apply in the Supabase SQL editor (isolated — do NOT `db push`, the history
-- table is empty and push would replay every earlier file).
-- ============================================================


-- ── 1. Run header ────────────────────────────────────────────
-- One row per capture. Everything else hangs off run_id.

create table if not exists public.finance_baseline_runs (
  id          uuid primary key default gen_random_uuid(),
  captured_at timestamptz not null default now(),
  label       text not null default 'pre-ledger',
  note        text
);

alter table public.finance_baseline_runs enable row level security;

-- Any signed-in agent may read the baseline; nobody may edit it from the app.
drop policy if exists "finance_baseline_runs_read" on public.finance_baseline_runs;
create policy "finance_baseline_runs_read" on public.finance_baseline_runs
  for select to authenticated using (true);


-- ── 2. Per-bus snapshot ──────────────────────────────────────
-- One row per (tour, bus) that has ANY money on it. Column names mirror the
-- Dart getters they must reproduce, so a mismatch points straight at the
-- getter that drifted.
--
-- The formulas are transcribed from lib/models/money_summary.dart:
--   expensesTotal      = expense rows + busRent      (rent is NOT a row today)
--   groundExpenses     = expensesTotal - busRent     ( = expense rows)
--   expectedHandover   = collected + income - groundExpenses
--   outstandingHandover= expectedHandover - handedOver
--   netCollected       = collected + income - expensesTotal
-- Rent is deliberately OUTSIDE the handover expectation: the admin settles the
-- owner, not the handler.

create table if not exists public.finance_baseline_bus (
  run_id                      uuid not null
                                references public.finance_baseline_runs(id) on delete cascade,
  tour_id                     uuid not null,
  bus_id                      uuid not null,
  -- False when this bus is not (or no longer) a bus of the collection's tour.
  -- Money on such a bus is counted in the tour totals but appears on no bus row
  -- in the app — today's `orphan*` figures.
  bus_is_current              boolean not null,

  collection_rows             integer not null,
  received_paise              bigint  not null,
  refunded_paise              bigint  not null,
  net_collected_paise         bigint  not null,
  -- Shortfalls / change-due as RECORDED on collection rows. This is the
  -- `Collection.stillToCollect` / `changeToReturn` sum only — it deliberately
  -- excludes seated-but-uncollected riders, which the app adds from the live
  -- fare (captured separately as billed_paise below).
  to_collect_recorded_paise   bigint  not null,
  to_return_recorded_paise    bigint  not null,

  expense_rows                integer not null,
  expenses_paise              bigint  not null,
  income_rows                 integer not null,
  incomes_paise               bigint  not null,
  handover_rows               integer not null,
  handed_over_paise           bigint  not null,

  -- buses.bus_price — a real cost that exists as NO row anywhere today.
  rent_paise                  bigint  not null,

  -- Accrual revenue: every berth currently seated on this bus, priced by the
  -- live engine. See §3 for the rounding note.
  billed_paise                bigint  not null,
  billed_active_paise         bigint  not null,

  expected_handover_paise     bigint  not null,
  outstanding_handover_paise  bigint  not null,
  net_collected_after_costs_paise bigint not null,

  primary key (run_id, tour_id, bus_id)
);

alter table public.finance_baseline_bus enable row level security;
drop policy if exists "finance_baseline_bus_read" on public.finance_baseline_bus;
create policy "finance_baseline_bus_read" on public.finance_baseline_bus
  for select to authenticated using (true);


-- ── 3. Table fingerprints ────────────────────────────────────
-- Row count + column sums + an order-independent digest per source table.
-- After the backfill, re-running proves NOTHING was added, dropped or altered
-- underneath us while the migration ran.

create table if not exists public.finance_baseline_fingerprint (
  run_id     uuid not null
               references public.finance_baseline_runs(id) on delete cascade,
  table_name text not null,
  row_count  bigint not null,
  sum_a      bigint,        -- collections.received | expenses.amount | incomes.amount | handovers.handed_over
  sum_b      bigint,        -- collections.refunded | handovers.expected
  sum_c      bigint,        -- collections.amount_due
  digest     text not null, -- md5 over every row's id + amounts, order-independent
  primary key (run_id, table_name)
);

alter table public.finance_baseline_fingerprint enable row level security;
drop policy if exists "finance_baseline_fingerprint_read" on public.finance_baseline_fingerprint;
create policy "finance_baseline_fingerprint_read" on public.finance_baseline_fingerprint
  for select to authenticated using (true);


-- ── 4. Live per-seat fare, transcribed from Dart ─────────────
-- `Bus.amountDueForSeat`: sum each berth this passenger holds on the seat at
-- its OWN leg factor, THEN round the per-seat total to whole rupees.
--
-- This deliberately differs from 049's `booking_amount_paise`, which rounds
-- each BERTH before summing. On a one-leg berth those two disagree by up to a
-- rupee. Dart's per-seat rounding is the one the stored money was actually
-- collected against, so the baseline must use it — the divergence itself is
-- recorded here as a finding for P5 to collapse into a single pricing path.
--
-- Returns paise. `p_seat_id` is the BASE seat id (anything after '#' stripped).

create or replace function public.baseline_seat_due_paise(
  p_passenger_id uuid,
  p_bus_id       uuid,
  p_seat_id      text
) returns bigint
language sql stable security definer set search_path = public
as $$
  with pax as (
    select assigned_seats, trip_type
      from public.passengers
     where id = p_passenger_id
  ),
  -- Every berth this passenger holds on THIS seat of THIS bus, with its own leg.
  berth as (
    select coalesce(nullif(seat->>'leg', ''), pax.trip_type, 'roundTrip') as leg
      from pax
      cross join lateral jsonb_array_elements(
        coalesce(pax.assigned_seats, '[]'::jsonb)
      ) as seat
     where seat->>'busId' = p_bus_id::text
       and split_part(seat->>'seatId', '#', 1) = p_seat_id
  ),
  cell as (
    select c->>'seatType' as seat_type, (c->>'row')::int as row_ix
      from public.buses b
      cross join lateral jsonb_array_elements(
        coalesce(b.layout->'grid', '[]'::jsonb)
      ) as c
     where b.id = p_bus_id
       and c->>'seatId' = p_seat_id
     limit 1
  )
  -- Sum berth × leg factor FIRST, round ONCE, then back to paise.
  select coalesce(
    round(
      sum(
        (public.bus_berth_price_paise(p_bus_id, cell.seat_type, cell.row_ix) / 100.0)
        * case when berth.leg = 'roundTrip' then 1.0 else 0.5 end
      )
    ) * 100,
    0
  )::bigint
  from berth cross join cell;
$$;

revoke all on function public.baseline_seat_due_paise(uuid, uuid, text) from public;
grant execute on function public.baseline_seat_due_paise(uuid, uuid, text) to authenticated;


-- ── 5. Capture ───────────────────────────────────────────────
-- Runs the whole snapshot in one transaction so every figure describes the
-- SAME instant. Returns the new run_id.

create or replace function public.capture_finance_baseline(
  p_label text default 'pre-ledger',
  p_note  text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_run uuid;
begin
  insert into public.finance_baseline_runs (label, note)
  values (coalesce(nullif(p_label, ''), 'pre-ledger'), p_note)
  returning id into v_run;

  -- ── per-bus ────────────────────────────────────────────────
  with
  -- Every (tour, bus) pair that carries money of any kind.
  scope as (
    select tour_id, bus_id from public.collections
    union select tour_id, bus_id from public.expenses
    union select tour_id, bus_id from public.incomes
    union select tour_id, bus_id from public.bus_handovers
    union select tour_id, id     from public.buses
  ),
  col as (
    select tour_id, bus_id,
           count(*)::int                                          as rows_n,
           sum(round(amount_received  * 100))::bigint             as received,
           sum(round(amount_refunded  * 100))::bigint             as refunded,
           sum(round((amount_received - amount_refunded) * 100))::bigint as net,
           -- stillToCollect / changeToReturn, epsilon-free in integer paise
           sum(greatest(round((amount_due - amount_received + amount_refunded) * 100), 0))::bigint as to_collect,
           sum(greatest(round((amount_received - amount_refunded - amount_due) * 100), 0))::bigint as to_return,
           sum(round(amount_due * 100))::bigint                   as due
      from public.collections
     group by tour_id, bus_id
  ),
  exp as (
    select tour_id, bus_id, count(*)::int as rows_n,
           sum(round(amount * 100))::bigint as total
      from public.expenses group by tour_id, bus_id
  ),
  inc as (
    select tour_id, bus_id, count(*)::int as rows_n,
           sum(round(amount * 100))::bigint as total
      from public.incomes group by tour_id, bus_id
  ),
  han as (
    select tour_id, bus_id, count(*)::int as rows_n,
           sum(round(handed_over_amount * 100))::bigint as total
      from public.bus_handovers group by tour_id, bus_id
  ),
  -- Accrual revenue: the DISTINCT seats each passenger holds on each bus,
  -- priced once per seat (a whole double sofa is two berths on ONE seat and
  -- must be charged once, at the full sofa price).
  seats as (
    select distinct
           p.id                                        as passenger_id,
           p.cancelled_at,
           (seat->>'busId')::uuid                      as bus_id,
           split_part(seat->>'seatId', '#', 1)         as seat_id
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as seat
     where seat->>'busId' is not null
       and seat->>'busId' <> ''
  ),
  billed as (
    select b.tour_id, s.bus_id,
           sum(public.baseline_seat_due_paise(s.passenger_id, s.bus_id, s.seat_id))::bigint as total,
           sum(case when s.cancelled_at is null
                    then public.baseline_seat_due_paise(s.passenger_id, s.bus_id, s.seat_id)
                    else 0 end)::bigint as total_active
      from seats s
      join public.buses b on b.id = s.bus_id
     group by b.tour_id, s.bus_id
  )
  insert into public.finance_baseline_bus (
    run_id, tour_id, bus_id, bus_is_current,
    collection_rows, received_paise, refunded_paise, net_collected_paise,
    to_collect_recorded_paise, to_return_recorded_paise,
    expense_rows, expenses_paise, income_rows, incomes_paise,
    handover_rows, handed_over_paise, rent_paise,
    billed_paise, billed_active_paise,
    expected_handover_paise, outstanding_handover_paise,
    net_collected_after_costs_paise
  )
  select
    v_run,
    sc.tour_id,
    sc.bus_id,
    -- current == this bus really belongs to this tour
    coalesce(bu.tour_id = sc.tour_id, false),
    coalesce(col.rows_n, 0), coalesce(col.received, 0), coalesce(col.refunded, 0),
    coalesce(col.net, 0),
    coalesce(col.to_collect, 0), coalesce(col.to_return, 0),
    coalesce(exp.rows_n, 0), coalesce(exp.total, 0),
    coalesce(inc.rows_n, 0), coalesce(inc.total, 0),
    coalesce(han.rows_n, 0), coalesce(han.total, 0),
    -- Rent belongs to the bus's OWN tour only. Counting it on a tour that
    -- merely has an orphan money row pointing at this bus would invent a cost
    -- that tour never incurred (and the app never charges it either — the app
    -- reads rent from `tour.buses`, which an orphan bus is not in).
    case when bu.tour_id = sc.tour_id
         then coalesce(round(bu.bus_price * 100), 0)::bigint else 0 end,
    coalesce(billed.total, 0), coalesce(billed.total_active, 0),
    -- expectedHandover = collected + income - groundExpenses(= expense rows)
    (coalesce(col.net, 0) + coalesce(inc.total, 0) - coalesce(exp.total, 0)),
    -- outstanding = expected - handedOver
    (coalesce(col.net, 0) + coalesce(inc.total, 0) - coalesce(exp.total, 0)
       - coalesce(han.total, 0)),
    -- netCollected = collected + income - (expense rows + rent)
    (coalesce(col.net, 0) + coalesce(inc.total, 0) - coalesce(exp.total, 0)
       - case when bu.tour_id = sc.tour_id
              then coalesce(round(bu.bus_price * 100), 0)::bigint else 0 end)
  from scope sc
  left join public.buses bu on bu.id = sc.bus_id
  left join col    on col.tour_id    = sc.tour_id and col.bus_id    = sc.bus_id
  left join exp    on exp.tour_id    = sc.tour_id and exp.bus_id    = sc.bus_id
  left join inc    on inc.tour_id    = sc.tour_id and inc.bus_id    = sc.bus_id
  left join han    on han.tour_id    = sc.tour_id and han.bus_id    = sc.bus_id
  left join billed on billed.tour_id = sc.tour_id and billed.bus_id = sc.bus_id;

  -- ── fingerprints ───────────────────────────────────────────
  -- sum(md5) is order-independent, so the digest is stable regardless of how
  -- Postgres happened to scan the table.
  insert into public.finance_baseline_fingerprint
    (run_id, table_name, row_count, sum_a, sum_b, sum_c, digest)
  select v_run, 'collections', count(*)::bigint,
         sum(round(amount_received * 100))::bigint,
         sum(round(amount_refunded * 100))::bigint,
         sum(round(amount_due      * 100))::bigint,
         coalesce(md5(sum(('x' || substr(md5(
           id::text || ':' || amount_due::text || ':' ||
           amount_received::text || ':' || amount_refunded::text
         ), 1, 8))::bit(32)::bigint)::text), 'empty')
    from public.collections
  union all
  select v_run, 'expenses', count(*)::bigint,
         sum(round(amount * 100))::bigint, null, null,
         coalesce(md5(sum(('x' || substr(md5(
           id::text || ':' || amount::text
         ), 1, 8))::bit(32)::bigint)::text), 'empty')
    from public.expenses
  union all
  select v_run, 'incomes', count(*)::bigint,
         sum(round(amount * 100))::bigint, null, null,
         coalesce(md5(sum(('x' || substr(md5(
           id::text || ':' || amount::text
         ), 1, 8))::bit(32)::bigint)::text), 'empty')
    from public.incomes
  union all
  select v_run, 'bus_handovers', count(*)::bigint,
         sum(round(handed_over_amount * 100))::bigint,
         sum(round(expected_amount    * 100))::bigint, null,
         coalesce(md5(sum(('x' || substr(md5(
           id::text || ':' || handed_over_amount::text || ':' || expected_amount::text
         ), 1, 8))::bit(32)::bigint)::text), 'empty')
    from public.bus_handovers
  union all
  select v_run, 'buses.bus_price', count(*)::bigint,
         sum(round(bus_price * 100))::bigint, null, null,
         coalesce(md5(sum(('x' || substr(md5(
           id::text || ':' || bus_price::text
         ), 1, 8))::bit(32)::bigint)::text), 'empty')
    from public.buses;

  return v_run;
end;
$$;

revoke all on function public.capture_finance_baseline(text, text) from public;
grant execute on function public.capture_finance_baseline(text, text) to authenticated;


-- ── 6. Readback ──────────────────────────────────────────────
-- Per-tour rollup of a run, for eyeballing. The per-bus table stays the
-- authoritative artifact.

create or replace view public.finance_baseline_tour as
select
  run_id,
  tour_id,
  count(*)::int                            as buses,
  count(*) filter (where not bus_is_current)::int as orphan_buses,
  sum(net_collected_paise)                 as collected_paise,
  sum(incomes_paise)                       as income_paise,
  sum(expenses_paise)                      as ground_expenses_paise,
  sum(rent_paise)                          as rent_paise,
  sum(expenses_paise) + sum(rent_paise)    as total_expenses_paise,
  sum(handed_over_paise)                   as handed_over_paise,
  sum(billed_paise)                        as billed_paise,
  sum(to_collect_recorded_paise)           as to_collect_recorded_paise,
  sum(to_return_recorded_paise)            as to_return_recorded_paise,
  sum(expected_handover_paise)             as expected_handover_paise,
  sum(outstanding_handover_paise)          as outstanding_handover_paise,
  sum(net_collected_after_costs_paise)     as net_cash_paise,
  sum(billed_paise) + sum(incomes_paise)
    - sum(expenses_paise) - sum(rent_paise) as net_billed_paise
from public.finance_baseline_bus
group by run_id, tour_id;


-- ============================================================
-- TO CAPTURE (run this line, keep the returned uuid):
--
--   select public.capture_finance_baseline('pre-ledger', 'before P1 soft delete');
--
-- TO READ BACK:
--
--   select * from public.finance_baseline_tour
--    where run_id = '<uuid>' order by tour_id;
--
--   select * from public.finance_baseline_fingerprint where run_id = '<uuid>';
--
-- TO DIFF TWO RUNS (this is what P3/P4 assert on):
--
--   select b.tour_id, b.bus_id,
--          a.net_collected_paise  as before_collected,
--          b.net_collected_paise  as after_collected,
--          b.net_collected_paise - a.net_collected_paise as delta
--     from public.finance_baseline_bus a
--     join public.finance_baseline_bus b using (tour_id, bus_id)
--    where a.run_id = '<before>' and b.run_id = '<after>'
--      and a.net_collected_paise is distinct from b.net_collected_paise;
-- ============================================================
