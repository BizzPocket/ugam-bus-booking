-- ============================================================
-- 047  Live bus location — handler device → admin map
-- ------------------------------------------------------------
-- Built against the LIVE schema (dumped 2026-07-31), not the migration files.
-- `supabase migration list --linked` shows the REMOTE history column EMPTY, so
-- `supabase db push` would replay 001..046 over a live database. Run THIS FILE
-- ALONE in the Supabase SQL editor. Idempotent — safe to re-run.
--
-- WHAT EXISTS LIVE THAT THIS BUILDS ON
--   buses.handler_passenger_id  -> passengers.id   (FK buses_handler_passenger_fk)
--   handler_ctx(uuid)           -> (tour_id, customer_phone)   SECURITY DEFINER,
--                                  granted to service_role ONLY (see 043)
--   is_request_handler(uuid)    -> boolean
--   handler_owns_bus(uuid,uuid) -> boolean, THE bus-ownership predicate:
--                                  ctx -> handler passenger -> bus whose
--                                  handler_passenger_id is that passenger.
--
-- Handlers are ANONYMOUS. They never touch these tables directly — every write
-- goes through the SECURITY DEFINER RPC below, which bypasses RLS after
-- checking ownership. So the tables carry OWNER-ONLY RLS and NO anon policy at
-- all, matching collections / expenses / bus_handovers.
--
-- TRACKING WINDOW: tours.status = 'locked' only.
--   planning → collecting → busBooked → assigning → locked → completed
-- Pre-lock the trip is not running and, per the 039 handler gate, a handler is
-- entitled to nothing. Post-'completed' the trip is over. Enforced SERVER-side
-- in the RPC, so a stale or tampered client cannot widen its own window.
-- ============================================================


-- ------------------------------------------------------------
-- 1. bus_live_positions — ONE row per bus, overwritten in place.
--
-- Why this exists separately from the trail: the admin map needs "where is
-- every bus right now" as a single cheap indexed read, and Realtime on an
-- append-only trail would push one event per bus per fix at the admin. A
-- 1-row-per-bus table yields clean UPDATE events and a bounded working set.
--
-- PK is bus_id (not a synthetic uuid) because the row IS the bus's current
-- position — one per bus, enforced structurally rather than by a unique index.
-- ------------------------------------------------------------
create table if not exists public.bus_live_positions (
  bus_id          uuid primary key
                    references public.buses(id) on delete cascade,
  tour_id         uuid not null
                    references public.tours(id) on delete cascade,
  lat             double precision not null,
  lng             double precision not null,
  accuracy_m      real,
  speed_kmh       real,
  heading_deg     real,
  leg             text,
  tracking_state  text not null default 'live',
  recorded_at     timestamp with time zone not null,
  received_at     timestamp with time zone default now() not null,
  updated_at      timestamp with time zone default now() not null,
  constraint bus_live_positions_lat_chk
    check (lat between -90 and 90),
  constraint bus_live_positions_lng_chk
    check (lng between -180 and 180),
  constraint bus_live_positions_leg_chk
    check (leg is null or leg = any (array['go'::text, 'ret'::text])),
  constraint bus_live_positions_state_chk
    check (tracking_state = any (array['live'::text, 'paused'::text, 'ended'::text]))
);

-- `leg` uses 'go' / 'ret' to match attendance.leg (attendance_leg_check).
-- NOTE a live divergence: tour_seat_snapshots.leg uses 'outbound' / 'return'
-- for the same concept. Location is an operational handler-side record like
-- attendance, so it follows attendance. Do not "harmonise" one without the
-- other — both are live and both have data.


