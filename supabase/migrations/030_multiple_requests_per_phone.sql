-- ============================================================
-- 030  Multiple booking requests per phone, per tour
-- ------------------------------------------------------------
-- Until now a customer was capped at ONE request per (tour, phone): the
-- create RPC (014 / 026) inserted the booking_requests audit row but UPSERTed
-- the live passenger row `on conflict (tour_id, phone) do update`, and the
-- edit RPC (014) resolved the passenger by (tour_id, phone). A second
-- submission from the same number silently OVERWROTE the first passenger.
--
-- The user wants a phone to hold MULTIPLE distinct requests on the same tour
-- (each a different traveller / seat mix), e.g. an agent submitting for several
-- people from their own handset. Each booking_requests row already has its own
-- UUID and each passenger row already has its own UUID — the only blockers were
-- the dedup points above.
--
-- THE STABLE LINK
--   booking_requests had NO column tying a request to the passenger row it
--   created, so (tour_id, phone) was the only handle — and it is now ambiguous
--   (N passengers share it). This migration adds `booking_requests.passenger_id`
--   as the unambiguous key:
--     • submit_booking_request now does a PLAIN INSERT into passengers and
--       writes the new passenger's id back onto the booking_requests row.
--     • booking_request_customer_update resolves the EXACT passenger via
--       booking_requests.passenger_id (the p_id it already receives), so an
--       edit touches only the one passenger tied to that request.
--   Legacy rows created before this migration have passenger_id = null; they are
--   backfilled below (newest passenger for the (tour, phone) wins) and the edit
--   RPC keeps a (tour_id, phone) fallback for any that still can't be resolved.
--
-- NO UNIQUE(tour_id, phone) CONSTRAINT exists on public.passengers in any
-- migration (the old `on conflict (tour_id, phone)` relied on a live-only index
-- that may or may not exist). To be safe this migration DROPS any such
-- constraint/index so a plain multi-row insert can never trip it.
--
-- Idempotent; safe to run in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- ── 0. Stable link column + backfill ───────────────────────────────
alter table public.booking_requests
  add column if not exists passenger_id uuid
    references public.passengers(id) on delete set null;

create index if not exists booking_requests_passenger_idx
  on public.booking_requests(passenger_id);

-- Backfill the link for legacy rows: pick the most-recently-created passenger
-- that matches the request's (tour_id, customer_phone). Only fills nulls, so it
-- is safe to re-run.
update public.booking_requests br
   set passenger_id = sub.pid
  from (
    select distinct on (p.tour_id, p.phone)
           p.tour_id, p.phone, p.id as pid
      from public.passengers p
     order by p.tour_id, p.phone, p.created_at desc
  ) sub
 where br.passenger_id is null
   and br.tour_id        = sub.tour_id
   and br.customer_phone = sub.phone;

-- ── 0b. Drop any stale UNIQUE(tour_id, phone) on passengers ─────────
-- Recon found none in-repo, but a live-only index/constraint could still exist
-- and would block the new plain insert. Remove it defensively.
do $$
declare
  r record;
begin
  -- table constraints (unique / pk) covering exactly (tour_id, phone)
  for r in
    select con.conname
      from pg_constraint con
      join pg_class      rel on rel.oid = con.conrelid
      join pg_namespace  nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'passengers'
       and con.contype in ('u', 'p')
       and (
         select array_agg(att.attname::text order by att.attname::text)
           from unnest(con.conkey) k
           join pg_attribute att
             on att.attrelid = con.conrelid and att.attnum = k
       ) = array['phone', 'tour_id']
  loop
    execute format('alter table public.passengers drop constraint %I', r.conname);
  end loop;

  -- standalone unique indexes covering exactly (tour_id, phone)
  for r in
    select ic.relname as idxname
      from pg_index      idx
      join pg_class      ic  on ic.oid  = idx.indexrelid
      join pg_class      tc  on tc.oid  = idx.indrelid
      join pg_namespace  nsp on nsp.oid = tc.relnamespace
     where nsp.nspname = 'public'
       and tc.relname  = 'passengers'
       and idx.indisunique
       and not idx.indisprimary
       and (
         select array_agg(att.attname::text order by att.attname::text)
           from unnest(idx.indkey) k
           join pg_attribute att
             on att.attrelid = idx.indrelid and att.attnum = k
       ) = array['phone', 'tour_id']
  loop
    execute format('drop index if exists public.%I', r.idxname);
  end loop;
