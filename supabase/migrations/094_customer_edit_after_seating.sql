-- ============================================================
-- 094  A seated customer can still edit their own request
-- ------------------------------------------------------------
-- Today booking_request_customer_update refuses outright the moment the
-- passenger holds ANY seat:
--
--     if v_seats_taken then return false; end if;
--
-- The organiser seats people days before departure, so in practice that gate
-- closed the door on almost every real edit — a customer who wants to move
-- their pickup point, correct a name, or take one more berth had to phone the
-- agent, and the agent had to make the change by hand on the admin side.
--
-- *** WHAT REPLACES THE REFUSAL ***
-- The edit goes through, and any berths it leaves SURPLUS are trimmed off the
-- passenger's assigned_seats, oldest-kept-first. That is not a new policy — it
-- is exactly what the admin's own edit sheet already does
-- (lib/widgets/edit_request_sheet.dart trims assignedSeats down to the new
-- berth total and tells the agent how many it released). Growing a party never
-- auto-seats anyone: the extra berths simply land unseated and the organiser
-- places them, same as a fresh request.
--
-- party_size is counted in BERTHS (a Double Sofa is two) and assigned_seats
-- holds one entry per berth, so the two are directly comparable.
--
-- *** TWO GATES ARE ADDED, NOT REMOVED ***
--   1. cancel_requested_at is not null — the customer has already asked the
--      organiser to cancel this booking and is awaiting their decision. Editing
--      it underneath that request is incoherent, and the customer screen no
--      longer offers "Edit request" on such a card either.
--   2. tours.status in ('locked','completed') — once locked, seat numbers have
--      been sent out and the chart is final. Same boundary
--      booking_request_tour_locked (025) already draws for revealing seats.
--
-- *** WHY A FULL create or replace, AND THE RISK ***
-- This function's gate lives in the middle of its body; there is no additive
-- trigger that can relax it. The body below is 045's verbatim (mandatory-pickup
-- guard, COALESCE pickup writes, passenger backfill) with only the changes
-- described above. 045 is the newest FILE that defines this function — but this
-- repo's migration history is not authoritative, so if the live body has since
-- been hand-edited in the SQL editor, re-issuing this reverts that edit. Check
-- the live source before applying:
--
--     select prosrc from pg_proc
--      where proname = 'booking_request_customer_update';
--
-- Idempotent. Changes no existing rows.
--
-- Run THIS FILE ALONE in the Supabase SQL editor.
-- ============================================================

create or replace function public.booking_request_customer_update(
  p_id            uuid,
  p_party_size    int,
  p_customer_name text,
  p_raw_form      jsonb,
  p_request_lines jsonb,
  p_trip_type     text,
  p_pickup_location_id   uuid default null,
  p_pickup_location_name text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_tour_id        uuid;
  v_customer_phone text;
  v_passenger_id   uuid;
  v_existing_pid   uuid;
  v_cancel_asked   timestamptz;
  v_tour_status    text;
  v_berths         int := greatest(coalesce(p_party_size, 0), 0);
begin
  select br.tour_id, br.customer_phone, br.passenger_id, br.pickup_location_id,
         br.cancel_requested_at
    into v_tour_id, v_customer_phone, v_passenger_id, v_existing_pid,
         v_cancel_asked
    from public.booking_requests br
   where br.id = p_id and br.status = 'pending';
  if not found then
    return false;
  end if;

  -- A cancellation is already on the organiser's desk for this booking.
  if v_cancel_asked is not null then
    return false;
  end if;

  -- Locked / completed tour: the chart is final and seat numbers have gone out.
  select t.status into v_tour_status
    from public.tours t
   where t.id = v_tour_id;
  if v_tour_status in ('locked', 'completed') then
    return false;
  end if;

  -- Mandatory unless the request already carries one (an edit that doesn't
  -- touch the pickup must still go through) or there is no list to pick from.
  if p_pickup_location_id is null
     and v_existing_pid is null
     and public.tour_requires_pickup(v_tour_id) then
    raise exception 'Please choose a pickup point.'
      using errcode = 'check_violation';
  end if;

  if v_passenger_id is null then
    select p.id into v_passenger_id
      from public.passengers p
     where p.tour_id = v_tour_id
       and p.phone   = v_customer_phone
     order by p.created_at desc
     limit 1;
    if v_passenger_id is not null then
      update public.booking_requests
         set passenger_id = v_passenger_id
       where id = p_id;
    end if;
  end if;

  update public.booking_requests
     set party_size           = p_party_size,
         customer_name        = p_customer_name,
         raw_form             = p_raw_form,
         trip_type            = p_trip_type,
         pickup_location_id   = coalesce(p_pickup_location_id, pickup_location_id),
         pickup_location_name = coalesce(p_pickup_location_name, pickup_location_name),
         customer_edited_at   = now()
   where id = p_id;

  if v_passenger_id is not null then
    update public.passengers
       set name                 = p_customer_name,
           request_lines        = p_request_lines,
           trip_type            = p_trip_type,
           pickup_location_id   = coalesce(p_pickup_location_id, pickup_location_id),
           pickup_location_name = coalesce(p_pickup_location_name, pickup_location_name),
           -- Shrink only. The surplus berths come off the END of the list, so
           -- the seats the rider has had longest are the ones they keep; a
           -- party that GROWS keeps every seat it already had and the new
           -- berths wait for the organiser to place them.
           assigned_seats       = case
             when jsonb_array_length(coalesce(assigned_seats, '[]'::jsonb))
                    > v_berths
               then coalesce(
                 (select jsonb_agg(s.seat order by s.ord)
                    from jsonb_array_elements(
                           coalesce(assigned_seats, '[]'::jsonb)
                         ) with ordinality as s(seat, ord)
                   where s.ord <= v_berths),
                 '[]'::jsonb)
             else assigned_seats
           end
     where id = v_passenger_id;
  end if;

  return true;
end;
$$;

revoke all on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text, uuid, text) from public;
grant execute on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text, uuid, text)
  to anon, authenticated;