-- ------------------------------------------------------------
-- 2. bus_location_fixes — append-only trail.
--
-- PK is a bigint identity, deliberately breaking the uuid-PK convention every
-- other table here follows. Nothing references a fix by id, and this is the
-- only time-series table in the schema: ~1000 rows per bus per travel day
-- arriving in ordered batches. A monotonic key keeps those batch inserts
-- appending to the right edge of the index instead of scattering random v4
-- uuids across it.
--
-- The (bus_id, recorded_at) unique index is what makes an offline flush
-- IDEMPOTENT: a handler driving through a dead zone buffers fixes locally and
-- retries the same batch until it lands, so a retry that partially succeeded
-- must not double-insert. See the `on conflict do nothing` in the RPC.
-- ------------------------------------------------------------
create table if not exists public.bus_location_fixes (
  id           bigint generated always as identity primary key,
  tour_id      uuid not null references public.tours(id) on delete cascade,
  bus_id       uuid not null references public.buses(id) on delete cascade,
  lat          double precision not null,
  lng          double precision not null,
  accuracy_m   real,
  speed_kmh    real,
  heading_deg  real,
  leg          text,
  recorded_at  timestamp with time zone not null,
  received_at  timestamp with time zone default now() not null,
  constraint bus_location_fixes_lat_chk
    check (lat between -90 and 90),
  constraint bus_location_fixes_lng_chk
    check (lng between -180 and 180),
  constraint bus_location_fixes_leg_chk
    check (leg is null or leg = any (array['go'::text, 'ret'::text]))
);


-- ------------------------------------------------------------
-- 3. Indexes — {table}_{cols}_idx / _unique, per live convention.
-- ------------------------------------------------------------
create unique index if not exists bus_location_fixes_bus_recorded_unique
  on public.bus_location_fixes using btree (bus_id, recorded_at);

create index if not exists bus_location_fixes_tour_idx
  on public.bus_location_fixes using btree (tour_id);

-- Trail playback for one bus, newest first.
create index if not exists bus_location_fixes_bus_recorded_idx
  on public.bus_location_fixes using btree (bus_id, recorded_at desc);

create index if not exists bus_live_positions_tour_idx
  on public.bus_live_positions using btree (tour_id);


-- ------------------------------------------------------------
-- 4. updated_at trigger — reuses the live public.set_updated_at().
-- ------------------------------------------------------------
create or replace trigger bus_live_positions_set_updated_at
  before update on public.bus_live_positions
  for each row execute function public.set_updated_at();


-- ------------------------------------------------------------
-- 5. RLS — owner-only, no anon policy.
--
-- Identical shape to collections_owner_all / expenses_owner_all: reach the
-- tour and compare its owner_id to auth.uid(). The handler write path does NOT
-- need a policy here; the RPC is SECURITY DEFINER and runs as the owner.
-- ------------------------------------------------------------
alter table public.bus_live_positions enable row level security;
alter table public.bus_location_fixes enable row level security;

drop policy if exists bus_live_positions_owner_all on public.bus_live_positions;
create policy bus_live_positions_owner_all
  on public.bus_live_positions
  to authenticated
  using (exists (
    select 1 from public.tours t
     where t.id = bus_live_positions.tour_id
       and t.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.tours t
     where t.id = bus_live_positions.tour_id
       and t.owner_id = auth.uid()
  ));

drop policy if exists bus_location_fixes_owner_all on public.bus_location_fixes;
create policy bus_location_fixes_owner_all
  on public.bus_location_fixes
  to authenticated
  using (exists (
    select 1 from public.tours t
     where t.id = bus_location_fixes.tour_id
       and t.owner_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.tours t
     where t.id = bus_location_fixes.tour_id
       and t.owner_id = auth.uid()
  ));


-- ------------------------------------------------------------
-- 6. Grants. Matches the live pattern (GRANT ALL to all three roles); RLS,
--    not the grant, is what actually confines each role.
-- ------------------------------------------------------------
grant all on table public.bus_live_positions to anon, authenticated, service_role;
grant all on table public.bus_location_fixes to anon, authenticated, service_role;


