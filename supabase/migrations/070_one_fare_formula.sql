-- ============================================================
-- 070_one_fare_formula.sql
-- ------------------------------------------------------------
-- Fixes findings D1–D4 from docs/2026-08-09-money-ledger-audit.md: the app, the
-- ledger and the online checkout each priced a seat with their OWN formula.
--
--   D1 · leg fallback. Dart resolves an unstamped berth's leg from the rider's
--        `request_lines` (`Passenger.legForSeatType`); both SQL functions fell
--        back to the stored `passengers.trip_type` column. A rider stored as
--        `roundTrip` whose lines are all one-way was charged HALF by the app and
--        FULL by the ledger — a 2x gap, visible forever as a phantom balance.
--   D2 · rounding. 049 rounded each BERTH, 053 rounded the per-SEAT total.
--   D3 · `#` suffix. 049 matched `seatId` raw, so a berth stored as `DL3#ret`
--        joined nothing and the customer was charged NOTHING for it.
--   D4 · berth cap. Dart caps berth-legs at `berthsPerUnit * 2`; neither SQL
--        function did, so a stray duplicate assignment row over-charged.
--
-- AFTER THIS FILE there is ONE implementation — `baseline_seat_due_paise` —
-- and `booking_amount_paise` is a thin caller of it. `Bus.amountDueForSeat` in
-- Dart remains the mirror; check 7 in supabase/diagnostics/finance_audit_checks.sql
-- proves the two agree on live data and must return zero rows.
--
-- Idempotent, re-runnable, read-path only: no table is touched and no entry is
-- posted. Existing ledger fares are re-reconciled by
-- `finance_resync_passenger_fare` the next time a rider's seating changes, or
-- immediately via `finance_resync_all_fares()` at the bottom.
--
-- REQUIRES 049 + 053 (the guard below enforces it), and must be applied AFTER
-- 069_online_payment_single_post.sql.
-- ============================================================

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'bus_berth_price_paise') then
    raise exception '070 requires 049_online_advance_payment.sql first';
  end if;
end $$;


-- ── 1. The coarse leg a rider's request lines collapse to ────
-- Transcribed from `Passenger.derivedTripType` (lib/models/passenger.dart:197):
--   no lines -> roundTrip · one distinct leg -> that leg · mixed -> roundTrip.
create or replace function public.passenger_derived_leg(p_passenger_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select case
           when count(*) = 0 then 'roundTrip'
           when count(distinct coalesce(nullif(l->>'leg', ''), 'roundTrip')) = 1
             then min(coalesce(nullif(l->>'leg', ''), 'roundTrip'))
           else 'roundTrip'
         end
    from public.passengers p
    cross join lateral jsonb_array_elements(
      coalesce(p.request_lines, '[]'::jsonb)) l
   where p.id = p_passenger_id;
$$;


-- ── 2. The leg to charge an UNSTAMPED berth of a given seat type ──
-- Transcribed from `Passenger.legForSeatType` (lib/models/passenger.dart:222):
--   * take the request lines of this seat TYPE;
--   * none -> the coarse derived leg (§1);
--   * if an EXACT position match exists among them, consider only those,
--     otherwise consider all lines of the type;
--   * all one leg -> that leg; mixed -> the HEAVIER leg
--     (roundTrip > outboundOnly > returnOnly).
--
-- The "heavier wins" tie-break is deliberate and must not be simplified: it is
-- what stops a mixed booking from being UNDER-charged.
create or replace function public.passenger_leg_for_seat_type(
  p_passenger_id uuid,
  p_seat_type    text,
  p_position     text default null
) returns text
language plpgsql stable security definer set search_path = public
as $$
declare
  v_legs text[];
begin
  -- Lines of this seat type, narrowed to an exact position match when one
  -- exists (mirrors `positionMatch.isNotEmpty ? positionMatch : typeLines`).
  select array_agg(leg) into v_legs from (
    select coalesce(nullif(l->>'leg', ''), 'roundTrip') as leg,
           (p_position is not null and l->>'position' = p_position) as exact
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.request_lines, '[]'::jsonb)) l
     where p.id = p_passenger_id
       and l->>'seatType' = p_seat_type
  ) t
  where t.exact or not exists (
    select 1
      from public.passengers p2
      cross join lateral jsonb_array_elements(
        coalesce(p2.request_lines, '[]'::jsonb)) l2
     where p2.id = p_passenger_id
       and l2->>'seatType' = p_seat_type
       and p_position is not null
       and l2->>'position' = p_position
  );

  if v_legs is null or array_length(v_legs, 1) is null then
    return public.passenger_derived_leg(p_passenger_id);
  end if;

  if 'roundTrip'    = any(v_legs) then return 'roundTrip';    end if;
  if 'outboundOnly' = any(v_legs) then return 'outboundOnly'; end if;
  return 'returnOnly';
end $$;


-- ── 3. The ONE per-seat fare ─────────────────────────────────
-- Replaces 053's version. Same shape, three corrections:
--   * the fallback leg is §2, not `passengers.trip_type`  (D1)
--   * berth-legs are capped at berthsPerUnit * 2           (D4)
--   * the per-seat total is rounded ONCE, as before        (D2 — the rule
--     049 must now adopt, see §4)
--
-- `p_seat_id` is the BASE seat id; anything after '#' is stripped by the
-- caller and again here, so a suffixed berth can never be silently dropped (D3).
create or replace function public.baseline_seat_due_paise(
  p_passenger_id uuid,
  p_bus_id       uuid,
  p_seat_id      text
) returns bigint
language plpgsql stable security definer set search_path = public
as $$
declare
  v_base      text := split_part(p_seat_id, '#', 1);
  v_type      text;
  v_position  text;
  v_row       int;
  v_price     bigint;
  v_coarse    text;
  v_cap       int;
  v_total     numeric := 0;
  v_n         int := 0;
  r           record;
