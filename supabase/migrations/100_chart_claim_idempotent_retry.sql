-- ============================================================
-- 100  Chart claim — a retried claim that already landed is a success
-- ------------------------------------------------------------
-- On 2G a seat claim can COMMIT on the server and still time out on the
-- rider's phone. The app now re-sends the SAME request / party ids when the
-- rider retries the same checkout (seat_booking_confirm_screen.dart,
-- `claimIdsFor`). But the claim RPCs could not tell "these seats are taken by
-- someone else" from "these seats are taken by the claim you already made":
-- the retry re-validated the seats, found them occupied by its own passenger
-- row, and answered `conflicts` — the rider was told "seats taken" for seats
-- that were theirs, and the phone never saved the ticket.
--
-- Each RPC is now a thin wrapper that, under the SAME per-tour advisory lock
-- the claim takes, first asks "did this exact request/party already land for
-- this phone?" and, if so, answers the original success shape plus
-- `already: true`. Otherwise it delegates to the unchanged claim body.
--
-- The bodies are NOT reproduced here. Migration files are not authoritative
-- for this schema (see 045/031), so the LIVE function is renamed to
-- `<name>_core` and the wrapper takes its name and signature. Every client
-- keeps calling the same RPC with the same params; nothing changes for a
-- first attempt. The lock is transaction-scoped and re-entrant, so the core
-- re-taking it is a no-op.
--
--   chart_claim_seats        → chart_claim_seats_core        (+ wrapper)
--   chart_claim_seats_multi  → chart_claim_seats_multi_core  (+ wrapper)
--   chart_hold_seats_multi   → chart_hold_seats_multi_core   (+ wrapper)
--
-- chart_hold_seats (single bus) is untouched: it is already idempotent on
-- `request_id` for a pending, unexpired hold.
--
-- The `_core` functions lose their anon/authenticated grants — the wrappers
-- are SECURITY DEFINER and call them as owner, so nothing can bypass the
-- check by calling the core directly.
--
-- !! A later `create or replace function public.chart_claim_seats(...)` would
-- !! replace the WRAPPER, not the body. Change the body via `<name>_core`.
--
-- Safe to re-run: the renames are skipped once the `_core` already exists.
-- NOT DEPLOYED with the client change — dry-run against a live schema dump
-- first, then apply.
-- ============================================================

do $$
begin
  if to_regprocedure('public.chart_claim_seats_core(uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text)') is null then
    alter function public.chart_claim_seats(
      uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
    ) rename to chart_claim_seats_core;
  end if;

  if to_regprocedure('public.chart_claim_seats_multi_core(uuid, uuid, text, text, text, jsonb, text, text, uuid, text)') is null then
    alter function public.chart_claim_seats_multi(
      uuid, uuid, text, text, text, jsonb, text, text, uuid, text
    ) rename to chart_claim_seats_multi_core;
  end if;

  if to_regprocedure('public.chart_hold_seats_multi_core(uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text)') is null then
    alter function public.chart_hold_seats_multi(
      uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
    ) rename to chart_hold_seats_multi_core;
  end if;
end;
$$;

