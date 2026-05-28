-- ============================================================
-- OccuBus Booking — Consolidated Supabase schema (nuke & rebuild)
-- Date: 2026-05-12
--
-- Single source of truth. Drops every project table and recreates
-- everything to match exactly what the Flutter Dart models serialise.
-- Run this in the Supabase SQL editor as the project owner.
--
-- ⚠️  This script DROPS every public table listed below and all rows.
--     Make a backup first if you have data you want to keep.
-- ============================================================


-- ============================================================
-- 0. DROP — remove every existing project object first.
--    Order is reverse-dependency; CASCADE clears triggers / policies.
-- ============================================================

drop trigger if exists on_auth_user_created on auth.users;

drop table if exists public.booking_requests  cascade;
drop table if exists public.admin_contacts    cascade;
drop table if exists public.passengers        cascade;
drop table if exists public.bus_details       cascade;  -- legacy name from 001_initial_schema
drop table if exists public.tours             cascade;
drop table if exists public.buses             cascade;
drop table if exists public.admins            cascade;
drop table if exists public.profiles          cascade;  -- legacy name from 001_initial_schema

drop function if exists public.handle_new_user()   cascade;
drop function if exists public.set_updated_at()    cascade;
drop function if exists public.current_user_role() cascade;

drop type if exists public.user_role      cascade;
drop type if exists public.tour_status    cascade;
drop type if exists public.payment_status cascade;
drop type if exists public.age_group      cascade;
drop type if exists public.seat_type      cascade;


-- ============================================================
-- 1. EXTENSIONS + helpers
-- ============================================================

create extension if not exists pgcrypto;  -- gen_random_uuid()

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ============================================================
-- 2. admins  (one row per authenticated agent)
-- ============================================================

