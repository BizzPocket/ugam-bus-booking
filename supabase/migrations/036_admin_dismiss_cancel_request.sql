-- ============================================================
-- 036  Admin dismiss customer cancellation request (keep the passenger)
-- ------------------------------------------------------------
-- The companion to 035. When a customer RAISES a cancellation request, 035
-- stamps cancel_requested_at on BOTH the passenger row (drives the admin badge +
-- "Approve cancellation" CTA) and the booking_request (drives the customer's
-- "cancellation requested" state + blocks a duplicate re-request). The organiser
-- then has two choices:
--   * APPROVE  → the existing removePassenger path (frees the seat, drops the
--                row) — no new server code needed.
--   * DISMISS  → keep the passenger on the tour. This file adds that path: it
--                simply CLEARS the cancel_requested_at marker on both rows, so
--                the admin card reverts to its normal state AND the customer's
--                app drops the pending-cancellation banner and may ask again
--                later. Nothing else changes — seat, confirmation and roster all
--                stay exactly as they were.
--
-- SECURITY DEFINER because the marker also lives on booking_requests, which the
-- admin app never writes directly (all booking_requests mutations go through
-- SECURITY DEFINER RPCs). Owner-guarded with the same idiom as 004
-- (tours.owner_id = auth.uid()); legacy tours with a null owner stay permissive
-- so the action never dead-ends on the current single-owner setup. Granted to
-- authenticated ONLY — customers are anonymous, so they can never dismiss their
-- own request.
--
-- DEPLOYMENT: run THIS FILE ALONE in the Supabase SQL editor (NOT db push — the
-- numbered history is out of sync with the live schema). No new secrets.
-- Idempotent.
-- ============================================================

begin;

create or replace function public.booking_request_admin_dismiss_cancel(p_passenger_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tour_id uuid;
  v_phone   text;
  v_owner   uuid;
begin
  select p.tour_id, p.phone
    into v_tour_id, v_phone
    from public.passengers p
   where p.id = p_passenger_id
   limit 1;
  if not found then
    return false;                       -- unknown passenger
  end if;

  -- Owner guard: when the tour has an owner, only that owner (the signed-in
  -- organiser) may dismiss. A null owner (legacy tour) stays permissive.
  select t.owner_id into v_owner from public.tours t where t.id = v_tour_id;
  if v_owner is not null and v_owner is distinct from auth.uid() then
    return false;
  end if;

  -- Clear the marker on the passenger row (the admin roster reads this) …
  update public.passengers
     set cancel_requested_at = null
   where id = p_passenger_id;

  -- … and on the linked booking_request (customer view + re-request gate).
  -- Resolve the request the same way 034/035 do: the explicit passenger_id link
  -- first, then the legacy tour_id + phone match.
  update public.booking_requests
     set cancel_requested_at = null
   where cancel_requested_at is not null
     and (passenger_id = p_passenger_id
          or (passenger_id is null
              and tour_id = v_tour_id
              and customer_phone = v_phone));

  return true;
end;
$$;

revoke all on function public.booking_request_admin_dismiss_cancel(uuid) from public;
grant execute on function public.booking_request_admin_dismiss_cancel(uuid)
  to authenticated;

commit;
