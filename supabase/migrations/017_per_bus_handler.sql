-- ============================================================
-- 017  Per-bus handler (replaces the tour-wide handler)
-- ------------------------------------------------------------
-- Handlers become per-BUS instead of per-tour. Each bus can name one of its
-- seated passengers as its handler; that handler later sees ONLY their own
-- bus(es). This migration:
--
--   1. buses.handler_passenger_id  uuid  FK -> passengers(id) on delete set null
--        The passenger who runs THIS bus on the ground. tours.handler_id is kept
--        in sync by the app as a legacy "tour has a handler" pointer.
--
--   2. passengers.journey_done     boolean not null default false
--        Model-drift fix — the Dart Passenger model already serialises this
--        (half-trip completion, see 016) but a clean apply of this migration
--        alone must not assume 016 ran. Idempotent; no-op if 016 already added it.
--
--   3. handler_tour_manifest()  rewritten to scope to the handler's OWN bus(es):
--        resolve the handler passenger (request's tour_id + customer_phone,
--        is_handler = true), return only buses with handler_passenger_id = that
--        passenger id, and limit passengers/collections/expenses to those bus
--        ids. Empty arrays when the handler owns no bus. Same SECURITY DEFINER +
--        is_request_handler gate; same return JSON shape (lib/models/
--        handler_manifest.dart) plus an added buses[].handler_passenger_id.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- 1. Per-bus handler column + FK + index. `on delete set null` so deleting a
--    passenger simply un-assigns them as a bus handler.
alter table public.buses
  add column if not exists handler_passenger_id uuid;

alter table public.buses
  drop constraint if exists buses_handler_passenger_fk;

alter table public.buses
  add constraint buses_handler_passenger_fk
  foreign key (handler_passenger_id)
  references public.passengers(id) on delete set null;

create index if not exists buses_handler_passenger_idx
  on public.buses(handler_passenger_id);

-- 2. Model-drift fix (idempotent; harmless if 016 already added it).
alter table public.passengers
  add column if not exists journey_done boolean not null default false;

-- 3. Per-bus-scoped manifest. Replaces the tour-wide body in place; the gate,
--    SECURITY DEFINER, grants, and return shape are unchanged (plus the added
--    buses[].handler_passenger_id field).
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
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;
