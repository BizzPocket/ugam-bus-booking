-- ============================================================
-- 046  Handler settlement (handover) + handler-side GO-leg completion
-- ------------------------------------------------------------
-- WRITTEN AGAINST THE LIVE SCHEMA, NOT THE MIGRATION FILES. The numbered
-- history in this folder has drifted from production (it was applied by hand,
-- in pieces, while bugs were fixed step by step), so every column and type
-- below was read back from the live PostgREST schema before being used:
--
--   bus_handovers : id, tour_id, bus_id, expected_amount, handed_over_amount,
--                   note, settled_at, created_at        <- NO `source` column
--   passengers    : ..., trip_type, journey_done, assigned_seats, cancelled_at
--   buses         : ..., handler_passenger_id
--
-- Two live facts drove real corrections to what the files assumed:
--
--   * 045_handler_handover.sql reads and writes `bus_handovers.source`, which
--     does NOT exist in production — running 045 as written would fail. This
--     file adds the column first, then defines the RPCs.
--   * 031_tour_seat_snapshots.sql declares `id uuid`, but the client writes a
--     COMPOSITE id ('<tourId>_outbound') through SyncService.smartInsert /
--     smartUpdate, which key on `id`. A uuid column can never accept that, so
--     the table is created here with `id text` — the shape the app actually
--     writes. Without this table the admin's completeOutboundLeg silently
--     destroys the GO chart (its snapshot is best-effort and swallows the
--     failure), which is the live data-loss bug this also closes.
--
-- Authorization: handlers are ANONYMOUS. Every RPC here checks BUS OWNERSHIP,
-- not merely "the bus is on my tour" — the weaker check used by the existing
-- 042 write RPCs, which lets any handler write to a co-handler's bus. The
-- shared helper `handler_owns_bus` below is the pattern those should adopt.
--
-- Idempotent: safe to re-run. Run THIS FILE ALONE in the SQL editor; never
-- `db push` (the history table is empty, so a push would replay everything).
-- ============================================================


-- ------------------------------------------------------------
-- 1. tour_seat_snapshots — frozen per-leg seat chart for past tours.
--    `id` is TEXT because the client uses the deterministic composite key
--    '<tourId>_<leg>' to make its upsert idempotent (tour_controller.dart).
-- ------------------------------------------------------------

create table if not exists public.tour_seat_snapshots (
  id            text primary key,
  tour_id       uuid not null references public.tours(id) on delete cascade,
  leg           text not null check (leg in ('outbound', 'return')),
  snapshot_data jsonb not null,
  captured_at   timestamptz not null default now(),
  unique (tour_id, leg)
);

create index if not exists tour_seat_snapshots_tour_idx
  on public.tour_seat_snapshots(tour_id);

alter table public.tour_seat_snapshots enable row level security;

-- Owner-scoped for the admin app (authenticated). The handler path below is
-- SECURITY DEFINER and therefore bypasses RLS by design.
drop policy if exists "tour_seat_snapshots_owner_select" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_select" on public.tour_seat_snapshots
  for select to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_insert" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_insert" on public.tour_seat_snapshots
  for insert to authenticated
  with check (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_update" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_update" on public.tour_seat_snapshots
  for update to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id))
  with check (auth.uid() = (select owner_id from public.tours where id = tour_id));

drop policy if exists "tour_seat_snapshots_owner_delete" on public.tour_seat_snapshots;
create policy "tour_seat_snapshots_owner_delete" on public.tour_seat_snapshots
  for delete to authenticated
  using (auth.uid() = (select owner_id from public.tours where id = tour_id));


-- ------------------------------------------------------------
-- 2. bus_handovers.source — who recorded the row. Without it a handler could
--    delete a handover the ADMIN recorded. Existing rows are admin-recorded.
-- ------------------------------------------------------------

alter table public.bus_handovers
  add column if not exists source text not null default 'admin';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'bus_handovers_source_chk'
  ) then
    alter table public.bus_handovers
      add constraint bus_handovers_source_chk check (source in ('admin', 'handler'));
  end if;
end $$;


