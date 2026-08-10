-- ============================================================
-- 074_claimed_hold_survives_verification.sql
-- ------------------------------------------------------------
-- The other half of the bug 073 fixed.
--
-- A chart hold lives 5 minutes. That budget was sized for "pick seats and
-- confirm" — it was never sized for "pick seats, switch to a UPI app, pay,
-- come back, record the reference, and then wait for a human organiser to
-- eyeball that reference and press Confirm."
--
-- `claim_upi_advance_for_hold` (064 §8) CHECKS that the hold is still pending
-- and unexpired, records the claim, links it both ways — and never touches
-- `expires_at`. So the clock keeps running from the original hold. By the time
-- the organiser gets to the claim the hold has almost always lapsed, the sweep
-- has flipped it to 'expired', and the berths are back on sale.
--
-- Before 073 that produced a silent loss: the claim confirmed, the money posted
-- against nobody, the seats went to someone else. 073 turned it into a visible
-- refusal. 074 stops it happening at all.
--
-- THREE CHANGES, and the second and third exist because of the first.
--
--   1. A CLAIMED HOLD GETS A VERIFICATION TTL. Recording a claim extends the
--      hold to now() + 24h. Money has allegedly changed hands, so the berths
--      stop being speculative and start being a human's decision. 24h is long
--      enough for an organiser who is asleep, driving, or on a bus, and short
--      enough that an abandoned claim cannot squat seats indefinitely.
--
--   2. REJECTING A CLAIM RELEASES THE HOLD. Today reject_payment_claim only
--      stamps the claim. That was harmless when the hold expired 5 minutes
--      later on its own; with a 24h TTL it would leave the berths dead for a
--      day after the organiser has already said no. Rejecting now marks the
--      hold 'released' — the answer is no, so the seats go back immediately.
--
--   3. THE HOLD PATH GETS THE RATE LIMIT THE BOOKING PATH ALREADY HAS.
--      claim_upi_advance (060 §2) caps a booking at 5 claims per 10 minutes.
--      claim_upi_advance_for_hold has no limit at all, and it is granted to
--      `anon`. Without a cap, change 1 turns "claim anything" into "hold any
--      seats for a day, for free, repeatedly". Same cap, keyed by hold.
--
-- PARTY HOLDS. A split party holds one set of berths per bus, and the claim
-- names only one of them. Extending just that one would let the siblings lapse
-- and strand the rest of the group — the same shape of bug 073 fixed for
-- finalization. Both the extend and the release cover the whole party.
--
-- Requires 060, 064, 068. Idempotent, re-runnable. Changes no existing data.
-- ============================================================

do $$
begin
  if to_regprocedure('public.claim_upi_advance_for_hold(uuid, bigint, text)')
       is null then
    raise exception '074 requires 064_seat_holds_chart_finalize.sql first';
  end if;
  if to_regprocedure('public.reject_payment_claim(uuid, text)') is null then
    raise exception '074 requires 060_upi_advance_claims.sql first';
  end if;
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'seat_holds'
       and column_name = 'party_id'
  ) then
    raise exception '074 requires 068_multi_bus_chart_claim.sql first';
  end if;
end $$;


