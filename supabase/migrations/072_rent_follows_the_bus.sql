-- ============================================================
-- 072_rent_follows_the_bus.sql
-- ------------------------------------------------------------
-- Three defects around ONE fact: `buses.tour_id` is NULLABLE, and bus rent is
-- the only ledger cost that is derived from a row rather than written as one.
--
-- HOW THIS SURFACED
-- `select * from public.backfill_finance_ledger();` failed with:
--     null value in column "tour_id" of relation "finance_entries"
--     violates not-null constraint
--     … owner rent for KHODAL DHAM 6363 … buses, 93cc6e35-…
-- That bus sits on no tour. `buses.tour_id` is ON DELETE SET NULL, so deleting a
-- tour leaves its buses behind as unassigned fleet rows — and 058 §3f loops over
-- EVERY bus, then hands a null tour to a ledger whose entries are tour-scoped
-- and NOT NULL.
--
-- Fixing only that would have left two more, both silent.
--
--   D1 · A tour-less bus crashes any rent post.
--        Not just the backfill: `finance_sync_bus_rent` (062 §7) passes
--        `v_row.tour_id` straight through too, so editing the price of an
--        unassigned fleet bus, or deleting one, failed the same way in the app.
--        `finance_post_delta` coalesces null AMOUNTS but never guarded the tour.
--
--   D2 · Rent does not follow the bus between tours.
--        The trigger computes ONE delta against the NEW tour. Move a bus from
--        tour A to tour B without touching its price and the delta is
--        `price - price = 0`, so nothing posts: **A keeps the rent forever and B
--        never gets it.** Assigning a fleet bus to its first tour is the same
--        shape — old price equals new price, so the tour never acquires the
--        cost it is actually paying.
--
--   D3 · A skipped bus was invisible.
--        Silently posting nothing is right for a tour-less bus, but nobody could
--        see which buses were skipped or how much rent is parked off-books.
--
-- THE FIX
--   §1 `backfill_post` refuses a null tour at the single choke point every
--      poster funnels through — the backfill loops, `finance_post_delta`, and
--      `confirm_payment_claim` alike.
--   §2 `finance_sync_bus_rent` treats a tour CHANGE as two deltas: retire the
--      rent from the tour the bus left, post it to the tour it joined.
--   §3 `finance_unassigned_bus_rent()` reports what §1 skips.
--
-- Requires 058 and 062. Idempotent, re-runnable, changes no data on its own.
-- Apply AFTER 071, BEFORE running `backfill_finance_ledger()`.
-- ============================================================

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'finance_post_delta') then
    raise exception '072 requires 062_ledger_write_through.sql first';
  end if;
end $$;


-- ── 1. No entry without a tour ───────────────────────────────
-- Byte-identical to 062's version apart from the tour guard. Placed beside the
-- zero-amount guard because it is the same kind of statement: this input cannot
-- form a valid entry, so there is nothing to post and nothing to report.
--
-- Silent rather than raising, deliberately. The alternative is a trigger that
-- refuses to let anyone save an unassigned bus, which is a legitimate thing to
-- have in the fleet. §3 is how the skipped rent stays visible.
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

  if p_amount_minor is null or p_amount_minor = 0 then
    return;
  end if;

  -- `finance_entries.tour_id` is NOT NULL: this ledger is scoped per trip and
  -- has nowhere to put a cost that belongs to no trip. Only `buses.tour_id` can
  -- ever be null among the sources, and a bus on no tour is not a tour's cost.
  -- It acquires one when it is assigned, which §2 posts at that moment.
  if p_tour_id is null then
    return;
  end if;

  -- The guard described in 062. Only ever restrains the BACKFILL: trigger posts
  -- carry a `row:` key and pass straight through.
  if p_key like 'backfill:%' and p_source_row is not null and exists (
    select 1 from public.finance_entries
     where source_table = p_source_table
       and source_row_id = p_source_row
       and client_request_id like 'row:%'
  ) then
    return;
  end if;

  insert into public.finance_entries (
    tour_id, kind, occurred_at, recorded_at,
    actor_kind, actor_label, client_request_id,
    memo, source_table, source_row_id
  )
  values (
    p_tour_id, p_kind, coalesce(p_occurred_at, now()), now(),
    coalesce(public.finance_actor_kind(), 'system'),
    coalesce(nullif(public.finance_actor_label(), ''), 'backfill'),
    p_key, p_memo, p_source_table, p_source_row
  )
  on conflict (tour_id, client_request_id) do nothing
  returning id into o_entry;

  if o_entry is not null then
    o_new := true;
    insert into public.finance_lines
      (entry_id, account_code, bus_id, passenger_id, category, amount_minor)
    values
      (o_entry, p_debit_code,  p_debit_bus,  p_debit_pax,  p_category,  p_amount_minor),
      (o_entry, p_credit_code, p_credit_bus, p_credit_pax, p_category, -p_amount_minor);
    return;
  end if;

  select id into o_entry
    from public.finance_entries
   where tour_id = p_tour_id and client_request_id = p_key;
