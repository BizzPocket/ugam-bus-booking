-- ============================================================
-- 018  Push notifications — device tokens + FCM dispatch
-- ------------------------------------------------------------
-- Adds the admin-facing push pipeline (booking-request alerts):
--
--   1. device_tokens            one row per (admin, FCM token, platform)
--   2. register/unregister RPCs  SECURITY DEFINER token lifecycle for the app
--   3. notify_booking_request()  AFTER INSERT trigger on booking_requests that
--                                fires the `send-push` Edge Function via pg_net
--
-- Forward-only and idempotent. Mirrors database.sql §9b — keep the two in sync.
--
-- One-time secret setup (NOT in git):
--   select vault.create_secret('<RANDOM>', 'push_trigger_secret');
--   supabase secrets set PUSH_TRIGGER_SECRET=<RANDOM>
--   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
--   supabase functions deploy send-push --no-verify-jwt
-- Until the vault secret exists, the trigger is a quiet no-op.
-- ============================================================

create extension if not exists pg_net;

create table if not exists public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  admin_id   uuid not null references public.admins(id) on delete cascade,
  token      text not null unique,
  platform   text not null check (platform in ('ios', 'android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists device_tokens_admin_idx on public.device_tokens(admin_id);

drop trigger if exists device_tokens_set_updated_at on public.device_tokens;
create trigger device_tokens_set_updated_at before update on public.device_tokens
  for each row execute function public.set_updated_at();

alter table public.device_tokens enable row level security;

drop policy if exists "device_tokens_owner_select" on public.device_tokens;
create policy "device_tokens_owner_select" on public.device_tokens
  for select to authenticated using (admin_id = auth.uid());

drop policy if exists "device_tokens_owner_delete" on public.device_tokens;
create policy "device_tokens_owner_delete" on public.device_tokens
  for delete to authenticated using (admin_id = auth.uid());

-- REGISTER: upsert the calling admin's token; re-point on conflict(token).
create or replace function public.register_device_token(p_token text, p_platform text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if p_token is null or length(p_token) = 0 then
    return;
  end if;
  insert into public.device_tokens (admin_id, token, platform)
  values (auth.uid(), p_token, coalesce(nullif(p_platform, ''), 'android'))
  on conflict (token) do update
     set admin_id   = excluded.admin_id,
         platform   = excluded.platform,
         updated_at = now();
end;
$$;
revoke all on function public.register_device_token(text, text) from public;
grant execute on function public.register_device_token(text, text) to authenticated;

-- UNREGISTER: drop this device's token on logout. Scoped to the caller.
create or replace function public.unregister_device_token(p_token text)
returns void
language sql security definer set search_path = public
as $$
  delete from public.device_tokens
   where token = p_token and admin_id = auth.uid();
$$;
revoke all on function public.unregister_device_token(text) from public;
grant execute on function public.unregister_device_token(text) to authenticated;

-- AFTER INSERT on booking_requests → fire send-push (best-effort, never blocks
-- the customer's booking insert).
create or replace function public.notify_booking_request()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_url text := 'https://rhyqjzulpvaeslbaymex.supabase.co/functions/v1/send-push';
begin
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
      body    := jsonb_build_object('request_id', new.id)
    );
  exception when others then
    raise warning 'notify_booking_request push dispatch failed: %', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists booking_requests_notify_push on public.booking_requests;
create trigger booking_requests_notify_push
  after insert on public.booking_requests
  for each row execute function public.notify_booking_request();
