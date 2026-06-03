-- ============================================================
-- 005  Per-bus rear-zone pricing
-- ------------------------------------------------------------
-- Adds a second price tier per bus. The last `rear_rows` rows form an
-- optional "rear zone" charged at `rear_price` per person instead of the
-- bus base price (buses.price_per_seat). rear_rows = 0 means no rear zone;
-- rear_price NULL means rear rows fall back to the base price.
--
-- The existing per-seat-type override columns (single_sofa_price,
-- double_sofa_price, seater_price) are left in place — they still tune the
-- front (non-rear) rows. No destructive drop.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

alter table public.buses
  add column if not exists rear_rows  integer not null default 0,
  add column if not exists rear_price numeric null;
