-- ============================================================
-- 016  Passenger "journey done" (half-trip completion)
-- ------------------------------------------------------------
-- Supports completing ONE leg of a round-trip tour. When the agent finishes
-- the outbound (GO) half, every GO-only (outboundOnly) passenger has their
-- seats freed and this flag set — so the return leg's chart shows those seats
-- empty and they drop off the active roster, while the record is KEPT for
-- money/history.
--
--   passengers.journey_done   boolean, default false
--
-- A default-valued column is backward compatible; the app fetches passengers
-- with a plain `select()` (all columns) so it round-trips with no RPC change.
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

alter table public.passengers add column if not exists journey_done boolean not null default false;
