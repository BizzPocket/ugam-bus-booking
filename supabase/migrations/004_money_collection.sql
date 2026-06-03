-- ============================================================
-- 003  Money collection — per-seat pricing, collections, expenses,
--      and handler→admin handovers.
-- ------------------------------------------------------------
-- Adds the money-tracking layer on top of the existing tour/bus/passenger
-- schema so a tour agent (and their on-bus handler) can record what each
-- passenger owes, what was actually collected, what was refunded, the
-- running expenses for a bus, and the final cash hand-over from the
-- handler back to the admin.
--
--   * buses          gains three optional per-seat-type price columns.
--                    Each is nullable; the app falls back to
--                    buses.price_per_seat when a type-specific price is null.
--   * collections    one row per (passenger, bus, seat): amount due / received /
--                    refunded, plus a free-text note and who collected it.
--   * expenses       per-bus line items (fuel, tolls, food, …).
--   * bus_handovers  handler→admin cash settlement events; multiple are
--                    allowed per bus (partial hand-overs over the trip).
--
-- ADDITIVE + idempotent-friendly: uses `add column if not exists`,
-- `create table if not exists`, `create index if not exists`, and
-- `drop policy if exists` + recreate. Safe to run on a database that
-- already holds live data — nothing is dropped and no rows are touched.
--
-- RLS follows the repo's tour-scoped child-table pattern (see passengers
-- in database.sql): a row is visible/writable to the authenticated agent
-- who owns the parent tour. The shared public.set_updated_at() trigger
-- function (already defined) keeps updated_at fresh.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================


-- ------------------------------------------------------------
-- 1. buses — optional per-seat-type prices (app falls back to
--    price_per_seat when any of these is null).
-- ------------------------------------------------------------

alter table public.buses
  add column if not exists single_sofa_price numeric(10, 2),
  add column if not exists double_sofa_price numeric(10, 2),
  add column if not exists seater_price      numeric(10, 2);


-- ------------------------------------------------------------
-- 2. collections — one row per (passenger, bus, seat).
-- ------------------------------------------------------------

create table if not exists public.collections (
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

alter table public.collections
  add column if not exists seat_id text not null default '';

drop index if exists collections_passenger_bus_unique;
create unique index if not exists collections_passenger_bus_seat_unique
  on public.collections(passenger_id, bus_id, seat_id);
create index if not exists collections_tour_idx on public.collections(tour_id);
create index if not exists collections_bus_idx  on public.collections(bus_id);

drop trigger if exists collections_set_updated_at on public.collections;
create trigger collections_set_updated_at before update on public.collections
  for each row execute function public.set_updated_at();

alter table public.collections enable row level security;

drop policy if exists "collections_owner_all" on public.collections;
create policy "collections_owner_all" on public.collections
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = collections.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = collections.tour_id and t.owner_id = auth.uid()));


-- ------------------------------------------------------------
-- 3. expenses — per-bus line items.
-- ------------------------------------------------------------

create table if not exists public.expenses (
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

create index if not exists expenses_tour_idx on public.expenses(tour_id);
create index if not exists expenses_bus_idx  on public.expenses(bus_id);

drop trigger if exists expenses_set_updated_at on public.expenses;
create trigger expenses_set_updated_at before update on public.expenses
  for each row execute function public.set_updated_at();

alter table public.expenses enable row level security;

drop policy if exists "expenses_owner_all" on public.expenses;
create policy "expenses_owner_all" on public.expenses
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = expenses.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = expenses.tour_id and t.owner_id = auth.uid()));


-- ------------------------------------------------------------
-- 4. bus_handovers — handler→admin cash settlement events.
--    Multiple rows per bus are allowed (partial hand-overs).
--    No updated_at column, so no set_updated_at trigger.
-- ------------------------------------------------------------

create table if not exists public.bus_handovers (
  id                 uuid primary key default gen_random_uuid(),
  tour_id            uuid not null references public.tours(id) on delete cascade,
  bus_id             uuid not null references public.buses(id) on delete cascade,
  expected_amount    numeric(10, 2) not null default 0,
  handed_over_amount numeric(10, 2) not null default 0,
  note               text,
  settled_at         timestamptz not null default now(),
  created_at         timestamptz not null default now()
);

create index if not exists bus_handovers_tour_idx on public.bus_handovers(tour_id);
create index if not exists bus_handovers_bus_idx  on public.bus_handovers(bus_id);

alter table public.bus_handovers enable row level security;

drop policy if exists "bus_handovers_owner_all" on public.bus_handovers;
create policy "bus_handovers_owner_all" on public.bus_handovers
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = bus_handovers.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = bus_handovers.tour_id and t.owner_id = auth.uid()));


-- ------------------------------------------------------------
-- 5. Realtime — let the app subscribe to changes. Each add is wrapped
--    so re-running the migration doesn't hard-fail when the table is
--    already a member of the publication.
-- ------------------------------------------------------------

do $$
begin
  alter publication supabase_realtime add table public.collections;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.expenses;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.bus_handovers;
exception when duplicate_object then null;
end $$;
