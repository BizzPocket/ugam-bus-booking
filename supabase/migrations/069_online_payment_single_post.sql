-- ============================================================
-- 069_online_payment_single_post.sql
-- ------------------------------------------------------------
-- Fixes finding C1 (and H1) from docs/2026-08-09-money-ledger-audit.md.
--
-- THE BUG
-- `confirm_payment_claim` (060) posts an `online_payment` entry AND writes a
-- legacy `collections` row. Since 062 went live, that row's own trigger posts a
-- SECOND credit to the same `ar.rider`. Every confirmed online advance of ₹X:
--   * understates what the rider owes by ₹X — the handler is told to collect
--     ₹X less than the rider actually owes;
--   * inflates `cash.handler` by ₹X — the handler is asked to hand over money
--     that went to a bank account.
--
-- THE FIX — one poster, correct accounts.
-- The collections trigger becomes the SINGLE poster for anything that reaches a
-- collection row, and learns to split that row between the bank and the
-- handler's pocket via a new `collections.amount_online` column. 060 stops
-- hand-rolling its own entry for money it also writes to a row, and instead
-- posts ONLY the remainder it could not apply to a seat (an unattached claim,
-- or an advance larger than the rider's total fare) — which no trigger will
-- ever see, so nothing is lost and nothing is counted twice.
--
-- Also folded in: H1, the empty reversal branch in 058's fare loop.
--
-- REPAIR of money already double-posted is a SEPARATE, explicit call —
-- `select * from public.finance_repair_online_double_post();` reports, and
-- `select * from public.finance_repair_online_double_post(true);` applies.
-- Nothing here rewrites history on its own.
--
-- REQUIRES 060 + 062 to be live (the guard below enforces it). Must be applied
-- BEFORE 070_one_fare_formula.sql, whose unified fare the repair paths price
-- against. Idempotent and re-runnable.
-- ============================================================

do $$
begin
  if to_regclass('public.payment_claims') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'finance_post_delta') then
    raise exception '069 requires 060 and 062 to be applied first';
  end if;
end $$;


-- ── 1. How much of a collection row came from a bank, not a pocket ──
-- Additive and defaulted, so every existing row keeps today's meaning ("all of
-- it was cash") and no client needs to know the column exists. `Collection`'s
-- Dart `toMap()` omits it, and PostgREST PATCH leaves absent columns alone, so
-- an ordinary app edit can never clobber it.
alter table public.collections
  add column if not exists amount_online numeric(10, 2) not null default 0;

comment on column public.collections.amount_online is
  'Portion of amount_received that arrived online (UPI/gateway) rather than as '
  'cash in the handler''s hand. Drives the bank-vs-cash split in the ledger.';


-- ── 2. The collections trigger splits bank money from pocket money ──
-- Was: the whole of `amount_received` debited `cash.handler`.
-- Now: the online slice debits `bank.gateway`, the rest debits `cash.handler`.
--
-- Both slices credit `ar.rider`, so a rider's balance is identical either way —
-- what changes is WHERE the app thinks the money is, which is what drives the
-- handover expectation.
create or replace function public.finance_sync_collection() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old_recv   bigint := 0;
  v_old_refd   bigint := 0;
  v_new_recv   bigint := 0;
  v_new_refd   bigint := 0;
  v_old_online bigint := 0;
  v_new_online bigint := 0;
  v_row        record;
