-- ============================================================
-- 090  Handler trip milestones + handler → agent problem reports
-- ------------------------------------------------------------
-- Two additions behind the handler redesign:
--
--   1. handler_bus_trip_state — the four timestamps the handler stamps on
--      their own bus (left / arrived / heading back / finished). The client
--      derives the trip PHASE from these (resolveHandlerPhase), and the phase
--      is what decides which leg the boarding list shows, which milestone is
--      offered, and whether settlement is the next step. Nothing stores the
--      phase itself, so two devices reading the same bus always agree.
--
--      Note `go_arrived_at` is what ends the outbound leg, NOT
--      handler_complete_outbound_leg: a bus carrying only round-trip riders
--      has no outbound-only seats to release, so keying the phase off the
--      seat-release RPC would strand it "en route" for the rest of the trip.
--      Releasing seats stays a separate, best-effort consequence of arriving.
--
--   2. handler_reports — the back-channel the handler flow never had. A
--      handler could broadcast to their passengers and phone the driver, but
--      had no way to reach the AGENT, so a seat problem (which they are
--      deliberately not allowed to fix) had nowhere to go.
--
-- Authorization follows 046, not 042: every write checks handler_owns_bus, so
-- a handler can only ever stamp or report against a bus that is genuinely
-- theirs — not merely one on the same tour as them.
--
-- Idempotent: safe to re-run. Run THIS FILE ALONE in the SQL editor; never
-- `db push` (the history table is empty, so a push would replay everything).
-- ============================================================


-- ------------------------------------------------------------
-- 1. handler_bus_trip_state — one row per bus, created on first stamp.
-- ------------------------------------------------------------

create table if not exists public.handler_bus_trip_state (
  bus_id          uuid primary key references public.buses(id) on delete cascade,
  tour_id         uuid not null references public.tours(id) on delete cascade,
  go_departed_at  timestamptz,
  go_arrived_at   timestamptz,
  ret_departed_at timestamptz,
  completed_at    timestamptz,
  updated_at      timestamptz not null default now()
);

create index if not exists handler_bus_trip_state_tour_idx
  on public.handler_bus_trip_state(tour_id);

alter table public.handler_bus_trip_state enable row level security;

-- Owner-scoped read for the admin app. The handler path below is SECURITY
-- DEFINER and bypasses RLS by design (handlers are anonymous).
drop policy if exists "handler_trip_state_owner_select" on public.handler_bus_trip_state;
create policy "handler_trip_state_owner_select" on public.handler_bus_trip_state
  for select to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));


-- ------------------------------------------------------------
-- 2. handler_reports — problems raised from the bus.
-- ------------------------------------------------------------

create table if not exists public.handler_reports (
  id              uuid primary key default gen_random_uuid(),
  tour_id         uuid not null references public.tours(id) on delete cascade,
  bus_id          uuid not null references public.buses(id) on delete cascade,
  kind            text not null default 'other'
                    check (kind in ('breakdown','delay','passenger','seat','other')),
  message         text not null,
  reported_by     text,
  created_at      timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by uuid
);

create index if not exists handler_reports_tour_idx
  on public.handler_reports(tour_id, created_at desc);

-- Partial index for the agent's unread badge — the only hot read.
create index if not exists handler_reports_open_idx
  on public.handler_reports(tour_id)
  where acknowledged_at is null;

alter table public.handler_reports enable row level security;

drop policy if exists "handler_reports_owner_select" on public.handler_reports;
create policy "handler_reports_owner_select" on public.handler_reports
  for select to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));

-- The agent acknowledges; nothing else about the row is theirs to change.
drop policy if exists "handler_reports_owner_update" on public.handler_reports;
create policy "handler_reports_owner_update" on public.handler_reports
  for update to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id))
  with check (auth.uid() = (select owner_id from public.tours where id = tour_id));


-- ------------------------------------------------------------
-- 3. handler_bus_trip_state(p_request_id) — read every trip row for the
--    caller's OWN buses. Returns [] (never an error) for a non-handler, so a
--    backend where this migration has not run yet degrades to "no milestones"
--    rather than taking the handler's whole board down.
-- ------------------------------------------------------------

