-- ============================================================
-- 022  Bus registration uniqueness: per-TOUR, not per-OWNER
-- ------------------------------------------------------------
-- A tour operator REUSES the same physical buses (same registration number)
-- across many tours. Each tour gets its own `buses` row (scoped by tour_id),
-- so the same registration legitimately appears on multiple tours.
--
-- The old uniqueness was OWNER-WIDE — `buses(owner_id, registration_no)` — so
-- adding a bus whose registration the admin had already used on ANY tour failed
-- with:
--   duplicate key value violates unique constraint "buses_owner_reg_unique"
--
-- Fix: scope uniqueness to the TOUR. The same registration may recur on
-- different tours, but never twice on ONE tour. Empty registrations are stored
-- as NULL and excluded from the index (multiple un-numbered buses are allowed).
--
-- The owner-wide rule may have been created as a CONSTRAINT or as a partial
-- INDEX depending on how the live DB was provisioned, so both are dropped
-- defensively. This change is strictly MORE permissive than the old one, so it
-- cannot break any bus that already saves today.
-- ============================================================

alter table public.buses
  drop constraint if exists buses_owner_reg_unique;

drop index if exists public.buses_owner_reg_unique;

create unique index if not exists buses_tour_reg_unique
  on public.buses(tour_id, registration_no)
  where registration_no is not null;