-- ------------------------------------------------------------
-- 3. handler_owns_bus — THE ownership predicate. True only when p_bus_id is on
--    the ref's tour AND its handler_passenger_id is the caller's own handler
--    passenger row. This is what 042's write RPCs are missing.
--
--    Not granted to anon/authenticated: only called from the SECURITY DEFINER
--    functions below, which execute as the owner.
-- ------------------------------------------------------------

create or replace function public.handler_owns_bus(p_request_id uuid, p_bus_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
      from public.handler_ctx(p_request_id) ctx
      join public.passengers p
        on p.tour_id = ctx.tour_id
       and p.phone   = ctx.customer_phone
       and p.is_handler = true
      join public.buses b
        on b.id = p_bus_id
       and b.tour_id = ctx.tour_id
       and b.handler_passenger_id = p.id
  );
$$;

revoke all on function public.handler_owns_bus(uuid, uuid) from public;


-- ------------------------------------------------------------
-- 4. handler_bus_handovers — every handover row for the caller's OWN bus.
--    Returns [] (never an error) for a non-handler, so the UI degrades quietly.
-- ------------------------------------------------------------

create or replace function public.handler_bus_handovers(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',                 h.id,
        'tour_id',            h.tour_id,
        'bus_id',             h.bus_id,
        'expected_amount',    h.expected_amount,
        'handed_over_amount', h.handed_over_amount,
        'note',               h.note,
        'source',             h.source,
        'settled_at',         h.settled_at,
        'created_at',         h.created_at
      )
      order by h.settled_at desc
    ),
    '[]'::jsonb
  )
    from public.bus_handovers h
   where public.is_request_handler(p_request_id)
     and public.handler_owns_bus(p_request_id, h.bus_id);
$$;

revoke all on function public.handler_bus_handovers(uuid) from public;
grant execute on function public.handler_bus_handovers(uuid) to anon, authenticated;


-- ------------------------------------------------------------
-- 5. handler_upsert_handover — record/correct one cash handover the handler
--    made to the admin. Stamps source='handler'. An ADMIN-recorded row can
--    never be overwritten through this path.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_handover(
  p_request_id uuid,
  p_handover   jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_bus_id  uuid;
  v_id      uuid;
  v_row     public.bus_handovers;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  v_bus_id := nullif(p_handover->>'bus_id', '')::uuid;
  if v_bus_id is null or not public.handler_owns_bus(p_request_id, v_bus_id) then
    return null;
  end if;

  v_id := coalesce(nullif(p_handover->>'id', '')::uuid, gen_random_uuid());

  -- Never let the handler edit a row the admin recorded.
  if exists (
    select 1 from public.bus_handovers h
     where h.id = v_id and h.source <> 'handler'
  ) then
    return null;
  end if;

  insert into public.bus_handovers as h (
    id, tour_id, bus_id, expected_amount, handed_over_amount, note,
    source, settled_at
  )
  values (
    v_id,
    v_tour_id,
    v_bus_id,
    coalesce((p_handover->>'expected_amount')::numeric, 0),
    coalesce((p_handover->>'handed_over_amount')::numeric, 0),
    nullif(p_handover->>'note', ''),
    'handler',
    coalesce(nullif(p_handover->>'settled_at', '')::timestamptz, now())
  )
  on conflict (id) do update
    set expected_amount    = excluded.expected_amount,
        handed_over_amount = excluded.handed_over_amount,
        note               = excluded.note,
        settled_at         = excluded.settled_at
    where h.source = 'handler'
  returning * into v_row;

  if v_row.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'id',                 v_row.id,
    'tour_id',            v_row.tour_id,
    'bus_id',             v_row.bus_id,
    'expected_amount',    v_row.expected_amount,
    'handed_over_amount', v_row.handed_over_amount,
    'note',               v_row.note,
    'source',             v_row.source,
    'settled_at',         v_row.settled_at,
    'created_at',         v_row.created_at
  );
end;
$$;

revoke all on function public.handler_upsert_handover(uuid, jsonb) from public;
grant execute on function public.handler_upsert_handover(uuid, jsonb) to anon, authenticated;


-- ------------------------------------------------------------
-- 6. handler_delete_handover — remove a handover the HANDLER logged, on a bus
--    they own. Admin rows stay read-only. Returns true when a row was removed.
--
--    Note the contrast with 042's handler_delete_expense / _income, which are
--    scoped to the TOUR with no bus predicate at all — any handler can delete
--    any expense on the tour there, including the admin's. This is the shape
--    those two should be rewritten to.
-- ------------------------------------------------------------

