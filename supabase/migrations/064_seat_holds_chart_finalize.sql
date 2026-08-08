-- ============================================================
-- 064  Soft seat holds for chart advance checkout
-- ------------------------------------------------------------
-- Revises 048's "no hold table" stance ONLY for tours that collect an
-- online advance. Final occupancy remains passengers.assigned_seats;
-- holds are a TTL overlay so availability can block double-sale during
-- the 5-minute pay window.
--
-- Flow:
--   chart_hold_seats  → pending hold (5 min)
--   customer asserts UPI via payment_claims (hold_id linked)
--   confirm_payment_claim OR chart_pay_later_hold → chart_finalize_hold
--     → passenger + booking_request, hold status = finalized
--
-- Tours without advance keep using chart_claim_seats (instant final).
-- Idempotent. Apply in Supabase SQL editor after 060.
-- ============================================================

do $$
begin
  if to_regclass('public.tours') is null then
    raise exception '064 requires base tours schema';
  end if;
end $$;

-- ── 1. Holds ─────────────────────────────────────────────────

create table if not exists public.seat_holds (
  id                   uuid primary key default gen_random_uuid(),
  tour_id              uuid not null references public.tours(id) on delete cascade,
  bus_id               uuid not null references public.buses(id) on delete cascade,
  request_id           uuid not null unique,

  phone                text not null,
  name                 text not null,
  leg                  text not null
                         check (leg in ('roundTrip','outboundOnly','returnOnly')),
  -- Same shape as chart_claim_seats p_seats: [{seatId, berths, type, position}]
  seats                jsonb not null,
  gender               text check (gender is null or gender in ('male','female')),
  note                 text,
  pickup_location_id   uuid,
  pickup_location_name text,

  status               text not null default 'pending'
                         check (status in ('pending','finalized','released','expired')),
  expires_at           timestamptz not null,
  payment_claim_id     uuid references public.payment_claims(id) on delete set null,
  passenger_id         uuid references public.passengers(id) on delete set null,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists seat_holds_tour_pending_idx
  on public.seat_holds(tour_id)
  where status = 'pending';

create index if not exists seat_holds_expires_idx
  on public.seat_holds(expires_at)
  where status = 'pending';

alter table public.seat_holds enable row level security;

drop policy if exists "seat_holds_owner_all" on public.seat_holds;
create policy "seat_holds_owner_all" on public.seat_holds
  for all using (
    exists (select 1 from public.tours t
             where t.id = seat_holds.tour_id and t.owner_id = auth.uid())
  )
  with check (
    exists (select 1 from public.tours t
             where t.id = seat_holds.tour_id and t.owner_id = auth.uid())
  );

-- Link claims → holds (optional; 060 may already exist without this column)
alter table public.payment_claims
  add column if not exists seat_hold_id uuid references public.seat_holds(id)
    on delete set null;

create index if not exists payment_claims_hold_idx
  on public.payment_claims(seat_hold_id)
  where seat_hold_id is not null;


-- ── 2. Occupancy helper: passengers ∪ active holds ───────────

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
    -- Active soft holds (each berth in seats jsonb)
    select h.leg as leg,
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


-- ── 3. Create hold (anon) ────────────────────────────────────

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
  v_claims     jsonb := '[]'::jsonb;
  v_conflicts  text[] := '{}';
  v_seat       jsonb;
  v_seat_id    text;
  v_berths     int;
  v_type       text;
  v_pos        text;
  v_cap        int;
  v_used_go    int;
  v_used_ret   int;
  v_wants_go   boolean;
  v_wants_ret  boolean;
  v_hold_id    uuid;
  v_expires    timestamptz := now() + interval '5 minutes';
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
      'type',   v_type,    'position', v_pos
    );
  end loop;

  if array_length(v_conflicts, 1) > 0 then
    return jsonb_build_object('ok', false, 'conflicts', to_jsonb(v_conflicts));
  end if;

  insert into public.seat_holds (
    id, tour_id, bus_id, request_id, phone, name, leg, seats,
    gender, note, pickup_location_id, pickup_location_name,
    status, expires_at
  ) values (
    gen_random_uuid(), p_tour_id, p_bus_id, p_request_id, p_phone, p_name,
    p_leg, v_claims, p_gender, p_note, p_pickup_location_id,
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

revoke all on function public.chart_hold_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) from public;
grant execute on function public.chart_hold_seats(
  uuid, uuid, uuid, text, text, text, jsonb, text, text, uuid, text
) to anon, authenticated;


