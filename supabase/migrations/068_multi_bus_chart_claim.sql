-- ============================================================
-- 068  Multi-bus chart claim — one checkout, several buses
-- ------------------------------------------------------------
-- A party that is willing to split across buses could not book in one go:
-- `chart_claim_seats` (048) and `chart_hold_seats` (064) each take a single
-- `p_bus_id`, and the client cleared the selection whenever the bus tab changed.
--
-- ── THE DATA MODEL, AND THE TWO ALTERNATIVES THAT DO NOT WORK ──
--
-- This creates ONE passenger + ONE booking_request PER BUS, inside a single
-- advisory-locked transaction, all-or-nothing across every bus. They are linked
-- by `party_id`, which is for DISPLAY ONLY.
--
--   * A single passenger row spanning buses was rejected: five client call
--     sites treat `assigned_seats[0].busId` as THE bus for a passenger —
--     including billing (money_controller `_primaryBusId`) and the WhatsApp
--     ticket. A split party would be billed entirely to one bus and vanish from
--     the other bus's manifest.
--
--   * Linking the rows with `group_id` was rejected too, and is worse: the
--     seating engine raises `groupWontFit` — "Group is locked across multiple
--     buses" — so a deliberately split party would sit on the organiser's
--     seating-exceptions screen forever.
--
-- Because every passenger row still holds all of its seats in exactly ONE bus,
-- nothing downstream changes: capacity, money, the handler manifest, the chart
-- PDF and notify are all untouched. `party_id` lives ONLY on booking_requests
-- and seat_holds — never on passengers — so the engine cannot see it.
--
-- ── THE CAP ──
-- 048 caps `jsonb_array_length(p_seats) > 6`, which counts CELLS. Six doubles
-- is six cells and TWELVE people. This counts BERTHS, across the whole party.
--
-- Idempotent. Apply in the Supabase SQL editor after 067.
-- ============================================================

-- ── 1. Party linkage (display only) ──────────────────────────

alter table public.booking_requests
  add column if not exists party_id uuid;

alter table public.seat_holds
  add column if not exists party_id uuid;

create index if not exists booking_requests_party_idx
  on public.booking_requests(party_id)
  where party_id is not null;

create index if not exists seat_holds_party_idx
  on public.seat_holds(party_id)
  where party_id is not null;

comment on column public.booking_requests.party_id is
  'Groups the per-bus bookings of ONE customer checkout, for customer-facing '
  'display only. Deliberately NOT group_id: the seating engine treats a group '
  'spanning buses as groupWontFit. Nothing server-side reads this.';


-- ── 2. Shared validator ──────────────────────────────────────
-- Re-validates one bus's seats against that bus's OWN layout and the live
-- occupancy, exactly as 048 does. Returns the resolved claims, or the
-- conflicting seat ids. Never trusts the client for seat type, capacity or the
-- reserved flag.
--
-- Occupancy goes through `chart_seat_slot_usage` (064) so ACTIVE HOLDS block a
-- claim as well as final passengers — otherwise two parties could both claim a
-- seat that one of them is already paying for.

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
  v_wants_go  boolean;
  v_wants_ret boolean;
begin
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
      'type',   v_type,    'position', v_pos
    );
  end loop;

  return jsonb_build_object(
    'claims',    v_claims,
    'conflicts', to_jsonb(v_conflicts)
  );
end;
$$;


