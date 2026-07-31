-- ============================================================
-- 045  Handler → admin cash handover
-- ------------------------------------------------------------
-- The handler holds the cash. They collect fares seat by seat, log their ground
-- expenses and any cabin/gallery income, and the chart shows them exactly what
-- they are holding ("In hand"). What the app never let them do is record the
-- moment that money actually reaches the organiser: `bus_handovers` is written
-- ONLY from the admin's BusMoneyScreen, whose RLS policy is owner-only, and no
-- handler RPC for it has ever existed. So the handler hands over ₹30,000 on the
-- roadside and the app still says they hold ₹30,000 until the admin remembers
-- to type it in from the other side.
--
-- This migration gives the handler the same three verbs they already have for
-- expenses and income — read, upsert, delete — over `bus_handovers`:
--
--   handler_bus_handovers(p_request_id)                -> jsonb array
--   handler_upsert_handover(p_request_id, p_handover)  -> jsonb (the row)
--   handler_delete_handover(p_request_id, p_id)        -> boolean
--
-- Deliberately NOT folded into handler_tour_manifest: that function has been
-- re-created verbatim ten times across migrations 003→044 and the live body has
-- drifted from the files. A standalone read RPC adds the handover array without
-- putting the whole manifest at risk of being rewritten from a stale copy.
--
-- Two things are tighter here than in the older handler write RPCs:
--
--   * `source` ('admin' | 'handler') records who logged the row. The handler may
--     only delete rows they logged themselves — an admin-recorded settlement is
--     read-only to them. Existing rows backfill to 'admin' via the default.
--   * The bus must be one of the CALLER'S OWN buses (buses.handler_passenger_id),
--     not merely a bus on the tour. The older expense/income RPCs check only
--     "bus is on my tour", which lets a co-handler post to another handler's bus.
--     Money leaving the handler's hands is the last place to repeat that.
--
-- The admin side needs no change: `bus_handovers` is already read live by
-- MoneyController, so a handler-recorded handover lands on the admin's per-bus
-- money screen and the tour money board on their next read.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (the numbered migration
-- history is out of sync with live). Idempotent — add-column-if-not-exists plus
-- pure create-or-replace.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Provenance column. Existing rows are all admin-recorded (the handler had
--    no way to write one), so the default backfills them correctly.
-- ------------------------------------------------------------

alter table public.bus_handovers
  add column if not exists source text not null default 'admin';


-- ------------------------------------------------------------
-- 2. handler_bus_handovers — every handover recorded against the buses this
--    handler owns, admin-logged ones included, so the handler sees the full
--    settlement picture for their bus and not just their own entries.
--    Returns '[]' for a non-handler rather than null: an empty ledger and "you
--    are not a handler" are the same read-only outcome for the caller, and the
--    screen gates on the manifest already.
-- ------------------------------------------------------------

create or replace function public.handler_bus_handovers(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select ctx.tour_id, ctx.customer_phone
      from public.handler_ctx(p_request_id) ctx
  ),
  handler_p as (
    select p.id
      from public.passengers p
      join req on req.tour_id = p.tour_id
     where p.phone = req.customer_phone
       and p.is_handler = true
     limit 1
  ),
  my_buses as (
    select b.id
      from public.buses b
      join req on req.tour_id = b.tour_id
     where b.handler_passenger_id in (select id from handler_p)
  )
  select case
    when not public.is_request_handler(p_request_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
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
                 order by h.settled_at
               )
          from public.bus_handovers h
         where h.bus_id in (select id from my_buses)
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.handler_bus_handovers(uuid) from public;
grant execute on function public.handler_bus_handovers(uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 3. handler_upsert_handover — a handler logs (or corrects) one cash handover
--    for one of their OWN buses. NULL when the caller isn't a handler or the
--    bus isn't theirs. Always stamps source='handler' and the server-resolved
--    tour_id; p_handover->>'tour_id' and ->>'source' are ignored.
--
--    An UPDATE additionally refuses to touch an admin-recorded row: the
--    `and h.source = 'handler'` guard in the conflict clause means a handler
--    cannot overwrite the organiser's own settlement entry even by sending its
--    id. Postgres reports zero updated rows there, so v_row stays null and the
--    function returns null — the client surfaces a save error.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_handover(
  p_request_id uuid,
  p_handover jsonb
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

  v_bus_id := (p_handover->>'bus_id')::uuid;
  v_id     := coalesce(nullif(p_handover->>'id', '')::uuid, gen_random_uuid());

  -- The bus must belong to this tour AND be handled by this caller.
  if not exists (
    select 1
      from public.buses b
      join public.passengers p
        on p.id = b.handler_passenger_id
      join public.handler_ctx(p_request_id) ctx
        on ctx.tour_id = b.tour_id
     where b.id = v_bus_id
       and b.tour_id = v_tour_id
       and p.phone = ctx.customer_phone
       and p.is_handler = true
  ) then
    return null;
  end if;

  insert into public.bus_handovers (
    id, tour_id, bus_id, expected_amount, handed_over_amount, note,
    settled_at, source
  )
  values (
    v_id, v_tour_id, v_bus_id,
    coalesce((p_handover->>'expected_amount')::numeric, 0),
    coalesce((p_handover->>'handed_over_amount')::numeric, 0),
    nullif(p_handover->>'note', ''),
    coalesce((p_handover->>'settled_at')::timestamptz, now()),
    'handler'
  )
  on conflict (id) do update set
    expected_amount    = excluded.expected_amount,
    handed_over_amount = excluded.handed_over_amount,
    note               = excluded.note,
    settled_at         = excluded.settled_at
  where public.bus_handovers.source = 'handler'
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_handover(uuid, jsonb) from public;
grant execute on function public.handler_upsert_handover(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 4. handler_delete_handover — a handler removes one HANDLER-logged handover
--    from one of their own buses. Returns true when a row was deleted; false
--    for a non-handler, another handler's bus, or an admin-recorded row.
-- ------------------------------------------------------------

create or replace function public.handler_delete_handover(
  p_request_id uuid,
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
     and h.bus_id in (
       select b.id
         from public.buses b
         join public.passengers p
           on p.id = b.handler_passenger_id
         join public.handler_ctx(p_request_id) ctx
           on ctx.tour_id = b.tour_id
        where b.tour_id = ctx.tour_id
          and p.phone = ctx.customer_phone
          and p.is_handler = true
     );

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_handover(uuid, uuid) from public;
grant execute on function public.handler_delete_handover(uuid, uuid)
  to anon, authenticated;
