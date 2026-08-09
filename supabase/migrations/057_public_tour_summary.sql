-- ============================================================
-- 057 — Public tour summary for the customer tour page
--
-- (Authored as 052 and applied to live under that name on 2026-08-03; renamed
-- so it sorts after the 053–056 files that already existed. The functions are
-- `create or replace`, so re-running under the new number is a no-op.)
--
-- PROBLEM: the public tour detail page could show neither a price nor a seat
-- count. `buses` has no anon SELECT policy, so `Tour.buses` is always empty on
-- the customer side: `total_bus_seats` was 0 (the "N seats left" chip could
-- never fire), the bus card never rendered, and `tours.price_per_seat` is 0
-- whenever the agent prices per bus or per band — which is the normal case.
--
-- 048 already exposes exactly the right data, but both of its readers are gated
-- behind `chart_tour_open()`, which requires `booking_mode = 'chart'` AND a tour
-- that is not yet locked. Request-mode tours — still the default, and most of
-- the live ones — therefore got '[]' from both. That gate is CORRECT for
-- claiming a berth and wrong for merely describing a tour.
--
-- FIX: two read-only twins gated on `is_public` alone. Same customer-safe
-- projections, no new columns, no writes.
--
-- WHY THE PROJECTIONS ARE COPIED RATHER THAN SHARED: refactoring 048's
-- functions to share a payload helper would mean re-running 048's definitions
-- here, and the migration history in this project is not authoritative (files
-- get replayed). Keeping 052 purely ADDITIVE means it can be run alone, twice,
-- in any order, without touching a working booking path. If the projection ever
-- changes, both places must change — the comment in 048 says so too.
--
-- SAFETY: both functions are `stable security definer`, read-only, and emit the
-- same fields 048 already deemed safe for anon. Driver/owner phones and
-- `bus_price` (the owner's rent) are omitted here exactly as they are there.
-- The occupancy twin carries NO name and NO phone — only berth counts per leg
-- plus the ladies marker.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent — safe to press
-- twice.
-- ============================================================

-- ── 1. Gate: may an anonymous visitor see this tour at all? ──
-- `is_public` only. Deliberately NOT gated on status or booking_mode: a locked
-- or request-mode tour still has a detail page, and that page should state the
-- price and how many berths are gone. Whether the customer may BOOK is a
-- separate question, answered by chart_tour_open() / the client's lock gate.
-- Unknown id -> false.
create or replace function public.public_tour_visible(p_tour_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select t.is_public from public.tours t where t.id = p_tour_id),
    false
  );
$$;

revoke all on function public.public_tour_visible(uuid) from public;
grant execute on function public.public_tour_visible(uuid) to anon, authenticated;

-- ── 2. Buses for DISPLAY (price bands, layout, AC, boarding) ──
-- Mirrors chart_tour_buses' projection exactly; only the gate differs. The
-- layout rides along because the client derives both the "from" price and the
-- berth capacity from it — a double sofa is 2 berths and a `reserved` seat is
-- offered to nobody, and that arithmetic already lives (and is tested) in Dart
-- at utils/chart_seat_availability.dart. Returning the raw layout instead of a
-- SQL-computed total is what keeps the server and the client from drifting into
-- two different answers.
create or replace function public.public_tour_buses(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case
    when not public.public_tour_visible(p_tour_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'id',                b.id,
                   'tour_id',           b.tour_id,
                   'name',              b.name,
                   'registration_no',   b.registration_no,
                   'is_ac',             b.is_ac,
                   'bus_type',          b.bus_type,
                   'boarding_point',    b.boarding_point,
                   'departure_time',    b.departure_time,
                   'layout',            b.layout,
                   'price_per_seat',    b.price_per_seat,
                   'single_sofa_price', b.single_sofa_price,
                   'double_sofa_price', b.double_sofa_price,
                   'seater_price',      b.seater_price,
                   'rear_rows',         b.rear_rows,
                   'rear_price',        b.rear_price,
                   'price_bands',       b.price_bands
                 )
                 order by b.name
               )
          from public.buses b
         where b.tour_id = p_tour_id
           and b.layout is not null
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.public_tour_buses(uuid) from public;
grant execute on function public.public_tour_buses(uuid) to anon, authenticated;

-- ── 3. Anonymised occupancy for DISPLAY ──────────────────────
-- Twin of chart_seat_availability with the same leg accounting: an assignment
-- consumes the GO slot when its leg is roundTrip/outboundOnly and the RET slot
-- when it is roundTrip/returnOnly, falling back to the passenger-level
-- trip_type for legacy entries that were never leg-stamped. Cancelled
-- passengers are excluded so a cancellation frees its berth here too.
create or replace function public.public_tour_availability(p_tour_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with occ as (
    select seat->>'busId'  as bus_id,
           seat->>'seatId' as seat_id,
           coalesce(nullif(seat->>'leg', ''), p.trip_type, 'roundTrip') as leg,
           p.gender as gender
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)
      ) as seat
     where p.tour_id = p_tour_id
       and p.cancelled_at is null
       and coalesce(seat->>'busId', '')  <> ''
       and coalesce(seat->>'seatId', '') <> ''
  )
  select case
    when not public.public_tour_visible(p_tour_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(g.o)
          from (
            select jsonb_build_object(
                     'bus_id',   bus_id,
                     'seat_id',  seat_id,
                     'used_go',  count(*) filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'used_ret', count(*) filter (
                                   where leg in ('roundTrip', 'returnOnly')),
                     'lady_go',  bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'outboundOnly')),
                     'lady_ret', bool_or(gender = 'female') filter (
                                   where leg in ('roundTrip', 'returnOnly'))
                   ) as o
              from occ
             group by bus_id, seat_id
          ) g
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.public_tour_availability(uuid) from public;
grant execute on function public.public_tour_availability(uuid) to anon, authenticated;
