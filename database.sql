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

drop table if exists public.bus_handovers     cascade;
drop table if exists public.expenses          cascade;
drop table if exists public.collections       cascade;
drop table if exists public.device_tokens     cascade;
drop table if exists public.booking_requests  cascade;
drop table if exists public.customer_memory   cascade;
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
  -- Admin self-service settings (migration 008).
  business_name              text,
  business_email             text,
  upi_id                     text,
  payee_name                 text,
  default_advance            numeric(12, 2),
  receipt_note               text,
  wa_handoff_template        text,
  notify_booking_requests    boolean not null default true,
  notify_payment_reminders   boolean not null default true,
  notify_departure_reminders boolean not null default true,
  push_enabled               boolean not null default true,
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
   where right(regexp_replace(a.phone, '\D', '', 'g'), 10)
       = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
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
  -- Local departure time-of-day on departure_date. Null until the agent
  -- sets it; kept separate from the date so an unset time is distinct from
  -- midnight and the date column/indexes keep their date semantics.
  departure_time  time,
  return_date     date,
  -- Local return time-of-day on return_date. Null when unset.
  return_time     time,
  price_per_seat  numeric(10, 2) not null default 0,
  description     text,
  status          text not null default 'planning',
  handler_id      uuid,
  created_by      text,
  is_public       boolean not null default true,
  -- Phase-2 WhatsApp broadcast composed at create time (announcement text +
  -- optional hero image in Supabase Storage). Sent via the whatsapp-send Edge
  -- Function. Null until the agent fills the broadcast composer.
  broadcast_message    text,
  broadcast_image_url  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index tours_owner_status_idx on public.tours(owner_id, status);
create index tours_departure_idx    on public.tours(departure_date);

-- Migration (safe on existing DBs): departure/return time-of-day columns.
alter table public.tours add column if not exists departure_time time;
alter table public.tours add column if not exists return_time    time;

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
  -- Full rent paid to the bus owner for this bus. Auto-counted as a `busOwner`
  -- expense in the app's money summaries (single source of truth — never a
  -- separate expenses row), so the handler can't double-count it.
  bus_price       numeric(10, 2) not null default 0,
  -- Per-bus departure place / venue; overrides the tour-level boarding place
  -- wherever boarding is shown (esp. the PDF footer).
  boarding_point  text not null default '',
  -- Per-bus departure time, canonical 'HH:mm' (mirrors tours.departure_time);
  -- overrides the tour-level / chart-footer time wherever boarding is shown.
  -- Nullable; null means no per-bus time set.
  departure_time  text,
  -- Optional rear-zone pricing: the last `rear_rows` rows are charged at
  -- `rear_price` per person instead of price_per_seat. rear_rows = 0 means
  -- no rear zone; rear_price null means rear rows fall back to the base price.
  -- LEGACY: superseded by `price_bands` (see below). The app exposes the rear
  -- zone to the pricing engine as a synthesized trailing band, so both keep
  -- working together; explicit price_bands take priority on overlapping rows.
  rear_rows         integer not null default 0,
  rear_price        numeric(10, 2),
  -- Flexible, named price bands: a JSON array of
  --   { "label": text, "fromRow": int, "toRow": int, "price": numeric }
  -- where rows are 0-based inclusive and price is PER BERTH (per person). A band
  -- overrides the base + per-type pricing for the rows it covers; the FIRST
  -- matching band wins on overlap. Defaults to an empty array (no bands).
  price_bands       jsonb not null default '[]'::jsonb,
  -- Optional per-seat-type overrides; null means fall back to price_per_seat.
  single_sofa_price numeric(10, 2),
  double_sofa_price numeric(10, 2),
  seater_price      numeric(10, 2),
  -- Per-bus handler: the passenger who runs THIS bus on the ground. Replaces the
  -- legacy tour-wide handler (tours.handler_id, kept in sync as a "tour has a
  -- handler" pointer). A per-bus handler's manifest is scoped to only their
  -- bus(es). FK to passengers(id) is added AFTER the passengers table exists
  -- (see below) because buses is created before passengers in this script.
  handler_passenger_id uuid,
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
-- 4b. passenger_groups
--    Cross-booking groups that must ride the same bus.
--    Mirrors PassengerGroup.toMap() in lib/models/passenger_group.dart
-- ============================================================

create table public.passenger_groups (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  label       text not null,
  color_index int  not null default 0,
  created_at  timestamptz not null default now()
);

create index passenger_groups_tour_idx on public.passenger_groups(tour_id);

alter table public.passenger_groups enable row level security;
create policy "passenger_groups_owner_all" on public.passenger_groups
  for all to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()));


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
  trip_type       text not null default 'roundTrip',
  request_lines   jsonb not null default '[]'::jsonb,
  assigned_seats  jsonb not null default '[]'::jsonb,
  payment_status  text not null default 'notPaid',
  is_handler      boolean not null default false,
  is_waitlisted   boolean not null default false,
  is_confirmed    boolean not null default false,
  -- Half-trip completion: when the agent finishes the outbound (GO) leg, every
  -- GO-only passenger has their seats freed and this flag set, so the return
  -- leg's chart shows those seats empty while the record is kept for money/
  -- history. The Dart Passenger model already serialises this column.
  journey_done    boolean not null default false,
  note            text,
  group_id        uuid references public.passenger_groups(id) on delete set null,
  priority_status text not null default 'none',
  priority_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index passengers_tour_idx on public.passengers(tour_id);