begin
  v_row := coalesce(new, old);

  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old_recv := round(old.amount_received * 100)::bigint;
    v_old_refd := round(old.amount_refunded * 100)::bigint;
    -- Clamped: an edit that lowers `amount_received` below the online slice
    -- (a correction) must never manufacture a negative cash slice.
    v_old_online := least(
      round(coalesce(old.amount_online, 0) * 100)::bigint,
      v_old_recv);
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new_recv := round(new.amount_received * 100)::bigint;
    v_new_refd := round(new.amount_refunded * 100)::bigint;
    v_new_online := least(
      round(coalesce(new.amount_online, 0) * 100)::bigint,
      v_new_recv);
  end if;

  -- Money that landed in the gateway / bank.
  perform public.finance_post_delta(
    v_row.tour_id, 'online_payment', v_old_online, v_new_online,
    'bank.gateway', null,         null,
    'ar.rider',     null,         v_row.passenger_id,
    'collections', v_row.id, 'online', v_row.note);

  -- Money that landed in the handler's hand.
  perform public.finance_post_delta(
    v_row.tour_id, 'cash_receipt',
    v_old_recv - v_old_online, v_new_recv - v_new_online,
    'cash.handler', v_row.bus_id, null,
    'ar.rider',     null,         v_row.passenger_id,
    'collections', v_row.id, null, v_row.note);

  -- A refund is cash physically handed back on the bus, so it stays against the
  -- handler regardless of how the money originally arrived.
  perform public.finance_post_delta(
    v_row.tour_id, 'refund', v_old_refd, v_new_refd,
    'ar.rider',     null,         v_row.passenger_id,
    'cash.handler', v_row.bus_id, null,
    'collections', v_row.id, null, v_row.note);

  return null;
end $$;