-- ── 4. Finalize hold → passenger (owner) ─────────────────────

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
  v_wants_go     boolean;
  v_wants_ret    boolean;
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

  v_wants_go  := h.leg in ('roundTrip', 'outboundOnly');
  v_wants_ret := h.leg in ('roundTrip', 'returnOnly');

  -- Re-validate vs OTHER holds + passengers (exclude this hold)
  for v_seat in select * from jsonb_array_elements(h.seats)
  loop
    v_seat_id := v_seat->>'seatId';
    v_berths  := coalesce((v_seat->>'berths')::int, 1);
    v_type    := v_seat->>'type';
    v_cap     := case when v_type = 'doubleSofa' then 2 else 1 end;

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
        select oh.leg, coalesce((c->>'berths')::int, 1)
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

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'busId',  h.bus_id::text,
             'seatId', c->>'seatId',
             'leg',    h.leg
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
             'leg',      h.leg
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
        from jsonb_array_elements(h.seats) c
       group by 1, 2
    ) g;

  v_total := jsonb_array_length(v_assigned);

  insert into public.passengers (
    id, tour_id, name, phone, gender, request_lines, assigned_seats,
    note, trip_type, is_confirmed, pickup_location_id, pickup_location_name
  ) values (
    v_passenger_id, h.tour_id, h.name, h.phone, h.gender, v_lines, v_assigned,
    h.note, h.leg, true, h.pickup_location_id, h.pickup_location_name
  );

  insert into public.booking_requests (
    id, tour_id, passenger_id, customer_phone, customer_name, party_size,
    trip_type, raw_form, pickup_location_id, pickup_location_name
  ) values (
    h.request_id, h.tour_id, v_passenger_id, h.phone, h.name, v_total,
    h.leg,
    jsonb_build_object(
      'source', 'chart_hold',
      'bus_id', h.bus_id::text,
      'seats',  h.seats,
      'leg',    h.leg,
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

revoke all on function public.chart_finalize_hold(uuid) from public;
grant execute on function public.chart_finalize_hold(uuid) to authenticated;


-- ── 5. Availability includes active holds ────────────────────

create or replace function public.chart_seat_availability(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with occ as (
    select seat->>'busId'  as bus_id,
           seat->>'seatId' as seat_id,
           coalesce(nullif(seat->>'leg', ''), p.trip_type, 'roundTrip') as leg,
           p.gender as gender,
           1 as berths
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as seat
     where p.tour_id = p_tour_id
       and p.cancelled_at is null
       and coalesce(seat->>'busId', '')  <> ''
       and coalesce(seat->>'seatId', '') <> ''
    union all
    select h.bus_id::text,
           c->>'seatId',
           h.leg,
           h.gender,
           coalesce((c->>'berths')::int, 1)
      from public.seat_holds h
      cross join lateral jsonb_array_elements(h.seats) c
     where h.tour_id = p_tour_id
       and h.status = 'pending'
       and h.expires_at > now()
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
                     'used_go',  sum(berths) filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'used_ret', sum(berths) filter (
                                   where leg in ('roundTrip', 'returnOnly')),
                     'lady_go',  bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'lady_ret', bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'returnOnly')),
                     'held',     bool_or(gender is not distinct from gender)
                                   -- marker only; client treats occupancy same
                   ) as o
              from occ
             group by bus_id, seat_id
          ) g
      ),
      '[]'::jsonb
    )
  end;
$$;


