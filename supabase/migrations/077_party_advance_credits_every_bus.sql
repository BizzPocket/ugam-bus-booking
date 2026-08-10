-- ============================================================
-- 077_party_advance_credits_every_bus.sql
-- ------------------------------------------------------------
-- A group too big for one bus is split across buses. They pay ONE advance for
-- the whole party — and only the first bus's rider is credited with it.
--
-- HOW THE PIECES LINE UP
-- The client is right: seat_booking_confirm_screen puts the advance on the
-- first ticket only (`carriesAdvance: i == 0`), because quoting the full amount
-- on every per-bus ticket would show a split party "Pay ₹3,000" twice and
-- invite them to pay double. So one claim is recorded, against one hold.
--
-- 073 then finalizes the WHOLE party, which is correct — every bus's berths
-- become real. But chart_finalize_hold mints a SEPARATE passenger per hold
-- (064:446) and stamps the claim only:
--
--     update public.payment_claims set passenger_id = v_passenger_id
--      where seat_hold_id = h.id and passenger_id is null;
--
-- Only the claimed hold matches. The party's other passengers exist, hold
-- seats, and owe money — and the claim has never heard of them.
--
-- confirm_payment_claim then walks the seats of `c.passenger_id` alone. The
-- advance is applied against bus 1's berths; anything left over does not reach
-- bus 2's rider, it falls through to the `v_remaining > 0` branch and posts as
-- an unattached `ar.rider` remainder. Bus 2's rider shows as owing their whole
-- fare, and the handler asks them for money they have already paid.
--
-- THE FIX
-- Spend the advance across every passenger of the party, not just the claim's
-- own. The seat set becomes the union over all passengers finalized from holds
-- sharing this party_id, ordered so the spend is deterministic, and each
-- collections row is written against THE SEAT'S OWN passenger rather than the
-- claim's.
--
-- WHAT IS DELIBERATELY UNCHANGED
--   - The unattached remainder still books against `c.passenger_id`. Money that
--     reached no seat belongs to the payer of record, not to an arbitrary
--     sibling.
--   - A solo booking is unaffected: with no party_id the passenger set is
--     exactly {c.passenger_id} and the loop is identical to 073's.
--   - The 073 finalize block and the 069 amount_online split are carried
--     forward verbatim.
--
-- Requires 073 (and therefore 064, 068, 069). Idempotent. Changes no data.
-- ============================================================