create table public.admins (
  id              uuid primary key references auth.users(id) on delete cascade,
  phone           text unique,
  name            text,
  whatsapp_number text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger admins_set_updated_at before update on public.admins
  for each row execute function public.set_updated_at();

alter table public.admins enable row level security;

create policy "admins_select_self" on public.admins
  for select to authenticated using (id = auth.uid());

create policy "admins_update_self" on public.admins
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "admins_insert_self" on public.admins
  for insert to authenticated with check (id = auth.uid());

-- ------------------------------------------------------------
-- Phone -> admin lookup for the login screen.
--
-- The login flow runs the phone lookup BEFORE the user has a Supabase Auth
-- session (we're trying to decide whether to prompt for a password). RLS
-- on `admins` hides every row from `anon`, so a direct `select` always
-- returns empty and every phone is misclassified as a passenger.
--
-- This SECURITY DEFINER RPC bypasses RLS but only exposes the three
-- columns the login screen actually needs: id, phone, name. WhatsApp
-- number and timestamps stay private until after a successful sign-in
-- (at which point `admins_select_self` lets the user read their own row).
-- ------------------------------------------------------------

create or replace function public.admin_lookup_by_phone(p_phone text)
returns table(id uuid, phone text, name text)
language sql
security definer
set search_path = public
as $$
  select a.id, a.phone, a.name
    from public.admins a
   where a.phone = p_phone
   limit 1;
$$;

revoke all on function public.admin_lookup_by_phone(text) from public;
grant execute on function public.admin_lookup_by_phone(text)
  to anon, authenticated;


-- ============================================================
-- 3. tours
--    Columns mirror Tour.toMap() in lib/models/tour.dart
--    Created BEFORE buses so buses.tour_id can reference it.
--    Note: column is `title` (not `name`) and includes `description`.
-- ============================================================

create table public.tours (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users(id) on delete cascade,
  title           text not null,
  from_city       text not null,
  to_city         text not null,
  departure_date  date not null,
  return_date     date,
  price_per_seat  numeric(10, 2) not null default 0,
  description     text,
  status          text not null default 'planning',
  handler_id      uuid,
  created_by      text,
  is_public       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index tours_owner_status_idx on public.tours(owner_id, status);
create index tours_departure_idx    on public.tours(departure_date);

create trigger tours_set_updated_at before update on public.tours
  for each row execute function public.set_updated_at();

alter table public.tours enable row level security;

create policy "tours_public_read" on public.tours
  for select to anon using (is_public = true);

create policy "tours_owner_all" on public.tours for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());


-- ============================================================
-- 4. buses  (one-to-many under a tour via tour_id)
--    Columns mirror Bus.toMap() in lib/models/bus_details.dart
-- ============================================================

create table public.buses (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users(id) on delete cascade,
  tour_id         uuid references public.tours(id) on delete set null,
  name            text not null default 'Bus',
  registration_no text,
  driver_name     text not null default '',
  driver_phone    text not null default '',
  owner_name      text,
  owner_phone     text,
  is_ac           boolean not null default false,
  bus_type        text not null default 'Semi-Sleeper',
  total_seats     int  not null default 0,
  price_per_seat  numeric(10, 2) not null default 0,
  notes           text,
  layout          jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index buses_owner_idx on public.buses(owner_id);
create index buses_tour_idx  on public.buses(tour_id);

create unique index buses_owner_reg_unique
  on public.buses(owner_id, registration_no)
  where registration_no is not null;

create trigger buses_set_updated_at before update on public.buses
  for each row execute function public.set_updated_at();

alter table public.buses enable row level security;
create policy "buses_owner_all" on public.buses for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());


-- ============================================================
-- 5. passengers
--    Columns mirror Passenger.toMap() in lib/models/passenger.dart
-- ============================================================

create table public.passengers (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id) on delete cascade,
  user_id         uuid references auth.users(id) on delete set null,
  name            text not null,
  phone           text not null,
  age_group       text not null default 'adult',
  request_lines   jsonb not null default '[]'::jsonb,
  assigned_seats  jsonb not null default '[]'::jsonb,
  payment_status  text not null default 'notPaid',
  is_handler      boolean not null default false,
  is_waitlisted   boolean not null default false,
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index passengers_tour_idx on public.passengers(tour_id);
create index passengers_user_idx on public.passengers(user_id);

-- Idempotency: re-submitting from the customer app updates the same row.
create unique index passengers_tour_phone_unique
  on public.passengers(tour_id, phone);

create trigger passengers_set_updated_at before update on public.passengers
  for each row execute function public.set_updated_at();

alter table public.passengers enable row level security;

-- The owning agent of the parent tour has full control.
create policy "passengers_owner_all" on public.passengers
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = passengers.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = passengers.tour_id and t.owner_id = auth.uid()));

-- Anonymous customers can submit a request against a public tour.
create policy "passengers_anon_insert" on public.passengers
  for insert to anon
  with check (exists (select 1 from public.tours t
                      where t.id = passengers.tour_id and t.is_public = true));

-- Anonymous customers can read back their own row by phone (used by the
-- customer mode "my requests" lookup if you add it later).
create policy "passengers_anon_select" on public.passengers
  for select to anon
  using (exists (select 1 from public.tours t
                 where t.id = passengers.tour_id and t.is_public = true));


-- ============================================================
-- 6. admin_contacts  (per-admin phonebook, for WA broadcast targets)
-- ============================================================

create table public.admin_contacts (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  phone       text not null,
  name        text not null,
  source      text not null default 'manual',
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index admin_contacts_owner_phone_unique
  on public.admin_contacts(owner_id, phone);
create index admin_contacts_phone_idx on public.admin_contacts(phone);

create trigger admin_contacts_set_updated_at before update on public.admin_contacts
  for each row execute function public.set_updated_at();

alter table public.admin_contacts enable row level security;
create policy "admin_contacts_owner_all" on public.admin_contacts
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());


-- ============================================================
-- 7. booking_requests  (anonymous customer form intake)
-- ============================================================

