-- ============================================================
-- 039  Handler access opens only AFTER the tour is LOCKED
-- ------------------------------------------------------------
-- Until an organiser LOCKS a tour, a selected handler must NOT be able to run
-- attendance / money / bus-messaging or even open the handler bus chart — the
-- tour is still being assigned and nothing is final. Before this migration the
-- handler flow gated ONLY on `passengers.is_handler` (via is_request_handler)
-- and `handler_requests_by_phone`, with NO tour-status check, so a handler
-- could operate the whole chart the moment they were flagged, pre-lock.
--
-- This closes that gap at the two choke points, SERVER-SIDE (so a client can
-- never bypass it):
--
--   1. is_request_handler(request_id) — the single gate every handler RPC and
--      the bus-message Edge Function funnel through (handler_tour_manifest +
--      handler_upsert_attendance / collection / expense / income + the delete_*
--      variants + the bus-message send, which re-checks this function). It now
--      additionally requires the request's tour to be in status 'locked' or
--      'completed'. Pre-lock it returns false, so the manifest reads NULL and
--      every write dead-ends — exactly the pre-lock (plain customer) state.
--
--   2. handler_requests_by_phone(phone) — the phone -> handler-request bridge
--      that surfaces the "Manage as handler" entry on the Find-my-seat screen.
--      It now returns only tours already locked/completed, so that entry never
--      appears before lock (mirrors 027_seat_lookup_by_phone's lock gate).
--
-- 'completed' stays allowed alongside 'locked' so post-trip money reconciliation
-- keeps working, consistent with 025 / 026 / 027. NO client change is required:
-- both CTAs (Find-my-seat handler entry, My-requests "View full chart") derive
-- from these two RPCs and disappear on their own once the gate returns
-- empty / false.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (the numbered migration
-- history is out of sync with live). Idempotent — pure create-or-replace.
-- ============================================================

-- ── 1. The shared handler gate: role AND the tour is locked/completed ──
-- Adds a join to public.tours and a status filter to the 003-era definition;
-- everything else is identical so all callers keep their contract.
create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.booking_requests br
        join public.passengers p
          on p.tour_id = br.tour_id
         and p.phone   = br.customer_phone
        join public.tours t
          on t.id = br.tour_id
       where br.id = p_request_id
         and p.is_handler = true
         and t.status in ('locked', 'completed')
    ),
    false
  );
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;

-- ── 2. Phone -> handler-request bridge: only locked/completed tours ────
-- Identical to 028 except for the added `t.status in (...)` filter on the refs
-- CTE, so the Find-my-seat handler entry never appears before lock.
create or replace function public.handler_requests_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  refs as (
    select distinct on (t.id)
           br.id             as request_id,
           t.id              as tour_id,
           t.title           as tour_title,
           t.from_city       as from_city,
           t.to_city         as to_city,
           t.departure_date  as departure_date,
           t.status          as status
      from public.passengers p
      cross join norm
      join public.tours t
        on t.id = p.tour_id
      join public.booking_requests br
        on br.tour_id = p.tour_id
       and right(regexp_replace(br.customer_phone, '\D', '', 'g'), 10) = norm.last10
     where norm.last10 <> ''
       and p.is_handler = true
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status in ('locked', 'completed')
     order by t.id, br.created_at, br.id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'request_id',     refs.request_id,
        'tour_id',        refs.tour_id,
        'tour_title',     refs.tour_title,
        'from_city',      refs.from_city,
        'to_city',        refs.to_city,
        'departure_date', refs.departure_date,
        'status',         refs.status
      )
      order by refs.departure_date desc
    ),
    '[]'::jsonb
  )
    from refs;
$$;

revoke all on function public.handler_requests_by_phone(text) from public;
grant execute on function public.handler_requests_by_phone(text)
  to anon, authenticated;