begin
  select c->>'seatType', c->>'position', (c->>'row')::int
    into v_type, v_position, v_row
    from public.buses b
    cross join lateral jsonb_array_elements(
      coalesce(b.layout->'grid', '[]'::jsonb)) as c
   where b.id = p_bus_id
     and c->>'seatId' = v_base
   limit 1;

  if v_type is null then
    return 0;                       -- no such seat on this bus
  end if;

  v_price  := public.bus_berth_price_paise(p_bus_id, v_type, v_row);
  v_coarse := public.passenger_leg_for_seat_type(
                p_passenger_id, v_type, v_position);
  -- A seat can be held on BOTH legs, so a double sofa tops out at 4 berth-legs
  -- (2 berths x 2 legs) and everything else at 2. The cap only guards against
  -- stray duplicate assignment rows.
  v_cap := case when v_type = 'doubleSofa' then 4 else 2 end;

  for r in
    select coalesce(nullif(s->>'leg', ''), v_coarse) as leg
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)) with ordinality as t(s, ord)
     where p.id = p_passenger_id
       and s->>'busId' = p_bus_id::text
       and split_part(s->>'seatId', '#', 1) = v_base
     order by t.ord
  loop
    exit when v_n >= v_cap;
    v_total := v_total
             + (v_price / 100.0)
               * case when r.leg = 'roundTrip' then 1.0 else 0.5 end;
    v_n := v_n + 1;
  end loop;

  -- No assignment rows at all: price the seat once at its coarse leg, exactly
  -- as Dart's `berthLegs.isEmpty ? [coarseLeg] : …` does.
  if v_n = 0 then
    v_total := (v_price / 100.0)
               * case when v_coarse = 'roundTrip' then 1.0 else 0.5 end;
  end if;

  -- Round the per-SEAT total ONCE, then back to paise. Fractional inputs
  -- (one-leg 0.5, sofa/2) otherwise leave sub-rupee dues that never square
  -- against integer cash.
  return (round(v_total) * 100)::bigint;
end $$;

revoke all on function public.baseline_seat_due_paise(uuid, uuid, text) from public;
grant execute on function public.baseline_seat_due_paise(uuid, uuid, text)
  to anon, authenticated;


-- ── 4. The online checkout uses the SAME formula ─────────────
-- Was its own implementation: per-BERTH rounding (D2) and a raw `seatId` match
-- that dropped suffixed berths entirely (D3). Now it groups the booking's
-- berths into DISTINCT seats and asks §3 for each — so the amount a customer is
-- charged is, by construction, the amount the app shows and the ledger bills.
create or replace function public.booking_amount_paise(p_request_id uuid)
returns table (total_paise bigint, berths int)
language sql stable security definer set search_path = public
as $$
  with pax as (
    select p.id
      from public.booking_requests br
      join public.passengers p on p.id = br.passenger_id
     where br.id = p_request_id
       and p.cancelled_at is null
       and p.deleted_at is null
  ),
  berth as (
    select (s->>'busId')::uuid            as bus_id,
           split_part(s->>'seatId','#',1) as seat_id
      from pax
      join public.passengers p on p.id = pax.id
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)) as s
     where coalesce(s->>'busId','')  <> ''
       and coalesce(s->>'seatId','') <> ''
  ),
  -- One priced record per DISTINCT seat: baseline_seat_due_paise already sums
  -- every berth the rider holds on that seat, so pricing per berth here would
  -- charge a whole double sofa twice.
  seat as (
    select distinct bus_id, seat_id from berth
  )
  select coalesce(sum(
           public.baseline_seat_due_paise((select id from pax), bus_id, seat_id)
         ), 0)::bigint,
         (select count(*)::int from berth)
    from seat;
$$;

revoke all on function public.booking_amount_paise(uuid) from public;
grant execute on function public.booking_amount_paise(uuid) to anon, authenticated;


-- ── 5. Re-price what the old formula already posted ──────────
-- Fares in the ledger were charged by the OLD rule. `finance_resync_passenger_fare`
-- (062 §6) reconciles a rider to a TARGET rather than posting per change, so
-- simply calling it for everyone re-posts only the difference — one entry per
-- rider who was actually mispriced, and nothing at all for the rest.
create or replace function public.finance_resync_all_fares(
  p_tour_id uuid default null
) returns table (passengers_touched int)
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  perform public.finance_set_actor('system', '070 fare unification');
  for r in
    select p.id
      from public.passengers p
     where (p_tour_id is null or p.tour_id = p_tour_id)
       and p.deleted_at is null
  loop
    perform public.finance_resync_passenger_fare(r.id);
    n := n + 1;
  end loop;
  passengers_touched := n;
  return next;
end $$;

revoke all on function public.finance_resync_all_fares(uuid) from public;
grant execute on function public.finance_resync_all_fares(uuid) to authenticated;


-- ============================================================
-- AFTER APPLYING
--
--   1. Re-price the ledger against the unified formula:
--        select * from public.finance_resync_all_fares();
--      (or pass a tour id to do one trip at a time)
--
--   2. Prove app and ledger now agree — check 7 in
--      supabase/diagnostics/finance_audit_checks.sql must return ZERO rows.
--
--   3. Check 9 (riders whose trip_type contradicts their request lines) should
--      still list rows — that data is untidy either way — but they no longer
--      cause a pricing difference, which is the point.
-- ============================================================
