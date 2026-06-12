-- ============================================================
-- 014_customer_booking_rpc.sql
-- Make customer booking reliable (create + edit).
--
-- Two bugs the CRUD audit found:
--   1. CREATE was two anonymous writes: insert booking_requests + UPSERT
--      passengers. The upsert's ON CONFLICT DO UPDATE path needs an anon
--      UPDATE policy on passengers, which does not exist — so a returning
--      customer (same tour+phone) failed with an RLS denial ("save failed").
--      It was also non-atomic (request row could commit without a passenger
--      row). Fix: one SECURITY DEFINER RPC that does both writes as owner.
--   2. EDIT called booking_request_customer_update with a 6th arg p_trip_type,
--      but the deployed function had only 5 params -> PGRST202, every edit
--      failed. Fix: replace it with a 6-param version that also persists
--      trip_type onto the passenger + request rows.
--
-- Idempotent; safe to run in the Supabase SQL editor.
-- ============================================================

-- Defensive: the customer flow writes trip_type to both tables.
alter table public.booking_requests add column if not exists trip_type text;
alter table public.passengers      add column if not exists trip_type text not null default 'roundTrip';


-- ── 1. Atomic customer CREATE ───────────────────────────────
create or replace function public.submit_booking_request(
  p_request_id   uuid,
  p_tour_id      uuid,
  p_phone        text,
  p_name         text,
  p_party_size   int,
  p_trip_type    text,
  p_raw_form     jsonb,
  p_request_lines jsonb,
  p_note         text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_public boolean;
begin
  -- Only allow booking on a tour that's open to the public.
  select is_public into v_public from public.tours where id = p_tour_id;
  if v_public is distinct from true then
    raise exception 'This tour is not open for booking.'
      using errcode = 'check_violation';
  end if;

  -- Audit row in the admin's request inbox.
  insert into public.booking_requests
    (id, tour_id, customer_phone, customer_name, party_size, trip_type, raw_form)
  values
    (p_request_id, p_tour_id, p_phone, p_name, p_party_size, p_trip_type, p_raw_form);

  -- Live admin-facing passenger row. Runs as the function owner, so the
  -- ON CONFLICT update path is NOT blocked by anon RLS — a returning
  -- customer correctly updates their existing row instead of erroring.
  insert into public.passengers
    (tour_id, name, phone, request_lines, trip_type, note)
  values
    (p_tour_id, p_name, p_phone, p_request_lines, p_trip_type, p_note)
  on conflict (tour_id, phone) do update
    set name          = excluded.name,
        request_lines = excluded.request_lines,
        trip_type     = excluded.trip_type,
        note          = excluded.note,
        updated_at    = now();
end;
$$;

revoke all on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text)
  from public;
grant execute on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text)
  to anon, authenticated;


-- ── 2. Customer EDIT — add p_trip_type (6 params) ───────────
-- Drop BOTH the old 5-arg version AND any existing 6-arg version before
-- recreating. A plain `create or replace` fails with 42P13 ("cannot remove
-- parameter defaults") when a prior 6-arg function already exists with a
-- defaulted param — so we drop first, then create clean.
drop function if exists public.booking_request_customer_update(uuid, int, text, jsonb, jsonb);
drop function if exists public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text);

create function public.booking_request_customer_update(
  p_id            uuid,
  p_party_size    int,
  p_customer_name text,
  p_raw_form      jsonb,
  p_request_lines jsonb,
  p_trip_type     text
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_tour_id        uuid;
  v_customer_phone text;
  v_seats_taken    boolean;
begin
  select br.tour_id, br.customer_phone
    into v_tour_id, v_customer_phone
    from public.booking_requests br
   where br.id = p_id and br.status = 'pending';
  if not found then
    return false;
  end if;

  -- Refuse the edit once the admin has assigned seats.
  select exists(
    select 1 from public.passengers p
     where p.tour_id = v_tour_id
       and p.phone   = v_customer_phone
       and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
  ) into v_seats_taken;
  if v_seats_taken then
    return false;
  end if;

  update public.booking_requests
     set party_size         = p_party_size,
         customer_name      = p_customer_name,
         raw_form           = p_raw_form,
         trip_type          = p_trip_type,
         customer_edited_at = now()
   where id = p_id;

  update public.passengers
     set name          = p_customer_name,
         request_lines = p_request_lines,
         trip_type     = p_trip_type
   where tour_id = v_tour_id
     and phone   = v_customer_phone;

  return true;
end;
$$;

revoke all on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text) from public;
grant execute on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text)
  to anon, authenticated;
