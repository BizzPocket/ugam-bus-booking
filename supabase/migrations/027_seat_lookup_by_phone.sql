-- 027_seat_lookup_by_phone.sql
--
-- "Find my seat by phone" — lets ANY passenger pull their own seat(s) without a
-- booking_request. The in-app "Your seat" view (bus_layouts_for_request) starts
-- from a booking_requests row, so passengers the agent added MANUALLY (the
-- majority) have no in-app seat view at all. This phone-keyed lookup closes that
-- gap: enter a mobile number, get back every seat held under that number on a
-- LOCKED (or completed) tour, plus the bus layout(s) to draw them.
--
-- Scope / safety:
--   * Only LOCKED or COMPLETED tours — pre-lock seats are provisional and stay
--     hidden, exactly like bus_layouts_for_request's lock gate.
--   * Phone is matched on the LAST 10 DIGITS of the stripped number, so +91 /
--     spaces / dashes never cause a miss (the same fragility that locks people
--     out elsewhere).
--   * SECURITY DEFINER: customers are anonymous and cannot read passengers /
--     buses directly; this returns only the seats for the queried number plus
--     the bus diagrams (other passengers' identities are never included).

create or replace function public.seat_lookup_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  -- Seated passengers whose phone's last 10 digits match, on a final-state tour.
  pax as (
    select p.id, p.tour_id, p.name, p.assigned_seats
      from public.passengers p
      join public.tours t on t.id = p.tour_id
      cross join norm
     where norm.last10 <> ''
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status in ('locked', 'completed')
       and p.assigned_seats is not null
       and p.assigned_seats <> '[]'::jsonb
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'tour_id',        t.id,
        'tour_title',     t.title,
        'from_city',      t.from_city,
        'to_city',        t.to_city,
        'departure_date', t.departure_date,
        'status',         t.status,
        'passenger_name', pax.name,
        'assigned_seats', pax.assigned_seats,
        'buses', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id',              b.id,
                'tour_id',         b.tour_id,
                'name',            b.name,
                'registration_no', b.registration_no,
                'bus_type',        b.bus_type,
                'total_seats',     b.total_seats,
                'layout',          b.layout,
                'boarding_point',  b.boarding_point,
                'departure_time',  b.departure_time
              )
              order by b.name
            ),
            '[]'::jsonb
          )
            from public.buses b
           where b.tour_id = t.id
             and b.id::text in (
               select distinct seat ->> 'busId'
                 from jsonb_array_elements(pax.assigned_seats) seat
                where seat ? 'busId'
             )
        )
      )
      order by t.departure_date desc
    ),
    '[]'::jsonb
  )
    from pax
    join public.tours t on t.id = pax.tour_id;
$$;

revoke all on function public.seat_lookup_by_phone(text) from public;
grant execute on function public.seat_lookup_by_phone(text)
  to anon, authenticated;
