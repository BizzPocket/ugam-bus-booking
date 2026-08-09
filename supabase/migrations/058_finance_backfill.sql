-- ============================================================
-- 058_finance_backfill.sql   —   P3 of the finance rebuild
-- ------------------------------------------------------------
-- Turns every existing money row into ledger entries, with provenance, so the
-- new books describe the same history the old tables do.
--
-- READ-ONLY with respect to the old tables. It only INSERTS into
-- finance_entries / finance_lines. Nothing existing is modified or deleted, and
-- the app is unaffected — nothing reads the ledger until P6.
--
-- IDEMPOTENT BY CONSTRUCTION. Every entry carries a deterministic
-- `client_request_id` derived from its source row (e.g.
-- `backfill:collection:receipt:<uuid>`), and `finance_entries` has
-- `unique (tour_id, client_request_id)`. Re-running inserts nothing new. That
-- is also what makes it safe to run tour-by-tour, or to resume after a failure.
--
-- WHAT MAPS TO WHAT
--   live fare per seated berth   fare_charge    DR ar.rider       CR revenue.fare
--   collections.amount_received  cash_receipt   DR cash.handler   CR ar.rider
--   collections.amount_refunded  refund         DR ar.rider       CR cash.handler
--   expenses.amount              expense        DR expense.ground CR cash.handler
--   incomes.amount               extra_income   DR cash.handler   CR revenue.extra
--   bus_handovers.handed_over    handover       DR cash.admin     CR cash.handler
--   buses.bus_price              owner_rent     DR expense.rent   CR payable.owner
--
-- The last line is the important one: the owner's rent has never existed as a
-- row anywhere. It was a number on the bus that three separate pieces of code
-- each remembered to subtract. Here it becomes a real, countable cost — and
-- because it credits `payable.owner` rather than `cash.handler`, "the admin
-- settles the owner, the handler never sees rent" stops being a rule three
-- files must remember and becomes the shape of the data.
--
-- ARCHIVED ROWS ARE POSTED, THEN REVERSED.
-- A soft-deleted row is still history. Omitting it would make the ledger
-- disagree with the baseline and lose the fact that the money ever moved. So
-- the original entry is posted AND a matching `reversal` entry is posted, which
-- nets it to zero. History complete, current balance correct.
--
-- CANCELLED PASSENGERS ARE NOT CHARGED.
-- A cancelled rider does not owe a fare. This is why 053 captured BOTH
-- `billed_paise` (everyone) and `billed_active_paise` (cancelled excluded):
-- the ledger reconciles against the ACTIVE figure. See §5.
--
-- SETTLEMENTS: backfilled entries carry `settlement_id = null`. They predate
-- the close/reopen model, which starts being used at P5.
--
-- Requires 056. Apply in the Supabase SQL editor, isolated, AFTER 057.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_entries') is null then
    raise exception '058 requires 056_finance_ledger.sql to be applied first'
      using hint = 'Apply 053 -> 054 -> 055 -> 056 -> 058 in order.';
  end if;
end $$;


-- ── 1. Post one balanced entry ───────────────────────────────
-- Every mapping below funnels through here, so the two-sided shape, the
-- provenance stamp and the idempotency key can never be written two ways.
--
-- Returns BOTH the entry id and whether this call created it. The distinction
-- is load-bearing: the caller needs the id even on a re-run, because a source
-- row archived AFTER its first backfill still has to be reversed. Returning
-- NULL for "already existed" (the first version of this file) silently skipped
-- exactly that case, and archived money stayed on the books forever.
--
-- `o_entry` is NULL only when there was nothing to post (zero amount).

