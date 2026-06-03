-- ============================================================
-- 006  Passenger groups + priority seating
-- ------------------------------------------------------------
-- Adds cross-booking GROUPS (passengers that must ride the same bus) and a
-- PRIORITY (front/sofa) request->approve flow used by the seating engine.
--
--   passenger_groups          one named group per tour
--   passengers.group_id       links a passenger row into a group
--   passengers.priority_status / priority_reason
--
-- Reserved seats (per seat) and locked assignments (per berth) live inside the
-- existing buses.layout / passengers.assigned_seats jsonb and need no DDL.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

create table if not exists public.passenger_groups (
  id          uuid primary key default gen_random_uuid(),
  tour_id     uuid not null references public.tours(id) on delete cascade,
  label       text not null,
  color_index int  not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists passenger_groups_tour_idx
  on public.passenger_groups(tour_id);

alter table public.passengers
  add column if not exists group_id uuid
    references public.passenger_groups(id) on delete set null;

alter table public.passengers
  add column if not exists priority_status text not null default 'none';

alter table public.passengers
  add column if not exists priority_reason text;

create index if not exists passengers_group_idx
  on public.passengers(tour_id, group_id);

-- RLS: a group is owned through its parent tour (same shape as collections).
alter table public.passenger_groups enable row level security;

create policy "passenger_groups_owner_all" on public.passenger_groups
  for all to authenticated
  using (
    exists (
      select 1 from public.tours t
       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.tours t
       where t.id = passenger_groups.tour_id and t.owner_id = auth.uid()
    )
  );
