-- ============================================================
-- 048  Customer seat-chart booking (per-tour mode + anon chart RPCs)
-- ------------------------------------------------------------
-- Lets a CUSTOMER pick their own seat off the bus chart, the way GSRTC /
-- redBus / every Gujarat operator app works, instead of sending a seat REQUEST
-- the organiser fulfils by hand. Selected per tour via `tours.booking_mode`,
-- so existing request-mode tours are completely untouched.
--
-- *** THE ONE INVARIANT ***
-- `passengers.assigned_seats` stays the SINGLE source of seat truth. There is
-- deliberately NO seat_holds / seat_claims table. The best-documented failure
-- in this market is two charts that disagree — a real 1-star review of a
-- Gujarat operator reads "their offline chart is different from the online one,
-- so you won't be getting the seats you selected". A customer chart fed by its
-- own table WOULD be that second chart. Everything below reads and writes the
-- same rows the seating engine does.
--
-- *** CONCURRENCY ***
-- `chart_claim_seats` takes pg_advisory_xact_lock on the tour, re-validates
-- every requested seat INSIDE the lock, and is all-or-nothing. Two customers
-- tapping the same berth: one wins, the other gets its id back in `conflicts`
-- and re-picks. No hold timer and no TTL — a claim is instant and final,
-- because there is no payment step to wait for. (GSRTC holds for 7 minutes and
-- its single most-reported bug is seats stuck "booked" after an abandoned
-- payment; having no hold state removes that whole failure class.)
--
-- *** PRIVACY ***
-- `chart_seat_availability` returns NO names and NO phone numbers — only
-- per-seat occupancy counts plus a ladies-occupied flag. That mirrors the
-- unanimous convention across Indian operator apps: a booked seat shows a
-- GENDER MARKER, never an identity. (Contrast `bus_roster_for_request` in 041,
-- which does reveal the roster — but only AFTER lock, to a rider who already
-- holds a booking.) `chart_tour_buses` likewise omits driver/owner phones and
-- `bus_price` (what the agent pays the owner — commercially sensitive).
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

-- ── 1. Per-tour booking mode ─────────────────────────────────
-- 'request' = legacy flow (customer asks, organiser assigns). Default, so every
-- existing row keeps today's behaviour. 'chart' = customer self-selects.
alter table public.tours
  add column if not exists booking_mode text not null default 'request';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'tours_booking_mode_chk'
  ) then
    alter table public.tours
      add constraint tours_booking_mode_chk
      check (booking_mode in ('request', 'chart'));
  end if;
end $$;

-- ── 2. Passenger gender ──────────────────────────────────────
-- Nullable: legacy rows and request-mode bookings have none, and the chart
-- tile must render fine without it. Drives the "booked ladies seat" marker and
-- (later) the seat-adjacent-to-a-lone-female convention that redBus enforces.
alter table public.passengers
  add column if not exists gender text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'passengers_gender_chk'
  ) then
    alter table public.passengers
      add constraint passengers_gender_chk
      check (gender is null or gender in ('male', 'female'));
  end if;
end $$;

-- ── 3. Gate: is this tour open for customer seat-chart booking? ──
-- Public + chart mode + still accepting bookings. Mirrors TourStatus
-- .acceptsBookings (closed from 'locked' onward). Unknown id -> false.
create or replace function public.chart_tour_open(p_tour_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (
      select t.is_public
         and t.booking_mode = 'chart'
         and t.status not in ('locked', 'completed')
        from public.tours t
       where t.id = p_tour_id
    ),
    false
  );
$$;

revoke all on function public.chart_tour_open(uuid) from public;
grant execute on function public.chart_tour_open(uuid) to anon, authenticated;

-- ── 4. The buses (and layouts) a customer may draw ───────────
-- Customer-facing fields ONLY. Deliberately omits driver_phone, owner_name,
-- owner_phone and bus_price. Empty until the tour is open in chart mode, which
-- is also what enforces "a chart tour needs a bus before it can sell".
create or replace function public.chart_tour_buses(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case
    when not public.chart_tour_open(p_tour_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',                b.id,
                   'tour_id',           b.tour_id,
                   'name',              b.name,
                   'registration_no',   b.registration_no,
                   'is_ac',             b.is_ac,
                   'bus_type',          b.bus_type,
                   'boarding_point',    b.boarding_point,
                   'departure_time',    b.departure_time,
                   'layout',            b.layout,
                   'price_per_seat',    b.price_per_seat,
                   'single_sofa_price', b.single_sofa_price,
                   'double_sofa_price', b.double_sofa_price,
                   'seater_price',      b.seater_price,
                   'rear_rows',         b.rear_rows,
                   'rear_price',        b.rear_price,
                   'price_bands',       b.price_bands
                 )
                 order by b.name
               )
          from public.buses b
         where b.tour_id = p_tour_id
           and b.layout is not null
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.chart_tour_buses(uuid) from public;
grant execute on function public.chart_tour_buses(uuid) to anon, authenticated;