-- ── 3. Multi-bus claim ───────────────────────────────────────
-- p_buses: [{"busId":"…","requestId":"…","seats":[{"seatId":"DL2","berths":2}]}]
--
-- Returns {ok:true, party_id, bookings:[{bus_id, request_id, passenger_id}],
-- berths} or {ok:false, conflicts:[{bus_id, seat_id}]} with NOTHING written.

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

    -- One assignment entry PER BERTH; a whole double is two entries sharing a
    -- seatId. Every entry names THIS bus, which is what keeps
    -- `assigned_seats[0].busId` truthful for the billing and manifest code.
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'busId',  v_bus_id::text,
               'seatId', c->>'seatId',
               'leg',    p_leg
             )
           ), '[]'::jsonb)
      into v_assigned
      from jsonb_array_elements(v_claims) c
      cross join lateral generate_series(1, (c->>'berths')::int);

    select coalesce(jsonb_agg(
             jsonb_build_object(
               'seatType', line_type, 'position', line_pos,
               'qty', cnt, 'leg', p_leg
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

    v_berths := jsonb_array_length(v_assigned);

    insert into public.passengers (
      id, tour_id, name, phone, gender, request_lines, assigned_seats,
      note, trip_type, is_confirmed, pickup_location_id, pickup_location_name
    ) values (
      v_passenger_id, p_tour_id, p_name, p_phone, p_gender, v_lines, v_assigned,
      p_note, p_leg, true, p_pickup_location_id, p_pickup_location_name
    );

    insert into public.booking_requests (
      id, tour_id, passenger_id, customer_phone, customer_name, party_size,
      trip_type, raw_form, pickup_location_id, pickup_location_name, party_id
    ) values (
      v_request_id, p_tour_id, v_passenger_id, p_phone, p_name, v_berths,
      p_leg,
      jsonb_build_object(
        'source', 'chart',
        'bus_id', v_bus_id::text,
        'seats',  v_claims,
        'leg',    p_leg
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

revoke all on function public.chart_claim_seats_multi(
  uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public;
grant execute on function public.chart_claim_seats_multi(
  uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) to anon, authenticated;


-- ── 4. Multi-bus hold (advance path) ─────────────────────────
-- N holds sharing a party_id, created under one lock, all-or-nothing.

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
  v_conflicts    jsonb := '[]'::jsonb;
  v_seat_conf    text;
  v_total_berths int := 0;
  v_holds        jsonb := '[]'::jsonb;
  v_hold_id      uuid;
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
    v_hold_id := gen_random_uuid();

    insert into public.seat_holds (
      id, tour_id, bus_id, request_id, phone, name, leg, seats,
      gender, note, pickup_location_id, pickup_location_name,
      status, expires_at, party_id
    ) values (
      v_hold_id, p_tour_id, v_bus_id, v_request_id, p_phone, p_name, p_leg,
      v_result->'claims', p_gender, p_note,
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

revoke all on function public.chart_hold_seats_multi(
  uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
) from public;
grant execute on function public.chart_hold_seats_multi(
  uuid, uuid, text, text, text, jsonb, int, text, text, uuid, text
) to anon, authenticated;


-- ── 5. Finalize a whole party's holds together ───────────────
-- A party that splits across buses gets N holds but pays ONE advance, and a
-- payment_claim links to a single hold. Finalizing only that hold would confirm
-- one bus and silently let the party's other seats expire — the customer would
-- have paid for a party and received half of it.
--
-- So the organiser-facing confirm/pay-later path finalizes by PARTY. Delegates
-- to 064's `chart_finalize_hold` per hold, so all its validation, passenger
-- creation and ledger write-through are reused unchanged.
--
-- Owner-only: it inherits `chart_finalize_hold`'s own authorisation check.

create or replace function public.chart_finalize_party_holds(
  p_party_id uuid
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_hold    record;
  v_result  jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  if p_party_id is null then
    raise exception 'No party id.' using errcode = 'check_violation';
  end if;

  -- Ordered for determinism, and locked for the duration so a concurrent
  -- expiry sweep cannot release half the party mid-finalize.
  for v_hold in
    select h.id, h.bus_id
      from public.seat_holds h
     where h.party_id = p_party_id
       and h.status = 'pending'
     order by h.created_at
     for update
  loop
    v_result := public.chart_finalize_hold(v_hold.id);
    v_results := v_results || jsonb_build_object(
      'hold_id', v_hold.id::text,
      'bus_id',  v_hold.bus_id::text,
      'result',  v_result
    );
  end loop;

  return jsonb_build_object('ok', true, 'finalized', v_results);
end;
$$;

revoke all on function public.chart_finalize_party_holds(uuid) from public;
grant execute on function public.chart_finalize_party_holds(uuid)
  to authenticated;


-- ── Verify ───────────────────────────────────────────────────
-- 048's single-bus functions are untouched and remain the path for a
-- one-bus booking.
--
-- A party of 4 split across the two seeded test buses:
--
--   select public.chart_claim_seats_multi(
--     gen_random_uuid(),
--     'aaaa1111-0000-4000-8000-000000000001'::uuid,
--     '9000000009', 'Split Party', 'roundTrip',
--     jsonb_build_array(
--       jsonb_build_object('busId','aaaa1111-0000-4000-8000-0000000000b1',
--                          'requestId', gen_random_uuid(),
--                          'seats', jsonb_build_array(
--                            jsonb_build_object('seatId','SU1','berths',1))),
--       jsonb_build_object('busId','bbbb2222-0000-4000-8000-0000000000b1',
--                          'requestId', gen_random_uuid(),
--                          'seats', jsonb_build_array(
--                            jsonb_build_object('seatId','ST1','berths',1)))));
--
-- Expect two booking_requests sharing one party_id, two passengers, and each
-- passenger's assigned_seats entirely within ONE bus:
--
--   select br.party_id, br.id, p.name,
--          jsonb_array_length(p.assigned_seats) as berths,
--          (select count(distinct s->>'busId')
--             from jsonb_array_elements(p.assigned_seats) s) as buses_per_passenger
--     from public.booking_requests br
--     join public.passengers p on p.id = br.passenger_id
--    where br.party_id is not null;
--   -- buses_per_passenger MUST be 1 for every row.
--
-- Rollback check — a bad seat on the SECOND bus must write nothing at all:
--   ... same call with 'seats' [{"seatId":"NOPE","berths":1}] on bus 2
--   -- expect {"ok": false, "conflicts": [{"bus_id": "...", "seat_id": "NOPE"}]}
--   -- and zero new rows in passengers / booking_requests.
