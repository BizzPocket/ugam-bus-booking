-- ============================================================
-- 089  A chart booking may carry a DIFFERENT leg on each seat
-- ------------------------------------------------------------
-- WHY
-- The chart RPCs took one `p_leg` and stamped it onto every assigned seat and
-- every request line. That made the ordinary case impossible to express: four
-- people go to Dwarka, two stay with relatives, two come home. Request mode has
-- always carried a leg per `request_lines` row; chart mode was the odd one out.
--
-- SHAPE OF THE CHANGE
-- Additive. Each element of the seats array MAY carry its own "leg"; where it
-- does not, `p_leg` is used exactly as before:
--
--     coalesce(v_seat->>'leg', p_leg)
--
-- No signature changes, so no grants are re-issued and no client has to probe
-- for a new function. Builds already on the Play Store send no per-seat leg and
-- therefore behave byte-for-byte as they do today. That backward compatibility
-- is the entire reason this is a coalesce and not a new parameter.
--
-- `booking_requests.trip_type` and `seat_holds.leg` become a DERIVED SUMMARY of
-- the per-seat legs — round-trip when any seat is round-trip or the legs are
-- mixed, else the single shared value. Identical rule to `summaryLegOf` in the
-- Dart client and to how request mode has always written that column.
--
-- ── SEVEN FUNCTIONS, NOT FIVE ──
-- Beyond the four claim/hold entry points and the shared validator, two more
-- functions read the leg and would otherwise silently flatten a mixed party:
--
--   * `chart_seat_slot_usage` counted a hold's berths using the HOLD-LEVEL
--     `h.leg`. A mixed hold summarised as 'roundTrip' would then block BOTH
--     legs of a seat whose occupant is only travelling out — quietly making
--     seats unsellable.
--
--   * `chart_finalize_hold` stamped `h.leg` onto every assignment it created,
--     so a mixed party that paid an advance would be finalized as if everyone
--     travelled both ways — the exact bug this migration exists to remove,
--     reintroduced on the advance-payment path.
--
-- DEPENDS ON: 067 and 068. Verify both are live before applying this file.
--
-- Idempotent. Run THIS FILE ALONE in the Supabase SQL editor.
-- ============================================================


-- ── 1. Helper: the coarse trip type of a set of per-seat legs ─
-- One derivation, used by every writer below, so the summary column can never
-- disagree with the per-seat truth it summarises.

create or replace function public.chart_summary_leg(p_legs text[])
returns text
language sql
immutable
as $$
  select case
    when p_legs is null or cardinality(p_legs) = 0 then 'roundTrip'
    when 'roundTrip' = any(p_legs) then 'roundTrip'
    when cardinality(array(select distinct unnest(p_legs))) = 1 then p_legs[1]
    else 'roundTrip'
  end;
$$;


-- ── 2. Slot usage reads a hold's PER-SEAT leg ─────────────────
-- Body reproduced from 064; the only change is the hold branch's leg source.

create or replace function public.chart_seat_slot_usage(
  p_tour_id uuid,
  p_bus_id  uuid,
  p_seat_id text
) returns table(used_go int, used_ret int)
language sql stable security definer set search_path = public
as $$
  with occ as (
    -- Final passengers
    select coalesce(nullif(s->>'leg', ''), p.trip_type, 'roundTrip') as leg,
           1 as berths
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) s
     where p.tour_id = p_tour_id
       and p.cancelled_at is null
       and s->>'busId'  = p_bus_id::text
       and s->>'seatId' = p_seat_id
    union all
    -- Active soft holds (each berth in seats jsonb).
    -- The SEAT's own leg wins over the hold's summary: a hold whose summary is
    -- 'roundTrip' because one of its seats is round-trip must not block the
    -- return leg of a seat that is outbound-only.
    select coalesce(nullif(c->>'leg', ''), h.leg) as leg,
           coalesce((c->>'berths')::int, 1) as berths
      from public.seat_holds h
      cross join lateral jsonb_array_elements(h.seats) c
     where h.tour_id = p_tour_id
       and h.bus_id = p_bus_id
       and h.status = 'pending'
       and h.expires_at > now()
       and c->>'seatId' = p_seat_id
  )
  select
    coalesce(sum(berths) filter (
      where leg in ('roundTrip', 'outboundOnly')), 0)::int,
    coalesce(sum(berths) filter (
      where leg in ('roundTrip', 'returnOnly')), 0)::int
  from occ;