create or replace function public.handler_bus_trip_state(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'bus_id',          t.bus_id,
        'go_departed_at',  t.go_departed_at,
        'go_arrived_at',   t.go_arrived_at,
        'ret_departed_at', t.ret_departed_at,
        'completed_at',    t.completed_at
      )
    ),
    '[]'::jsonb
  )
    from public.handler_bus_trip_state t
   where public.is_request_handler(p_request_id)
     and public.handler_owns_bus(p_request_id, t.bus_id);
$$;

revoke all on function public.handler_bus_trip_state(uuid) from public;
grant execute on function public.handler_bus_trip_state(uuid) to anon, authenticated;


-- ------------------------------------------------------------
-- 4. handler_stamp_milestone — stamp one milestone and return the bus's whole
--    updated state.
--
--    now() is stamped SERVER-side: a handler's phone can be hours out, and
--    these timestamps order the trip.
--
--    Idempotent per milestone (`coalesce(existing, now())`), so a double tap
--    and a retry after a lost response both leave the first stamp standing —
--    which matters on exactly the 2G links this feature targets.
-- ------------------------------------------------------------

create or replace function public.handler_stamp_milestone(
  p_request_id uuid,
  p_bus_id     uuid,
  p_milestone  text
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_row     public.handler_bus_trip_state;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;
  if not public.handler_owns_bus(p_request_id, p_bus_id) then
    return null;
  end if;
  if p_milestone not in ('departGo', 'arriveGo', 'departRet', 'endTrip') then
    return null;
  end if;

  select b.tour_id into v_tour_id from public.buses b where b.id = p_bus_id;
  if v_tour_id is null then
    return null;
  end if;

  insert into public.handler_bus_trip_state (bus_id, tour_id)
  values (p_bus_id, v_tour_id)
  on conflict (bus_id) do nothing;

  update public.handler_bus_trip_state t
     set go_departed_at = case
           when p_milestone = 'departGo' then coalesce(t.go_departed_at, now())
           else t.go_departed_at end,
         go_arrived_at = case
           when p_milestone = 'arriveGo' then coalesce(t.go_arrived_at, now())
           else t.go_arrived_at end,
         ret_departed_at = case
           when p_milestone = 'departRet' then coalesce(t.ret_departed_at, now())
           else t.ret_departed_at end,
         completed_at = case
           when p_milestone = 'endTrip' then coalesce(t.completed_at, now())
           else t.completed_at end,
         updated_at = now()
   where t.bus_id = p_bus_id
  returning t.* into v_row;

  return jsonb_build_object(
    'bus_id',          v_row.bus_id,
    'go_departed_at',  v_row.go_departed_at,
    'go_arrived_at',   v_row.go_arrived_at,
    'ret_departed_at', v_row.ret_departed_at,
    'completed_at',    v_row.completed_at
  );
end;
$$;

revoke all on function public.handler_stamp_milestone(uuid, uuid, text) from public;
grant execute on function public.handler_stamp_milestone(uuid, uuid, text)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 5. handler_reports(p_request_id) — the caller's own reports, newest first,
--    so the Trip tab can show what was sent and whether it has been seen.
-- ------------------------------------------------------------

create or replace function public.handler_reports(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',              r.id,
        'tour_id',         r.tour_id,
        'bus_id',          r.bus_id,
        'kind',            r.kind,
        'message',         r.message,
        'reported_by',     r.reported_by,
        'created_at',      r.created_at,
        'acknowledged_at', r.acknowledged_at
      )
      order by r.created_at desc
    ),
    '[]'::jsonb
  )
    from public.handler_reports r
   where public.is_request_handler(p_request_id)
     and public.handler_owns_bus(p_request_id, r.bus_id);
$$;

revoke all on function public.handler_reports(uuid) from public;
grant execute on function public.handler_reports(uuid) to anon, authenticated;


