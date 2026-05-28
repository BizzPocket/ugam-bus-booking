-- ============================================================
-- OccuBus Booking — Supabase schema patch
-- Date: 2026-05-11
--
-- Run AFTER the original 2026-05-10 schema.
-- Brings the Postgres tables up to match the rich field shapes that
-- the Flutter Dart models actually serialise. Idempotent — safe to
-- re-run.
-- ============================================================

-- ─── tours: rename + extend ──────────────────────────────────
-- Old columns (source/destination/start_date/end_date) become
-- (from_city/to_city/departure_date/return_date) to match Tour model.
-- Adds price_per_seat, handler_id, created_by, is_public.

-- Renames are wrapped in DO blocks so the patch stays idempotent.
-- If the column is already renamed (or never existed), each block no-ops.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='tours'
               and column_name='source') then
    alter table public.tours rename column source to from_city;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='tours'
               and column_name='destination') then
    alter table public.tours rename column destination to to_city;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='tours'
               and column_name='start_date') then
    alter table public.tours rename column start_date to departure_date;
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='tours'
               and column_name='end_date') then
    alter table public.tours rename column end_date to return_date;
  end if;
end $$;

-- The Tour model treats departure_date as required (non-null).
-- Existing rows (if any) without a date can be set to today; new rows must supply.
update public.tours set departure_date = current_date where departure_date is null;
alter table public.tours alter column departure_date set not null;

alter table public.tours
  add column if not exists price_per_seat numeric(10, 2),
  add column if not exists handler_id     uuid references auth.users(id) on delete set null,
  add column if not exists created_by     uuid references auth.users(id) on delete set null,
  add column if not exists is_public      boolean not null default true;

-- ─── buses: extend ──────────────────────────────────────────
-- Drop unused 'model' column, add the operational metadata fields
-- the Bus Dart model writes.

alter table public.buses drop column if exists model;

alter table public.buses
  add column if not exists name          text,
  add column if not exists driver_name   text,
  add column if not exists driver_phone  text,
  add column if not exists owner_name    text,
  add column if not exists owner_phone   text,
  add column if not exists is_ac         boolean not null default false,
  add column if not exists bus_type      text,
  add column if not exists notes         text;

-- ─── passengers: extend ─────────────────────────────────────
-- Replace the simple seat_no/gender/age/status/request_source columns
-- with the structured shape the Passenger Dart model writes.

alter table public.passengers drop column if exists seat_no;
alter table public.passengers drop column if exists gender;
alter table public.passengers drop column if exists age;
alter table public.passengers drop column if exists status;
alter table public.passengers drop column if exists request_source;

-- The unique partial index on (tour_id, seat_no) referenced the dropped
-- column — drop it. Seat uniqueness is now enforced inside the
-- assigned_seats jsonb at the application layer.
drop index if exists public.passengers_seat_unique;

alter table public.passengers
  add column if not exists user_id          uuid references auth.users(id) on delete set null,
  add column if not exists age_group        text not null default 'adult',
  add column if not exists request_lines    jsonb not null default '[]'::jsonb,
  add column if not exists assigned_seats   jsonb not null default '[]'::jsonb,
  add column if not exists payment_status   text not null default 'notPaid',
  add column if not exists is_handler       boolean not null default false,
  add column if not exists note             text,
  add column if not exists is_waitlisted    boolean not null default false;

-- Idempotency key per the Dart docstring on Passenger: (tour_id, phone)
-- means re-submitting from the app updates an existing row rather than
-- creating a duplicate.
create unique index if not exists passengers_tour_phone_unique
  on public.passengers(tour_id, phone);

-- ─── done ───────────────────────────────────────────────────
-- After running, confirm with:
--   select column_name, data_type
--     from information_schema.columns
--     where table_schema='public' and table_name in ('tours','buses','passengers')
--     order by table_name, ordinal_position;
