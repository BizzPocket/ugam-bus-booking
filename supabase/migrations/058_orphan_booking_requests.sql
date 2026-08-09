-- ============================================================
-- 058 — Orphan booking requests: repair the existing ones, then
--       make new ones impossible.
--
-- SYMPTOM (reported 2026-08-02): a customer taps "Send request", the organiser's
-- phone buzzes with "New booking request — <name> requested 1 seat", and the
-- request is nowhere in the admin app. The customer meanwhile sees "Could not
-- save your request — try again", taps again, and the organiser gets a second
-- and third identical notification for requests that also do not exist.
--
-- ROOT CAUSE: the client's legacy non-RPC fallback (removed in the same change
-- as this migration) did two loose writes instead of one transaction —
-- `booking_requests` first, `passengers` second. Anon RLS treats those two
-- tables in OPPOSITE ways, verified against this database:
--
--   insert into booking_requests -> 23503 foreign_key_violation   (RLS PASSED)
--   insert into passengers       -> 42501 row-level security      (RLS REFUSED)
--
-- So the fallback could NEVER complete for an anonymous customer. It always
-- landed the booking_requests row — whose AFTER INSERT trigger
-- (`booking_requests_notify_push`, 018/019) immediately pushed the organiser —
-- and then threw on the passenger. The admin app reads the roster from
-- `passengers` and never from `booking_requests`, so the notification pointed at
-- a row no screen in the app can display. The push is not lying about the
-- write: the booking_requests row really is there. It is just half a request.
--
-- The fallback ran because PostgREST answered PGRST202 ("not found in the schema
-- cache"). That is not only "migration 014 was never applied" — PostgREST also
-- answers PGRST202 for a few seconds after ANY DDL while it rebuilds its cache,
-- which is exactly the window the 053-057 batch opened.
--
-- THIS FILE DOES TWO THINGS:
--   1. REPAIRS every orphan already in the table, so the organiser gets the
--      customers back instead of losing them. Each orphan is either linked to
--      the passenger it should have had, or given a freshly reconstructed one
--      built from its own raw_form.
--   2. REVOKES anon INSERT on booking_requests. Nothing legitimate writes there
--      directly: every customer-facing path goes through the SECURITY DEFINER
--      `submit_booking_request`, which is unaffected by this revoke because a
--      definer function runs as its owner. After this, a client that somehow
--      tries the two-write shape gets refused on the FIRST write and no push
--      fires — the failure becomes honest and silent instead of loud and empty.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (do NOT `supabase db push` —
-- the numbered migration history is out of sync with live). Idempotent: the
-- repair only ever touches rows that are still orphaned, so pressing twice is a
-- no-op the second time.
-- ============================================================

-- ── 1. Repair, one orphan GROUP at a time ────────────────────
-- The unit of repair is a GROUP, not a row, because the fallback's failure mode
-- produced retries: the customer was told the save failed, so they tapped again,
-- and each tap minted another orphan for the SAME booking. Rebuilding one rider
-- per orphan ROW would put that customer on the bus three times.
--
-- The grouping key is exactly the client's own duplicate rule
-- (`_preflightCreate`): same tour + phone + name + seat counts = one booking,
-- however many times it was submitted. A different name or a different seat mix
-- is a genuinely different request and gets its own rider, which is what
-- migration 030 made legal in the first place.
--
-- A LOOP rather than one set-based UPDATE...FROM: with three identical orphans,
-- a join has three equally-valid source rows per target and Postgres may pair
-- them arbitrarily, leaving created passengers unlinked and rows sharing a
-- rider. Iterating makes the pairing exact and obvious.
do $$
declare
  g            record;
  v_passenger  uuid;
  v_lines      jsonb;
  v_repaired   int := 0;
  v_adopted    int := 0;
begin
  for g in
    select br.tour_id,
           br.customer_phone,
           br.customer_name,
           -- One leg/pickup/note per group: retries carry identical payloads,
           -- and min() is deterministic where an edit made them differ.
           min(br.trip_type)                                as trip_type,
           min(br.pickup_location_id::text)::uuid           as pickup_location_id,
           min(br.pickup_location_name)                     as pickup_location_name,
           min(nullif(trim(coalesce(br.raw_form->>'note', '')), '')) as note,
           greatest(coalesce(max((br.raw_form->>'double_sofa')::int), 0), 0) as dbl,
           greatest(coalesce(max((br.raw_form->>'single_sofa')::int), 0), 0) as sgl,
           array_agg(br.id)                                 as request_ids
      from public.booking_requests br
     where br.passenger_id is null
       and br.status = 'pending'
     group by br.tour_id,
              br.customer_phone,
              br.customer_name,
              br.raw_form->>'double_sofa',
              br.raw_form->>'single_sofa'
  loop
    -- 1a. Adopt an existing rider before inventing one. Only a passenger that
    -- no other booking_requests row already claims is eligible — otherwise this
    -- would steal the rider belonging to a different, healthy request.
    select p.id into v_passenger
      from public.passengers p
     where p.tour_id    = g.tour_id
       and p.phone      = g.customer_phone
       and p.deleted_at is null
       and not exists (
             select 1 from public.booking_requests b2
              where b2.passenger_id = p.id
           )
     order by p.created_at desc
     limit 1;

    if v_passenger is not null then
      v_adopted := v_adopted + 1;
    else
      -- 1b. Rebuild from the orphan's own raw_form — that IS the payload the
      -- customer submitted. request_lines is synthesized in the modern per-line
      -- shape (`seatType`/`position`/`qty`/`leg`, matching RequestLine.toMap) so
      -- the recovered rider prices, seats and counts toward capacity exactly
      -- like one booked today. `position` stays null: the form never captured a
      -- window/aisle preference and inventing one would seat a rider where they
      -- did not ask to sit. Each line inherits the request's own trip_type as
      -- its leg — a request-mode booking is one leg choice for the whole party.
      v_lines := '[]'::jsonb;
      if g.dbl > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'seatType', 'doubleSofa', 'position', null,
          'qty', g.dbl, 'leg', g.trip_type));
      end if;
      if g.sgl > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'seatType', 'singleSofa', 'position', null,
          'qty', g.sgl, 'leg', g.trip_type));
      end if;

      -- Both counts zero means there is no rider to rebuild, only a malformed
      -- row. Leave it for the audit at the end rather than creating a passenger
      -- who booked nothing and would sit on the roster demanding no seats.
      if v_lines = '[]'::jsonb then
        continue;
      end if;

      insert into public.passengers
        (tour_id, name, phone, request_lines, trip_type, note,
         pickup_location_id, pickup_location_name)
      values
        (g.tour_id, g.customer_name, g.customer_phone, v_lines, g.trip_type,
         g.note, g.pickup_location_id, g.pickup_location_name)
      returning id into v_passenger;

      v_repaired := v_repaired + 1;
    end if;

    -- Every orphan in the group points at the one rider.
    update public.booking_requests
       set passenger_id = v_passenger
     where id = any(g.request_ids);
  end loop;

  raise notice
    '058: % orphan group(s) rebuilt, % adopted an existing passenger',
    v_repaired, v_adopted;
end;
$$;

-- ── 2. Close the door: anon may no longer write booking_requests ──
-- `submit_booking_request` is SECURITY DEFINER, so it keeps writing as its owner
-- and is NOT affected by this. This only stops a direct table insert from an
-- anonymous client — the exact write that produced every orphan above.
revoke insert on public.booking_requests from anon;

drop policy if exists "booking_requests_anon_insert" on public.booking_requests;

-- ── 3. Audit: what is still orphaned after the repair? ───────
-- Anything listed here had no usable seat counts to rebuild from and needs the
-- organiser to ask the customer what they wanted. Expected: zero rows.
select br.id,
       br.tour_id,
       br.customer_name,
       br.customer_phone,
       br.party_size,
       br.raw_form,
       br.created_at
  from public.booking_requests br
 where br.passenger_id is null
   and br.status = 'pending'
 order by br.created_at desc;
