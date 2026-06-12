-- ============================================================
-- 011_audit_security_hardening.sql
-- Backend fixes from the application audit (2026-06).
-- Safe to run as-is in the Supabase SQL editor; every statement is idempotent.
--
-- Covers:
--   SEC-2  drop the anon PII-leak policy on passengers
--   DI-1   swap_passenger_seats()       — atomic 2-passenger seat swap
--   DI-2   apply_seat_assignments()     — atomic bulk seat-plan apply (fillTour)
--   SEC-3  booking_requests rate limit  — throttle anon spam
--   SEC-5  make seat-chart / broadcast storage buckets PRIVATE
--   SEC-1  RLS coverage check (read-only query at the bottom)
--
-- NOTE: DI-1 and DI-2 are deployable now but only take effect once the Flutter
-- client calls them via supabase.rpc(...) instead of the two/N direct writes.
-- The functions sit harmlessly unused until then.
-- ============================================================


-- ── SEC-2 ───────────────────────────────────────────────────
-- Remove the policy that let ANY anonymous caller read every passenger's
-- name/phone/seat for any public tour. The customer "my requests" lookup must
-- go through a phone-scoped SECURITY DEFINER RPC instead, never a blanket
-- anon SELECT.
drop policy if exists "passengers_anon_select" on public.passengers;


-- ── DI-1: atomic seat swap ──────────────────────────────────
-- Updates both passengers' assigned_seats in ONE transaction so a crash can't
-- leave A on B's seat while B still holds it (a double-booked berth). The
-- client computes both new seat arrays (as it already does locally) and passes
-- them in. Owner-scoped via the tour's owner_id.
create or replace function public.swap_passenger_seats(
  p_passenger_a uuid,
  p_seats_a     jsonb,
  p_passenger_b uuid,
  p_seats_b     jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner_a uuid;
  v_owner_b uuid;
begin
  select t.owner_id into v_owner_a
    from public.passengers p join public.tours t on t.id = p.tour_id
   where p.id = p_passenger_a;
  select t.owner_id into v_owner_b
    from public.passengers p join public.tours t on t.id = p.tour_id
   where p.id = p_passenger_b;

  if v_owner_a is null or v_owner_b is null then
    raise exception 'passenger not found';
  end if;
  if v_owner_a <> auth.uid() or v_owner_b <> auth.uid() then
    raise exception 'not authorized';
  end if;

  update public.passengers
     set assigned_seats = p_seats_a, updated_at = now()
   where id = p_passenger_a;
  update public.passengers
     set assigned_seats = p_seats_b, updated_at = now()
   where id = p_passenger_b;
end;
$$;

grant execute on function
  public.swap_passenger_seats(uuid, jsonb, uuid, jsonb) to authenticated;


-- ── DI-2: atomic bulk seat-plan apply (fillTour) ────────────
-- Applies every changed passenger's assigned_seats in ONE transaction, so a
-- mid-apply failure can never leave half the tour on the new plan and half on
-- the old. p_assignments is [{"id": <uuid>, "assigned_seats": [...]}, ...].
create or replace function public.apply_seat_assignments(
  p_tour_id     uuid,
  p_assignments jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
  rec     jsonb;
begin
  select owner_id into v_owner from public.tours where id = p_tour_id;
  if v_owner is null then
    raise exception 'tour not found';
  end if;
  if v_owner <> auth.uid() then
    raise exception 'not authorized';
  end if;

  for rec in select jsonb_array_elements(p_assignments) loop
    update public.passengers
       set assigned_seats = rec->'assigned_seats', updated_at = now()
     where id = (rec->>'id')::uuid
       and tour_id = p_tour_id;
  end loop;
end;
$$;

grant execute on function
  public.apply_seat_assignments(uuid, jsonb) to authenticated;


-- ── SEC-3: booking-request rate limit ───────────────────────
-- Caps anonymous booking submissions at 3 per phone, per tour, per hour so a
-- script can't flood the admin's Requests inbox. SECURITY DEFINER so the count
-- sees all rows regardless of RLS.
create or replace function public.booking_requests_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
    from public.booking_requests
   where customer_phone = new.customer_phone
     and tour_id = new.tour_id
     and created_at > now() - interval '1 hour';

  if v_recent >= 3 then
    raise exception
      'Too many booking requests for this tour from this number — please wait a bit and try again.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists booking_requests_rate_limit_trg on public.booking_requests;
create trigger booking_requests_rate_limit_trg
  before insert on public.booking_requests
  for each row execute function public.booking_requests_rate_limit();


-- ── SEC-5: make the manifest/broadcast buckets PRIVATE ──────
-- The seat-chart PDFs contain the full passenger manifest. With public buckets
-- the files are reachable forever at their path. Make them private; the app now
-- mints short-lived SIGNED URLs (Meta fetches them once at send time).
update storage.buckets set public = false
 where id in ('seat-charts', 'tour-broadcasts');

-- Allow the signed-in admin to upload + read these objects (reading is needed
-- to MINT signed URLs). Recipients/Meta use the signed token, not RLS.
-- If you already have storage policies for these buckets, review for overlap.
drop policy if exists "charts_admin_rw" on storage.objects;
create policy "charts_admin_rw" on storage.objects
  for all to authenticated
  using      (bucket_id in ('seat-charts', 'tour-broadcasts'))
  with check (bucket_id in ('seat-charts', 'tour-broadcasts'));


-- ── SEC-1: RLS coverage check (read-only) ───────────────────
-- Run this any time (and ideally in CI after each migration). It returns any
-- public table that does NOT have row-level security enabled — the anon key
-- would expose such a table to the whole internet. Expect ZERO rows.
--
--   select c.relname as table_without_rls
--     from pg_class c
--     join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public'
--      and c.relkind = 'r'
--      and not c.relrowsecurity;
