-- ============================================================
-- 073_confirm_claim_finalizes_hold.sql
-- ------------------------------------------------------------
-- A customer pays a UPI advance against a seat hold, the organiser confirms
-- the claim — and nobody is booked. The money is recorded, the claim leaves the
-- pending list, the 5-minute hold lapses, and the seats go back on sale.
--
-- HOW IT HAPPENED
-- 064 §7 taught confirm_payment_claim to finalize the linked hold BEFORE
-- posting money, precisely so that `passenger_id` exists by the time the seat
-- loop runs:
--
--     -- Finalize linked hold BEFORE posting money so passenger_id exists
--     if c.seat_hold_id is not null and c.passenger_id is null then
--       select chart_finalize_hold(c.seat_hold_id) into v_fin;
--       select * into c from public.payment_claims where id = p_claim_id;
--     end if;
--
-- 069 rewrote the same function to stop double-posting online money. Its header
-- says the body is "identical to 060's version except…" — and that is the bug:
-- it was rebased off 060, which predates 064. The finalize block was never in
-- 060, so it silently vanished. `grep chart_finalize 069` returns nothing.
--
-- WHAT THE USER SEES
-- With `c.passenger_id` null the whole seat loop is skipped: no passenger row,
-- no collections row. The full amount falls through to the `v_remaining > 0`
-- branch and posts as an unattached `ar.rider` remainder. The claim flips to
-- 'confirmed' and disappears. The hold then expires on its 5-minute timer and
-- the berths are resold. The customer has paid, the organiser believes it is
-- settled, and the seats belong to someone else.
--
-- This is the only in-app path from a paid advance to a seat.
--
-- THE FIX
-- Restore the finalize step, with two corrections to the 064 original:
--
--   1. PARTY HOLDS. 068 added multi-bus parties and wrote
--      chart_finalize_party_holds() to finalize every sibling hold together.
--      Nothing ever called it (zero callers repo-wide). A split party confirmed
--      through the 064 block would finalize only the hold the claim names and
--      let the other buses' holds lapse. Here, a hold carrying a party_id goes
--      through the party function.
--
--   2. A LAPSED HOLD IS AN EXPLICIT REFUSAL, NOT A SHRUG. 064 wrapped the call
--      in `exception when others then raise`, which is a no-op. If the hold has
--      already expired the seats may well have been resold, so finalizing is
--      not safe and neither is continuing. We refuse with a message that names
--      the situation and leaves the claim PENDING — the organiser keeps it in
--      their list and can re-seat or refund deliberately. Loudly stuck beats
--      silently lost.
--
-- Everything else is 069's body verbatim: the per-seat apply loop, the
-- amount_online split, the unattached remainder, the status update.
--
-- NOTE ON THE REMAINING HALF OF THIS BUG
-- Recording a UPI advance does not extend the 5-minute hold (defect #6 in the
-- 2026-08-10 defect register). Until that is fixed, a customer who pays slowly
-- still loses the hold — the difference is that this migration turns that into
-- a visible refusal instead of a silent loss. Fix #6 next.
--
-- Requires 064, 068, 069. Idempotent, re-runnable, changes no data.
-- ============================================================

-- to_regPROCEDURE, not to_regproc: `regproc` accepts a bare function NAME and
-- cannot parse an argument list, so to_regproc('f(uuid)') is always null and
-- the guard would fire on a perfectly healthy database. `regprocedure` is the
-- one that takes a full signature.
do $$
begin
  if to_regprocedure('public.chart_finalize_hold(uuid)') is null then
    raise exception '073 requires 064_seat_holds_chart_finalize.sql first';
  end if;
  if to_regprocedure('public.chart_finalize_party_holds(uuid)') is null then
    raise exception '073 requires 068_multi_bus_chart_claim.sql first';
  end if;
  if to_regprocedure('public.confirm_payment_claim(uuid, text)') is null then
    raise exception '073 requires 069_online_payment_single_post.sql first';
  end if;
end $$;


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
  v_hold       record;
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

  -- ── Restored from 064 §7 ───────────────────────────────────
  -- Finalize the linked hold BEFORE posting money, so passenger_id exists by
  -- the time the seat loop below runs. Without this the loop is skipped
  -- entirely and the payment lands on nobody.
  if c.seat_hold_id is not null and c.passenger_id is null then
    select h.id, h.party_id, h.status, h.expires_at
      into v_hold
      from public.seat_holds h
     where h.id = c.seat_hold_id
     for update;

    if not found then
      raise exception
        'the seat hold for this payment no longer exists; re-seat the rider '
        'manually or refund the advance'
        using errcode = 'check_violation';
    end if;

    -- Refuse rather than guess. An expired hold's berths may already be sold
    -- to someone else, so finalizing could double-sell them — and continuing
    -- would post the money against no seats at all, which is the bug this
    -- migration exists to fix. Raising leaves the claim 'pending' and visible.
    if v_hold.status <> 'pending' or v_hold.expires_at <= now() then
      raise exception
        'the seat hold for this payment lapsed at %; the berths may have been '
        'resold. Re-seat the rider manually or refund the advance, then reject '
        'this claim', v_hold.expires_at
        using errcode = 'check_violation';
    end if;

    -- A split party holds one set of berths per bus. Finalizing only the hold
    -- the claim happens to name would let the siblings lapse, stranding the
    -- rest of the group. chart_finalize_party_holds had no callers before this.
    if v_hold.party_id is not null then
      perform public.chart_finalize_party_holds(v_hold.party_id);
    else
      perform public.chart_finalize_hold(v_hold.id);
    end if;

    -- Re-read: finalizing stamps passenger_id onto the claim.
    select * into c from public.payment_claims where id = p_claim_id;
    if c.passenger_id is null then
      raise exception
        'seat hold % finalized but the claim still has no passenger; refusing '
        'to post money against no seats', c.seat_hold_id
        using errcode = 'check_violation';
    end if;
  end if;
  -- ── end restored block ─────────────────────────────────────

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


-- ============================================================
-- VERIFY
--
-- 1. The finalize step is back (this returned 0 before 073):
--      select count(*) from pg_proc
--       where proname = 'confirm_payment_claim'
--         and prosrc like '%chart_finalize%';     -- expect 1
--
-- 2. The party path is reachable — chart_finalize_party_holds had no callers
--    anywhere before this file:
--      select count(*) from pg_proc
--       where proname = 'confirm_payment_claim'
--         and prosrc like '%chart_finalize_party_holds%';  -- expect 1
--
-- 3. End to end, on a scratch tour: create a hold, record a UPI claim against
--    it, confirm it, then assert the rider actually exists and holds the seats:
--      select p.id, p.assigned_seats
--        from public.passengers p
--        join public.payment_claims c on c.passenger_id = p.id
--       where c.id = '<claim id>';                -- expect one row, seats set
--      select amount_online from public.collections
--       where passenger_id = (select passenger_id
--                               from public.payment_claims where id='<claim id>');
--                                                 -- expect the advance, not 0
--
-- 4. The lapsed-hold path refuses instead of losing the money. Expire the hold
--    (update seat_holds set expires_at = now() - interval '1 minute'), then:
--      select public.confirm_payment_claim('<claim id>');
--    expect: "the seat hold for this payment lapsed at …", and afterwards
--      select status from public.payment_claims where id = '<claim id>';
--                                                 -- expect 'pending', NOT 'confirmed'
-- ============================================================
