-- ============================================================
-- 093  A one-leg request starts on the WAITING LIST
-- ------------------------------------------------------------
-- A Go-only or Return-only rider is never charged at request time: they consume
-- ONE leg of a berth, the organiser pairs them with a rider going the other
-- way, and only then are they quoted and confirmed. For that workflow to have
-- anything to work with, such a request has to LAND in the waitlist bucket —
-- and today it lands in "New" alongside the paid full-trip requests.
--
-- *** WHY A TRIGGER AND NOT A NEW submit_booking_request BODY ***
-- The obvious fix is to compute the flag inside the RPC. It is also the
-- dangerous one: this repo's migration history is not authoritative (the remote
-- history table is empty and files are applied by hand), so the LIVE body of
-- submit_booking_request has drifted from every file that claims to define it —
-- 032, 045 and 058 all issue a `create or replace` of the same function. Re-
-- issuing any of them would silently revert whatever landed last. 075 hit this
-- exact wall and chose a targeted patch for the same reason.
--
-- A trigger is purely ADDITIVE. It cannot revert drift, it does not care which
-- version of the RPC is live, and it keeps working if the RPC is replaced again.
--
-- *** WHY IT IS SCOPED TO ANONYMOUS INSERTS ***
-- `auth.uid() is null` means an anonymous CUSTOMER submitted this. An
-- authenticated organiser adding a rider by hand — most importantly through the
-- add-return-ticket sheet, which exists precisely to create Return-only
-- passengers the agent has ALREADY decided to take — must not have their
-- decision overridden. SECURITY DEFINER changes the privilege the RPC runs
-- with, not the JWT claims auth.uid() reads, so this stays true inside
-- submit_booking_request.
--
-- Idempotent. Changes no existing rows — only the flag on rows inserted after
-- it is applied.
--
-- Run THIS FILE ALONE in the Supabase SQL editor.
-- ============================================================

-- ── Every line is a single leg? ──────────────────────────────
-- True only when there is at least one line AND none of them is a round trip.
-- An empty or malformed request_lines answers false, so a row we cannot read
-- keeps today's behaviour rather than being silently parked on the waitlist.
create or replace function public.request_lines_are_one_leg(p_lines jsonb)
returns boolean
language sql immutable set search_path = public
as $$
  select coalesce(
    jsonb_typeof(p_lines) = 'array'
    and jsonb_array_length(p_lines) > 0
    and not exists (
      select 1
        from jsonb_array_elements(p_lines) as l
       where coalesce(l->>'leg', 'roundTrip') not in ('outboundOnly', 'returnOnly')
    ),
    false
  );
$$;

revoke all on function public.request_lines_are_one_leg(jsonb) from public;
grant execute on function public.request_lines_are_one_leg(jsonb)
  to anon, authenticated;

-- ── The trigger ──────────────────────────────────────────────
create or replace function public.passenger_one_leg_waitlist()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Organiser-entered riders keep whatever the organiser chose.
  if auth.uid() is not null then
    return new;
  end if;
  -- Never override an explicit true that arrived on the insert.
  if coalesce(new.is_waitlisted, false) then
    return new;
  end if;
  if public.request_lines_are_one_leg(new.request_lines) then
    new.is_waitlisted := true;
  end if;
  return new;
end $$;

drop trigger if exists passengers_one_leg_waitlist on public.passengers;
create trigger passengers_one_leg_waitlist
  before insert on public.passengers
  for each row execute function public.passenger_one_leg_waitlist();

-- ============================================================
-- VERIFY
--   select public.request_lines_are_one_leg(
--     '[{"seatType":"singleSofa","qty":1,"leg":"outboundOnly"}]'::jsonb);  -- t
--   select public.request_lines_are_one_leg(
--     '[{"seatType":"singleSofa","qty":1,"leg":"roundTrip"}]'::jsonb);     -- f
--   select public.request_lines_are_one_leg(
--     '[{"seatType":"singleSofa","qty":1,"leg":"outboundOnly"},
--       {"seatType":"seater","qty":1,"leg":"roundTrip"}]'::jsonb);         -- f
--   -- then submit a Go-only request from the app and confirm it lands in
--   -- the Waitlist bucket rather than New:
--   select name, is_waitlisted, request_lines
--     from public.passengers order by created_at desc limit 1;
-- ============================================================
