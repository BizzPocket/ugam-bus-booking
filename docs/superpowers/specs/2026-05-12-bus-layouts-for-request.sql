-- ============================================================
-- OccuBus Booking — bus_layouts_for_request RPC
-- Date: 2026-05-12
--
-- Lets an anonymous customer fetch the seat layouts of just the
-- buses where their own booking request has assigned seats, so the
-- "My Requests" screen can render the layout with their seats
-- highlighted. Bypasses the owner_id RLS on public.buses by going
-- through a SECURITY DEFINER function, scoped to the (tour_id,
-- customer_phone) pair on the originating booking_requests row.
--
-- Idempotent — safe to re-run.
-- ============================================================

create or replace function public.bus_layouts_for_request(p_id uuid)
returns table(
  id              uuid,
  tour_id         uuid,
  name            text,
  registration_no text,
  bus_type        text,
  total_seats     int,
  layout          jsonb
)
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_id
  ),
  seats as (
    select distinct (elem ->> 'busId')::uuid as bus_id
      from public.passengers p
      join req on req.tour_id = p.tour_id
                and req.customer_phone = p.phone
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as elem
     where elem ? 'busId'
  )
  select b.id, b.tour_id, b.name, b.registration_no,
         b.bus_type, b.total_seats, b.layout
    from public.buses b
    join seats on seats.bus_id = b.id;
$$;

revoke all on function public.bus_layouts_for_request(uuid) from public;
grant execute on function public.bus_layouts_for_request(uuid)
  to anon, authenticated;
