-- ============================================================
-- 035  Customer cancellation REQUEST (confirmed / seat-assigned bookings)
-- ------------------------------------------------------------
-- The companion to 034. Where 034 lets a customer INSTANTLY self-cancel a booking
-- that is still purely pending, this file handles the other half: once the
-- organiser has confirmed the booking or assigned it a seat, the customer can no
-- longer pull the booking out from under the organiser. Instead the app's cancel
-- button raises a *request* — the customer asks to be cancelled, and the
-- organiser approves it later. Nothing is freed here.
--
-- On such a request we DO NOT change status, DO NOT free any seat, and the
-- passenger STAYS on the active roster/capacity (the organiser still has to
-- approve it). We only stamp two mirrored markers:
--   * booking_requests.cancel_requested_at = now()  → drives the customer's
--     "Cancellation requested" state and the organiser push.
--   * passengers.cancel_requested_at    = now()  → the admin roster reads ONLY
--     the passengers table (never booking_requests), so the flag is mirrored
--     here exactly like 034 mirrors cancelled_at. UNLIKE cancelled_at this is
--     NOT filtered out of the roster — the passenger keeps counting toward
--     demand until the organiser APPROVES (which removes the row + frees seat).
--   The seat, the confirmation and the roster all stay exactly as they were
--   until the organiser acts on the request.
--
-- The organiser is notified via the existing send-push pipeline (no new secret,
-- no new channel): notify_booking_request now fires a 'cancel_requested' event
-- when cancel_requested_at first goes non-null. send-push renders the copy.
--
-- The RPC is the mirror image of 034's gate: booking_request_customer_cancel
-- refuses once a booking is confirmed/seated; booking_request_customer_request_cancel
-- refuses UNLESS it is confirmed/seated. The client picks the right RPC by state
-- (still-pending → instant cancel; confirmed/seated → request cancel).
--
-- booking_request_status_lookup also returns cancel_requested_at so the customer
-- app can render the pending-cancellation banner from a single lookup.
--
-- DEPLOYMENT: run THIS FILE ALONE in the Supabase SQL editor (NOT db push — the
-- numbered history is out of sync with the live schema). No new secrets are
-- needed; it reuses the push pipeline from 018/019/034. Idempotent.
-- ============================================================

begin;

-- ── 1. Pending-cancellation markers (keep everything, just flag the ask) ──
-- Mirrored on BOTH tables: booking_requests drives the customer app + push,
-- passengers is the ONLY table the admin roster loads, so the organiser can
-- see + act on the request. Neither marker removes the row or frees a seat.
alter table public.booking_requests
  add column if not exists cancel_requested_at timestamptz;

alter table public.passengers
  add column if not exists cancel_requested_at timestamptz;

