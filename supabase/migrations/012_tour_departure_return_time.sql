-- ============================================================
-- 012_tour_departure_return_time.sql
-- Add the tour departure/return time-of-day columns to a LIVE DB.
-- Safe to run as-is in the Supabase SQL editor; every statement is idempotent.
--
-- Why this exists:
--   The Flutter Tour model serialises `departure_time` and `return_time` on
--   every tour insert/update (create + edit tour screens). The consolidated
--   database.sql snapshot already has these columns, but no incremental
--   migration added them — so a DB built up from 001..011 is missing them and
--   PostgREST rejects the write with "column does not exist", silently failing
--   tour create/edit. This migration backfills the columns.
--
-- Both columns are NULLABLE: the time-of-day is OPTIONAL. A tour can have a
-- departure/return DATE with no time set, and a one-way tour has no return at
-- all. They are kept separate from departure_date/return_date so an unset time
-- stays distinct from midnight and the date columns/indexes keep date semantics.
-- ============================================================

-- Local departure time-of-day on departure_date. NULL until the agent sets it.
alter table public.tours add column if not exists departure_time time;

-- Local return time-of-day on return_date. NULL when unset (no return date, or
-- a return date without a time) — return time is optional.
alter table public.tours add column if not exists return_time time;

-- Reload PostgREST's schema cache so the new columns are immediately writable
-- via the REST API without waiting for the next auto-reload. This is what makes
-- the failing tour create/edit start working the moment the migration runs.
notify pgrst, 'reload schema';