-- ── 3. `confirm_payment_claim` stops posting what the trigger will post ──
-- Identical to 060's version except:
--   * the collection rows it writes now carry `amount_online`, so §2 books them
--     against the bank;
--   * the hand-rolled ledger entry covers ONLY the remainder that reached no
--     collection row (an unattached claim, or an advance exceeding the rider's
--     whole fare). That money is invisible to every trigger, so posting it here
--     is the only way it is recorded — and it can never be double-counted.
create or replace function public.confirm_payment_claim(
  p_claim_id uuid,
  p_note     text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  c            record;
  v_entry      uuid;
  v_remaining  bigint;
  v_seat       record;
  v_due        bigint;
  v_apply      bigint;
begin
  select * into c from public.payment_claims where id = p_claim_id;
  if not found then
    raise exception 'unknown payment claim';
  end if;

  if not exists (
    select 1 from public.tours t
     where t.id = c.tour_id and t.owner_id = auth.uid()
  ) then
    raise exception 'not authorized for this tour';
  end if;

  if c.status = 'confirmed' then
    return c.finance_entry_id;        -- idempotent
  end if;
  if c.status = 'rejected' then
    raise exception 'claim was already rejected';
  end if;

  perform public.finance_set_actor('admin', 'advance confirmation');

  -- Apply the advance across the rider's seats, cheapest bookkeeping first.
  -- Each row written here fires finance_sync_collection, which books the
  -- `amount_online` slice to bank.gateway. No entry is posted from this
  -- function for any rupee that lands on a row.
  v_remaining := c.amount_paise;
  if c.passenger_id is not null then
    for v_seat in
      select distinct
             (s->>'busId')::uuid              as bus_id,
             split_part(s->>'seatId','#',1)   as seat_id
        from public.passengers p
        cross join lateral jsonb_array_elements(
          coalesce(p.assigned_seats,'[]'::jsonb)) s
       where p.id = c.passenger_id
         and coalesce(s->>'busId','') <> ''
       order by 1, 2
    loop
      exit when v_remaining <= 0;
      v_due  := public.baseline_seat_due_paise(
                  c.passenger_id, v_seat.bus_id, v_seat.seat_id);
      v_apply := least(v_remaining, greatest(v_due, 0));
      if v_apply > 0 then
        insert into public.collections (
          tour_id, bus_id, passenger_id, seat_id,
          amount_due, amount_received, amount_online, amount_refunded,
          note, collected_by
        )
        values (
          c.tour_id, v_seat.bus_id, c.passenger_id, v_seat.seat_id,
          v_due / 100.0, v_apply / 100.0, v_apply / 100.0, 0,
          'UPI advance' || case when c.upi_ref is null then ''
                                else ' ref ' || c.upi_ref end,
          'online'
        )
        on conflict (passenger_id, bus_id, seat_id) where deleted_at is null
        do update set
          amount_received = public.collections.amount_received
                            + excluded.amount_received,
          -- Tracked alongside, so a row holding BOTH the handler's cash and an
          -- online advance splits correctly instead of booking the whole lot to
          -- whichever account `collected_by` happens to name.
          amount_online   = public.collections.amount_online
                            + excluded.amount_online,
          note = case
                   when coalesce(btrim(public.collections.note), '') = ''
                     then excluded.note
                   else public.collections.note || ' · ' || excluded.note
                 end,
          updated_at = now();
        v_remaining := v_remaining - v_apply;
      end if;
    end loop;
  end if;

  -- Whatever reached no seat: an unattached claim, or an overpayment beyond the
  -- rider's whole fare. No collection row carries it, so no trigger will, and
  -- this is the only place it can be recorded.
  if v_remaining > 0 then
    select o_entry into v_entry from public.backfill_post(
      c.tour_id, 'online_payment', 'claim:' || c.id,
      c.claimed_at, v_remaining,
      'bank.gateway', null, null,
      'ar.rider',     null, c.passenger_id,
      'payment_claims', c.id, 'upi_advance',
      coalesce(p_note, 'UPI advance (unapplied remainder)' ||
        case when c.upi_ref is null then '' else ' ref ' || c.upi_ref end)
    );
  end if;

  update public.payment_claims
     set status = 'confirmed',
         reviewed_at = now(),
         reviewed_by = auth.uid(),
         review_note = p_note,
         finance_entry_id = v_entry,
         updated_at = now()
   where id = p_claim_id;

  return v_entry;
end $$;

revoke all on function public.confirm_payment_claim(uuid, text) from public;
grant execute on function public.confirm_payment_claim(uuid, text) to authenticated;


-- ── 4. Repair what was already double-posted ─────────────────
-- Reports by default; pass `true` to apply. For every confirmed claim that has
-- BOTH a hand-rolled `online_payment` entry AND collection rows the trigger
-- already posted as `cash_receipt`, it:
--   a. reverses the hand-rolled entry (the ledger is append-only — corrections
--      are reversals, never edits), and
--   b. stamps `amount_online` on the rider's online collection rows, which
--      makes §2 re-book that slice from `cash.handler` to `bank.gateway` on its
--      own, as an ordinary delta.
-- After (a) and (b) the rider is credited exactly once and the cash sits in the
-- right account.
create or replace function public.finance_repair_online_double_post(
  p_apply boolean default false
) returns table (
  claim_id       uuid,
  passenger_id   uuid,
  tour_id        uuid,
  rupees         numeric,
  action         text
)
language plpgsql security definer set search_path = public
as $$
declare
  r       record;
  c       record;
  v_rev   uuid;
  v_left  bigint;
  v_slice bigint;
begin
  for r in
    select pc.id as claim_id, pc.passenger_id, pc.tour_id,
           pc.amount_paise, e.id as hand_entry
      from public.payment_claims pc
      join public.finance_entries e
        on e.source_table = 'payment_claims' and e.source_row_id = pc.id
     where pc.status = 'confirmed'
       -- not already reversed by a previous run
       and not exists (select 1 from public.finance_entries rv
                        where rv.reverses_entry_id = e.id)
       -- and the trigger really did post the same money a second time
       and exists (
         select 1
           from public.collections c
           join public.finance_entries e2
             on e2.source_table = 'collections' and e2.source_row_id = c.id
          where c.passenger_id = pc.passenger_id
            and c.tour_id      = pc.tour_id
            and c.collected_by = 'online'
            and c.deleted_at is null
            and e2.kind = 'cash_receipt')
  loop
    claim_id     := r.claim_id;
    passenger_id := r.passenger_id;
    tour_id      := r.tour_id;
    rupees       := r.amount_paise / 100.0;

    if not p_apply then
      action := 'WOULD reverse hand-rolled entry + move slice to bank.gateway';
      return next;
      continue;
    end if;

    perform public.finance_set_actor('system', 'C1 repair');

    v_rev := public.backfill_reverse(
      r.hand_entry,
      'repair:c1:' || r.claim_id,
      'C1 repair: this advance was also posted by the collections trigger');

    -- Stamping the slice makes the trigger emit the two correcting deltas.
    -- The claim is walked across the rider's online rows in the same order
    -- 060 applied it, so a row that ALSO holds the handler's cash is only
    -- credited to the bank for the part the claim actually paid.
    v_left := r.amount_paise;
    for c in
      select id, amount_received
        from public.collections
       where passenger_id = r.passenger_id
         and tour_id      = r.tour_id
         and collected_by = 'online'
         and deleted_at is null
         and coalesce(amount_online, 0) = 0
       order by bus_id, seat_id
    loop
      exit when v_left <= 0;
      v_slice := least(v_left, round(c.amount_received * 100)::bigint);
      if v_slice > 0 then
        update public.collections
           set amount_online = v_slice / 100.0,
               updated_at    = now()
         where id = c.id;
        v_left := v_left - v_slice;
      end if;
    end loop;

    action := case when v_rev is null
                   then 'reversal already existed; slice moved to bank.gateway'
                   else 'reversed + slice moved to bank.gateway' end;
    return next;
  end loop;
end $$;

revoke all on function public.finance_repair_online_double_post(boolean) from public;
grant execute on function public.finance_repair_online_double_post(boolean) to authenticated;


-- ── 5. H1 · the backfill can now reverse a cancelled rider's fare ──
-- 058's fare loop filters cancelled/archived riders out of its SELECT and then
-- has an EMPTY `if v_entry is not null then … end if;` where every other
-- section calls `backfill_reverse`. A rider cancelled AFTER an earlier backfill
-- therefore keeps their `fare_charge` forever on a re-run — which is exactly
-- what you do to repair a stale ledger.
--
-- Rather than re-issue the whole of 058, this reverses those strays directly.
-- Safe to run any time; it only ever touches riders who are genuinely cancelled
-- or archived and still carry a live backfilled fare.
create or replace function public.finance_repair_cancelled_fares(
  p_apply boolean default false
) returns table (
  passenger_id uuid,
  tour_id      uuid,
  rupees       numeric,
  action       text
)
language plpgsql security definer set search_path = public
as $$
declare
  r     record;
  v_rev uuid;
begin
  for r in
    select p.id as pid, p.tour_id, e.id as entry_id,
           coalesce(-sum(l.amount_minor) filter
             (where l.account_code = 'revenue.fare'), 0) as fare_minor
      from public.passengers p
      join public.finance_entries e
        on e.source_table = 'passengers' and e.source_row_id = p.id
       and e.kind = 'fare_charge'
      join public.finance_lines l on l.entry_id = e.id
     where (p.cancelled_at is not null or p.deleted_at is not null)
       and not exists (select 1 from public.finance_entries rv
                        where rv.reverses_entry_id = e.id)
     group by p.id, p.tour_id, e.id
    having coalesce(-sum(l.amount_minor) filter
             (where l.account_code = 'revenue.fare'), 0) <> 0
  loop
    passenger_id := r.pid;
    tour_id      := r.tour_id;
    rupees       := r.fare_minor / 100.0;

    if not p_apply then
      action := 'WOULD reverse the fare of a cancelled/archived rider';
      return next;
      continue;
    end if;

    perform public.finance_set_actor('system', 'H1 repair');
    v_rev := public.backfill_reverse(
      r.entry_id,
      'repair:h1:' || r.entry_id,
      'H1 repair: rider is cancelled/archived and owes no fare');
    action := case when v_rev is null then 'already reversed' else 'reversed' end;
    return next;
  end loop;
end $$;

revoke all on function public.finance_repair_cancelled_fares(boolean) from public;
grant execute on function public.finance_repair_cancelled_fares(boolean) to authenticated;


-- ============================================================
-- AFTER APPLYING
--
--   1. See what is wrong, changing nothing:
--        select * from public.finance_repair_online_double_post();
--        select * from public.finance_repair_cancelled_fares();
--
--   2. Fix it:
--        select * from public.finance_repair_online_double_post(true);
--        select * from public.finance_repair_cancelled_fares(true);
--
--   3. Prove it: check 5 in supabase/diagnostics/finance_audit_checks.sql must
--      come back empty, and check 4's deltas must all be 0.
-- ============================================================
