-- ============================================================
-- OccuBus Booking — trip-direction patch
-- Date: 2026-05-12
--
-- Adds per-passenger trip direction so the agent can record
-- one-way-outbound / one-way-return / round-trip on each booking.
-- The seat on the bus can then be reused on the opposite leg for a
-- different passenger (e.g. one customer joins outbound only because
-- they're staying longer; another customer boards at the destination
-- for the return leg — same physical seat, two riders).
--
-- Idempotent — safe to re-run.
-- ============================================================

-- ─── passengers: add trip_type ──────────────────────────────
-- Allowed values mirror the Dart TripType enum: roundTrip /
-- outboundOnly / returnOnly. We store the enum .name string (no
-- snake_case translation) so the Dart-side serialiser is symmetric.
alter table public.passengers
  add column if not exists trip_type text not null default 'roundTrip';

alter table public.passengers
  drop constraint if exists passengers_trip_type_check;
alter table public.passengers
  add constraint passengers_trip_type_check
  check (trip_type in ('roundTrip', 'outboundOnly', 'returnOnly'));

-- ─── booking_requests: persist trip_type alongside party_size ──
-- The customer form sends a trip_type with each create/update.
-- We mirror it on the audit row so the inbox can show it without
-- joining to passengers.
alter table public.booking_requests
  add column if not exists trip_type text not null default 'roundTrip';

alter table public.booking_requests
  drop constraint if exists booking_requests_trip_type_check;
alter table public.booking_requests
  add constraint booking_requests_trip_type_check
  check (trip_type in ('roundTrip', 'outboundOnly', 'returnOnly'));

-- ─── status_lookup RPC: surface trip_type to the customer ────
-- Postgres refuses CREATE OR REPLACE when the OUT columns change shape,
-- so drop the prior definition first. Safe because the function has no
-- dependent views/policies — it's only called from the customer app.
drop function if exists public.booking_request_status_lookup(uuid);

create or replace function public.booking_request_status_lookup(p_id uuid)
returns table(
  id                 uuid,
  status             text,
  party_size         int,
  customer_name      text,
  customer_phone     text,
  tour_id            uuid,
  tour_title         text,
  tour_from          text,
  tour_to            text,
  tour_departure_date date,
  tour_price_per_seat numeric,
  raw_form           jsonb,
  assigned_seats     jsonb,
  trip_type          text,
  customer_edited_at timestamptz,
  created_at         timestamptz
)
language sql security definer set search_path = public
as $$
  select
    br.id,
    br.status,
    br.party_size,
    br.customer_name,
    br.customer_phone,
    t.id,
    t.title,
    t.from_city,
    t.to_city,
    t.departure_date,
    t.price_per_seat,
    br.raw_form,
    (select p.assigned_seats from public.passengers p
       where p.tour_id = br.tour_id
         and p.phone   = br.customer_phone
       limit 1),
    br.trip_type,
    br.customer_edited_at,
    br.created_at
  from public.booking_requests br
  join public.tours t on t.id = br.tour_id
  where br.id = p_id
  limit 1;
$$;

revoke all on function public.booking_request_status_lookup(uuid) from public;
grant execute on function public.booking_request_status_lookup(uuid)
  to anon, authenticated;

-- ─── customer_update RPC: accept and propagate trip_type ────
-- Adds p_trip_type and updates both booking_requests and the
-- matching passengers row inside the same atomic call. Same gates
-- as before (status still pending, no seats assigned yet).
create or replace function public.booking_request_customer_update(
  p_id            uuid,
  p_party_size    int,
  p_customer_name text,
  p_raw_form      jsonb,
  p_request_lines jsonb,
  p_trip_type     text default 'roundTrip'
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id        uuid;
  v_customer_phone text;
  v_seats_taken    boolean;
begin
  if p_trip_type not in ('roundTrip', 'outboundOnly', 'returnOnly') then
    p_trip_type := 'roundTrip';
  end if;

  select br.tour_id, br.customer_phone
    into v_tour_id, v_customer_phone
    from public.booking_requests br
   where br.id = p_id
     and br.status = 'pending';

  if not found then
    return false;
  end if;

  select exists(
    select 1 from public.passengers p
     where p.tour_id = v_tour_id
       and p.phone   = v_customer_phone
       and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
  ) into v_seats_taken;

  if v_seats_taken then
    return false;
  end if;

  update public.booking_requests
     set party_size         = p_party_size,
         customer_name      = p_customer_name,
         raw_form           = p_raw_form,
         trip_type          = p_trip_type,
         customer_edited_at = now()
   where id = p_id;

  update public.passengers
     set name          = p_customer_name,
         request_lines = p_request_lines,
         trip_type     = p_trip_type
   where tour_id = v_tour_id
     and phone   = v_customer_phone;

  return true;
end;
$$;

revoke all on function public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text)
  from public;
grant execute on function public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text)
  to anon, authenticated;

-- The previous 5-arg signature is left in place so older app builds
-- can still call it (they'll default to roundTrip). Drop it once the
-- mandatory app update is out:
--   drop function if exists public.booking_request_customer_update(uuid, int, text, jsonb, jsonb);
