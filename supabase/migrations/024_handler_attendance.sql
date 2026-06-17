-- ============================================================
-- 024  Handler attendance (read in manifest + mark present on the ground)
-- ------------------------------------------------------------
-- The handler runs a bus on the ground and needs to take a head-count per leg
-- (going / return) so nobody gets left behind at a stop. This adds an
-- attendance layer alongside collections (004) and expenses (010):
--
--   * attendance     one row per (passenger, bus, leg): present flag plus who
--                    marked it and when. leg is 'go' or 'ret'.
--
--   handler_tour_manifest(p_request_id) -> jsonb
--       Re-created from the 020 body UNCHANGED except for one addition: a
--       top-level "attendance" array scoped to my_buses, the same way
--       "collections" and "expenses" are exposed.
--
--   handler_upsert_attendance(p_request_id, p_attendance) -> jsonb
--       Inserts/updates one attendance row for the handler's own tour and
--       returns it. Gated on is_request_handler AND the target passenger + bus
--       belonging to the handler's tour. The server always uses its own
--       resolved tour_id; p_attendance->>'tour_id' is ignored.
--
-- ADDITIVE + idempotent-friendly: uses `create table if not exists`,
-- `create index if not exists`, `drop policy if exists` + recreate, and
-- `create or replace function`. Must run AFTER 020 (it re-creates
-- handler_tour_manifest from the 020 body).
--
-- RLS follows the repo's tour-scoped child-table pattern (see collections /
-- expenses in 004_money_collection.sql): a row is visible/writable to the
-- authenticated agent who owns the parent tour. Handler writes go through the
-- SECURITY DEFINER RPC below, so the table's own policy only needs to let the
-- tour's admin read their own rows.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================


-- ------------------------------------------------------------
-- 1. attendance — one row per (passenger, bus, leg).
-- ------------------------------------------------------------

create table if not exists public.attendance (
  id            uuid primary key default gen_random_uuid(),
  tour_id       uuid not null references public.tours(id) on delete cascade,
  bus_id        uuid not null references public.buses(id) on delete cascade,
  passenger_id  uuid not null references public.passengers(id) on delete cascade,
  leg           text not null check (leg in ('go', 'ret')),
  present       boolean not null default true,
  marked_by     text,
  marked_at     timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

create unique index if not exists attendance_passenger_bus_leg_unique
  on public.attendance(passenger_id, bus_id, leg);
create index if not exists attendance_tour_idx on public.attendance(tour_id);
create index if not exists attendance_bus_idx  on public.attendance(bus_id);

alter table public.attendance enable row level security;

drop policy if exists "attendance_owner_all" on public.attendance;
create policy "attendance_owner_all" on public.attendance
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = attendance.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = attendance.tour_id and t.owner_id = auth.uid()));


-- ------------------------------------------------------------
-- 2. handler_tour_manifest — re-created from the 020 body, adding a
--    top-level "attendance" array scoped to my_buses. Everything else is
--    byte-identical to 020.
-- ------------------------------------------------------------

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
                     'driver_name',       b.driver_name,
                     'driver_phone',      b.driver_phone,
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
      ),
      'attendance', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',           at.id,
                     'tour_id',      at.tour_id,
                     'bus_id',       at.bus_id,
                     'passenger_id', at.passenger_id,
                     'leg',          at.leg,
                     'present',      at.present,
                     'marked_by',    at.marked_by,
                     'marked_at',    at.marked_at,
                     'created_at',   at.created_at
                   )
                   order by at.created_at
                 )
            from public.attendance at
           where at.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 3. handler_upsert_attendance — a handler marks one (passenger, bus, leg)
--    present / left-behind on their own tour. Returns NULL when the caller is
--    not a handler, or when the target passenger / bus does not belong to the
--    handler's own tour. The server always uses its own resolved tour_id;
--    p_attendance->>'tour_id' is ignored.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_attendance(
  p_request_id uuid,
  p_attendance jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id      uuid;
  v_bus_id       uuid;
  v_passenger_id uuid;
  v_leg          text;
  v_id           uuid;
  v_row          public.attendance;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  v_bus_id       := (p_attendance->>'bus_id')::uuid;
  v_passenger_id := (p_attendance->>'passenger_id')::uuid;
  v_leg          := coalesce(nullif(p_attendance->>'leg', ''), 'go');
  v_id           := coalesce(nullif(p_attendance->>'id', '')::uuid, gen_random_uuid());

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

  insert into public.attendance (
    id, tour_id, bus_id, passenger_id, leg, present, marked_by, marked_at
  )
  values (
    v_id, v_tour_id, v_bus_id, v_passenger_id, v_leg,
    coalesce((p_attendance->>'present')::boolean, true),
    nullif(p_attendance->>'marked_by', ''),
    now()
  )
  on conflict (passenger_id, bus_id, leg) do update set
    present   = excluded.present,
    marked_by = excluded.marked_by,
    marked_at = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_attendance(uuid, jsonb) from public;
grant execute on function public.handler_upsert_attendance(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 4. Realtime — let the app subscribe to attendance changes, the same way
--    collections / expenses are published in 004_money_collection.sql.
-- ------------------------------------------------------------

do $$
begin
  alter publication supabase_realtime add table public.attendance;
exception when duplicate_object then null;
end $$;
