-- ============================================================
-- 025  Customer seat-reveal lock gate
-- ------------------------------------------------------------
-- Customers must only see their assigned seats AFTER the organiser LOCKS the
-- tour (all seats assigned + notifications sent). Until then, seat numbers and
-- the seat-layout sheet stay hidden behind a "seats not finalized yet" state.
--
-- A customer is anonymous (no Supabase Auth session), so the client cannot read
-- public.tours.status directly under owner_id RLS. This migration adds a
-- SECURITY DEFINER read that the client polls during its per-row refresh:
--
--   booking_request_tour_locked(p_id uuid) -> boolean
--       true iff the request's tour status is 'locked' or 'completed'.
--       Safe (false, never error) for unknown ids — treated as not-locked.
--
-- !!! LIVE-DB CAVEAT — READ BEFORE APPLYING !!!
--   The customer lookup RPCs `booking_request_status_lookup(p_id)` and
--   `bus_layouts_for_request(p_id)` are NOT defined in this repo's migrations —
--   they exist ONLY in the live Supabase DB. This migration deliberately does
--   NOT `create or replace` `bus_layouts_for_request`, because its live body is
--   not visible here and blindly replacing it could drop behavior.
--
--   For full server-side enforcement (defense in depth — the client already
--   gates on the boolean below), the PRODUCTION `bus_layouts_for_request`
--   SHOULD ALSO be updated in the Supabase SQL editor to return an EMPTY result
--   unless the request's tour is locked/completed, e.g. wrap its existing body
--   with a guard like:
--       if not public.booking_request_tour_locked(p_id) then return; end if;
--   Apply that edit by hand against the live function; it cannot be expressed
--   safely from this repo.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- READ: is the caller's booking request on a tour that has been locked?
-- Returns true only once the organiser advances the tour to 'locked' (or the
-- terminal 'completed') state, which is the point at which seats are final and
-- may be revealed to the customer. Safe for unknown/deleted ids (-> false).
create or replace function public.booking_request_tour_locked(p_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.booking_requests br
        join public.tours t
          on t.id = br.tour_id
       where br.id = p_id
         and t.status in ('locked', 'completed')
    ),
    false
  );
$$;

revoke all on function public.booking_request_tour_locked(uuid) from public;
grant execute on function public.booking_request_tour_locked(uuid)
  to anon, authenticated;
