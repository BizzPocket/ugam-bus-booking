-- ============================================================
-- 003  Handler full bus chart (whole-tour manifest)
-- ------------------------------------------------------------
-- A "handler" is a passenger flagged is_handler = true who runs the tour on
-- the ground. From the customer flow they arrive as an anonymous booking
-- request, so they can't read public.buses / public.passengers directly
-- (owner_id RLS). These two SECURITY DEFINER functions let a verified handler
-- pull the entire tour's bus chart — every bus layout plus every passenger's
-- seat assignment — gated on their own request id.
--
--   is_request_handler(p_request_id)  -> boolean
--       true iff the request's (tour_id, customer_phone) matches a passenger
--       row with is_handler = true. Safe (false, never error) for unknown ids.
--
--   handler_tour_manifest(p_request_id) -> jsonb
--       NULL unless the request belongs to a handler; otherwise a jsonb object
--       { "buses": [...], "passengers": [...] } for the whole tour.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- READ: is the caller's booking request owned by a tour handler?
create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.booking_requests br
        join public.passengers p
          on p.tour_id = br.tour_id
         and p.phone   = br.customer_phone
       where br.id = p_request_id
         and p.is_handler = true
    ),
    false
  );
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;

-- READ: full tour manifest (all buses + all passengers) for a handler.
-- Returns NULL for non-handler (or unknown) requests so the app can treat
-- "not a handler" and "no data" identically.
create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
  )
  select case
    when not public.is_request_handler(p_request_id) then null
    else jsonb_build_object(
      'buses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              b.id,
                     'tour_id',         b.tour_id,
                     'name',            b.name,
                     'registration_no', b.registration_no,
                     'bus_type',        b.bus_type,
                     'total_seats',     b.total_seats,
                     'layout',          b.layout
                   )
                   order by b.name
                 )
            from public.buses b
            join req on req.tour_id = b.tour_id
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',             p.id,
                     'tour_id',        p.tour_id,
                     'name',           p.name,
                     'phone',          p.phone,
                     'age_group',      p.age_group,
                     'assigned_seats', p.assigned_seats,
                     'is_handler',     p.is_handler
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;