create index passengers_user_idx on public.passengers(user_id);
create index passengers_group_idx on public.passengers(tour_id, group_id);

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

-- SECURITY: there is intentionally NO anon SELECT policy on passengers.
-- A blanket "anon can read every passenger on any public tour" policy would
-- leak full PII (name, phone, payment, seat) of all passengers to any
-- unauthenticated caller who knows/guesses a tour_id. The customer "my
-- requests" lookup must instead go through a SECURITY DEFINER RPC that
-- returns ONLY the caller's own row (scoped by their verified phone), e.g.
-- get_booking_status / cancel_my_booking. Drop the old policy if present.
drop policy if exists "passengers_anon_select" on public.passengers;

-- Per-bus handler FK — added here because buses is created before passengers.
-- `on delete set null`: removing a passenger un-assigns them as a bus handler
-- rather than blocking the delete.
alter table public.buses
  add constraint buses_handler_passenger_fk
  foreign key (handler_passenger_id)
  references public.passengers(id) on delete set null;

create index buses_handler_passenger_idx
  on public.buses(handler_passenger_id);


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
-- 6b. customer_memory  (per-admin, phone-keyed repeat-customer memory)
--    ~80% of customers repeat across tours, but priority + group
--    membership live ONLY inside per-tour `passengers` rows, which
--    cascade-delete with the tour. Before a tour is deleted, the app
--    snapshots each passenger's agent-set priority and their travel
--    companions (the other phones in their group) into this table, so a
--    returning phone can have its priority auto-restored and its usual
--    group recreated in one tap.
--    Mirrors CustomerMemory.toMap() in lib/models/customer_memory.dart
-- ============================================================

