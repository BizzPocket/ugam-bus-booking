-- ============================================================
-- 034  Customer self-cancel (only before confirmation)
-- ------------------------------------------------------------
-- Lets a customer cancel their OWN booking request from the app — but ONLY
-- while it is still purely pending (not admin-confirmed, no seats assigned).
-- Once the organiser confirms or seats it, the customer must contact the
-- organiser by phone; the RPC below refuses the cancel server-side, so a stale
-- client screen can never slip a confirmed booking out from under the organiser.
--
-- On a successful cancel we KEEP both rows (audit trail) and just MARK them:
--   * passengers.cancelled_at   is stamped  → the app filters this passenger out
--     of every active roster / capacity calc (it stops counting toward demand),
--     while the row survives for history.
--   * booking_requests.status = 'cancelled', cancelled_at stamped → drives the
--     customer's "Cancelled" tab and the organiser push.
--
-- The organiser is notified via the existing send-push pipeline: the
-- notify_booking_request trigger now fires a 'cancelled' event when status
-- flips to 'cancelled' (send-push renders the cancellation copy).
--
-- Also extends booking_request_status_lookup to return is_confirmed, so the
-- customer app knows a request is confirmed even before seats exist (today an
-- admin-confirmed-but-unseated request still reads "Pending" to the customer).
--
-- DEPLOYMENT: run THIS FILE ALONE in the Supabase SQL editor (NOT db push — the
-- numbered history is out of sync with the live schema). Idempotent.
-- ============================================================

begin;

-- ── 1. Soft-cancel columns (keep the rows, just mark them) ──
alter table public.passengers
  add column if not exists cancelled_at timestamptz;

alter table public.booking_requests
  add column if not exists cancelled_at timestamptz;

-- ── 2. Customer self-cancel RPC ────────────────────────────
-- Customers are anonymous (no Supabase session) so this is SECURITY DEFINER and
-- does its own authorization: it only acts on the request id the caller passes,
-- and refuses unless that request is still cancel-eligible. Returns true when a
-- cancel happened, false when the gate blocked it (confirmed / seated / gone).
create or replace function public.booking_request_customer_cancel(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status       text;
  v_passenger_id uuid;
  v_tour_id      uuid;
  v_phone        text;
  v_confirmed    boolean;
  v_seat_count   int;
begin
  select br.status, br.passenger_id, br.tour_id, br.customer_phone
    into v_status, v_passenger_id, v_tour_id, v_phone
    from public.booking_requests br
   where br.id = p_id
   limit 1;

  if not found then
    return false;                       -- unknown request
  end if;
  if v_status is distinct from 'pending' then
    return false;                       -- already confirmed / cancelled / gone
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

  -- A confirmed or already-seated passenger can NEVER be self-cancelled.
  if v_confirmed is true or coalesce(v_seat_count, 0) > 0 then
    return false;
  end if;

  -- Mark the passenger cancelled (kept for history; filtered from active lists).
  if v_passenger_id is not null then
    update public.passengers
       set cancelled_at = now()
     where id = v_passenger_id
       and cancelled_at is null;
  end if;

  -- Flip the request to cancelled (fires the 'cancelled' push via the trigger).
  update public.booking_requests
     set status = 'cancelled',
         cancelled_at = now()
   where id = p_id;

  return true;
end;
$$;

revoke all on function public.booking_request_customer_cancel(uuid) from public;
grant execute on function public.booking_request_customer_cancel(uuid)
  to anon, authenticated;

-- ── 3. status_lookup: also expose is_confirmed ─────────────
-- The return-table signature changes, so DROP then re-create. Matches the
-- passenger by the explicit booking_requests.passenger_id link (falling back to
-- tour_id + phone for legacy rows), which also sharpens assigned_seats for
-- phones holding multiple requests.
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
  created_at          timestamptz
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
    br.created_at
  from public.booking_requests br
  join public.tours t on t.id = br.tour_id
  where br.id = p_id
  limit 1;
$$;
revoke all on function public.booking_request_status_lookup(uuid) from public;
grant execute on function public.booking_request_status_lookup(uuid)
  to anon, authenticated;

-- ── 4. Push on customer cancel ─────────────────────────────
-- Extends notify_booking_request (018/019): a flip to status='cancelled' now
-- fires the send-push 'cancelled' event. The customer edit branch is unchanged;
-- admin status changes still stay silent (they don't set status='cancelled' —
-- admin decline DELETEs the row).
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
