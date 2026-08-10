-- ============================================================
-- 067  chart_hold_status_lookup — let a customer see their own seat hold
-- ------------------------------------------------------------
-- THE BUG THIS FIXES
--
-- On a tour that collects an online advance, `chart_hold_seats` (064) writes
-- ONLY a `seat_holds` row. The `booking_requests` row is created later, by
-- `chart_finalize_hold`, once the advance is confirmed.
--
-- The customer app refreshes a ticket through `booking_request_status_lookup`
-- and treated an empty result as "the organiser deleted this", flipping the
-- local ticket to Cancelled. For a live, unpaid hold that is simply wrong: the
-- seats ARE blocked on the chart, the booking IS alive, it just has not been
-- paid for yet. Customers watched their booking read "Cancelled" while the
-- chart showed their berths taken and the organiser showed 0 occupied.
--
-- This RPC supplies the missing half of that picture. The client merges the two
-- results; `booking_request_status_lookup` is NOT modified, because it exists
-- only in the live database and not in this repo.
--
-- WHY IT IS SAFE TO EXPOSE TO anon
--   * Keyed by request_id, which is a client-generated uuid v4 known only to
--     the device that created the booking — the same secret the existing
--     booking_request_status_lookup already relies on.
--   * Returns NO name, NO phone, NO seat ids, and nothing about any other
--     booking. Only: which request, which bus, hold state, deadline, how many
--     berths. Nothing here identifies a person.
--   * Capped at 50 ids per call so it cannot be walked cheaply.
--
-- Idempotent. Apply in the Supabase SQL editor after 066.
-- ============================================================

create or replace function public.chart_hold_status_lookup(
  p_request_ids uuid[]
) returns table (
  request_id uuid,
  hold_id    uuid,
  bus_id     uuid,
  status     text,
  expires_at timestamptz,
  berths     int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    h.request_id,
    -- The client needs this to record a late UPI claim through
    -- claim_upi_advance_for_hold when the customer pays from My Requests
    -- rather than in the sheet shown at checkout.
    h.id as hold_id,
    h.bus_id,
    -- Report a lapsed hold as 'expired' rather than leaking the raw 'pending'
    -- with a past deadline. The client floors the countdown at zero anyway,
    -- but the two must agree on what "still holding" means, and the server is
    -- the authority: chart_seat_availability releases the seats on exactly
    -- this predicate.
    case
      when h.status = 'pending' and h.expires_at <= now() then 'expired'
      else h.status
    end as status,
    h.expires_at,
    coalesce((
      select sum(coalesce((c->>'berths')::int, 1))::int
        from jsonb_array_elements(h.seats) c
    ), 0) as berths
  from public.seat_holds h
  where h.request_id = any(p_request_ids)
    and array_length(p_request_ids, 1) <= 50;
$$;

revoke all on function public.chart_hold_status_lookup(uuid[]) from public;
grant execute on function public.chart_hold_status_lookup(uuid[])
  to anon, authenticated;


-- ── Verify ───────────────────────────────────────────────────
-- Should list every live hold on the seeded test tour, with the time left.
--
--   select h.request_id,
--          l.status,
--          l.berths,
--          l.expires_at - now() as time_left
--     from public.seat_holds h
--     cross join lateral public.chart_hold_status_lookup(array[h.request_id]) l
--    where h.tour_id = 'aaaa1111-0000-4000-8000-000000000001';
--
-- An unknown id must return ZERO rows (that is the genuine-deletion case the
-- client still maps to Cancelled):
--
--   select count(*) from public.chart_hold_status_lookup(
--     array['00000000-0000-4000-8000-000000000000'::uuid]);
--   -- expected: 0