-- ------------------------------------------------------------
-- 6. handler_create_report — raise a problem with the agent.
--
--    The client mints the id so a retry after a lost response updates the same
--    row rather than filing the breakdown twice. acknowledged_at is NEVER
--    written from here: only the agent clears a report, and accepting it from
--    the bus would let a retry silently un-acknowledge one already dealt with.
--
--    The message is capped at 500 characters. This is an anon-callable write
--    on a table the agent reads, so it needs a length bound of its own.
-- ------------------------------------------------------------

create or replace function public.handler_create_report(
  p_request_id uuid,
  p_report     jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_bus_id  uuid;
  v_tour_id uuid;
  v_id      uuid;
  v_kind    text;
  v_message text;
  v_row     public.handler_reports;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  v_bus_id := nullif(p_report->>'bus_id', '')::uuid;
  if v_bus_id is null or not public.handler_owns_bus(p_request_id, v_bus_id) then
    return null;
  end if;

  select b.tour_id into v_tour_id from public.buses b where b.id = v_bus_id;
  if v_tour_id is null then
    return null;
  end if;

  v_message := left(trim(coalesce(p_report->>'message', '')), 500);
  if v_message = '' then
    return null;
  end if;

  v_kind := coalesce(nullif(p_report->>'kind', ''), 'other');
  if v_kind not in ('breakdown','delay','passenger','seat','other') then
    v_kind := 'other';
  end if;

  v_id := coalesce(nullif(p_report->>'id', '')::uuid, gen_random_uuid());

  insert into public.handler_reports (
    id, tour_id, bus_id, kind, message, reported_by
  )
  values (
    v_id, v_tour_id, v_bus_id, v_kind, v_message,
    left(nullif(p_report->>'reported_by', ''), 80)
  )
  on conflict (id) do update
    set kind    = excluded.kind,
        message = excluded.message
  returning * into v_row;

  return jsonb_build_object(
    'id',              v_row.id,
    'tour_id',         v_row.tour_id,
    'bus_id',          v_row.bus_id,
    'kind',            v_row.kind,
    'message',         v_row.message,
    'reported_by',     v_row.reported_by,
    'created_at',      v_row.created_at,
    'acknowledged_at', v_row.acknowledged_at
  );
end;
$$;

revoke all on function public.handler_create_report(uuid, jsonb) from public;
grant execute on function public.handler_create_report(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 7. notify_handler_report — push the agent when a report lands.
--
--    Mirrors notify_booking_request (019): same shared secret out of the
--    vault, same fire-and-forget pg_net call, same swallow-and-warn so a push
--    outage can never fail the handler's write. A handler on a roadside
--    reporting a breakdown must get their row committed whether or not
--    Firebase is reachable.
--
--    Only URGENT kinds push. A delay note does not deserve to wake an agent at
--    2am; a breakdown or a seat dispute does.
-- ------------------------------------------------------------

create or replace function public.notify_handler_report()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_secret text;
  v_owner  uuid;
  v_title  text;
  v_bus    text;
  v_url text := 'https://rhyqjzulpvaeslbaymex.supabase.co/functions/v1/send-push';
begin
  if new.kind not in ('breakdown', 'seat') then
    return new;
  end if;

  select t.owner_id, t.title into v_owner, v_title
    from public.tours t
   where t.id = new.tour_id;
  if v_owner is null then
    return new;
  end if;

  select coalesce(b.name, '') into v_bus
    from public.buses b
   where b.id = new.bus_id;

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
      body    := jsonb_build_object(
                   'type',      'handler_report',
                   'owner_id',  v_owner,
                   'tour_id',   new.tour_id,
                   'title',     coalesce(nullif(v_title, ''), 'Tour') ||
                                ' — ' || new.kind,
                   'body',      left(new.message, 120),
                   'report_id', new.id)
    );
  exception when others then
    raise warning 'notify_handler_report push dispatch failed: %', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists handler_reports_notify_push on public.handler_reports;
create trigger handler_reports_notify_push
  after insert on public.handler_reports
  for each row execute function public.notify_handler_report();