do $$
begin
  if to_regprocedure('public.confirm_payment_claim(uuid, text)') is null then
    raise exception '077 requires 069/073 first';
  end if;
  if not exists (
    select 1 from pg_proc
     where proname = 'confirm_payment_claim'
       and prosrc like '%chart_finalize%'
  ) then
    raise exception
      '077 builds on 073''s finalize block, which is not present in the live '
      'confirm_payment_claim. Apply 073_confirm_claim_finalizes_hold.sql first.';
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
  v_party_id   uuid;
  v_pax        uuid[];
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

  -- ── From 073: finalize the linked hold before posting money ──
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

    if v_hold.status <> 'pending' or v_hold.expires_at <= now() then
      raise exception
        'the seat hold for this payment lapsed at %; the berths may have been '
        'resold. Re-seat the rider manually or refund the advance, then reject '
        'this claim', v_hold.expires_at
        using errcode = 'check_violation';
    end if;

    if v_hold.party_id is not null then
      perform public.chart_finalize_party_holds(v_hold.party_id);
    else
      perform public.chart_finalize_hold(v_hold.id);
    end if;

    select * into c from public.payment_claims where id = p_claim_id;
    if c.passenger_id is null then
      raise exception
        'seat hold % finalized but the claim still has no passenger; refusing '
        'to post money against no seats', c.seat_hold_id
        using errcode = 'check_violation';
    end if;
  end if;
  -- ── end 073 block ────────────────────────────────────────────

  if c.status = 'confirmed' then
    return c.finance_entry_id;        -- idempotent
  end if;
  if c.status = 'rejected' then
    raise exception 'claim was already rejected';
  end if;

  perform public.finance_set_actor('admin', 'advance confirmation');

  -- ── NEW IN 077: who this advance is allowed to pay for ───────
  -- One claim, one hold — but a split party has one passenger PER BUS, and
  -- only the claimed hold's passenger was ever stamped onto the claim. Spend
  -- across all of them or the siblings are billed for money already paid.
  if c.seat_hold_id is not null then
    select h.party_id into v_party_id
      from public.seat_holds h
     where h.id = c.seat_hold_id;
  end if;

  if v_party_id is not null then
    select coalesce(array_agg(distinct h.passenger_id), array[]::uuid[])
      into v_pax
      from public.seat_holds h
     where h.party_id = v_party_id
       and h.passenger_id is not null;
  end if;

  -- Solo booking, or a party whose holds carry no passenger yet: fall back to
  -- the claim's own rider. This makes the non-party path byte-identical to 073.
  if v_pax is null or cardinality(v_pax) = 0 then
    v_pax := array[c.passenger_id];
  elsif c.passenger_id is not null and not (c.passenger_id = any(v_pax)) then
    -- Defensive: the payer of record is always eligible, even if their hold
    -- lost its party link somehow.
    v_pax := v_pax || c.passenger_id;
  end if;

  v_remaining := c.amount_paise;
  if c.passenger_id is not null then
    for v_seat in
      select distinct
             pax.id                           as passenger_id,
             (s->>'busId')::uuid              as bus_id,
             split_part(s->>'seatId','#',1)   as seat_id
        from public.passengers pax
        cross join lateral jsonb_array_elements(
          coalesce(pax.assigned_seats,'[]'::jsonb)) s
       where pax.id = any(v_pax)
         and coalesce(s->>'busId','') <> ''
       -- Deterministic spend order. Without it, two confirmations of the same
       -- party could distribute an insufficient advance differently.
       order by 1, 2, 3
    loop
      exit when v_remaining <= 0;
      -- Per-SEAT owner, not the claim's passenger: on a split party these
      -- differ, and pricing a bus-2 seat against the bus-1 rider would be
      -- wrong twice over — wrong fare, and the row written to the wrong rider.
      v_due  := public.baseline_seat_due_paise(
                  v_seat.passenger_id, v_seat.bus_id, v_seat.seat_id);
      v_apply := least(v_remaining, greatest(v_due, 0));
      if v_apply > 0 then
        insert into public.collections (
          tour_id, bus_id, passenger_id, seat_id,
          amount_due, amount_received, amount_online, amount_refunded,
          note, collected_by
        )
        values (
          c.tour_id, v_seat.bus_id, v_seat.passenger_id, v_seat.seat_id,
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

  -- Whatever reached no seat stays with the payer of record.
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
-- 1. Both halves are present in the live body:
--      select prosrc like '%chart_finalize%'    as has_073_finalize,
--             prosrc like '%v_pax%'             as has_077_party_spend
--        from pg_proc where proname = 'confirm_payment_claim';
--                                             -- expect t, t
--
-- 2. On a SPLIT party: confirm one advance, then check every bus got credit.
--    Before 077 only the first bus had a collections row.
--      select col.bus_id, col.passenger_id, col.amount_online
--        from public.collections col
--       where col.passenger_id in (
--               select h.passenger_id from public.seat_holds h
--                where h.party_id = '<party id>' and h.passenger_id is not null)
--       order by col.bus_id;
--                                 -- expect one row per seat, across ALL buses
--
-- 3. Nothing vanished. The advance is fully accounted for:
--      select
--        (select coalesce(sum(amount_online * 100), 0)::bigint
--           from public.collections
--          where passenger_id in (
--                  select h.passenger_id from public.seat_holds h
--                   where h.party_id = '<party id>')) as applied_minor,
--        (select amount_paise from public.payment_claims
--          where id = '<claim id>')                   as claimed_minor;
--    applied_minor <= claimed_minor, and the difference must appear as the
--    ar.rider remainder entry — never disappear.
--
-- 4. A SOLO booking is unchanged. Confirm a single-bus claim and diff the
--    collections rows against a pre-077 run: they must be identical.
-- ============================================================
