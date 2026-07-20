-- ============================================================
-- 032  Global pickup locations  (owner-scoped — matches the LIVE schema)
-- ------------------------------------------------------------
-- Admin-managed list of pickup points, shared across every tour the admin owns
-- (NOT per-tour). Customers OPTIONALLY choose one when creating/editing a
-- booking request. The chosen point is snapshotted (id + name) onto the
-- passenger + booking_requests rows so a later rename/retire never breaks a
-- historical request.
--
-- WRITTEN AGAINST THE LIVE DB (verified, not the migration files): production
-- uses the OWNER model — tables carry owner_id and RLS keys on
-- `owner_id = auth.uid()`; customers are anonymous (no auth session); there is
-- NO public.current_user_role() function (an earlier draft of this migration
-- referenced it and failed). booking_requests + passengers already carry
-- passenger_id / trip_type, and submit_booking_request /
-- booking_request_customer_update already exist at their 030-era signatures.
-- This migration therefore mirrors the live `tours` / `buses` policies and only
-- ADDS the pickup pieces.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (do NOT `supabase db push` —
-- the numbered migration history is out of sync with live). Idempotent.
-- ============================================================

-- There is deliberately NO foreign key from passengers/booking_requests to
-- pickup_locations: deleting a point must never cascade into a request. The
-- name snapshot keeps historical requests readable after a point is removed.

-- ── 1. The table (owner-scoped) ────────────────────────────
create table if not exists public.pickup_locations (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid()
               references auth.users(id) on delete cascade,
  name       text not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists pickup_locations_owner_idx
  on public.pickup_locations(owner_id);

alter table public.pickup_locations enable row level security;

-- Customers are anonymous: let `anon` read the ACTIVE points. Mirrors
-- tours_public_read.
drop policy if exists "pickup_locations_anon_read" on public.pickup_locations;
create policy "pickup_locations_anon_read" on public.pickup_locations
  for select to anon using (is_active = true);

-- The admin (owner) manages exactly their own list — sees active + hidden,
-- inserts/updates/deletes only their own. Mirrors tours_owner_all /
-- buses_owner_all. owner_id defaults to auth.uid() so app inserts auto-stamp it.
drop policy if exists "pickup_locations_owner_all" on public.pickup_locations;
create policy "pickup_locations_owner_all" on public.pickup_locations
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ── 2. Snapshot columns on the request rows ────────────────
alter table public.passengers
  add column if not exists pickup_location_id   uuid,
  add column if not exists pickup_location_name text;

alter table public.booking_requests
  add column if not exists pickup_location_id   uuid,
  add column if not exists pickup_location_name text;

-- ── 3. Customer CREATE — carry the pickup snapshot ─────────
-- Drop EVERY existing overload of the name first (defensive: live carries the
-- 9-arg version; dropping all overloads means the recreate below can never
-- leave two candidates for PostgREST to disambiguate). Then recreate with the
-- two optional pickup params appended — old clients that omit them still match
-- via the defaults.
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
     where pronamespace = 'public'::regnamespace and proname = 'submit_booking_request'
  loop
    execute 'drop function ' || r.sig::text || ' cascade';
  end loop;
end $$;

create function public.submit_booking_request(
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

-- ── 4. Customer EDIT — allow updating the pickup snapshot ──
-- Same defensive drop-all-overloads, then recreate with the pickup params
-- appended. Preserves the 030 passenger_id resolution (+ legacy (tour_id, phone)
-- fallback) and the seats-assigned edit gate.
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig from pg_proc
     where pronamespace = 'public'::regnamespace and proname = 'booking_request_customer_update'
  loop
    execute 'drop function ' || r.sig::text || ' cascade';
  end loop;
end $$;

create function public.booking_request_customer_update(
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
begin
  select br.tour_id, br.customer_phone, br.passenger_id
    into v_tour_id, v_customer_phone, v_passenger_id
    from public.booking_requests br
   where br.id = p_id and br.status = 'pending';
  if not found then
    return false;
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
         pickup_location_id   = p_pickup_location_id,
         pickup_location_name = p_pickup_location_name,
         customer_edited_at   = now()
   where id = p_id;

  if v_passenger_id is not null then
    update public.passengers
       set name                 = p_customer_name,
           request_lines        = p_request_lines,
           trip_type            = p_trip_type,
           pickup_location_id   = p_pickup_location_id,
           pickup_location_name = p_pickup_location_name
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