$$;


-- ── 3. Shared validator resolves a leg per seat ───────────────
-- Body reproduced from 068. `v_wants_go` / `v_wants_ret` move INSIDE the loop
-- because they are now a property of the seat, not of the call.

create or replace function public.chart_validate_bus_seats(
  p_tour_id uuid,
  p_bus_id  uuid,
  p_leg     text,
  p_seats   jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_claims    jsonb := '[]'::jsonb;
  v_conflicts text[] := '{}';
  v_seat      jsonb;
  v_seat_id   text;
  v_berths    int;
  v_type      text;
  v_pos       text;
  v_cap       int;
  v_used_go   int;
  v_used_ret  int;
  v_seat_leg  text;
  v_wants_go  boolean;
  v_wants_ret boolean;
begin
  if not exists (
    select 1 from public.buses b
     where b.id = p_bus_id and b.tour_id = p_tour_id and b.layout is not null
  ) then
    raise exception 'That bus is not on this tour.' using errcode = 'check_violation';
  end if;

  for v_seat in select * from jsonb_array_elements(p_seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);

    -- The seat's own leg, falling back to the call's. An old client sends no
    -- per-seat leg and therefore lands on exactly the previous behaviour.
    v_seat_leg := coalesce(nullif(v_seat->>'leg', ''), p_leg);
    if v_seat_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
      raise exception 'Invalid seat leg.' using errcode = 'check_violation';
    end if;
    v_wants_go  := v_seat_leg in ('roundTrip', 'outboundOnly');
    v_wants_ret := v_seat_leg in ('roundTrip', 'returnOnly');

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

    if v_type is null then           -- unknown seat, or held back
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_cap := case when v_type = 'doubleSofa' then 2 else 1 end;
    if v_berths < 1 or v_berths > v_cap then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    select u.used_go, u.used_ret
      into v_used_go, v_used_ret
      from public.chart_seat_slot_usage(p_tour_id, p_bus_id, v_seat_id) u;

    if (v_wants_go  and coalesce(v_used_go, 0)  + v_berths > v_cap)
    or (v_wants_ret and coalesce(v_used_ret, 0) + v_berths > v_cap) then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_claims := v_claims || jsonb_build_object(
      'seatId', v_seat_id, 'berths', v_berths,
      'type',   v_type,    'position', v_pos,
      'leg',    v_seat_leg
    );
  end loop;

  return jsonb_build_object(
    'claims',    v_claims,
    'conflicts', to_jsonb(v_conflicts)
  );
end;
$$;


-- ── 4. Single-bus claim ───────────────────────────────────────
-- Body reproduced from 048. Its occupancy probe is deliberately left as-is
-- (passengers only, no holds) — that predates seat_holds and changing it here
-- would be a behaviour change beyond this migration.

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
  v_seat_leg     text;
  v_wants_go     boolean;
  v_wants_ret    boolean;
  v_total        int;
  v_summary_leg  text;
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

  for v_seat in select * from jsonb_array_elements(p_seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);

    v_seat_leg := coalesce(nullif(v_seat->>'leg', ''), p_leg);
    if v_seat_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
      raise exception 'Invalid seat leg.' using errcode = 'check_violation';
    end if;
    v_wants_go  := v_seat_leg in ('roundTrip', 'outboundOnly');
    v_wants_ret := v_seat_leg in ('roundTrip', 'returnOnly');

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
      'type',   v_type,    'position', v_pos,
      'leg',    v_seat_leg
    );
  end loop;

  -- All-or-nothing: one lost seat aborts the whole claim, unwritten.
  if array_length(v_conflicts, 1) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', to_jsonb(v_conflicts));
  end if;

  v_summary_leg := public.chart_summary_leg(
    array(select c->>'leg' from jsonb_array_elements(v_claims) c)
  );

  -- One assignment entry PER BERTH. A whole double sofa is therefore two
  -- entries sharing a seatId — exactly how the app already stores it.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'busId',  p_bus_id::text,
             'seatId', c->>'seatId',
             'leg',    c->>'leg'
           )
         ), '[]'::jsonb)
    into v_assigned
    from jsonb_array_elements(v_claims) c
    cross join lateral generate_series(1, (c->>'berths')::int);

  -- Grouped by LEG as well as type and position: two people in the same kind
  -- of berth on different legs are two lines, and are billed differently.
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'seatType', line_type,
             'position', line_pos,
             'qty',      cnt,
             'leg',      line_leg
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
             c->>'leg' as line_leg,
             count(*) as cnt
        from jsonb_array_elements(v_claims) c
       group by 1, 2, 3
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
    p_note, v_summary_leg, true, p_pickup_location_id, p_pickup_location_name
  );

  insert into public.booking_requests (
    id, tour_id, passenger_id, customer_phone, customer_name, party_size,
    trip_type, raw_form, pickup_location_id, pickup_location_name
  ) values (
    p_request_id, p_tour_id, v_passenger_id, p_phone, p_name, v_total,
    v_summary_leg,
    jsonb_build_object(
      'source', 'chart',
      'bus_id', p_bus_id::text,
      'seats',  v_claims,
      'leg',    v_summary_leg
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


-- ── 5. Single-bus hold ────────────────────────────────────────
-- Body reproduced from 064.

create or replace function public.chart_hold_seats(
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
  v_claims      jsonb := '[]'::jsonb;
  v_conflicts   text[] := '{}';
  v_seat        jsonb;
  v_seat_id     text;
  v_berths      int;
  v_type        text;
  v_pos         text;
  v_cap         int;
  v_used_go     int;
  v_used_ret    int;
  v_seat_leg    text;
  v_wants_go    boolean;
  v_wants_ret   boolean;
  v_hold_id     uuid;
  v_summary_leg text;
  v_expires     timestamptz := now() + interval '5 minutes';
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
  if jsonb_array_length(p_seats) > 6 then
    raise exception 'At most 6 seats per booking.' using errcode = 'check_violation';
  end if;

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

  -- Idempotent: same request_id already pending → return it
  if exists (
    select 1 from public.seat_holds
     where request_id = p_request_id and status = 'pending' and expires_at > now()
  ) then
    select id, expires_at into v_hold_id, v_expires
      from public.seat_holds where request_id = p_request_id;
    return jsonb_build_object(
      'ok', true, 'hold_id', v_hold_id, 'request_id', p_request_id,
      'expires_at', v_expires
    );
  end if;

  for v_seat in select * from jsonb_array_elements(p_seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);

    v_seat_leg := coalesce(nullif(v_seat->>'leg', ''), p_leg);
    if v_seat_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
      raise exception 'Invalid seat leg.' using errcode = 'check_violation';
    end if;
    v_wants_go  := v_seat_leg in ('roundTrip', 'outboundOnly');
    v_wants_ret := v_seat_leg in ('roundTrip', 'returnOnly');

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

    if v_type is null then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_cap := case when v_type = 'doubleSofa' then 2 else 1 end;
    if v_berths < 1 or v_berths > v_cap then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    select used_go, used_ret into v_used_go, v_used_ret
      from public.chart_seat_slot_usage(p_tour_id, p_bus_id, v_seat_id);

    if (v_wants_go  and v_used_go  + v_berths > v_cap)
    or (v_wants_ret and v_used_ret + v_berths > v_cap) then
      v_conflicts := v_conflicts || v_seat_id;
      continue;
    end if;

    v_claims := v_claims || jsonb_build_object(
      'seatId', v_seat_id, 'berths', v_berths,
      'type',   v_type,    'position', v_pos,
      'leg',    v_seat_leg
    );
  end loop;

  if array_length(v_conflicts, 1) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', to_jsonb(v_conflicts));
  end if;

  -- The hold's own `leg` column is the SUMMARY; the per-seat truth lives in
  -- `seats`, which is what finalize and slot-usage read.
  v_summary_leg := public.chart_summary_leg(
    array(select c->>'leg' from jsonb_array_elements(v_claims) c)
  );

  insert into public.seat_holds (
    id, tour_id, bus_id, request_id, phone, name, leg, seats,
    gender, note, pickup_location_id, pickup_location_name,
    status, expires_at
  ) values (
    gen_random_uuid(), p_tour_id, p_bus_id, p_request_id, p_phone, p_name,
    v_summary_leg, v_claims, p_gender, p_note, p_pickup_location_id,
    p_pickup_location_name, 'pending', v_expires
  )
  returning id into v_hold_id;

  return jsonb_build_object(
    'ok', true,
    'hold_id', v_hold_id,
    'request_id', p_request_id,
    'expires_at', v_expires
  );
end;
$$;


-- ── 6. Multi-bus claim ────────────────────────────────────────
-- Body reproduced from 068. The validator already resolved each seat's leg, so
-- the aggregations read it off the claim.

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
  v_bus          jsonb;
  v_bus_id       uuid;
  v_request_id   uuid;
  v_result       jsonb;
  v_claims       jsonb;
  v_conflicts    jsonb := '[]'::jsonb;
  v_seat_conf    text;
  v_total_berths int := 0;
  v_bookings     jsonb := '[]'::jsonb;
  v_passenger_id uuid;
  v_assigned     jsonb;
  v_lines        jsonb;
  v_berths       int;
  v_summary_leg  text;
begin
  if p_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
    raise exception 'Invalid trip leg.' using errcode = 'check_violation';
  end if;
  if p_gender is not null and p_gender not in ('male', 'female') then
    raise exception 'Invalid gender.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_buses) <> 'array' or jsonb_array_length(p_buses) = 0 then
    raise exception 'No seats selected.' using errcode = 'check_violation';
  end if;

  -- Berths, not cells. Six doubles is six cells and twelve people.
  select coalesce(sum(coalesce((c->>'berths')::int, 1)), 0)
    into v_total_berths
    from jsonb_array_elements(p_buses) b
    cross join lateral jsonb_array_elements(b->'seats') c;

  if v_total_berths > 6 then
    raise exception 'At most 6 berths per booking.' using errcode = 'check_violation';
  end if;

  -- One lock for the WHOLE party, held to COMMIT. Locking per bus would let a
  -- second party interleave between our buses and win a seat we had validated.
  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  if not public.chart_tour_open(p_tour_id) then
    raise exception 'This tour is not open for seat selection.'
      using errcode = 'check_violation';
  end if;

  -- Pass 1 — validate EVERY bus before writing anything.
  for v_bus in select * from jsonb_array_elements(p_buses)
  loop
    v_bus_id := (v_bus->>'busId')::uuid;
    v_result := public.chart_validate_bus_seats(
      p_tour_id, v_bus_id, p_leg, v_bus->'seats'
    );
    for v_seat_conf in
      select jsonb_array_elements_text(v_result->'conflicts')
    loop
      v_conflicts := v_conflicts || jsonb_build_object(
        'bus_id', v_bus_id::text, 'seat_id', v_seat_conf
      );
    end loop;
  end loop;

  -- All-or-nothing ACROSS BUSES: one lost seat on the second bus must not
  -- leave the customer holding half a party on the first.
  if jsonb_array_length(v_conflicts) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', v_conflicts);
  end if;

  -- Pass 2 — write one passenger + one booking_request per bus.
  for v_bus in select * from jsonb_array_elements(p_buses)
  loop
    v_bus_id     := (v_bus->>'busId')::uuid;
    v_request_id := (v_bus->>'requestId')::uuid;
    v_result     := public.chart_validate_bus_seats(
      p_tour_id, v_bus_id, p_leg, v_bus->'seats'
    );
    v_claims       := v_result->'claims';
    v_passenger_id := gen_random_uuid();

    -- Summarised PER BUS, because each bus gets its own passenger row and its
    -- own booking_request, and each must describe its own seats.
    v_summary_leg := public.chart_summary_leg(
      array(select c->>'leg' from jsonb_array_elements(v_claims) c)
    );

    -- One assignment entry PER BERTH; a whole double is two entries sharing a
    -- seatId. Every entry names THIS bus, which is what keeps
    -- `assigned_seats[0].busId` truthful for the billing and manifest code.
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'busId',  v_bus_id::text,
               'seatId', c->>'seatId',
               'leg',    c->>'leg'
             )
           ), '[]'::jsonb)
      into v_assigned
      from jsonb_array_elements(v_claims) c
      cross join lateral generate_series(1, (c->>'berths')::int);

    select coalesce(jsonb_agg(
             jsonb_build_object(
               'seatType', line_type, 'position', line_pos,
               'qty', cnt, 'leg', line_leg
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
               c->>'leg' as line_leg,
               count(*) as cnt
          from jsonb_array_elements(v_claims) c
         group by 1, 2, 3
      ) g;

    v_berths := jsonb_array_length(v_assigned);

    insert into public.passengers (
      id, tour_id, name, phone, gender, request_lines, assigned_seats,
      note, trip_type, is_confirmed, pickup_location_id, pickup_location_name
    ) values (
      v_passenger_id, p_tour_id, p_name, p_phone, p_gender, v_lines, v_assigned,
      p_note, v_summary_leg, true, p_pickup_location_id, p_pickup_location_name
    );

    insert into public.booking_requests (
      id, tour_id, passenger_id, customer_phone, customer_name, party_size,
      trip_type, raw_form, pickup_location_id, pickup_location_name, party_id
    ) values (
      v_request_id, p_tour_id, v_passenger_id, p_phone, p_name, v_berths,
      v_summary_leg,
      jsonb_build_object(
        'source', 'chart',
        'bus_id', v_bus_id::text,
        'seats',  v_claims,
        'leg',    v_summary_leg
      ),
      p_pickup_location_id, p_pickup_location_name, p_party_id
    );

    v_bookings := v_bookings || jsonb_build_object(
      'bus_id',       v_bus_id::text,
      'request_id',   v_request_id::text,
      'passenger_id', v_passenger_id::text,
      'berths',       v_berths
    );
  end loop;

  return jsonb_build_object(
    'ok',       true,
    'party_id', p_party_id,
    'bookings', v_bookings,
    'berths',   v_total_berths
  );
end;
$$;


-- ── 7. Multi-bus hold ─────────────────────────────────────────
-- Body reproduced from 068.

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
  v_bus          jsonb;
  v_bus_id       uuid;
  v_request_id   uuid;
  v_result       jsonb;
  v_claims       jsonb;
  v_conflicts    jsonb := '[]'::jsonb;
  v_seat_conf    text;
  v_total_berths int := 0;
  v_holds        jsonb := '[]'::jsonb;
  v_hold_id      uuid;
  v_summary_leg  text;
  v_expires      timestamptz;
begin
  if p_leg not in ('roundTrip', 'outboundOnly', 'returnOnly') then
    raise exception 'Invalid trip leg.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_buses) <> 'array' or jsonb_array_length(p_buses) = 0 then
    raise exception 'No seats selected.' using errcode = 'check_violation';
  end if;

  select coalesce(sum(coalesce((c->>'berths')::int, 1)), 0)
    into v_total_berths
    from jsonb_array_elements(p_buses) b
    cross join lateral jsonb_array_elements(b->'seats') c;

  if v_total_berths > 6 then
    raise exception 'At most 6 berths per booking.' using errcode = 'check_violation';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_tour_id::text));

  if not public.chart_tour_open(p_tour_id) then
    raise exception 'This tour is not open for seat selection.'
      using errcode = 'check_violation';
  end if;

  for v_bus in select * from jsonb_array_elements(p_buses)
  loop
    v_bus_id := (v_bus->>'busId')::uuid;
    v_result := public.chart_validate_bus_seats(
      p_tour_id, v_bus_id, p_leg, v_bus->'seats'
    );
    for v_seat_conf in
      select jsonb_array_elements_text(v_result->'conflicts')
    loop
      v_conflicts := v_conflicts || jsonb_build_object(
        'bus_id', v_bus_id::text, 'seat_id', v_seat_conf
      );
    end loop;
  end loop;

  if jsonb_array_length(v_conflicts) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', v_conflicts);
  end if;

  -- One deadline for the whole party: staggering them would expire half a
  -- party's seats while the customer was still paying for the other half.
  v_expires := now() + make_interval(secs => greatest(p_ttl_seconds, 60));

  for v_bus in select * from jsonb_array_elements(p_buses)
  loop
    v_bus_id     := (v_bus->>'busId')::uuid;
    v_request_id := (v_bus->>'requestId')::uuid;
    v_result     := public.chart_validate_bus_seats(
      p_tour_id, v_bus_id, p_leg, v_bus->'seats'
    );
    v_claims  := v_result->'claims';
    v_hold_id := gen_random_uuid();

    v_summary_leg := public.chart_summary_leg(
      array(select c->>'leg' from jsonb_array_elements(v_claims) c)
    );

    insert into public.seat_holds (
      id, tour_id, bus_id, request_id, phone, name, leg, seats,
      gender, note, pickup_location_id, pickup_location_name,
      status, expires_at, party_id
    ) values (
      v_hold_id, p_tour_id, v_bus_id, v_request_id, p_phone, p_name,
      v_summary_leg, v_claims, p_gender, p_note,
      p_pickup_location_id, p_pickup_location_name,
      'pending', v_expires, p_party_id
    );

    v_holds := v_holds || jsonb_build_object(
      'hold_id',    v_hold_id::text,
      'bus_id',     v_bus_id::text,
      'request_id', v_request_id::text
    );
  end loop;

  return jsonb_build_object(
    'ok',         true,
    'party_id',   p_party_id,
    'holds',      v_holds,
    'expires_at', v_expires,
    'berths',     v_total_berths
  );