-- ------------------------------------------------------------
-- 6b. Safe scalar casts — POISON-PILL GUARD.
--
-- A plain `(e->>'recorded_at')::timestamptz` RAISES on malformed input, which
-- aborts the whole RPC. That is the worst possible failure mode here: the
-- handler client buffers fixes locally through dead zones and retries the same
-- batch until it lands, so ONE corrupt entry would abort every retry forever
-- and silently freeze that bus on the admin's map. Found by dry-run test T8.
--
-- These trap instead, so a bad fix is dropped and its batch-mates still land.
-- Internal only — not part of the anon API surface.
-- ------------------------------------------------------------
create or replace function public.try_timestamptz(p text)
  returns timestamp with time zone
  language plpgsql immutable parallel safe
as $$
begin
  return p::timestamp with time zone;
exception when others then
  return null;
end;
$$;

create or replace function public.try_float(p text)
  returns double precision
  language plpgsql immutable parallel safe
as $$
begin
  return p::double precision;
exception when others then
  return null;
end;
$$;

alter function public.try_timestamptz(text) owner to postgres;
alter function public.try_float(text) owner to postgres;

revoke all on function public.try_timestamptz(text) from public, anon, authenticated;
revoke all on function public.try_float(text) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 7. handler_push_locations — THE write path.
--
-- Batched: p_fixes is an ARRAY, so a flush after a dead zone is one round-trip
-- rather than forty. Modelled on handler_upsert_handover — same guard order,
-- same SECURITY DEFINER + search_path, same "return null-ish on refusal rather
-- than raise" so the client degrades quietly instead of crashing mid-drive.
--
-- Returns {accepted, skipped, live_updated} so the client knows what to drop
-- from its local buffer.
-- ------------------------------------------------------------
create or replace function public.handler_push_locations(
  p_request_id uuid,
  p_bus_id     uuid,
  p_fixes      jsonb
) returns jsonb
  language plpgsql
  security definer
  set search_path to 'public'
as $$
declare
  v_tour_id  uuid;
  v_status   text;
  v_accepted int := 0;
  v_latest   record;
  v_state    text;
