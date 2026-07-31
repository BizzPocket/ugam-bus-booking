-- ============================================================
-- 044_handler_manifest_pickup
-- ------------------------------------------------------------
-- The handler-facing bus chart (Attendance view) groups riders by pickup
-- point and shows a per-rider pickup chip. Both read Passenger.pickupLocationId
-- / pickupLocationName. But handler_tour_manifest() never selected those two
-- columns into the passenger JSON, so every handler-side Passenger arrived with
-- null pickup — the group headers collapsed and the chip rendered nothing.
--
-- This redefinition is IDENTICAL to 042's handler_tour_manifest EXCEPT it adds
--   'pickup_location_id'   and
--   'pickup_location_name'
-- to the per-passenger jsonb_build_object. Nothing else changes.
--
-- Deploy note (see project memory: live schema ≠ migration files): apply this
-- as a single file in the Supabase SQL editor, then verify by calling the RPC
-- for a handler request and confirming pickup_location_* now appear.
-- ============================================================

create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select ctx.tour_id, ctx.customer_phone
      from public.handler_ctx(p_request_id) ctx
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
                     'priority_reason', p.priority_reason,
                     -- Added in 044: the handler chart groups/chips by pickup.
                     'pickup_location_id',   p.pickup_location_id,
                     'pickup_location_name', p.pickup_location_name
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
      ),
      'incomes', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',          inc.id,
                     'tour_id',     inc.tour_id,
                     'bus_id',      inc.bus_id,
                     'category',    inc.category,
                     'label',       inc.label,
                     'amount',      inc.amount,
                     'received_by', inc.received_by,
                     'note',        inc.note,
                     'created_at',  inc.created_at,
                     'updated_at',  inc.updated_at
                   )
                   order by inc.created_at
                 )
            from public.incomes inc
           where inc.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;