-- ── 6. Admin: list pending holds for a tour ──────────────────

create or replace function public.tour_pending_seat_holds(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case
    when not exists (
      select 1 from public.tours t
       where t.id = p_tour_id and t.owner_id = auth.uid()
    ) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(jsonb_build_object(
                 'id',          h.id,
                 'request_id',  h.request_id,
                 'bus_id',      h.bus_id,
                 'phone',       h.phone,
                 'name',        h.name,
                 'leg',         h.leg,
                 'seats',       h.seats,
                 'expires_at',  h.expires_at,
                 'created_at',  h.created_at
               ) order by h.created_at desc)
          from public.seat_holds h
         where h.tour_id = p_tour_id
           and h.status = 'pending'
           and h.expires_at > now()
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.tour_pending_seat_holds(uuid) from public;
grant execute on function public.tour_pending_seat_holds(uuid) to authenticated;


-- ── 7. confirm_payment_claim also finalizes linked hold ──────

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
  v_fin        jsonb;
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

  -- Finalize linked hold BEFORE posting money so passenger_id exists
  if c.seat_hold_id is not null and c.passenger_id is null then
    begin
      select chart_finalize_hold(c.seat_hold_id) into v_fin;
      select * into c from public.payment_claims where id = p_claim_id;
    exception when others then
      raise;
    end;
  end if;

  if c.status = 'confirmed' then
    return c.finance_entry_id;
  end if;
  if c.status = 'rejected' then
    raise exception 'claim was already rejected';
  end if;

  perform public.finance_set_actor('admin', 'advance confirmation');

  select o_entry into v_entry from public.backfill_post(
    c.tour_id, 'online_payment', 'claim:' || c.id,
    c.claimed_at, c.amount_paise,
    'bank.gateway', null, null,
    'ar.rider',     null, c.passenger_id,
    'payment_claims', c.id, 'upi_advance',
    coalesce(p_note, 'UPI advance' ||
      case when c.upi_ref is null then '' else ' ref ' || c.upi_ref end)
  );

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
          amount_due, amount_received, amount_refunded, note, collected_by
        )
        values (
          c.tour_id, v_seat.bus_id, c.passenger_id, v_seat.seat_id,
          v_due / 100.0, v_apply / 100.0, 0,
          'UPI advance' || case when c.upi_ref is null then ''
                                else ' ref ' || c.upi_ref end,
          'online'
        )
        on conflict (passenger_id, bus_id, seat_id) where deleted_at is null
        do update set
          amount_received = public.collections.amount_received
                            + excluded.amount_received,
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

  update public.payment_claims
     set status = 'confirmed',
         reviewed_at = now(),
         reviewed_by = auth.uid(),
         review_note = p_note,
         finance_entry_id = v_entry,
         updated_at = now()
   where id = p_claim_id;

  return v_entry;
end;
$$;


-- ── 8. Claim UPI against a pending hold (no booking_request yet) ──

create or replace function public.claim_upi_advance_for_hold(
  p_hold_id      uuid,
  p_amount_paise bigint,
  p_upi_ref      text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  h    record;
  v_id uuid;
begin
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'claim amount must be positive';
  end if;
  if p_amount_paise > 100000000 then
    raise exception 'claim amount is implausibly large';
  end if;

  select * into h from public.seat_holds where id = p_hold_id;
  if not found then
    raise exception 'unknown hold';
  end if;
  if h.status <> 'pending' or h.expires_at <= now() then
    raise exception 'hold expired or missing' using errcode = 'check_violation';
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

  update public.seat_holds
     set payment_claim_id = v_id, updated_at = now()
   where id = h.id;

  return v_id;
end;
$$;

revoke all on function public.claim_upi_advance_for_hold(uuid, bigint, text) from public;
grant execute on function public.claim_upi_advance_for_hold(uuid, bigint, text)
  to anon, authenticated;

comment on table public.seat_holds is
  'Temporary chart checkout holds (5 min). Final seats live on passengers.assigned_seats only after chart_finalize_hold.';
