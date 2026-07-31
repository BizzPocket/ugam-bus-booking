-- ============================================================
-- 045  Pickup point is REQUIRED on every booking request
-- ------------------------------------------------------------
-- 032 made the pickup point OPTIONAL. That decision is reversed: a request
-- created without a pickup point leaves the roster and the driver's chart
-- guessing where to collect the rider, so it must never be created that way.
--
-- The Flutter form (BookingCaptureForm.requirePickup, now ON by default on
-- EVERY capture surface — customer, admin add, admin edit, return-ticket) is
-- the primary gate. This migration is the BACKSTOP for what the app can't
-- police: a customer running a stale build, or anything calling the anon RPCs
-- directly. Without it the client rule is advisory only.
--
-- Two holes are closed:
--   1. submit_booking_request accepted a null pickup silently.
--   2. booking_request_customer_update wrote the incoming pickup
--      UNCONDITIONALLY, so an edit from a stale client (which sends null)
--      WIPED a pickup the customer had already chosen.
--
-- The enforcement mirrors the client rule exactly, including its escape hatch:
-- a pickup is only demanded when the tour's owner actually HAS active pickup
-- points. An owner who hasn't configured any (or a legacy tour with a null
-- owner_id — see 036) is never blocked, because there would be nothing to pick
-- and the field is hidden in the app.
--
-- Deliberately NOT a NOT NULL / CHECK constraint on the columns: historical
-- rows predate the rule and must stay readable, and the no-points-configured
-- escape hatch has to remain legal.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (do NOT `supabase db push` —
-- the numbered migration history is out of sync with live). Idempotent.
-- ============================================================

-- ── 1. Does this tour's owner have any active pickup points? ──
-- SECURITY DEFINER so the anon-facing RPCs can consult the owner's list, which
-- anon RLS otherwise only exposes for is_active = true rows. Returns false for
-- an unknown tour or a legacy null owner_id, so those never block a booking.
create or replace function public.tour_requires_pickup(p_tour_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.tours t
      join public.pickup_locations pl on pl.owner_id = t.owner_id
     where t.id = p_tour_id
       and t.owner_id is not null
       and pl.is_active
  );
$$;

revoke all on function public.tour_requires_pickup(uuid) from public;
grant execute on function public.tour_requires_pickup(uuid) to anon, authenticated;

-- ── 2. Customer CREATE — reject a pickup-less submission ──
-- Same signature as 032 (create-or-replace requires identical parameter names
-- and types); only the pickup guard is added.
create or replace function public.submit_booking_request(
  p_request_id   uuid,
  p_tour_id      uuid,
  p_phone        text,
  p_name         text,
  p_party_size   int,
  p_trip_type    text,
  p_raw_form     jsonb,
  p_request_lines jsonb,
  p_note         text default null,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_public       boolean;
  v_status       text;
  v_passenger_id uuid;
begin
  select is_public, status into v_public, v_status
    from public.tours where id = p_tour_id;
  if v_public is distinct from true then
    raise exception 'This tour is not open for booking.'
      using errcode = 'check_violation';
  end if;
  if v_status in ('locked', 'completed') then
    raise exception 'Bookings are closed for this tour.'
      using errcode = 'check_violation';
  end if;

  -- Pickup is mandatory whenever there is a list to pick from.
  if p_pickup_location_id is null and public.tour_requires_pickup(p_tour_id) then
    raise exception 'Please choose a pickup point.'
      using errcode = 'check_violation';
  end if;

  insert into public.passengers
    (tour_id, name, phone, request_lines, trip_type, note,
     pickup_location_id, pickup_location_name)
  values
    (p_tour_id, p_name, p_phone, p_request_lines, p_trip_type, p_note,
     p_pickup_location_id, p_pickup_location_name)
  returning id into v_passenger_id;

  insert into public.booking_requests
    (id, tour_id, customer_phone, customer_name, party_size, trip_type, raw_form,
     passenger_id, pickup_location_id, pickup_location_name)
  values
    (p_request_id, p_tour_id, p_phone, p_name, p_party_size, p_trip_type, p_raw_form,
     v_passenger_id, p_pickup_location_id, p_pickup_location_name);

  return p_request_id;
end;
$$;

revoke all on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text, uuid, text)
  from public;
grant execute on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text, uuid, text)
  to anon, authenticated;

-- ── 3. Customer EDIT — never null out an existing pickup ──
-- Body is 032's, with two changes: the same mandatory guard, and the pickup
-- writes now COALESCE onto the stored value so an omitted/null pickup from a
-- stale client leaves the existing choice intact instead of erasing it.
create or replace function public.booking_request_customer_update(
  p_id            uuid,
  p_party_size    int,
  p_customer_name text,
  p_raw_form      jsonb,
  p_request_lines jsonb,
  p_trip_type     text,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_tour_id        uuid;
  v_customer_phone text;
  v_passenger_id   uuid;
  v_seats_taken    boolean;
  v_existing_pid   uuid;
begin
  select br.tour_id, br.customer_phone, br.passenger_id, br.pickup_location_id
    into v_tour_id, v_customer_phone, v_passenger_id, v_existing_pid
    from public.booking_requests br
   where br.id = p_id and br.status = 'pending';
  if not found then
    return false;
  end if;

  -- Mandatory unless the request already carries one (an edit that doesn't
  -- touch the pickup must still go through) or there is no list to pick from.
  if p_pickup_location_id is null
     and v_existing_pid is null
     and public.tour_requires_pickup(v_tour_id) then
    raise exception 'Please choose a pickup point.'
      using errcode = 'check_violation';
  end if;

  if v_passenger_id is null then
    select p.id into v_passenger_id
      from public.passengers p
     where p.tour_id = v_tour_id
       and p.phone   = v_customer_phone
     order by p.created_at desc
     limit 1;
    if v_passenger_id is not null then
      update public.booking_requests
         set passenger_id = v_passenger_id
       where id = p_id;
    end if;
  end if;

  if v_passenger_id is not null then
    select exists(
      select 1 from public.passengers p
       where p.id = v_passenger_id
         and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
    ) into v_seats_taken;
    if v_seats_taken then
      return false;
    end if;
  end if;

  update public.booking_requests
     set party_size           = p_party_size,
         customer_name        = p_customer_name,
         raw_form             = p_raw_form,
         trip_type            = p_trip_type,
         pickup_location_id   = coalesce(p_pickup_location_id, pickup_location_id),
         pickup_location_name = coalesce(p_pickup_location_name, pickup_location_name),
         customer_edited_at   = now()
   where id = p_id;

  if v_passenger_id is not null then
    update public.passengers
       set name                 = p_customer_name,
           request_lines        = p_request_lines,
           trip_type            = p_trip_type,
           pickup_location_id   = coalesce(p_pickup_location_id, pickup_location_id),
           pickup_location_name = coalesce(p_pickup_location_name, pickup_location_name)
     where id = v_passenger_id;
  end if;

  return true;
end;
$$;

revoke all on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text, uuid, text) from public;
grant execute on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text, uuid, text)
  to anon, authenticated;