create table public.customer_memory (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users(id) on delete cascade,
  phone           text not null,            -- 10-digit normalised key
  name            text not null default '',
  priority_status text not null default 'none',
  priority_reason text,
  companions      jsonb not null default '[]'::jsonb,  -- array of companion phones
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- One memory row per (admin, phone). Upserts target this constraint.
create unique index customer_memory_owner_phone_unique
  on public.customer_memory(owner_id, phone);
create index customer_memory_phone_idx on public.customer_memory(phone);

create trigger customer_memory_set_updated_at before update on public.customer_memory
  for each row execute function public.set_updated_at();

alter table public.customer_memory enable row level security;
create policy "customer_memory_owner_all" on public.customer_memory
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

-- READ: "Find my seat by phone" — every seat held under a mobile number on a
-- LOCKED/completed tour, with the bus diagram(s). Bypasses booking_requests so
-- manually-added passengers (who have no in-app ticket) can still see their
-- seat. Phone is matched on the LAST 10 DIGITS so +91/spaces never miss. See
-- migration 027_seat_lookup_by_phone.sql for full notes.
create or replace function public.seat_lookup_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  pax as (
    select p.id, p.tour_id, p.name, p.assigned_seats
      from public.passengers p
      join public.tours t on t.id = p.tour_id
      cross join norm
     where norm.last10 <> ''
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status in ('locked', 'completed')
       and p.assigned_seats is not null
       and p.assigned_seats <> '[]'::jsonb
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tour_id',        t.id,
        'tour_title',     t.title,
        'from_city',      t.from_city,
        'to_city',        t.to_city,
        'departure_date', t.departure_date,
        'status',         t.status,
        'passenger_name', pax.name,
        'assigned_seats', pax.assigned_seats,
        'buses', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id',              b.id,
                'tour_id',         b.tour_id,
                'name',            b.name,
                'registration_no', b.registration_no,
                'bus_type',        b.bus_type,
                'total_seats',     b.total_seats,
                'layout',          b.layout,
                'boarding_point',  b.boarding_point,
                'departure_time',  b.departure_time
              )
              order by b.name
            ),
            '[]'::jsonb
          )
            from public.buses b
           where b.tour_id = t.id
             and b.id::text in (
               select distinct seat ->> 'busId'
                 from jsonb_array_elements(pax.assigned_seats) seat
                where seat ? 'busId'
             )
        )
      )
      order by t.departure_date desc
    ),
    '[]'::jsonb
  )
    from pax
    join public.tours t on t.id = pax.tour_id;
$$;

revoke all on function public.seat_lookup_by_phone(text) from public;
grant execute on function public.seat_lookup_by_phone(text)
  to anon, authenticated;

-- READ: is the caller's booking request owned by a tour handler?
-- A handler is a passenger (matched by tour_id + customer_phone) flagged
-- is_handler = true. Returns false (never errors) for unknown request ids.
create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.booking_requests br
        join public.passengers p
          on p.tour_id = br.tour_id
         and p.phone   = br.customer_phone
       where br.id = p_request_id
         and p.is_handler = true
    ),
    false
  );
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;

-- NOTE: handler_tour_manifest + handler_upsert_collection are defined further
-- down, immediately after the public.collections table, because the manifest's
-- SQL body references public.collections and must be created after it exists.

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
-- 7.1 collections  (one row per passenger+bus+seat money record)
--     amount due / received / refunded for a passenger on a bus.
--     Tour-scoped child table: RLS via the tours-owner join.
-- ============================================================

create table public.collections (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id) on delete cascade,
  bus_id          uuid not null references public.buses(id) on delete cascade,
  passenger_id    uuid not null references public.passengers(id) on delete cascade,
  seat_id         text not null default '',
  amount_due      numeric(10, 2) not null default 0,
  amount_received numeric(10, 2) not null default 0,
  amount_refunded numeric(10, 2) not null default 0,
  note            text,
  collected_by    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create unique index collections_passenger_bus_seat_unique
  on public.collections(passenger_id, bus_id, seat_id);
create index collections_tour_idx on public.collections(tour_id);
create index collections_bus_idx  on public.collections(bus_id);

create trigger collections_set_updated_at before update on public.collections
  for each row execute function public.set_updated_at();

alter table public.collections enable row level security;
create policy "collections_owner_all" on public.collections
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = collections.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = collections.tour_id and t.owner_id = auth.uid()));


-- ============================================================
-- 7.1b expenses  (per-bus line items: fuel, tolls, food, …)
--     Defined here — before handler_tour_manifest — because that function is
--     language-sql and resolves public.expenses at creation time.
-- ============================================================

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  bus_id      uuid not null references public.buses(id) on delete cascade,
  category    text not null default 'other',
  label       text not null,
  amount      numeric(10, 2) not null default 0,
  paid_by     text,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index expenses_tour_idx on public.expenses(tour_id);
