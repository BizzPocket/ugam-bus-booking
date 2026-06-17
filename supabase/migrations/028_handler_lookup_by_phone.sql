-- 028_handler_lookup_by_phone.sql
--
-- Phone -> handler-request bridge.
--
-- The whole handler flow (is_request_handler, handler_tour_manifest,
-- handler_upsert_collection, ...) is requestId-scoped: every one of those RPCs
-- takes a p_request_id and resolves the tour from public.booking_requests,
-- matching br.tour_id = p.tour_id AND br.customer_phone = p.phone. So to let a
-- handler reach the existing HandlerBusChartScreen(requestId:) flow by simply
-- typing their phone number, we need to translate a PHONE into the
-- booking_request id(s) of every tour where that phone is the designated
-- handler. This function is that translation step — it does NO writing, so all
-- the existing write RPCs keep working unchanged.
--
-- For each DISTINCT tour where:
--   * a passenger p has p.is_handler = true and last-10-digits(p.phone) matches
--     the queried number, AND
--   * a booking_requests row br exists for that same tour + phone,
-- we return one object carrying a booking_request id the UI can hand straight to
-- the requestId-scoped flow.
--
-- INTENTIONAL OMISSION: a tour whose handler has NO booking_requests row cannot
-- be managed through the requestId flow at all (every handler RPC dead-ends on
-- the missing br), so such tours are deliberately NOT returned here — surfacing
-- them would only produce a request id the rest of the flow can't honor.
--
-- Phone matching mirrors 027_seat_lookup_by_phone.sql exactly: compare the LAST
-- 10 DIGITS of the stripped number, so +91 / spaces / dashes never cause a miss.
--
-- SECURITY DEFINER: handlers arrive anonymous (no auth, no direct read on
-- passengers / booking_requests / tours under owner RLS); this returns only the
-- request/tour refs for the queried number and nothing else.

create or replace function public.handler_requests_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  -- One row per tour this phone handles, carrying a single deterministically
  -- chosen booking_request id (earliest created, then smallest id) for that
  -- tour + handler phone.
  refs as (
    select distinct on (t.id)
           br.id             as request_id,
           t.id              as tour_id,
           t.title           as tour_title,
           t.from_city       as from_city,
           t.to_city         as to_city,
           t.departure_date  as departure_date,
           t.status          as status
      from public.passengers p
      cross join norm
      join public.tours t
        on t.id = p.tour_id
      join public.booking_requests br
        on br.tour_id = p.tour_id
       and right(regexp_replace(br.customer_phone, '\D', '', 'g'), 10) = norm.last10
     where norm.last10 <> ''
       and p.is_handler = true
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
     order by t.id, br.created_at, br.id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'request_id',     refs.request_id,
        'tour_id',        refs.tour_id,
        'tour_title',     refs.tour_title,
        'from_city',      refs.from_city,
        'to_city',        refs.to_city,
        'departure_date', refs.departure_date,
        'status',         refs.status
      )
      order by refs.departure_date desc
    ),
    '[]'::jsonb
  )
    from refs;
$$;

revoke all on function public.handler_requests_by_phone(text) from public;
grant execute on function public.handler_requests_by_phone(text)
  to anon, authenticated;