revoke all on function public.chart_claim_seats_core(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public, anon, authenticated;
revoke all on function public.chart_claim_seats_multi_core(
  uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public, anon, authenticated;
revoke all on function public.chart_hold_seats_multi_core(
  uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
) from public, anon, authenticated;


-- ── 1. Single-bus claim ───────────────────────────────────────

create or replace function public.chart_claim_seats(
  p_request_id           uuid,
  p_tour_id              uuid,
  p_bus_id               uuid,
  p_phone                text,
  p_name                 text,
  p_leg                  text,
  p_seats                jsonb,
  p_gender               text default null,
  p_note                 text default null,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_landed record;
begin
  -- The claim's own lock, taken BEFORE the check, so two copies of the same
  -- retry cannot both miss it and the second be refused by the first.
  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  select br.passenger_id, br.party_size
    into v_landed
    from public.booking_requests br
   where br.id = p_request_id
     and br.tour_id = p_tour_id
     and br.customer_phone = p_phone
   limit 1;

  if found then
    return jsonb_build_object(
      'ok',           true,
      'already',      true,
      'request_id',   p_request_id,
      'passenger_id', v_landed.passenger_id,
      'berths',       v_landed.party_size
    );
  end if;

  return public.chart_claim_seats_core(
    p_request_id, p_tour_id, p_bus_id, p_phone, p_name, p_leg, p_seats,
    p_gender, p_note, p_pickup_location_id, p_pickup_location_name
  );
end;
$$;

revoke all on function public.chart_claim_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public;
grant execute on function public.chart_claim_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) to anon, authenticated;


-- ── 2. Multi-bus claim ────────────────────────────────────────

create or replace function public.chart_claim_seats_multi(
  p_party_id             uuid,
  p_tour_id              uuid,
  p_phone                text,
  p_name                 text,
  p_leg                  text,
  p_buses                jsonb,
  p_gender               text default null,
  p_note                 text default null,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_bookings jsonb;
  v_berths   int;
begin
  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  -- The party is all-or-nothing (one transaction), so ANY landed row means
  -- the whole party landed.
  select
      jsonb_agg(jsonb_build_object(
        'bus_id',       br.raw_form->>'bus_id',
        'request_id',   br.id::text,
        'passenger_id', br.passenger_id::text,
        'berths',       br.party_size
      )),
      sum(br.party_size)::int
    into v_bookings, v_berths
    from public.booking_requests br
   where br.party_id = p_party_id
     and br.tour_id = p_tour_id
     and br.customer_phone = p_phone;

  if v_bookings is not null then
    return jsonb_build_object(
      'ok',       true,
      'already',  true,
      'party_id', p_party_id,
      'bookings', v_bookings,
      'berths',   v_berths
    );
  end if;

  return public.chart_claim_seats_multi_core(
    p_party_id, p_tour_id, p_phone, p_name, p_leg, p_buses,
    p_gender, p_note, p_pickup_location_id, p_pickup_location_name
  );
end;
$$;

revoke all on function public.chart_claim_seats_multi(
  uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public;
grant execute on function public.chart_claim_seats_multi(
  uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) to anon, authenticated;


-- ── 3. Multi-bus hold ─────────────────────────────────────────

create or replace function public.chart_hold_seats_multi(
  p_party_id             uuid,
  p_tour_id              uuid,
  p_phone                text,
  p_name                 text,
  p_leg                  text,
  p_buses                jsonb,
  p_ttl_seconds          int default 300,
  p_gender               text default null,
  p_note                 text default null,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_holds   jsonb;
  v_expires timestamptz;
  v_berths  int;
begin
  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  -- Only a hold that is still live counts: an expired or finalized party is
  -- not "your seats", and falls through to a fresh validation.
  select
      jsonb_agg(jsonb_build_object(
        'hold_id',    h.id::text,
        'bus_id',     h.bus_id::text,
        'request_id', h.request_id::text
      )),
      max(h.expires_at)
    into v_holds, v_expires
    from public.seat_holds h
   where h.party_id = p_party_id
     and h.tour_id = p_tour_id
     and h.phone = p_phone
     and h.status = 'pending'
     and h.expires_at > now();

  if v_holds is not null then
    -- Same berth count the core reports: berths, not cells, of the request.
    select coalesce(sum(coalesce((c->>'berths')::int, 1)), 0)
      into v_berths
      from jsonb_array_elements(p_buses) b
      cross join lateral jsonb_array_elements(b->'seats') c;

    return jsonb_build_object(
      'ok',         true,
      'already',    true,
      'party_id',   p_party_id,
      'holds',      v_holds,
      'expires_at', v_expires,
      'berths',     v_berths
    );
  end if;

  return public.chart_hold_seats_multi_core(
    p_party_id, p_tour_id, p_phone, p_name, p_leg, p_buses, p_ttl_seconds,
    p_gender, p_note, p_pickup_location_id, p_pickup_location_name
  );
end;
$$;

revoke all on function public.chart_hold_seats_multi(
  uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
) from public;
grant execute on function public.chart_hold_seats_multi(
  uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
) to anon, authenticated;