create index expenses_bus_idx  on public.expenses(bus_id);

create trigger expenses_set_updated_at before update on public.expenses
  for each row execute function public.set_updated_at();

alter table public.expenses enable row level security;
create policy "expenses_owner_all" on public.expenses
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = expenses.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = expenses.tour_id and t.owner_id = auth.uid()));


-- READ: per-bus handler manifest (the handler's OWN bus(es) + the passengers
-- seated on them + their collections/expenses), money-aware. Handlers are now
-- per-bus (buses.handler_passenger_id) rather than tour-wide, so the manifest is
-- SCOPED to only the bus(es) this handler owns:
--   * resolve the handler passenger (request's tour_id + customer_phone,
--     is_handler = true — same predicate as is_request_handler);
--   * 'buses'      -> only buses with handler_passenger_id = that passenger id;
--   * 'passengers' -> only passengers seated on one of those buses (their
--                     assigned_seats jsonb contains a busId in that set), PLUS
--                     the handler themselves so the chart can flag them;
--   * 'collections'/'expenses' -> only rows whose bus_id is in that set.
-- If the handler owns no bus, every array comes back empty.
--
-- The buses payload carries price_per_seat + the three per-seat-type prices +
-- the rear-zone fields (rear_rows / rear_price) + the flexible price_bands +
-- the bus owner rent (bus_price) + the per-bus boarding_point so the handler
-- app resolves the same per-row fares as the admin; each passenger carries
-- trip_type + request_lines + group_id / priority_status / priority_reason (so
-- the handler chart can draw group rings + priority stars).
-- NULL for non-handler (or unknown) requests; empty arrays come back as [].
-- Defined here (after the collections + expenses tables) because the SQL body
-- references public.collections and public.expenses.
create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
  ),
  -- The handler passenger behind this request (same match as is_request_handler).
  handler_p as (
    select p.id
      from public.passengers p
      join req on req.tour_id = p.tour_id
     where p.phone = req.customer_phone
       and p.is_handler = true
     limit 1
  ),
  -- Only the bus(es) this handler owns. Empty when they own none.
  my_buses as (
    select b.id
      from public.buses b
      join req on req.tour_id = b.tour_id
     where b.handler_passenger_id in (select id from handler_p)
  )
  select case
    when not public.is_request_handler(p_request_id) then null
    else jsonb_build_object(
      'buses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',                b.id,
                     'tour_id',           b.tour_id,
                     'name',              b.name,
                     'registration_no',   b.registration_no,
                     'bus_type',          b.bus_type,
                     'total_seats',       b.total_seats,
                     'layout',            b.layout,
                     'price_per_seat',    b.price_per_seat,
                     'bus_price',         b.bus_price,
                     'boarding_point',    b.boarding_point,
                     'departure_time',    b.departure_time,
                     'single_sofa_price', b.single_sofa_price,
                     'double_sofa_price', b.double_sofa_price,
                     'seater_price',      b.seater_price,
                     'rear_rows',         b.rear_rows,
                     'rear_price',        b.rear_price,
                     'price_bands',       b.price_bands,
                     'handler_passenger_id', b.handler_passenger_id
                   )
                   order by b.name
                 )
            from public.buses b
           where b.id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              p.id,
                     'tour_id',         p.tour_id,
                     'name',            p.name,
                     'phone',           p.phone,
                     'age_group',       p.age_group,
                     'assigned_seats',  p.assigned_seats,
                     'is_handler',      p.is_handler,
                     'trip_type',       p.trip_type,
                     'request_lines',   p.request_lines,
                     'group_id',        p.group_id,
                     'priority_status', p.priority_status,
                     'priority_reason', p.priority_reason
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
           where
             -- always include the handler themselves
             p.id in (select id from handler_p)
             -- plus anyone seated on one of this handler's buses
             or exists (
               select 1
                 from jsonb_array_elements(p.assigned_seats) seat
                where (seat->>'busId') in (
                        select id::text from my_buses
                      )
             )
        ),
        '[]'::jsonb
      ),
      'collections', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              col.id,
                     'tour_id',         col.tour_id,
                     'bus_id',          col.bus_id,
                     'passenger_id',    col.passenger_id,
                     'seat_id',         col.seat_id,
                     'amount_due',      col.amount_due,
                     'amount_received', col.amount_received,
                     'amount_refunded', col.amount_refunded,
                     'note',            col.note,
                     'collected_by',    col.collected_by,
                     'created_at',      col.created_at,
                     'updated_at',      col.updated_at
                   )
                   order by col.created_at
                 )
            from public.collections col
           where col.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'expenses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',         ex.id,
                     'tour_id',    ex.tour_id,
                     'bus_id',     ex.bus_id,
                     'category',   ex.category,
                     'label',      ex.label,
                     'amount',     ex.amount,
                     'paid_by',    ex.paid_by,
                     'note',       ex.note,
                     'created_at', ex.created_at,
                     'updated_at', ex.updated_at
                   )
                   order by ex.created_at
                 )
            from public.expenses ex
           where ex.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;