end $$;


-- ── 2. Rent follows the bus ──────────────────────────────────
-- Rent belongs to the tour the bus is ON. When the bus MOVES, that is TWO
-- deltas against two different tours, not one delta against the new one — which
-- is why the old single-delta form posted nothing at all when the price
-- happened to be unchanged, the overwhelmingly common case.
--
-- Every branch is reached through an explicit `tg_op` test rather than a CASE
-- over OLD/NEW. Touching OLD in an INSERT trigger (or NEW in a DELETE) raises
-- `record "old" is not assigned yet`; the whole-record `coalesce(new, old)` is
-- the one form that is safe in all three, and is what supplies the bus id.
create or replace function public.finance_sync_bus_rent() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_row      record;
  v_old      bigint := 0;
  v_new      bigint := 0;
  v_old_tour uuid;
  v_new_tour uuid;
begin
  v_row := coalesce(new, old);

  if tg_op <> 'INSERT' then
    v_old_tour := old.tour_id;
    if old.deleted_at is null then
      v_old := coalesce(round(old.bus_price * 100)::bigint, 0);
    end if;
  end if;

  if tg_op <> 'DELETE' then
    v_new_tour := new.tour_id;
    if new.deleted_at is null then
      v_new := coalesce(round(new.bus_price * 100)::bigint, 0);
    end if;
  end if;

  -- The bus changed tours (which includes INSERT: null → a tour, DELETE: a tour
  -- → null, assignment, unassignment, and a straight A → B move).
  if v_old_tour is distinct from v_new_tour then
    if v_old_tour is not null then
      perform public.finance_post_delta(
        v_old_tour, 'owner_rent', v_old, 0,
        'expense.rent',  v_row.id, null,
        'payable.owner', v_row.id, null,
        'buses', v_row.id, 'rent', 'owner rent - bus left this tour');
    end if;
    if v_new_tour is not null then
      perform public.finance_post_delta(
        v_new_tour, 'owner_rent', 0, v_new,
        'expense.rent',  v_row.id, null,
        'payable.owner', v_row.id, null,
        'buses', v_row.id, 'rent', 'owner rent - bus joined this tour');
    end if;
    return null;
  end if;

  -- Same tour on both sides. If that tour is null the bus is an unassigned
  -- fleet row: no trip is paying for it, so there is nothing to post. §1 would
  -- catch this anyway; saying so here keeps the intent readable.
  if v_new_tour is null then
    return null;
  end if;

  perform public.finance_post_delta(
    v_new_tour, 'owner_rent', v_old, v_new,
    'expense.rent',  v_row.id, null,
    'payable.owner', v_row.id, null,
    'buses', v_row.id, 'rent', 'owner rent');

  return null;
end $$;

-- The trigger itself is unchanged — `create or replace function` swaps the body
-- under the existing `buses_ledger_sync`, so nothing needs re-attaching.


-- ── 3. What the guard skipped ────────────────────────────────
-- Rent parked on buses that belong to no trip. Expected to be non-empty on any
-- database where a tour has been deleted; it is a fleet inventory, not an error.
-- Assigning one of these to a tour posts its rent there, via §2.
create or replace function public.finance_unassigned_bus_rent()
returns table (bus_id uuid, bus_name text, rent numeric)
language sql stable security definer set search_path = public
as $$
  select b.id, b.name, b.bus_price
    from public.buses b
   where b.tour_id is null
     and b.deleted_at is null
     and coalesce(b.bus_price, 0) > 0
   order by b.bus_price desc;
$$;

revoke all on function public.finance_unassigned_bus_rent() from public;
grant execute on function public.finance_unassigned_bus_rent() to authenticated;


-- ============================================================
-- AFTER APPLYING
--
--   1. See the rent that belongs to no trip — this is what the backfill skips:
--        select * from public.finance_unassigned_bus_rent();
--
--   2. The backfill now completes:
--        select * from public.backfill_finance_ledger();
--
--   3. Prove rent follows a bus. Moving it must move the cost, even though the
--      price never changes:
--        select coalesce(sum(l.amount_minor),0) from public.finance_lines l
--          join public.finance_entries e on e.id = l.entry_id
--         where l.bus_id = '<bus>' and l.account_code = 'expense.rent'
--           and e.tour_id = '<tour A>';        -- note this figure
--        update public.buses set tour_id = '<tour B>' where id = '<bus>';
--        -- re-run for tour A: now 0. Re-run for tour B: now the full rent.
--
--   4. Check 6 in supabase/diagnostics/finance_audit_checks.sql must return
--      zero rows, with no allowance needed: it INNER JOINs `tours`, so a bus on
--      no tour is already outside it. The step-1 list and check 6 are disjoint
--      by construction — nothing appears in both.
-- ============================================================