-- ── 5. Anonymised per-seat occupancy ─────────────────────────
-- One row per OCCUPIED (bus_id, seat_id). Seats absent from the result are
-- wholly free. The client owns berth capacity (a double sofa is 2 berths) and
-- the `reserved` flag, both of which ride on the layout from chart_tour_buses.
--
-- Leg accounting matches the Dart model exactly: an assignment consumes the GO
-- slot when its leg is roundTrip/outboundOnly and the RET slot when it is
-- roundTrip/returnOnly, falling back to the passenger-level trip_type for
-- legacy entries that were never leg-stamped. That is what lets one berth sell
-- twice — GO to one rider, RET to another.
create or replace function public.chart_seat_availability(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with occ as (
    select seat->>'busId'  as bus_id,
           seat->>'seatId' as seat_id,
           coalesce(nullif(seat->>'leg', ''), p.trip_type, 'roundTrip') as leg,
           p.gender as gender
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as seat
     where p.tour_id = p_tour_id
       and p.cancelled_at is null
       and coalesce(seat->>'busId', '')  <> ''
       and coalesce(seat->>'seatId', '') <> ''
  )
  select case
    when not public.chart_tour_open(p_tour_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(g.o)
          from (
            select jsonb_build_object(
                     'bus_id',   bus_id,
                     'seat_id',  seat_id,
                     'used_go',  count(*) filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'used_ret', count(*) filter (
                                   where leg in ('roundTrip', 'returnOnly')),
                     -- Gender MARKER only (no identity): is a female rider
                     -- holding this berth on that leg?
                     'lady_go',  bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'lady_ret', bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'returnOnly'))
                   ) as o
              from occ
             group by bus_id, seat_id
          ) g
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.chart_seat_availability(uuid) from public;
grant execute on function public.chart_seat_availability(uuid) to anon, authenticated;

-- ── 6. Atomically claim seats and create the booking ─────────
-- p_seats: [{"seatId":"DL2","berths":2}, {"seatId":"SU1","berths":1}]
--
-- `berths` is what lets a customer take HALF a double sofa. Evidence from the
-- Indian sleeper market is unambiguous that a "double" is two independently
-- sold berths and that strangers routinely share one (Bitla had to ship a
-- special feature to BLOCK the second half during COVID — you only build that
-- if it otherwise sells). Mapping to request lines therefore follows the
-- engine's existing convention:
--     double cell, 2 berths -> one doubleSofa line  (the whole sofa)
--     double cell, 1 berth  -> one singleSofa line  (half a sofa; the seating
--                              engine already cross-fills singles onto double
--                              berths, see resolveAssignmentLegs)
--     single cell / seater  -> one line of that type
-- so `seatBerths` keeps matching `assigned_seats.length` and every downstream
-- money/capacity getter stays honest.
--
-- Returns {ok:true, request_id, passenger_id, berths} on success, or
-- {ok:false, conflicts:[seatId,...]} when any seat was taken (or reserved, or
-- unknown) — nothing is written in that case.
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
  v_claims       jsonb := '[]'::jsonb;
  v_conflicts    text[] := '{}';
  v_assigned     jsonb;
  v_lines        jsonb;
  v_passenger_id uuid := gen_random_uuid();
  v_seat         jsonb;
  v_seat_id      text;
  v_berths       int;
  v_type         text;
  v_pos          text;
  v_cap          int;
  v_used_go      int;
  v_used_ret     int;
  v_wants_go     boolean;
  v_wants_ret    boolean;
  v_total        int;