create or replace function public.handler_delete_handover(
  p_request_id  uuid,
  p_handover_id uuid
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_deleted int;
begin
  if not public.is_request_handler(p_request_id) then
    return false;
  end if;

  delete from public.bus_handovers h
   where h.id = p_handover_id
     and h.source = 'handler'
     and public.handler_owns_bus(p_request_id, h.bus_id);

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_handover(uuid, uuid) from public;
grant execute on function public.handler_delete_handover(uuid, uuid) to anon, authenticated;


-- ------------------------------------------------------------
-- 7. handler_bus_leg_state — how far the caller's own bus has got through the
--    journey. The handler manifest does NOT return journey_done (its live body
--    has drifted from the files, so it is deliberately left untouched here);
--    this small sibling RPC supplies just that state, the same way handovers
--    get their own reader.
--
--    A seat counts toward the OUTBOUND leg when its per-seat leg says so;
--    `leg` is NULL on legacy rows, so it falls back to the passenger's coarse
--    trip_type — per-seat leg is canonical, trip_type is the legacy fallback.
-- ------------------------------------------------------------

create or replace function public.handler_bus_leg_state(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with ctx as (
    select ctx.tour_id, ctx.customer_phone
      from public.handler_ctx(p_request_id) ctx
     where public.is_request_handler(p_request_id)
  ),
  my_bus as (
    select b.id as bus_id, b.tour_id
      from ctx
      join public.passengers hp
        on hp.tour_id = ctx.tour_id
       and hp.phone   = ctx.customer_phone
       and hp.is_handler = true
      join public.buses b
        on b.tour_id = ctx.tour_id
       and b.handler_passenger_id = hp.id
  ),
  seats as (
    select mb.bus_id,
           p.id           as passenger_id,
           p.journey_done as journey_done,
           coalesce(nullif(e->>'leg', ''), p.trip_type) as seat_leg,
           p.trip_type
      from my_bus mb
      join public.passengers p
        on p.tour_id = mb.tour_id
       and p.cancelled_at is null
      cross join lateral jsonb_array_elements(p.assigned_seats) e
     where e->>'busId' = mb.bus_id::text
  )
  select coalesce(
    jsonb_agg(x order by x->>'bus_id'),
    '[]'::jsonb
  )
    from (
      select jsonb_build_object(
               'bus_id', mb.bus_id,
               'outbound_only_total', (
                 select count(distinct s.passenger_id) from seats s
                  where s.bus_id = mb.bus_id and s.trip_type = 'outboundOnly'
               ),
               'outbound_only_done', (
                 select count(distinct s.passenger_id) from seats s
                  where s.bus_id = mb.bus_id
                    and s.trip_type = 'outboundOnly'
                    and s.journey_done
               ),
               'riders_on_outbound', (
                 select count(distinct s.passenger_id) from seats s
                  where s.bus_id = mb.bus_id
                    and s.seat_leg in ('roundTrip', 'outboundOnly')
               ),
               'riders_on_return', (
                 select count(distinct s.passenger_id) from seats s
                  where s.bus_id = mb.bus_id
                    and s.seat_leg in ('roundTrip', 'returnOnly')
               )
             ) as x
        from my_bus mb
    ) t;
$$;

revoke all on function public.handler_bus_leg_state(uuid) from public;
grant execute on function public.handler_bus_leg_state(uuid) to anon, authenticated;


-- ------------------------------------------------------------
-- 8. handler_complete_outbound_leg — the handler finishes the GO leg for THEIR
--    OWN bus: every outbound-only rider on that bus has completed their only
--    journey, so their seats on this bus are released and they are marked
--    journey_done. Round-trip and return-only riders are untouched.
--
--    Before releasing anything it FREEZES this bus's outbound chart into
--    tour_seat_snapshots, MERGING into the tour's existing outbound snapshot
--    rather than overwriting it — four handlers finish four buses at different
--    times, and a plain overwrite would erase the buses already completed.
--    Unlike the client's best-effort capture, a snapshot failure here aborts
--    the whole thing (it is one transaction), so seats are never released
--    without their history being kept first.
--
--    Returns the number of riders cleared, or null when unauthorized.
-- ------------------------------------------------------------

create or replace function public.handler_complete_outbound_leg(
  p_request_id uuid,
  p_bus_id     uuid
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id  uuid;
  v_bus_json jsonb;
  v_existing jsonb;
  v_merged   jsonb;
  v_cleared  int;
begin
  if not public.is_request_handler(p_request_id)
     or not public.handler_owns_bus(p_request_id, p_bus_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  -- (a0) Nothing left to release? Return WITHOUT touching the snapshot.
  --
  -- This guard is what makes a second press safe. Re-running after the leg is
  -- already closed would otherwise re-capture the chart in its POST-wipe state
  -- and overwrite the good pre-wipe snapshot — silently erasing exactly the
  -- one-way riders the freeze exists to preserve. A double tap, or a retry
  -- after a write that actually landed, is enough to trigger it.
  if not exists (
    select 1
      from public.passengers p
      cross join lateral jsonb_array_elements(p.assigned_seats) e
     where p.tour_id = v_tour_id
       and p.trip_type = 'outboundOnly'
       and p.journey_done = false
       and e->>'busId' = p_bus_id::text
  ) then
    return 0;
  end if;

  -- (a) Freeze this bus's OUTBOUND chart as it stands right now.
  select jsonb_build_object(
           'busId', p_bus_id::text,
           'seats', coalesce(
             jsonb_agg(
               jsonb_build_object(
                 'seatId', s.seat_id,
                 'name',   s.name,
                 'phone',  s.phone
               ) order by s.seat_id
             ),
             '[]'::jsonb
           )
         )
    into v_bus_json
    from (
      select distinct
             e->>'seatId' as seat_id,
             p.name       as name,
             p.phone      as phone
        from public.passengers p
        cross join lateral jsonb_array_elements(p.assigned_seats) e
       where p.tour_id = v_tour_id
         and p.cancelled_at is null
         and e->>'busId' = p_bus_id::text
         and coalesce(nullif(e->>'leg', ''), p.trip_type)
               in ('roundTrip', 'outboundOnly')
    ) s;

  -- (b) Merge into the tour's outbound snapshot, replacing only this bus.
  select coalesce(ts.snapshot_data->'buses', '[]'::jsonb)
    into v_existing
    from public.tour_seat_snapshots ts
   where ts.tour_id = v_tour_id and ts.leg = 'outbound';

  select coalesce(jsonb_agg(b), '[]'::jsonb)
    into v_merged
    from jsonb_array_elements(coalesce(v_existing, '[]'::jsonb)) b
   where b->>'busId' <> p_bus_id::text;

  v_merged := v_merged || jsonb_build_array(v_bus_json);

  insert into public.tour_seat_snapshots as ts (id, tour_id, leg, snapshot_data, captured_at)
  values (
    v_tour_id::text || '_outbound',
    v_tour_id,
    'outbound',
    jsonb_build_object('buses', v_merged),
    now()
  )
  on conflict (tour_id, leg) do update
    set snapshot_data = excluded.snapshot_data,
        captured_at   = excluded.captured_at;

  -- (c) Release the outbound-only riders' seats ON THIS BUS and retire them.
  with victims as (
    select distinct p.id
      from public.passengers p
      cross join lateral jsonb_array_elements(p.assigned_seats) e
     where p.tour_id = v_tour_id
       and p.trip_type = 'outboundOnly'
       and p.journey_done = false
       and e->>'busId' = p_bus_id::text
  )
  update public.passengers p
     set assigned_seats = coalesce((
           select jsonb_agg(e)
             from jsonb_array_elements(p.assigned_seats) e
            where e->>'busId' <> p_bus_id::text
         ), '[]'::jsonb),
         journey_done = true,
         updated_at   = now()
    from victims v
   where p.id = v.id;

  get diagnostics v_cleared = row_count;
  return v_cleared;
end;
$$;

revoke all on function public.handler_complete_outbound_leg(uuid, uuid) from public;
grant execute on function public.handler_complete_outbound_leg(uuid, uuid)
  to anon, authenticated;