-- ── 2. Customer "request cancellation" RPC ─────────────────
-- Anonymous customers have no Supabase session, so this is SECURITY DEFINER and
-- does its own authorization: it only acts on the request id passed, and refuses
-- unless that request is confirmed / seat-assigned and has not already asked.
-- Returns true when the request was stamped, false when the gate blocked it
-- (still purely pending / already cancelled / already requested / gone). For the
-- purely-pending case the client falls back to booking_request_customer_cancel.
create or replace function public.booking_request_customer_request_cancel(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status       text;
  v_cancel_req   timestamptz;
  v_passenger_id uuid;
  v_tour_id      uuid;
  v_phone        text;
  v_confirmed    boolean;
  v_seat_count   int;
begin
  select br.status, br.cancel_requested_at, br.passenger_id, br.tour_id, br.customer_phone
    into v_status, v_cancel_req, v_passenger_id, v_tour_id, v_phone
    from public.booking_requests br
   where br.id = p_id
   limit 1;

  if not found then
    return false;                       -- unknown request
  end if;
  if v_status in ('cancelled', 'rejected') then
    return false;                       -- already gone
  end if;
  if v_cancel_req is not null then
    return false;                       -- already requested → no duplicate push
  end if;

  -- Resolve the linked passenger (prefer the explicit link, fall back to the
  -- tour_id + phone match used elsewhere for legacy rows).
  select p.is_confirmed,
         coalesce(jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)), 0),
         p.id
    into v_confirmed, v_seat_count, v_passenger_id
    from public.passengers p
   where (v_passenger_id is not null and p.id = v_passenger_id)
      or (v_passenger_id is null and p.tour_id = v_tour_id and p.phone = v_phone)
   order by p.created_at asc
   limit 1;

  -- Mirror of 034: this path is ONLY for confirmed / already-seated bookings.
  -- A still-purely-pending booking must use the instant self-cancel RPC instead.
  if not (v_confirmed is true or coalesce(v_seat_count, 0) > 0) then
    return false;
  end if;

  -- Stamp the ask only — status, seat and the passenger's place on the roster
  -- all stay untouched; the organiser approves (and actually frees the seat)
  -- later. Mirror the marker onto the passenger row too, because the admin app
  -- loads ONLY the passengers table — this is what surfaces the request to the
  -- organiser. Fires the 'cancel_requested' push via the booking_requests trigger.
  if v_passenger_id is not null then
    update public.passengers
       set cancel_requested_at = now()
     where id = v_passenger_id
       and cancel_requested_at is null;
  end if;

  update public.booking_requests
     set cancel_requested_at = now()
   where id = p_id
     and cancel_requested_at is null;

  return true;
end;
$$;

revoke all on function public.booking_request_customer_request_cancel(uuid) from public;
grant execute on function public.booking_request_customer_request_cancel(uuid)
  to anon, authenticated;

-- ── 3. status_lookup: also expose cancel_requested_at ──────
-- The return-table signature changes, so DROP then re-create. Every column from
-- 034 is preserved; cancel_requested_at is appended so the customer app can show
-- the "cancellation requested — awaiting organiser" banner from one lookup.
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
  cancel_requested_at timestamptz
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
    br.cancel_requested_at
  from public.booking_requests br
  join public.tours t on t.id = br.tour_id
  where br.id = p_id
  limit 1;
$$;
revoke all on function public.booking_request_status_lookup(uuid) from public;
grant execute on function public.booking_request_status_lookup(uuid)
  to anon, authenticated;

-- ── 4. Push on customer cancellation request ───────────────
-- Extends notify_booking_request (018/019/034): the created/updated/cancelled
-- branches are preserved verbatim; we add a 'cancel_requested' event that fires
-- when cancel_requested_at first goes non-null (status stays 'pending'/'confirmed',
-- so this can never collide with the 'cancelled' or 'updated' branches). Same
-- vault secret + net.http_post + swallow-on-error pattern.
create or replace function public.notify_booking_request()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_event  text;
  v_url text := 'https://rhyqjzulpvaeslbaymex.supabase.co/functions/v1/send-push';
begin
  if tg_op = 'INSERT' then
    v_event := 'created';
  else
    -- Customer self-cancelled → tell the organiser.
    if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
      v_event := 'cancelled';
    -- Customer requested cancellation of a confirmed/seated booking (needs approval).
    elsif new.cancel_requested_at is distinct from old.cancel_requested_at
          and new.cancel_requested_at is not null then
      v_event := 'cancel_requested';
    -- Customer edited an existing request (customer_edited_at advanced).
    elsif new.customer_edited_at is distinct from old.customer_edited_at
          and new.customer_edited_at is not null then
      v_event := 'updated';
    else
      return new;
    end if;
  end if;

  begin
    select decrypted_secret into v_secret
      from vault.decrypted_secrets
     where name = 'push_trigger_secret'
     limit 1;
    if v_secret is null then
      return new;  -- push not configured yet
    end if;
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-push-secret', v_secret),
      body    := jsonb_build_object('request_id', new.id, 'event', v_event)
    );
  exception when others then
    raise warning 'notify_booking_request push dispatch failed: %', sqlerrm;
  end;
  return new;
end;
$$;

commit;