create or replace function public.backfill_post(
  p_tour_id      uuid,
  p_kind         text,
  p_key          text,
  p_occurred_at  timestamptz,
  p_amount_minor bigint,
  p_debit_code   text,
  p_debit_bus    uuid,
  p_debit_pax    uuid,
  p_credit_code  text,
  p_credit_bus   uuid,
  p_credit_pax   uuid,
  p_source_table text,
  p_source_row   uuid,
  p_category     text default null,
  p_memo         text default null,
  out o_entry    uuid,
  out o_new      boolean
)
language plpgsql security definer set search_path = public
as $$
begin
  o_entry := null;
  o_new   := false;

  -- A zero-value row carries no information and cannot form a balanced entry
  -- (finance_lines forbids amount_minor = 0).
  if p_amount_minor is null or p_amount_minor = 0 then
    return;
  end if;

  insert into public.finance_entries (
    tour_id, kind, occurred_at, recorded_at,
    actor_kind, actor_label, client_request_id,
    memo, source_table, source_row_id
  )
  values (
    p_tour_id, p_kind, coalesce(p_occurred_at, now()), now(),
    'system', 'backfill', p_key,
    p_memo, p_source_table, p_source_row
  )
  on conflict (tour_id, client_request_id) do nothing
  returning id into o_entry;

  if o_entry is not null then
    o_new := true;
    -- Debits positive, credits negative; the pair sums to zero, which the
    -- deferred constraint trigger re-checks at COMMIT.
    insert into public.finance_lines
      (entry_id, account_code, bus_id, passenger_id, category, amount_minor)
    values
      (o_entry, p_debit_code,  p_debit_bus,  p_debit_pax,  p_category,  p_amount_minor),
      (o_entry, p_credit_code, p_credit_bus, p_credit_pax, p_category, -p_amount_minor);
    return;
  end if;

  -- Re-run: resolve the entry that already exists so the caller can still
  -- reverse it if its source row has since been archived. `on conflict do
  -- update` is not available here — finance_entries is append-only and its
  -- immutability trigger would raise on any UPDATE.
  select id into o_entry
    from public.finance_entries
   where tour_id = p_tour_id and client_request_id = p_key;
end $$;

revoke all on function public.backfill_post(
  uuid, text, text, timestamptz, bigint, text, uuid, uuid, text, uuid, uuid,
  text, uuid, text, text) from public;


-- ── 2. Reverse an entry ──────────────────────────────────────
-- Used for archived source rows. Mirrors every line with the opposite sign so
-- the net is zero while both the original and its cancellation stay visible.

