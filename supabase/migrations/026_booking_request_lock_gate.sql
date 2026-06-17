-- ============================================================
-- 026  Server-side booking lock gate
-- ------------------------------------------------------------
-- Bookings must close the moment the organiser LOCKS a tour (all seats
-- assigned + notifications sent — the allocation is final). The client now
-- gates every "book"/"add request" surface on Tour.acceptsBookings, but a
-- customer create is an anonymous SECURITY DEFINER RPC (submit_booking_request,
-- migration 014) that previously only checked is_public — so a locked tour
-- still accepted a fresh request server-side. This adds the missing status
-- guard, the true "no new request from anywhere" enforcement (defense in depth,
-- matching the seat-reveal gate in migration 025).
--
-- submit_booking_request IS defined in-repo (014), so create-or-replace is
-- safe here (unlike the live-only RPCs noted in 025).
--
-- Idempotent; safe to run in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

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
  v_status text;
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
