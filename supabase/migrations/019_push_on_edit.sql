-- ============================================================
-- 019  Push on customer edit (in addition to new requests)
-- ------------------------------------------------------------
-- Extends the booking-request push (migration 018) to also fire when a CUSTOMER
-- edits an existing request — not just on a brand-new one. The edit signal is
-- customer_edited_at advancing (stamped by booking_request_customer_update).
-- Admin status changes bump updated_at but never customer_edited_at, so they
-- stay silent and don't spam the organiser.
--
-- The trigger now fires AFTER INSERT OR UPDATE and passes an `event`
-- ('created' | 'updated') to the send-push function, which varies the copy.
-- Forward-only and idempotent. Mirrors database.sql §9b.
-- ============================================================

-- Defensive: customer_edited_at is referenced by the UPDATE branch below and is
-- stamped by booking_request_customer_update (014). Ensure it exists so the
-- trigger never errors on a DB where that column was missed.
alter table public.booking_requests
  add column if not exists customer_edited_at timestamptz;

create or replace function public.notify_booking_request()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_event  text;
  v_url text := 'https://rhyqjzulpvaeslbaymex.supabase.co/functions/v1/send-push';
begin
  -- Decide which event (if any) warrants a push.
  if tg_op = 'INSERT' then
    v_event := 'created';
  else
    -- UPDATE: only a CUSTOMER edit notifies (customer_edited_at advanced).
    if new.customer_edited_at is distinct from old.customer_edited_at
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

drop trigger if exists booking_requests_notify_push on public.booking_requests;
create trigger booking_requests_notify_push
  after insert or update on public.booking_requests
  for each row execute function public.notify_booking_request();
