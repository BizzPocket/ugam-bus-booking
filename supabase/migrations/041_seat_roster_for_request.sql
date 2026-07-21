-- ============================================================
-- 041  Seat roster for a customer request (occupant name + phone)
-- ------------------------------------------------------------
-- The customer "Your Seat" sheet previously rendered an ANONYMOUS chart — a
-- rider saw only their own highlighted seat, never who sat elsewhere. By
-- deliberate organiser choice, co-travellers on a community group tour may now
-- see the FULL roster (name + phone per seat) so they can coordinate boarding.
--
-- *** PRIVACY POSTURE — READ THIS ***
-- This RPC returns EVERY assigned passenger's NAME and PHONE for the tour behind
-- the given request, to an ANONYMOUS caller (customers have no auth session).
-- Any customer holding a booking on a LOCKED tour can therefore read the whole
-- roster's contact details. This is intentional for this app's group-travel use
-- case; do NOT reuse this function anywhere a rider must not see co-travellers.
--
-- Lock-gated exactly like the seat reveal (025 / 027): returns [] until the tour
-- is 'locked' or 'completed', so nothing leaks while assignment is still in
-- progress. Cancelled passengers are excluded. Deliberately does NOT touch the
-- live-only bus_layouts_for_request — the sheet keeps calling that for the
-- layout and merges THIS roster on top by (busId, seatId).
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

create or replace function public.bus_roster_for_request(p_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id
      from public.booking_requests br
     where br.id = p_id
  )
  select case
    when not public.booking_request_tour_locked(p_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'bus_id',  seat->>'busId',
                   'seat_id', seat->>'seatId',
                   'name',    p.name,
                   'phone',   p.phone
                 )
               )
          from public.passengers p
          join req on req.tour_id = p.tour_id
          cross join lateral jsonb_array_elements(
            coalesce(p.assigned_seats, '[]'::jsonb)
          ) as seat
         where p.cancelled_at is null
           and coalesce(seat->>'busId', '')  <> ''
           and coalesce(seat->>'seatId', '') <> ''
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.bus_roster_for_request(uuid) from public;
grant execute on function public.bus_roster_for_request(uuid)
  to anon, authenticated;
