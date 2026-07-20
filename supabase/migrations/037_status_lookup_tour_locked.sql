-- ============================================================
-- 037  Fold the tour-lock flag into booking_request_status_lookup
-- ------------------------------------------------------------
-- The customer "My Requests" screen decides whether to reveal a seat (and to
-- stop showing "seats being finalized") from a `tourLocked` flag. Until now the
-- client fetched that flag with a SECOND, standalone RPC (booking_request_tour_locked)
-- immediately after booking_request_status_lookup — two independent round trips
-- per request on every refresh.
--
-- That split is the bug behind "the tour is locked but it still says the seats
-- are being finalized": the standalone lock RPC fails CLOSED (any error/null →
-- false), so a transient failure or slowness of the SECOND call overwrote an
-- already-locked ticket back to not-locked, reverting the card to "finalizing"
-- and re-hiding the seat.
--
-- Fix: expose the lock state as a column on the SAME lookup, so one atomic read
-- returns status + seats + lock together. The client prefers this inline
-- `tour_locked`; the old standalone RPC (kept from 025) is now only a fallback
-- for app builds that predate this migration, and the client no longer lets an
-- indeterminate answer revert a locked ticket.
--
-- Every column from 035 is preserved verbatim; `tour_locked` is appended, so
-- older clients that ignore it are unaffected. The lock condition mirrors
-- booking_request_tour_locked / TourStatus.acceptsBookings exactly:
-- tour.status in ('locked','completed').
--
-- DEPLOYMENT: run THIS FILE ALONE in the Supabase SQL editor (NOT db push — the
-- numbered history is out of sync with the live schema). No new secrets, no data
-- migration. Idempotent (drop + create).
-- ============================================================

begin;

-- The return-table signature changes (new column), so DROP then re-create.
drop function if exists public.booking_request_status_lookup(uuid);
create function public.booking_request_status_lookup(p_id uuid)
returns table(
  id                  uuid,
  status              text,
  party_size          int,
  customer_name       text,
  customer_phone      text,
  tour_id             uuid,
  tour_title          text,
  tour_from           text,
  tour_to             text,
  tour_departure_date date,
  tour_price_per_seat numeric,
  raw_form            jsonb,
  assigned_seats      jsonb,
  is_confirmed        boolean,
  customer_edited_at  timestamptz,
  created_at          timestamptz,
  cancel_requested_at timestamptz,
  tour_locked         boolean
)
language sql security definer set search_path = public
as $$
  select
    br.id,
    br.status,
    br.party_size,
    br.customer_name,
    br.customer_phone,
    t.id,
    t.title,
    t.from_city,
    t.to_city,
    t.departure_date,
    t.price_per_seat,
    br.raw_form,
    coalesce(
      (select p.assigned_seats from public.passengers p where p.id = br.passenger_id),
      (select p.assigned_seats from public.passengers p
         where p.tour_id = br.tour_id and p.phone = br.customer_phone
         order by p.created_at asc limit 1)
    ),
    coalesce(
      (select p.is_confirmed from public.passengers p where p.id = br.passenger_id),
      (select p.is_confirmed from public.passengers p
         where p.tour_id = br.tour_id and p.phone = br.customer_phone
         order by p.created_at asc limit 1),
      false
    ),
    br.customer_edited_at,
    br.created_at,
    br.cancel_requested_at,
    -- Seats are final once the organiser locks the tour; stays true through the
    -- terminal 'completed' state. Mirrors booking_request_tour_locked exactly.
    (t.status in ('locked', 'completed'))
  from public.booking_requests br
  join public.tours t on t.id = br.tour_id
  where br.id = p_id
  limit 1;
$$;
revoke all on function public.booking_request_status_lookup(uuid) from public;
grant execute on function public.booking_request_status_lookup(uuid)
  to anon, authenticated;

commit;