create or replace function public.backfill_reverse(
  p_entry_id uuid,
  p_key      text,
  p_memo     text default 'source row was archived'
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_src   record;
  v_entry uuid;
begin
  if p_entry_id is null then
    return null;
  end if;

  select * into v_src from public.finance_entries where id = p_entry_id;
  if not found then
    return null;
  end if;

  insert into public.finance_entries (
    tour_id, kind, occurred_at, recorded_at,
    actor_kind, actor_label, client_request_id,
    reverses_entry_id, memo, source_table, source_row_id
  )
  values (
    v_src.tour_id, 'reversal', v_src.occurred_at, now(),
    'system', 'backfill', p_key,
    p_entry_id, p_memo, v_src.source_table, v_src.source_row_id
  )
  on conflict (tour_id, client_request_id) do nothing
  returning id into v_entry;

  if v_entry is null then
    return null;
  end if;

  insert into public.finance_lines
    (entry_id, account_code, bus_id, passenger_id, category, amount_minor)
  select v_entry, l.account_code, l.bus_id, l.passenger_id, l.category,
         -l.amount_minor
    from public.finance_lines l
   where l.entry_id = p_entry_id;

  return v_entry;
end $$;

revoke all on function public.backfill_reverse(uuid, text, text) from public;


-- ── 3. The backfill ──────────────────────────────────────────
-- Pass a tour id to do one trip, or null for everything. Returns per-kind
-- counts so a re-run visibly reports zeros.

create or replace function public.backfill_finance_ledger(
  p_tour_id uuid default null
) returns table (kind text, entries_posted bigint, reversals_posted bigint)
language plpgsql security definer set search_path = public
as $$
declare
  r        record;
  v_entry  uuid;
  v_new    boolean;
  v_rev    uuid;
  v_counts jsonb := '{}'::jsonb;
  v_revs   jsonb := '{}'::jsonb;
begin
  -- ── 3a. Fare charged for every berth a LIVE rider currently holds ──
  -- Priced by the same engine the app uses (053's baseline_seat_due_paise,
  -- which sums berth-legs then rounds ONCE per seat — the app's rule, not
  -- 049's per-berth rounding).
  for r in
    select distinct
           p.tour_id,
           p.id                                as passenger_id,
           (seat->>'busId')::uuid              as bus_id,
           split_part(seat->>'seatId', '#', 1) as seat_id,
           p.created_at
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as seat
     where (p_tour_id is null or p.tour_id = p_tour_id)
       and p.cancelled_at is null
       and p.deleted_at is null
       and coalesce(seat->>'busId', '') <> ''
       and coalesce(seat->>'seatId', '') <> ''
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'fare_charge',
      'backfill:fare:' || r.passenger_id || ':' || r.bus_id || ':' || r.seat_id,
      r.created_at,
      public.baseline_seat_due_paise(r.passenger_id, r.bus_id, r.seat_id),
      'ar.rider',     null,      r.passenger_id,
      'revenue.fare', r.bus_id,  null,
      'passengers', r.passenger_id, null,
      'seat ' || r.seat_id
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{fare_charge}',
        to_jsonb(coalesce((v_counts->>'fare_charge')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
    end if;
  end loop;

  -- ── 3b. Cash taken in, and cash handed back ──
  for r in
    select c.* from public.collections c
     where (p_tour_id is null or c.tour_id = p_tour_id)
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'cash_receipt', 'backfill:collection:receipt:' || r.id,
      r.created_at, round(r.amount_received * 100)::bigint,
      'cash.handler', r.bus_id, null,
      'ar.rider',     null,     r.passenger_id,
      'collections', r.id, null, r.note
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{cash_receipt}',
        to_jsonb(coalesce((v_counts->>'cash_receipt')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(
          v_entry, 'backfill:collection:receipt:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{cash_receipt}',
            to_jsonb(coalesce((v_revs->>'cash_receipt')::bigint, 0) + 1));
        end if;
      end if;
    end if;

    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'refund', 'backfill:collection:refund:' || r.id,
      r.created_at, round(r.amount_refunded * 100)::bigint,
      'ar.rider',     null,     r.passenger_id,
      'cash.handler', r.bus_id, null,
      'collections', r.id, null, r.note
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{refund}',
        to_jsonb(coalesce((v_counts->>'refund')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(
          v_entry, 'backfill:collection:refund:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{refund}',
            to_jsonb(coalesce((v_revs->>'refund')::bigint, 0) + 1));
        end if;
      end if;
    end if;
  end loop;

  -- ── 3c. Ground expenses ──
  for r in
    select e.* from public.expenses e
     where (p_tour_id is null or e.tour_id = p_tour_id)
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'expense', 'backfill:expense:' || r.id,
      r.created_at, round(r.amount * 100)::bigint,
      'expense.ground', r.bus_id, null,
      'cash.handler',   r.bus_id, null,
      'expenses', r.id, r.category, r.label
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{expense}',
        to_jsonb(coalesce((v_counts->>'expense')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(v_entry, 'backfill:expense:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{expense}',
            to_jsonb(coalesce((v_revs->>'expense')::bigint, 0) + 1));
        end if;
      end if;
    end if;
  end loop;

  -- ── 3d. Extra income (cabin / gallery / other) ──
  for r in
    select i.* from public.incomes i
     where (p_tour_id is null or i.tour_id = p_tour_id)
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'extra_income', 'backfill:income:' || r.id,
      r.created_at, round(r.amount * 100)::bigint,
      'cash.handler',  r.bus_id, null,
      'revenue.extra', r.bus_id, null,
      'incomes', r.id, r.category, r.label
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{extra_income}',
        to_jsonb(coalesce((v_counts->>'extra_income')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(v_entry, 'backfill:income:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{extra_income}',
            to_jsonb(coalesce((v_revs->>'extra_income')::bigint, 0) + 1));
        end if;
      end if;
    end if;
  end loop;

  -- ── 3e. Handovers to the admin ──
  for r in
    select h.* from public.bus_handovers h
     where (p_tour_id is null or h.tour_id = p_tour_id)
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'handover', 'backfill:handover:' || r.id,
      coalesce(r.settled_at, r.created_at),
      round(r.handed_over_amount * 100)::bigint,
      'cash.admin',   null,     null,
      'cash.handler', r.bus_id, null,
      'bus_handovers', r.id, null, r.note
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{handover}',
        to_jsonb(coalesce((v_counts->>'handover')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(v_entry, 'backfill:handover:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{handover}',
            to_jsonb(coalesce((v_revs->>'handover')::bigint, 0) + 1));
        end if;
      end if;
    end if;
  end loop;

  -- ── 3f. The owner's rent — the cost that never had a row ──
  for r in
    select b.id, b.tour_id, b.bus_price, b.name, b.deleted_at, b.created_at
      from public.buses b
     where (p_tour_id is null or b.tour_id = p_tour_id)
  loop
    select o_entry, o_new into v_entry, v_new from public.backfill_post(
      r.tour_id, 'owner_rent', 'backfill:rent:' || r.id,
      r.created_at, round(r.bus_price * 100)::bigint,
      'expense.rent',  r.id, null,
      'payable.owner', r.id, null,
      'buses', r.id, 'rent', 'owner rent for ' || coalesce(r.name, 'bus')
    );
    if v_new then
      v_counts := jsonb_set(v_counts, '{owner_rent}',
        to_jsonb(coalesce((v_counts->>'owner_rent')::bigint, 0) + 1));
    end if;
    -- Reverse regardless of whether the entry was posted just now: a row
    -- archived AFTER an earlier backfill must still be cancelled out.
    if v_entry is not null then
      if r.deleted_at is not null then
        v_rev := public.backfill_reverse(v_entry, 'backfill:rent:rev:' || r.id);
        if v_rev is not null then
          v_revs := jsonb_set(v_revs, '{owner_rent}',
            to_jsonb(coalesce((v_revs->>'owner_rent')::bigint, 0) + 1));
        end if;
      end if;
    end if;
  end loop;

  -- ── 3g. Un-charge riders who have since cancelled or been archived ──
  -- §3a only visits ACTIVE riders, so a passenger who cancels after an earlier
  -- backfill would keep their fare on the books forever — the same defect the
  -- archived-row reversal above fixes, in the one place a filtered loop cannot
  -- see. Driven off the ledger rather than the roster for exactly that reason.
  for r in
    select e.id as entry_id, e.tour_id
      from public.finance_entries e
      join public.passengers p on p.id = e.source_row_id
     where e.kind = 'fare_charge'
       and e.source_table = 'passengers'
       and (p_tour_id is null or e.tour_id = p_tour_id)
       and (p.cancelled_at is not null or p.deleted_at is not null)
       and not exists (
         select 1 from public.finance_entries rev
          where rev.reverses_entry_id = e.id
       )
  loop
    v_rev := public.backfill_reverse(
      r.entry_id, 'backfill:fare:rev:' || r.entry_id,
      'rider cancelled or archived');
    if v_rev is not null then
      v_revs := jsonb_set(v_revs, '{fare_charge}',
        to_jsonb(coalesce((v_revs->>'fare_charge')::bigint, 0) + 1));
    end if;
  end loop;

  return query
  select k,
         coalesce((v_counts->>k)::bigint, 0),
         coalesce((v_revs->>k)::bigint, 0)
    from unnest(array['fare_charge','cash_receipt','refund','expense',
                      'extra_income','handover','owner_rent']) k;
end $$;

revoke all on function public.backfill_finance_ledger(uuid) from public;
grant execute on function public.backfill_finance_ledger(uuid) to authenticated;


-- ── 4. Proof ─────────────────────────────────────────────────
-- Compares the ledger against a baseline run, per bus, in paise. Every column
-- must be zero. This is what makes "the migration was lossless" a query rather
-- than an opinion.
--
-- `billed` is checked against `billed_active_paise` — the backfill does not
-- charge cancelled riders, and 053 captured both figures precisely so this
-- comparison could be exact.

create or replace function public.verify_finance_backfill(p_run_id uuid)
returns table (
  tour_id            uuid,
  bus_id             uuid,
  collected_delta    bigint,
  billed_delta       bigint,
  income_delta       bigint,
  ground_exp_delta   bigint,
  rent_delta         bigint,
  handover_delta     bigint,
  ok                 boolean
)
language sql stable security definer set search_path = public
as $$
  with ledger as (
    select e.tour_id,
           l.bus_id,
           -- cash actually received minus handed back, on this bus
           coalesce(sum(l.amount_minor) filter (
             where l.account_code = 'cash.handler'
               and e.kind in ('cash_receipt','refund','reversal')), 0)      as collected,
           coalesce(-sum(l.amount_minor) filter (
             where l.account_code = 'revenue.fare'), 0)                     as billed,
           coalesce(-sum(l.amount_minor) filter (
             where l.account_code = 'revenue.extra'), 0)                    as income,
           coalesce(sum(l.amount_minor) filter (
             where l.account_code = 'expense.ground'), 0)                   as ground_exp,
           coalesce(sum(l.amount_minor) filter (
             where l.account_code = 'expense.rent'), 0)                     as rent,
           coalesce(-sum(l.amount_minor) filter (
             where l.account_code = 'cash.handler'
               and e.kind = 'handover'), 0)                                 as handed_over
      from public.finance_lines l
      join public.finance_entries e on e.id = l.entry_id
     where l.bus_id is not null
     group by e.tour_id, l.bus_id
  )
  select
    b.tour_id,
    b.bus_id,
    coalesce(g.collected, 0)
      - (b.received_paise - b.refunded_paise)                  as collected_delta,
    coalesce(g.billed, 0)      - b.billed_active_paise         as billed_delta,
    coalesce(g.income, 0)      - b.incomes_paise               as income_delta,
    coalesce(g.ground_exp, 0)  - b.expenses_paise              as ground_exp_delta,
    coalesce(g.rent, 0)        - b.rent_paise                  as rent_delta,
    coalesce(g.handed_over, 0) - b.handed_over_paise           as handover_delta,
    (coalesce(g.collected, 0)   = b.received_paise - b.refunded_paise
     and coalesce(g.billed, 0)      = b.billed_active_paise
     and coalesce(g.income, 0)      = b.incomes_paise
     and coalesce(g.ground_exp, 0)  = b.expenses_paise
     and coalesce(g.rent, 0)        = b.rent_paise
     and coalesce(g.handed_over, 0) = b.handed_over_paise)     as ok
  from public.finance_baseline_bus b
  left join ledger g
    on g.tour_id = b.tour_id and g.bus_id = b.bus_id
  where b.run_id = p_run_id;
$$;

revoke all on function public.verify_finance_backfill(uuid) from public;
grant execute on function public.verify_finance_backfill(uuid) to authenticated;


-- ============================================================
-- HOW TO RUN
--
-- 1. Make sure a baseline exists (053). If not:
--      select public.capture_finance_baseline('pre-ledger','before backfill');
--
-- 2. Backfill. Start with ONE tour to see the shape:
--      select * from public.backfill_finance_ledger('<tour id>');
--    Then everything:
--      select * from public.backfill_finance_ledger();
--
-- 3. PROVE IT — do this IMMEDIATELY after step 2, before anything else
--    changes. Every row must show ok = true:
--      select * from public.verify_finance_backfill('<baseline run id>')
--       where not ok;
--    An empty result means the ledger reproduces the old books exactly.
--
--    The baseline is a SNAPSHOT. Archive a row or cancel a rider afterwards
--    and the ledger will correctly diverge from it — that is the ledger being
--    right, not the backfill being wrong. To re-verify later, capture a fresh
--    baseline first and compare against that one.
--
-- 4. Re-running step 2 must report all zeros — that is the idempotency check.
--
-- NOTHING IN THE APP READS THIS YET. Reads switch over at P6.
-- ============================================================