end;
$$;


-- ── 8. Finalize a hold, honouring its per-seat legs ───────────
-- Body reproduced from 064. Without this, a mixed party that paid an advance
-- would be finalized as if everyone travelled both ways.

create or replace function public.chart_finalize_hold(
  p_hold_id uuid
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  h              record;
  v_assigned     jsonb;
  v_lines        jsonb;
  v_passenger_id uuid := gen_random_uuid();
  v_total        int;
  v_used_go      int;
  v_used_ret     int;
  v_cap          int;
  v_seat         jsonb;
  v_seat_id      text;
  v_berths       int;
  v_type         text;
  v_seat_leg     text;
  v_wants_go     boolean;
  v_wants_ret    boolean;
  v_summary_leg  text;
begin
  select * into h from public.seat_holds where id = p_hold_id for update;
  if not found then
    raise exception 'unknown hold';
  end if;

  if not exists (
    select 1 from public.tours t
     where t.id = h.tour_id and t.owner_id = auth.uid()
  ) then
    raise exception 'not authorized for this tour';
  end if;

  if h.status = 'finalized' then
    return jsonb_build_object(
      'ok', true, 'hold_id', h.id, 'passenger_id', h.passenger_id,
      'request_id', h.request_id, 'already', true
    );
  end if;

  if h.status <> 'pending' then
    raise exception 'hold is %', h.status;
  end if;

  if h.expires_at <= now() then
    update public.seat_holds set status = 'expired', updated_at = now()
     where id = h.id;
    raise exception 'hold expired' using errcode = 'check_violation';
  end if;

  perform pg_advisory_xact_lock(hashtext(h.tour_id::text));

  if not public.chart_tour_open(h.tour_id) then
    raise exception 'This tour is not open for seat selection.'
      using errcode = 'check_violation';
  end if;

  -- Re-validate vs OTHER holds + passengers (exclude this hold)
  for v_seat in select * from jsonb_array_elements(h.seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);
    v_type    := v_seat->>'type';
    v_cap     := case when v_type = 'doubleSofa' then 2 else 1 end;

    -- Per seat, falling back to the hold's summary for holds written before
    -- 089 (whose seats carry no leg of their own).
    v_seat_leg  := coalesce(nullif(v_seat->>'leg', ''), h.leg);
    v_wants_go  := v_seat_leg in ('roundTrip', 'outboundOnly');
    v_wants_ret := v_seat_leg in ('roundTrip', 'returnOnly');

    select
      coalesce(sum(b) filter (where lg in ('roundTrip','outboundOnly')), 0),
      coalesce(sum(b) filter (where lg in ('roundTrip','returnOnly')), 0)
      into v_used_go, v_used_ret
      from (
        select coalesce(nullif(s->>'leg',''), p.trip_type, 'roundTrip') as lg,
               1 as b
          from public.passengers p
          cross join lateral jsonb_array_elements(
            coalesce(p.assigned_seats,'[]'::jsonb)) s
         where p.tour_id = h.tour_id and p.cancelled_at is null
           and s->>'busId' = h.bus_id::text and s->>'seatId' = v_seat_id
        union all
        select coalesce(nullif(c->>'leg',''), oh.leg),
               coalesce((c->>'berths')::int, 1)
          from public.seat_holds oh
          cross join lateral jsonb_array_elements(oh.seats) c
         where oh.tour_id = h.tour_id
           and oh.id <> h.id
           and oh.status = 'pending' and oh.expires_at > now()
           and oh.bus_id = h.bus_id
           and c->>'seatId' = v_seat_id
      ) q;

    if (v_wants_go  and v_used_go  + v_berths > v_cap)
    or (v_wants_ret and v_used_ret + v_berths > v_cap) then
      raise exception 'Seat % no longer free', v_seat_id
        using errcode = 'check_violation';
    end if;
  end loop;

  v_summary_leg := public.chart_summary_leg(
    array(select coalesce(nullif(c->>'leg', ''), h.leg)
            from jsonb_array_elements(h.seats) c)
  );

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'busId',  h.bus_id::text,
             'seatId', c->>'seatId',
             'leg',    coalesce(nullif(c->>'leg', ''), h.leg)
           )
         ), '[]'::jsonb)
    into v_assigned
    from jsonb_array_elements(h.seats) c
    cross join lateral generate_series(1, (c->>'berths')::int);

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'seatType', line_type,
             'position', line_pos,
             'qty',      cnt,
             'leg',      line_leg
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
             coalesce(nullif(c->>'leg', ''), h.leg) as line_leg,
             count(*) as cnt
        from jsonb_array_elements(h.seats) c
       group by 1, 2, 3
    ) g;

  v_total := jsonb_array_length(v_assigned);

  insert into public.passengers (
    id, tour_id, name, phone, gender, request_lines, assigned_seats,
    note, trip_type, is_confirmed, pickup_location_id, pickup_location_name
  ) values (
    v_passenger_id, h.tour_id, h.name, h.phone, h.gender, v_lines, v_assigned,
    h.note, v_summary_leg, true, h.pickup_location_id, h.pickup_location_name
  );

  insert into public.booking_requests (
    id, tour_id, passenger_id, customer_phone, customer_name, party_size,
    trip_type, raw_form, pickup_location_id, pickup_location_name
  ) values (
    h.request_id, h.tour_id, v_passenger_id, h.phone, h.name, v_total,
    v_summary_leg,
    jsonb_build_object(
      'source', 'chart_hold',
      'bus_id', h.bus_id::text,
      'seats',  h.seats,
      'leg',    v_summary_leg,
      'hold_id', h.id::text
    ),
    h.pickup_location_id, h.pickup_location_name
  )
  on conflict (id) do nothing;

  update public.seat_holds
     set status = 'finalized',
         passenger_id = v_passenger_id,
         updated_at = now()
   where id = h.id;

  -- Attach passenger to any pending claim on this hold
  update public.payment_claims
     set passenger_id = v_passenger_id,
         booking_request_id = coalesce(booking_request_id, h.request_id),
         updated_at = now()
   where seat_hold_id = h.id
     and passenger_id is null;

  return jsonb_build_object(
    'ok', true,
    'hold_id', h.id,
    'request_id', h.request_id,
    'passenger_id', v_passenger_id,
    'berths', v_total
  );