-- WRITE: a handler records cash for one (passenger, bus) pair. Takes the
-- collection as a jsonb payload; the server always uses its own resolved
-- tour_id (p_collection->>'tour_id' is ignored) and defensively verifies the
-- target passenger + bus belong to the handler's own tour. Conflict target is
-- the collections_passenger_bus_seat_unique index. Returns the upserted row as
-- jsonb, or NULL when the caller is not a handler / the target is out of tour.
create or replace function public.handler_upsert_collection(
  p_request_id uuid,
  p_collection jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id      uuid;
  v_bus_id       uuid;
  v_passenger_id uuid;
  v_seat_id      text;
  v_id           uuid;
  v_row          public.collections;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  v_bus_id       := (p_collection->>'bus_id')::uuid;
  v_passenger_id := (p_collection->>'passenger_id')::uuid;
  v_seat_id      := coalesce(nullif(p_collection->>'seat_id', ''), '');
  v_id           := coalesce(nullif(p_collection->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.passengers p
     where p.id = v_passenger_id and p.tour_id = v_tour_id
  ) then
    return null;
  end if;

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.collections (
    id, tour_id, bus_id, passenger_id, seat_id,
    amount_due, amount_received, amount_refunded, note, collected_by
  )
  values (
    v_id, v_tour_id, v_bus_id, v_passenger_id, v_seat_id,
    coalesce((p_collection->>'amount_due')::numeric, 0),
    coalesce((p_collection->>'amount_received')::numeric, 0),
    coalesce((p_collection->>'amount_refunded')::numeric, 0),
    nullif(p_collection->>'note', ''),
    nullif(p_collection->>'collected_by', '')
  )
  on conflict (passenger_id, bus_id, seat_id) do update set
    amount_due      = excluded.amount_due,
    amount_received = excluded.amount_received,
    amount_refunded = excluded.amount_refunded,
    note            = excluded.note,
    collected_by    = excluded.collected_by,
    updated_at      = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_collection(uuid, jsonb) from public;
grant execute on function public.handler_upsert_collection(uuid, jsonb)
  to anon, authenticated;


-- 7.2 expenses — the table is defined ABOVE (just after collections, before
-- handler_tour_manifest) because the language-sql manifest references it at
-- creation time. See the "7.1b expenses" block above.


-- ============================================================
-- 7.3 bus_handovers  (handler→admin cash settlement events)
--     Multiple rows per bus allowed (partial hand-overs).
--     No updated_at column, so no set_updated_at trigger.
-- ============================================================

create table public.bus_handovers (
  id                 uuid primary key default gen_random_uuid(),
  tour_id            uuid not null references public.tours(id) on delete cascade,
  bus_id             uuid not null references public.buses(id) on delete cascade,
  expected_amount    numeric(10, 2) not null default 0,
  handed_over_amount numeric(10, 2) not null default 0,
  note               text,
  settled_at         timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

create index bus_handovers_tour_idx on public.bus_handovers(tour_id);
create index bus_handovers_bus_idx  on public.bus_handovers(bus_id);

alter table public.bus_handovers enable row level security;
create policy "bus_handovers_owner_all" on public.bus_handovers
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = bus_handovers.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = bus_handovers.tour_id and t.owner_id = auth.uid()));


-- WRITE: a handler logs (or edits) one expense for a bus on their own tour.
-- Takes the expense as a jsonb payload; the server always uses its own resolved
-- tour_id (p_expense->>'tour_id' is ignored) and verifies the target bus
-- belongs to the handler's own tour. Conflict target is the primary key (id).
-- Returns the upserted row as jsonb, or NULL when the caller is not a handler /
-- the bus is out of tour. Handover settlement stays admin-side.
create or replace function public.handler_upsert_expense(
  p_request_id uuid,
  p_expense jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_bus_id  uuid;
  v_id      uuid;
  v_row     public.expenses;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  v_bus_id := (p_expense->>'bus_id')::uuid;
  v_id     := coalesce(nullif(p_expense->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.expenses (
    id, tour_id, bus_id, category, label, amount, paid_by, note
  )
  values (
    v_id, v_tour_id, v_bus_id,
    coalesce(nullif(p_expense->>'category', ''), 'other'),
    coalesce(p_expense->>'label', ''),
    coalesce((p_expense->>'amount')::numeric, 0),
    nullif(p_expense->>'paid_by', ''),
    nullif(p_expense->>'note', '')
  )
  on conflict (id) do update set
    category   = excluded.category,
    label      = excluded.label,
    amount     = excluded.amount,
    paid_by    = excluded.paid_by,
    note       = excluded.note,
    updated_at = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_expense(uuid, jsonb) from public;
grant execute on function public.handler_upsert_expense(uuid, jsonb)
  to anon, authenticated;

-- DELETE: a handler removes one expense from their own tour. Returns true when
-- a row was deleted, gated on is_request_handler AND the expense's tour being
-- the handler's resolved tour.
create or replace function public.handler_delete_expense(
  p_request_id uuid,
  p_expense_id uuid
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_deleted int;
begin
  if not public.is_request_handler(p_request_id) then
    return false;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  delete from public.expenses ex
   where ex.id = p_expense_id and ex.tour_id = v_tour_id;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_expense(uuid, uuid) from public;
grant execute on function public.handler_delete_expense(uuid, uuid)
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
-- Money-collection tables push live so collections/expenses/hand-over edits
-- made on one device (e.g. the handler) reflect on the admin's screen.
alter publication supabase_realtime add table public.collections;
alter publication supabase_realtime add table public.expenses;
alter publication supabase_realtime add table public.bus_handovers;


-- ============================================================
-- 9b. Push notifications — device tokens + FCM dispatch
--
-- The admin app registers its FCM token here on login (and on token refresh)
-- and removes it on logout. When a customer inserts a booking_request, an
-- AFTER INSERT trigger fires the `send-push` Edge Function (via pg_net). That
-- function resolves the tour's owning admin, honours their notification prefs
-- (push_enabled && notify_booking_requests), and delivers an FCM push to every
-- registered device. Section 9 already streams booking_requests over Realtime
-- for the FOREGROUNDED app; FCM is what reaches a backgrounded/killed phone.
--
-- One-time setup (secrets — NEVER commit these):
--   1. Pick a random shared secret. Store it for the DB trigger:
--        select vault.create_secret('<RANDOM>', 'push_trigger_secret');
--      and hand the SAME value to the Edge Function:
--        supabase secrets set PUSH_TRIGGER_SECRET=<RANDOM>
--   2. Give the function the Firebase service-account JSON (one line):
--        supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
--   3. Deploy:  supabase functions deploy send-push --no-verify-jwt
-- Until step 1's vault secret exists, the trigger is a quiet no-op, so the
-- booking flow keeps working before push is switched on.
-- ============================================================

create extension if not exists pg_net;

create table public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  admin_id   uuid not null references public.admins(id) on delete cascade,
  token      text not null unique,
  platform   text not null check (platform in ('ios', 'android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index device_tokens_admin_idx on public.device_tokens(admin_id);

create trigger device_tokens_set_updated_at before update on public.device_tokens
  for each row execute function public.set_updated_at();

alter table public.device_tokens enable row level security;

-- An admin reads/deletes only their own tokens (debug + explicit unregister).
-- Inserts/upserts go through register_device_token() so a device that switches
-- accounts re-points its row cleanly (the unique key is the token itself, which
-- a plain RLS upsert can't re-own across admins).
create policy "device_tokens_owner_select" on public.device_tokens
  for select to authenticated using (admin_id = auth.uid());
create policy "device_tokens_owner_delete" on public.device_tokens
  for delete to authenticated using (admin_id = auth.uid());

-- REGISTER: upsert the calling admin's token. on conflict(token) re-points an
-- existing row to whoever just logged in on that device.
create or replace function public.register_device_token(p_token text, p_platform text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_token is null or length(p_token) = 0 then
    return;
  end if;
  insert into public.device_tokens (admin_id, token, platform)
  values (auth.uid(), p_token, coalesce(nullif(p_platform, ''), 'android'))
  on conflict (token) do update
     set admin_id   = excluded.admin_id,
         platform   = excluded.platform,
         updated_at = now();
end;
$$;
revoke all on function public.register_device_token(text, text) from public;
grant execute on function public.register_device_token(text, text) to authenticated;

-- UNREGISTER: drop this device's token on logout. Scoped to the caller.
create or replace function public.unregister_device_token(p_token text)
returns void
language sql security definer set search_path = public
as $$
  delete from public.device_tokens
   where token = p_token and admin_id = auth.uid();
$$;
revoke all on function public.unregister_device_token(text) from public;
grant execute on function public.unregister_device_token(text) to authenticated;

-- AFTER INSERT on booking_requests → fire send-push. Best-effort: any failure
-- here must NOT roll back the customer's booking, so the whole call is wrapped
-- in an exception-swallowing block.
create or replace function public.notify_booking_request()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_event  text;
  -- Deterministic Edge Function endpoint for THIS project (see SupabaseConfig).
  v_url text := 'https://rhyqjzulpvaeslbaymex.supabase.co/functions/v1/send-push';
begin
  -- Decide which event (if any) warrants a push.
  if tg_op = 'INSERT' then
    v_event := 'created';
  else
    -- UPDATE: only a CUSTOMER edit notifies. The customer edit RPC
    -- (booking_request_customer_update) advances customer_edited_at; admin
    -- status changes bump updated_at but never customer_edited_at, so they
    -- stay silent and don't spam the organiser.
    if new.customer_edited_at is distinct from old.customer_edited_at
       and new.customer_edited_at is not null then
      v_event := 'updated';
    else
      return new;
    end if;
  end if;

  begin
    select decrypted_secret into v_secret
      from vault.decrypted_secrets
     where name = 'push_trigger_secret'
     limit 1;
    -- Push not configured yet → skip quietly so bookings still work.
    if v_secret is null then
      return new;
    end if;
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-push-secret', v_secret),
      body    := jsonb_build_object('request_id', new.id, 'event', v_event)
    );
  exception when others then
    raise warning 'notify_booking_request push dispatch failed: %', sqlerrm;
  end;
  return new;
end;
$$;

create trigger booking_requests_notify_push
  after insert or update on public.booking_requests
  for each row execute function public.notify_booking_request();


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
-- Expected tables: admin_contacts, admins, booking_requests, bus_handovers,
--                  buses, collections, expenses, passengers, tours
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