end $$;


-- ── 1. Customer CREATE — plain insert, return the new request id ────
-- Copied from 026 (the lock-gate version, the latest definition) and changed:
--   • passengers insert is a PLAIN INSERT (no ON CONFLICT) — every submission
--     creates its own passenger row, so one phone can hold many on a tour.
--   • the new passenger's id is written onto the booking_requests row
--     (passenger_id) as the stable edit handle.
--   • returns the request id so the client can track this exact request.
-- The lock-gate checks (is_public + status not locked/completed) are preserved.
-- The 014 version returned void; changing the return type to uuid needs a DROP
-- first (CREATE OR REPLACE cannot change a function's return type).
drop function if exists public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text);
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
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_public       boolean;
  v_status       text;
  v_passenger_id uuid;
begin
  -- Only allow booking on a tour that's open to the public AND still open for
  -- new requests (not yet locked/completed).
  select is_public, status into v_public, v_status
    from public.tours where id = p_tour_id;
  if v_public is distinct from true then
    raise exception 'This tour is not open for booking.'
      using errcode = 'check_violation';
  end if;
  if v_status in ('locked', 'completed') then
    raise exception 'Bookings are closed for this tour.'
      using errcode = 'check_violation';
  end if;

  -- Live admin-facing passenger row. PLAIN INSERT — a phone may now hold
  -- multiple distinct requests on one tour, each its own passenger row, so we
  -- never collapse onto an existing (tour_id, phone) row.
  insert into public.passengers
    (tour_id, name, phone, request_lines, trip_type, note)
  values
    (p_tour_id, p_name, p_phone, p_request_lines, p_trip_type, p_note)
  returning id into v_passenger_id;

  -- Audit row in the admin's request inbox, linked to the passenger it created
  -- so the edit RPC can resolve the exact row later.
  insert into public.booking_requests
    (id, tour_id, customer_phone, customer_name, party_size, trip_type, raw_form, passenger_id)
  values
    (p_request_id, p_tour_id, p_phone, p_name, p_party_size, p_trip_type, p_raw_form, v_passenger_id);

  return p_request_id;
end;
$$;

revoke all on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text)
  from public;
grant execute on function
  public.submit_booking_request(uuid, uuid, text, text, int, text, jsonb, jsonb, text)
  to anon, authenticated;


-- ── 2. Customer EDIT — resolve the EXACT passenger by p_id ──────────
-- Copied from 014 and changed so the UPDATE targets ONLY the one passenger row
-- tied to this booking_requests id. Resolution key: booking_requests.passenger_id
-- (the stable link added above). For legacy rows whose passenger_id never got
-- backfilled, fall back to the newest (tour_id, phone) match so old tickets
-- remain editable.
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
  v_passenger_id   uuid;
  v_seats_taken    boolean;
begin
  -- Resolve the request and its linked passenger. The passenger_id is the
  -- unambiguous key; tour_id/phone are only used for the legacy fallback below.
  select br.tour_id, br.customer_phone, br.passenger_id
    into v_tour_id, v_customer_phone, v_passenger_id
    from public.booking_requests br
   where br.id = p_id and br.status = 'pending';
  if not found then
    return false;
  end if;

  -- Legacy fallback: a pre-030 request with no link → newest passenger for the
  -- (tour, phone). Lazily backfill the link so future edits hit the fast path.
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

  -- Refuse the edit once the admin has assigned seats to THIS passenger.
  if v_passenger_id is not null then
    select exists(
      select 1 from public.passengers p
       where p.id = v_passenger_id
         and jsonb_array_length(coalesce(p.assigned_seats, '[]'::jsonb)) > 0
    ) into v_seats_taken;
    if v_seats_taken then
      return false;
    end if;
  end if;

  update public.booking_requests
     set party_size         = p_party_size,
         customer_name      = p_customer_name,
         raw_form           = p_raw_form,
         trip_type          = p_trip_type,
         customer_edited_at = now()
   where id = p_id;

  -- Update ONLY the one passenger tied to this request.
  if v_passenger_id is not null then
    update public.passengers
       set name          = p_customer_name,
           request_lines = p_request_lines,
           trip_type     = p_trip_type
     where id = v_passenger_id;
  end if;

  return true;
end;
$$;

revoke all on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text) from public;
grant execute on function
  public.booking_request_customer_update(uuid, int, text, jsonb, jsonb, text)
  to anon, authenticated;