end;
$$;


-- ── Grants ───────────────────────────────────────────────────
-- No signature changed, so the existing grants from 048/064/068 still apply
-- and are deliberately NOT re-issued. `chart_summary_leg` is new but is only
-- ever called from inside these SECURITY DEFINER functions, so it needs no
-- grant to anon/authenticated.

revoke all on function public.chart_summary_leg(text[]) from public;


-- ── POST-DEPLOY VERIFICATION (run by hand, do not automate) ───
--
--   1. Old-client shape — a payload with NO per-seat leg must behave as before:
--      select public.chart_validate_bus_seats(
--        '<tour>', '<bus>', 'outboundOnly',
--        '[{"seatId":"SU1","berths":1}]'::jsonb
--      );
--      Expect the same result as before 089, with each returned claim now
--      carrying "leg":"outboundOnly" (inherited from p_leg).
--
--   2. Mixed shape — two seats, two legs, one call:
--      select public.chart_validate_bus_seats(
--        '<tour>', '<bus>', 'roundTrip',
--        '[{"seatId":"SU1","berths":1,"leg":"roundTrip"},
--          {"seatId":"SU2","berths":1,"leg":"outboundOnly"}]'::jsonb
--      );
--      Expect SU2 to be checked against the outbound leg only.
--
--   3. The summary derivation:
--      select public.chart_summary_leg(array['outboundOnly','returnOnly']);
--      -- 'roundTrip'  (mixed collapses to round-trip)
--      select public.chart_summary_leg(array['outboundOnly','outboundOnly']);
--      -- 'outboundOnly'
--      select public.chart_summary_leg(array[]::text[]);
--      -- 'roundTrip'
--
--   4. A mixed claim writes mixed request_lines:
--      After a chart_claim_seats call with two different per-seat legs, the
--      passenger's request_lines must contain TWO rows with different "leg"
--      values, and trip_type must read 'roundTrip'.
--
--   5. Pre-089 holds still finalize: any seat_holds row written before this
--      migration has no per-seat leg, so chart_finalize_hold must fall back to
--      h.leg and produce exactly the assignments it would have before.