begin
  -- (a) Same two guards every handler write uses. handler_owns_bus is the one
  --     that matters: the 042-era RPCs authorised the TOUR, which let any
  --     handler write to a co-handler's bus. Authorise the BUS.
  if not public.is_request_handler(p_request_id)
     or not public.handler_owns_bus(p_request_id, p_bus_id) then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'forbidden');
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  -- (b) Tracking window, enforced server-side. A stale build or a tampered
  --     client cannot keep pushing after the trip is marked completed.
  select t.status into v_status
    from public.tours t
   where t.id = v_tour_id;

  if v_status is distinct from 'locked' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'window_closed');
  end if;

  if p_fixes is null or jsonb_typeof(p_fixes) <> 'array' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'bad_payload');
  end if;

  v_state := coalesce(nullif(p_fixes -> 0 ->> 'tracking_state', ''), 'live');
  if v_state <> all (array['live', 'paused', 'ended']) then
    v_state := 'live';
  end if;

  -- (c) Insert the trail. `on conflict do nothing` on (bus_id, recorded_at) is
  --     what makes a retried flush idempotent.
  --
  --     Rejected inline rather than trusted:
  --       * more than 500 fixes in one call (bulk-insert via a leaked uuid)
  --       * a device clock more than 5 min ahead of the server, or a fix older
  --         than 24h — phone clocks drift and reset, and a bad recorded_at
  --         would otherwise poison the unique key and the live-position sort.
  --       * out-of-range or null coordinates
  with incoming as (
    select
      public.try_float(e->>'lat')                      as lat,
      public.try_float(e->>'lng')                      as lng,
      public.try_float(e->>'accuracy_m')::real         as accuracy_m,
      public.try_float(e->>'speed_kmh')::real          as speed_kmh,
      public.try_float(e->>'heading_deg')::real        as heading_deg,
      nullif(e->>'leg', '')                            as leg,
      public.try_timestamptz(e->>'recorded_at')        as recorded_at
    from jsonb_array_elements(p_fixes) with ordinality as a(e, ord)
    where a.ord <= 500
  ),
  valid as (
    select * from incoming
     where lat is not null and lng is not null
       and lat between -90 and 90
       and lng between -180 and 180
       and recorded_at is not null
       and recorded_at <= now() + interval '5 minutes'
       and recorded_at >= now() - interval '24 hours'
       and (leg is null or leg in ('go', 'ret'))
  ),
  ins as (
    insert into public.bus_location_fixes (
      tour_id, bus_id, lat, lng, accuracy_m, speed_kmh, heading_deg, leg, recorded_at
    )
    select v_tour_id, p_bus_id, v.lat, v.lng, v.accuracy_m, v.speed_kmh,
           v.heading_deg, v.leg, v.recorded_at
      from valid v
    on conflict (bus_id, recorded_at) do nothing
    returning 1
  )
  select count(*) into v_accepted from ins;

  -- (d) Advance the live dot to the NEWEST fix this bus has on record.
  --
  --     Read back from the table rather than from the payload: an offline
  --     flush can arrive out of order, or after a newer real-time fix already
  --     landed, and the map must never rewind to a stale position.
  select f.lat, f.lng, f.accuracy_m, f.speed_kmh, f.heading_deg, f.leg, f.recorded_at
    into v_latest
    from public.bus_location_fixes f
   where f.bus_id = p_bus_id
   order by f.recorded_at desc
   limit 1;

  if v_latest.recorded_at is not null then
    insert into public.bus_live_positions as lp (
      bus_id, tour_id, lat, lng, accuracy_m, speed_kmh, heading_deg,
      leg, tracking_state, recorded_at, received_at
    )
    values (
      p_bus_id, v_tour_id, v_latest.lat, v_latest.lng, v_latest.accuracy_m,
      v_latest.speed_kmh, v_latest.heading_deg, v_latest.leg, v_state,
      v_latest.recorded_at, now()
    )
    on conflict (bus_id) do update
      set tour_id        = excluded.tour_id,
          lat            = excluded.lat,
          lng            = excluded.lng,
          accuracy_m     = excluded.accuracy_m,
          speed_kmh      = excluded.speed_kmh,
          heading_deg    = excluded.heading_deg,
          leg            = excluded.leg,
          tracking_state = excluded.tracking_state,
          recorded_at    = excluded.recorded_at,
          received_at    = excluded.received_at
      where excluded.recorded_at >= lp.recorded_at
         or excluded.tracking_state <> lp.tracking_state;
  end if;

  return jsonb_build_object(
    'accepted',     v_accepted,
    'skipped',      jsonb_array_length(p_fixes) - v_accepted,
    'live_updated', v_latest.recorded_at
  );
end;
$$;

alter function public.handler_push_locations(uuid, uuid, jsonb) owner to postgres;

revoke all on function public.handler_push_locations(uuid, uuid, jsonb) from public;
grant execute on function public.handler_push_locations(uuid, uuid, jsonb)
  to anon, authenticated, service_role;


-- ------------------------------------------------------------
-- 8. Realtime. The admin map subscribes to bus_live_positions only — the
--    trail is fetched on demand when a bus is tapped, never streamed.
--    Guarded because ALTER PUBLICATION ... ADD TABLE errors if already a member.
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'bus_live_positions'
  ) then
    alter publication supabase_realtime add table public.bus_live_positions;
  end if;
end $$;

-- Realtime sends only the primary key in `old` on UPDATE unless replica
-- identity is full. The admin only ever needs the NEW row, so the default is
-- correct here and deliberately left alone.


-- ============================================================
-- VERIFY (run after, in the same SQL editor session)
-- ============================================================
-- select tablename from pg_publication_tables
--  where pubname = 'supabase_realtime' and schemaname = 'public'
--  order by tablename;
--
-- select proname, pg_get_function_identity_arguments(oid) as args,
--        prosecdef as security_definer
--   from pg_proc where proname = 'handler_push_locations';
--
-- select polname, polroles::regrole[] from pg_policy
--  where polrelid in ('public.bus_live_positions'::regclass,
--                     'public.bus_location_fixes'::regclass);
--
-- -- Must return forbidden (random uuid is not a handler):
-- select public.handler_push_locations(
--   gen_random_uuid(), gen_random_uuid(), '[]'::jsonb);