create table public.booking_requests (
  id                  uuid primary key default gen_random_uuid(),
  tour_id             uuid not null references public.tours(id) on delete cascade,
  customer_phone      text not null,
  customer_name       text not null,
  party_size          int  not null default 1 check (party_size > 0),
  raw_form            jsonb,
  status              text not null default 'pending',
  -- Stamped by booking_request_customer_update() whenever the customer
  -- edits their own pending request via the My Requests screen. Distinct
  -- from updated_at (which the set_updated_at trigger advances on every
  -- write, admin or customer). Admin UIs use this to detect "edited since
  -- I last looked" and re-sort the inbox.
  customer_edited_at  timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index booking_requests_tour_status_idx
  on public.booking_requests(tour_id, status);

create trigger booking_requests_set_updated_at before update on public.booking_requests
  for each row execute function public.set_updated_at();

alter table public.booking_requests enable row level security;

create policy "booking_requests_anon_insert" on public.booking_requests
  for insert to anon with check (true);

create policy "booking_requests_owner_select" on public.booking_requests
  for select to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = booking_requests.tour_id and t.owner_id = auth.uid()));

create policy "booking_requests_owner_update" on public.booking_requests
  for update to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = booking_requests.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = booking_requests.tour_id and t.owner_id = auth.uid()));

-- ------------------------------------------------------------
-- Customer-side RPCs.
--
-- The customer is anonymous (no Supabase Auth session). RLS hides
-- booking_requests rows from `anon` for SELECT, and we don't want to open
-- arbitrary anon updates either. These two SECURITY DEFINER functions
-- give the customer's "My Requests" screen exactly what it needs and
-- nothing more — keyed on the request UUID the customer already has on
-- their device (knowing a random UUIDv4 ≈ free read of one row, no
-- enumeration risk).
-- ------------------------------------------------------------

-- READ: latest status + seats for one specific booking request.
-- The assigned_seats column comes from the matching passenger row
-- (matched by tour_id + customer_phone), which is where the admin's
-- seat assignment actually lives.
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

-- READ: bus layouts for the buses where this booking request has at least
-- one assigned seat. Customers are anonymous and can't select from
-- public.buses directly (owner_id RLS), so we expose just the seat-layout
-- shaped rows they need to render their own seats on the bus diagram.
create or replace function public.bus_layouts_for_request(p_id uuid)
returns table(
  id              uuid,
  tour_id         uuid,
  name            text,
  registration_no text,
  bus_type        text,
  total_seats     int,
  layout          jsonb
)
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_id
  ),
  seats as (
    select distinct (elem ->> 'busId')::uuid as bus_id
      from public.passengers p
      join req on req.tour_id = p.tour_id
                and req.customer_phone = p.phone
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as elem
     where elem ? 'busId'
  )
  select b.id, b.tour_id, b.name, b.registration_no,
         b.bus_type, b.total_seats, b.layout
    from public.buses b
    join seats on seats.bus_id = b.id;
$$;

revoke all on function public.bus_layouts_for_request(uuid) from public;
grant execute on function public.bus_layouts_for_request(uuid)
  to anon, authenticated;