-- ── 1. Recording a claim buys the hold time to be verified ───
create or replace function public.claim_upi_advance_for_hold(
  p_hold_id      uuid,
  p_amount_paise bigint,
  p_upi_ref      text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  h        record;
  v_id     uuid;
  v_recent int;
  -- How long a claimed hold survives while a human verifies the reference.
  -- Named so the trade-off is visible: too short loses paying customers, too
  -- long squats berths after an abandoned claim.
  c_verify_ttl constant interval := interval '24 hours';
begin
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'claim amount must be positive';
  end if;
  if p_amount_paise > 100000000 then
    raise exception 'claim amount is implausibly large';
  end if;

  -- Locked: a concurrent expiry sweep must not flip this row between the check
  -- below and the extension at the end.
  select * into h from public.seat_holds where id = p_hold_id for update;
  if not found then
    raise exception 'unknown hold';
  end if;
  if h.status <> 'pending' or h.expires_at <= now() then
    raise exception 'hold expired or missing' using errcode = 'check_violation';
  end if;

  -- The cap claim_upi_advance has had since 060 and this path never did —
  -- load-bearing now that a claim extends the hold to a full day.
  select count(*) into v_recent
    from public.payment_claims
   where seat_hold_id = p_hold_id
     and claimed_at > now() - interval '10 minutes';
  if v_recent >= 5 then
    raise exception 'too many payment claims for this hold; please wait';
  end if;

  insert into public.payment_claims (
    tour_id, booking_request_id, passenger_id,
    amount_paise, upi_ref, payer_name, payer_phone, seat_hold_id
  ) values (
    h.tour_id, null, null,
    p_amount_paise, nullif(btrim(coalesce(p_upi_ref, '')), ''),
    h.name, h.phone, h.id
  )
  returning id into v_id;

  -- Extend the WHOLE party, not just the hold the claim names. Never shorten:
  -- greatest() means a re-claim on an already-extended hold cannot pull the
  -- deadline back in.
  update public.seat_holds
     set payment_claim_id = case when id = h.id then v_id else payment_claim_id end,
         expires_at       = greatest(expires_at, now() + c_verify_ttl),
         updated_at       = now()
   where status = 'pending'
     and (
       id = h.id
       or (h.party_id is not null and party_id = h.party_id)
     );

  return v_id;
end $$;

revoke all on function public.claim_upi_advance_for_hold(uuid, bigint, text) from public;
grant execute on function public.claim_upi_advance_for_hold(uuid, bigint, text)
  to anon, authenticated;


-- ── 2. "No" means the berths go back now ─────────────────────
create or replace function public.reject_payment_claim(
  p_claim_id uuid,
  p_reason   text
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  c      record;
  v_hold record;
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
    raise exception 'claim was already confirmed; reverse it in the ledger instead';
  end if;

  update public.payment_claims
     set status = 'rejected',
         reviewed_at = now(),
         reviewed_by = auth.uid(),
         review_note = coalesce(nullif(btrim(p_reason), ''), 'rejected'),
         updated_at = now()
   where id = p_claim_id;

  -- Release the berths the rejected claim was holding. Without this, §1's 24h
  -- verification TTL would keep them dead for a day after the organiser has
  -- already decided. Only 'pending' holds are touched — a finalized hold is a
  -- real booking and is none of this function's business.
  if c.seat_hold_id is not null then
    select id, party_id into v_hold
      from public.seat_holds
     where id = c.seat_hold_id
     for update;

    if found then
      update public.seat_holds
         set status = 'released', updated_at = now()
       where status = 'pending'
         and (
           id = v_hold.id
           or (v_hold.party_id is not null and party_id = v_hold.party_id)
         );
    end if;
  end if;
end $$;

revoke all on function public.reject_payment_claim(uuid, text) from public;
grant execute on function public.reject_payment_claim(uuid, text) to authenticated;


-- ============================================================
-- VERIFY
--
-- 1. A claim now buys the hold a day (this was ~5 minutes before 074):
--      select h.expires_at - now() as remaining
--        from public.seat_holds h
--       where h.id = '<hold id>';        -- expect ~24h after claiming
--
-- 2. The whole party moved, not just the claimed hold:
--      select id, expires_at from public.seat_holds
--       where party_id = '<party id>';   -- expect every pending row extended
--
-- 3. Rejecting hands the berths back immediately:
--      select public.reject_payment_claim('<claim id>', 'no payment found');
--      select status from public.seat_holds where id = '<hold id>';
--                                        -- expect 'released', not 'pending'
--
-- 4. The rate limit bites on the sixth claim inside ten minutes:
--      -- repeat 6x
--      select public.claim_upi_advance_for_hold('<hold id>', 100, 'ref');
--      -- expect: "too many payment claims for this hold; please wait"
--
-- 5. Re-claiming cannot SHORTEN an already-extended hold:
--      -- claim, note expires_at, claim again, compare
--                                        -- expect the later value to be >= the first
-- ============================================================
