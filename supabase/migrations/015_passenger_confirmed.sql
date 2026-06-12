-- ============================================================
-- 015  Passenger "Confirmed" state
-- ------------------------------------------------------------
-- Adds a CONFIRMED flag to the request pipeline:
--   New -> (Confirm) -> Confirmed (eligible for seats, none yet) -> Assigned
-- Waitlist remains a side state. Confirming a passenger also clears the
-- waitlist flag in application code.
--
--   passengers.is_confirmed   boolean, default false
--
-- A default-valued column is backward compatible; no RPC/function bodies
-- change. Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

alter table public.passengers add column if not exists is_confirmed boolean not null default false;