-- UPDATE: customer edits their own pending request.
-- Server enforces both gates:
--   1) booking_requests.status must still be 'pending'
--   2) the matching passenger row (if any) must have no seats assigned
-- Updates BOTH tables atomically so the admin's Requests UI (which reads
-- the passengers row) stays in sync with the booking_requests audit row.
-- Returns true on success, false when blocked by the gates above.
create or replace function public.booking_request_customer_update(
  p_id            uuid,
  p_party_size    int,
  p_customer_name text,
  p_raw_form      jsonb,
  p_request_lines jsonb
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id        uuid;
  v_customer_phone text;
  v_seats_taken    boolean;
begin
  -- Resolve the request and capture its (tour_id, customer_phone) pair —
  -- those identify the matching passenger row.
  select br.tour_id, br.customer_phone
    into v_tour_id, v_customer_phone
    from public.booking_requests br
   where br.id = p_id
     and br.status = 'pending';

  if not found then
    return false;
  end if;

  -- Gate: refuse the edit if the admin has already assigned seats.
  select exists(
    select 1 from public.passengers p
     where p.tour_id = v_tour_id
       and p.phone   = v_customer_phone
       and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
  ) into v_seats_taken;

  if v_seats_taken then
    return false;
  end if;

  -- Audit row.
  update public.booking_requests
     set party_size         = p_party_size,
         customer_name      = p_customer_name,
         raw_form           = p_raw_form,
         customer_edited_at = now()
   where id = p_id;

  -- Live admin-facing row. The customer flow always upserts a passenger
  -- on submit, so this update should hit exactly one row; the where-clause
  -- is defensive (no-op if the passenger row was deleted in between).
  update public.passengers
     set name          = p_customer_name,
         request_lines = p_request_lines
   where tour_id = v_tour_id
     and phone   = v_customer_phone;

  return true;
end;
$$;

revoke all on function public.booking_request_customer_update(uuid, int, text, jsonb, jsonb) from public;
grant execute on function public.booking_request_customer_update(uuid, int, text, jsonb, jsonb)
  to anon, authenticated;


-- ============================================================
-- 8. Auto-seed an admins row when an auth user signs up
-- ============================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.admins (id, phone, name, whatsapp_number)
  values (
    new.id,
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'whatsapp_number'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
-- 9. Realtime — let the app subscribe to changes
-- ============================================================

alter publication supabase_realtime add table public.tours;
alter publication supabase_realtime add table public.passengers;
alter publication supabase_realtime add table public.buses;
-- booking_requests is added so the admin app receives a live push when a
-- customer submits or edits a request, instead of needing a manual refresh.
alter publication supabase_realtime add table public.booking_requests;


-- ============================================================
-- 10. Seed test admin
--     Name:    zeel
--     Phone:   9327148044
--     Email:   9327148044@occubus.local   (synthetic — see SupabaseConfig)
--     Pass:    Zeel@1234
--
--     Idempotent: deletes any existing user with this email first, so
--     re-running the script always produces a clean, working login.
--
--     The on_auth_user_created trigger above will mirror this user into
--     public.admins automatically; the explicit upsert at the bottom is
--     a belt-and-braces safety net in case the trigger is ever disabled.
-- ============================================================

do $$
declare
  v_email   text := '9327148044@occubus.local';
  v_phone   text := '9327148044';
  v_name    text := 'zeel';
  v_pw      text := 'Zeel@1234';
  v_user_id uuid;
begin
  -- Wipe any prior copy of this user; cascades to public.admins.
  delete from auth.users where email = v_email;

  v_user_id := gen_random_uuid();

  insert into auth.users (
    instance_id, id, aud, role,
    email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000', v_user_id,
    'authenticated', 'authenticated',
    v_email, crypt(v_pw, gen_salt('bf')), now(),
    jsonb_build_object('provider', 'email',
                       'providers', jsonb_build_array('email')),
    jsonb_build_object('name', v_name,
                       'phone', v_phone,
                       'whatsapp_number', v_phone),
    now(), now(),
    '', '', '', ''
  );

  insert into auth.identities (
    id, user_id, provider, provider_id, identity_data,
    last_sign_in_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), v_user_id, 'email', v_user_id::text,
    jsonb_build_object('sub', v_user_id::text,
                       'email', v_email,
                       'email_verified', true),
    now(), now(), now()
  );

  -- Fallback in case the on_auth_user_created trigger didn't populate admins.
  insert into public.admins (id, phone, name, whatsapp_number)
  values (v_user_id, v_phone, v_name, v_phone)
  on conflict (id) do update
     set phone           = excluded.phone,
         name            = excluded.name,
         whatsapp_number = excluded.whatsapp_number;

  raise notice 'Seeded admin % (id=%, email=%)', v_name, v_user_id, v_email;
end $$;


-- ============================================================
-- DONE.  Verify with:
--   select table_name
--     from information_schema.tables
--     where table_schema='public'
--     order by table_name;
--
-- Expected tables: admin_contacts, admins, booking_requests, buses,
--                  passengers, tours
--
-- Verify the test admin exists:
--   select a.id, a.phone, a.name, u.email
--     from public.admins a
--     join auth.users  u on u.id = a.id
--    where a.phone = '9327148044';
--
-- Then log in from the app with:
--   phone:    9327148044
--   password: Zeel@1234
-- ============================================================