begin
  if p_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
    raise exception 'Invalid trip leg.' using errcode = 'check_violation';
  end if;
  if p_gender is not null and p_gender not in ('male', 'female') then
    raise exception 'Invalid gender.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) = 0 then
    raise exception 'No seats selected.' using errcode = 'check_violation';
  end if;
  -- Same cap GSRTC and the Maventech operator apps use.
  if jsonb_array_length(p_seats) > 6 then
    raise exception 'At most 6 seats per booking.' using errcode = 'check_violation';
  end if;

  -- Serialise every claim on this tour. Held to COMMIT, so the re-validation
  -- below sees a stable world and two racing claims can never both win.
  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  if not public.chart_tour_open(p_tour_id) then
    raise exception 'This tour is not open for seat selection.'
      using errcode = 'check_violation';
  end if;

  if not exists (
    select 1 from public.buses b
     where b.id = p_bus_id and b.tour_id = p_tour_id and b.layout is not null
  ) then
    raise exception 'That bus is not on this tour.' using errcode = 'check_violation';
  end if;

  v_wants_go  := p_leg in ('roundTrip', 'outboundOnly');
  v_wants_ret := p_leg in ('roundTrip', 'returnOnly');

  for v_seat in select * from jsonb_array_elements(p_seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);

    -- Resolve the cell from the bus's own layout. Never trust the client for
    -- seat type, capacity or the reserved flag.
    select cell->>'seatType', cell->>'position'
      into v_type, v_pos
      from public.buses b
      cross join lateral jsonb_array_elements(
        coalesce(b.layout->'grid', '[]'::jsonb)
      ) as cell
     where b.id = p_bus_id
       and cell->>'seatId' = v_seat_id
       and coalesce((cell->>'reserved')::boolean, false) = false
     limit 1;

    -- Unknown seat id, or one the organiser has held back.
    if v_type is null then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_cap := case when v_type = 'doubleSofa' then 2 else 1 end;
    if v_berths < 1 or v_berths > v_cap then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    select
      count(*) filter (where lg in ('roundTrip', 'outboundOnly')),
      count(*) filter (where lg in ('roundTrip', 'returnOnly'))
      into v_used_go, v_used_ret
      from (
        select coalesce(nullif(s->>'leg', ''), p.trip_type, 'roundTrip') as lg
          from public.passengers p
          cross join lateral jsonb_array_elements(
            coalesce(p.assigned_seats, '[]'::jsonb)
          ) s
         where p.tour_id = p_tour_id
           and p.cancelled_at is null
           and s->>'busId'  = p_bus_id::text
           and s->>'seatId' = v_seat_id
      ) q;

    -- A berth offers one GO slot and one RET slot. Taking N berths on a leg
    -- needs N free slots on that leg.
    if (v_wants_go  and v_used_go  + v_berths > v_cap)
    or (v_wants_ret and v_used_ret + v_berths > v_cap) then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_claims := v_claims || jsonb_build_object(
      'seatId', v_seat_id, 'berths', v_berths,
      'type',   v_type,    'position', v_pos
    );
  end loop;

  -- All-or-nothing: one lost seat aborts the whole claim, unwritten.
  if array_length(v_conflicts, 1) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', to_jsonb(v_conflicts));
  end if;

  -- One assignment entry PER BERTH. A whole double sofa is therefore two
  -- entries sharing a seatId — exactly how the app already stores it.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'busId',  p_bus_id::text,
             'seatId', c->>'seatId',
             'leg',    p_leg
           )
         ), '[]'::jsonb)
    into v_assigned
    from jsonb_array_elements(v_claims) c
    cross join lateral generate_series(1, (c->>'berths')::int);

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'seatType', line_type,
             'position', line_pos,
             'qty',      cnt,
             'leg',      p_leg
           )
         ), '[]'::jsonb)
    into v_lines
    from (
      select case
               when c->>'type' = 'seater' then 'seater'
               when c->>'type' = 'doubleSofa' and (c->>'berths')::int = 2
                 then 'doubleSofa'
               else 'singleSofa'
             end as line_type,
             case when c->>'type' = 'seater' then null else c->>'position' end
               as line_pos,
             count(*) as cnt
        from jsonb_array_elements(v_claims) c
       group by 1, 2
    ) g;

  v_total := jsonb_array_length(v_assigned);

  -- is_confirmed = true: the customer chose this seat themselves, so there is
  -- nothing left for the organiser to confirm. The row is otherwise IDENTICAL
  -- in shape to a request-mode passenger, which is what keeps money, capacity,
  -- the handler manifest, the chart PDF and notify working untouched.
  insert into public.passengers (
    id, tour_id, name, phone, gender, request_lines, assigned_seats,
    note, trip_type, is_confirmed, pickup_location_id, pickup_location_name
  ) values (
    v_passenger_id, p_tour_id, p_name, p_phone, p_gender, v_lines, v_assigned,
    p_note, p_leg, true, p_pickup_location_id, p_pickup_location_name
  );

  insert into public.booking_requests (
    id, tour_id, passenger_id, customer_phone, customer_name, party_size,
    trip_type, raw_form, pickup_location_id, pickup_location_name
  ) values (
    p_request_id, p_tour_id, v_passenger_id, p_phone, p_name, v_total,
    p_leg,
    jsonb_build_object(
      'source', 'chart',
      'bus_id', p_bus_id::text,
      'seats',  v_claims,
      'leg',    p_leg
    ),
    p_pickup_location_id, p_pickup_location_name
  );

  return jsonb_build_object(
    'ok',           true,
    'request_id',   p_request_id,
    'passenger_id', v_passenger_id,
    'berths',       v_total
  );
end;
$$;

revoke all on function public.chart_claim_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public;
grant execute on function public.chart_claim_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) to anon, authenticated;
