-- ============================================================
-- 031  Tour seat-history snapshot (per-leg frozen seat chart)
-- ------------------------------------------------------------
-- A tour is kept forever after its trip date passes (soft-archived to
-- 'completed', never deleted), and the admin can already browse a past tour's
-- passengers, buses, money and groups. The one piece of data that today gets
-- DESTROYED is the GO-leg seat chart: when the outbound leg completes, the live
-- editor clears outbound-only riders' assigned_seats to free those berths for
-- return-leg rebooking. The seat POSITIONS are lost even though the passenger
-- rows survive.
--
-- This adds a small, write-once-per-leg history table so that authoritative
-- chart can be snapshotted BEFORE the seats are recycled and replayed read-only
-- on the past-tour seat view:
--
--   * tour_seat_snapshots   one row per (tour, leg): a frozen JSON seat chart
--                           captured at a point in time. leg is
--                           'outbound' / 'return'. snapshot_data holds
--                           { "buses": [ { "busId", "seats": [ { "seatId",
--                           "name", "phone" } ] } ] }.
--
-- ADDITIVE + idempotent: uses `create table if not exists`,
-- `create index if not exists`, and `drop policy if exists` + recreate. Safe to
-- run on a database that already holds live data — nothing is dropped and no
-- rows are touched. The Dart client degrades gracefully until this is applied
-- (writes are best-effort and swallowed; reads return no history).
--
-- RLS follows the repo's tour-scoped child-table pattern (see collections /
-- expenses in 004_money_collection.sql and attendance in
-- 024_handler_attendance.sql): a row is visible/writable to the authenticated
-- agent who owns the parent tour. Split into the four per-action policies the
-- way 018_push_notifications.sql does, all gated on the same owner check.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================


-- ------------------------------------------------------------
-- 1. tour_seat_snapshots — one frozen seat chart per (tour, leg).
-- ------------------------------------------------------------

create table if not exists public.tour_seat_snapshots (
  id            uuid primary key default gen_random_uuid(),
  tour_id       uuid not null references public.tours(id) on delete cascade,
  leg           text not null check (leg in ('outbound', 'return')),
  snapshot_data jsonb not null,
  captured_at   timestamptz not null default now(),
  unique (tour_id, leg)
);

create index if not exists tour_seat_snapshots_tour_idx
  on public.tour_seat_snapshots(tour_id);

alter table public.tour_seat_snapshots enable row level security;

-- Owner-scoped CRUD: a row belongs to whoever owns the parent tour. The gate is
-- the same for every action — auth.uid() must equal the tour's owner_id.
drop policy if exists "tour_seat_snapshots_owner_select" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_select" on public.tour_seat_snapshots
  for select to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_insert" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_insert" on public.tour_seat_snapshots
  for insert to authenticated
  with check (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_update" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_update" on public.tour_seat_snapshots
  for update to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id))
  with check (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_delete" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_delete" on public.tour_seat_snapshots
  for delete to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));
