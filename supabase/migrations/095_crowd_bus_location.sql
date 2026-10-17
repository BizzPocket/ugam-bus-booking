-- ============================================================
-- 095  Crowd location — every phone on a bus, one dot per bus
-- ------------------------------------------------------------
-- 047 took the bus position from a single device: the handler's. When that
-- person denies location permission the bus vanishes from the map, even
-- though a coach full of phones is sitting on the same road.
--
-- Each seated passenger (and the handler, who is a passenger) now pushes
-- their own fixes. The live dot is NOT the newest phone. It is recomputed,
-- per bus, from the phones on THAT bus:
--
--   * only fixes from the last 10 minutes
--   * one fix per phone (the newest)
--   * the largest group of phones within 400 m of each other — a phone left
--     at home, or a passenger who already got off, does not pull the bus
--   * inside that group, a fine GPS fix (small accuracy_m) outweighs a
--     coarse cell-tower fix
--
-- Bus A and bus B never share a pool. The recompute is keyed by bus_id, and
-- a phone may only write the bus its assigned seat is on.
--
-- The Dart twin of the maths is lib/services/bus_location_consensus.dart.
-- Keep the two in step: radius 400 m, window 10 min, accuracy clamp 5..500,
-- unknown accuracy 80.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Who sent the fix.
--
-- The old unique key was (bus_id, recorded_at). Two phones reporting in the
-- same second would collide and one would be dropped. The trail is now one
-- series per phone.
-- ------------------------------------------------------------
alter table public.bus_location_fixes
  add column if not exists contributor_id uuid;

update public.bus_location_fixes f
   set contributor_id = coalesce(b.handler_passenger_id, b.id)
  from public.buses b
 where b.id = f.bus_id
   and f.contributor_id is null;

update public.bus_location_fixes
   set contributor_id = bus_id
 where contributor_id is null;

alter table public.bus_location_fixes
  alter column contributor_id set not null;

drop index if exists public.bus_location_fixes_bus_recorded_unique;

create unique index if not exists bus_location_fixes_contributor_recorded_unique
  on public.bus_location_fixes using btree (bus_id, contributor_id, recorded_at);


-- ------------------------------------------------------------
-- 2. Distance, in metres. Internal. Used only by the recompute below.
-- ------------------------------------------------------------
create or replace function public.haversine_m(
  lat1 double precision,
  lng1 double precision,
  lat2 double precision,
  lng2 double precision
) returns double precision
  language sql
  immutable
  parallel safe
as $$
  select 6371000 * 2 * asin(least(1::double precision, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2))
      * power(sin(radians(lng2 - lng1) / 2), 2)
  )));
$$;

alter function public.haversine_m(double precision, double precision, double precision, double precision)
  owner to postgres;
revoke all on function public.haversine_m(double precision, double precision, double precision, double precision)
  from public, anon, authenticated;


-- ------------------------------------------------------------
-- 3. Recompute ONE bus's live dot from the phones on that bus.
--
-- Returns the timestamp of the newest fix that survived into the cluster,
-- or null when nobody on this bus has reported in the fresh window. A null
-- leaves the previous dot where it is — an empty window must not rewind the
-- map to an older flush.
-- ------------------------------------------------------------
create or replace function public.recompute_bus_live_position(p_bus_id uuid)
  returns timestamp with time zone
  language plpgsql
  security definer
  set search_path to 'public'
as $$
declare
  v_tour_id  uuid;
  v_lat      double precision;
  v_lng      double precision;
  v_acc      real;
  v_speed    real;
  v_heading  real;
  v_leg      text;
  v_recorded timestamp with time zone;
  v_count    int;
begin
  select b.tour_id into v_tour_id
    from public.buses b
   where b.id = p_bus_id;

  if v_tour_id is null then
    return null;
  end if;

  with latest as (
    select distinct on (f.contributor_id)
           f.contributor_id,
           f.lat,
           f.lng,
           f.accuracy_m,
           f.speed_kmh,
           f.heading_deg,
           f.leg,
           f.recorded_at,
           (1.0 / least(greatest(coalesce(f.accuracy_m, 80), 5), 500)) as w
      from public.bus_location_fixes f
     where f.bus_id = p_bus_id
       and f.recorded_at >= now() - interval '10 minutes'
       and f.recorded_at <= now() + interval '5 minutes'
     order by f.contributor_id, f.recorded_at desc
  ),
  scored as (
    select a.contributor_id,
           count(*)::int as neighbors,
           sum(b.w)      as weight_sum
      from latest a
      join latest b
        on public.haversine_m(a.lat, a.lng, b.lat, b.lng) <= 400
     group by a.contributor_id
  ),
  seed as (
    select s.contributor_id
      from scored s
      join latest l on l.contributor_id = s.contributor_id
     order by s.neighbors desc,
              s.weight_sum desc,
              coalesce(l.accuracy_m, 80) asc,
              l.recorded_at desc
     limit 1
  ),
  cluster as (
    select l.*
      from latest l
      join latest seedrow
        on seedrow.contributor_id = (select contributor_id from seed)
     where public.haversine_m(l.lat, l.lng, seedrow.lat, seedrow.lng) <= 400
  ),
  centre as (
    select sum(lat * w) / sum(w) as lat,
           sum(lng * w) / sum(w) as lng,
           count(*)::int         as n,
           max(recorded_at)      as recorded_at
      from cluster
  ),
  spread as (
    select max(public.haversine_m(c.lat, c.lng, centre.lat, centre.lng)) as radius
      from cluster c
      cross join centre
  ),
  finest as (
    select c.accuracy_m, c.speed_kmh, c.heading_deg, c.leg
      from cluster c
     order by coalesce(c.accuracy_m, 80) asc, c.recorded_at desc
     limit 1
  )
  select centre.lat,
         centre.lng,
         greatest(coalesce(finest.accuracy_m, 80), coalesce(spread.radius, 0))::real,
         finest.speed_kmh,
         finest.heading_deg,
         finest.leg,
         centre.recorded_at,
         centre.n
    into v_lat, v_lng, v_acc, v_speed, v_heading, v_leg, v_recorded, v_count
    from centre
    cross join spread
    cross join finest;

  if v_count is null or v_count = 0 or v_lat is null then
    return null;
  end if;

  -- Always replace. The previous dot may be a single phone that this
  -- cluster has just voted off the bus; keeping it because its timestamp
  -- is newer would put the map back on the outlier.
  insert into public.bus_live_positions as lp (
    bus_id, tour_id, lat, lng, accuracy_m, speed_kmh, heading_deg,
    leg, tracking_state, recorded_at, received_at
  )
  values (
    p_bus_id, v_tour_id, v_lat, v_lng, v_acc, v_speed, v_heading,
    v_leg, 'live', v_recorded, now()
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
        received_at    = excluded.received_at;

  return v_recorded;
end;
$$;

alter function public.recompute_bus_live_position(uuid) owner to postgres;
revoke all on function public.recompute_bus_live_position(uuid)
  from public, anon, authenticated;


-- ------------------------------------------------------------
-- 4. Shared insert. Both the handler RPC and the passenger RPC land here,
--    then recompute. Malformed fixes are dropped; they never abort the batch.
-- ------------------------------------------------------------
create or replace function public.insert_bus_location_fixes(
  p_tour_id        uuid,
  p_bus_id         uuid,
  p_contributor_id uuid,
  p_fixes          jsonb
) returns int
  language plpgsql
  security definer
  set search_path to 'public'
as $$
declare
  v_accepted int := 0;
begin
  with incoming as (
    select
      public.try_float(e->>'lat')               as lat,
      public.try_float(e->>'lng')               as lng,
      public.try_float(e->>'accuracy_m')::real  as accuracy_m,
      public.try_float(e->>'speed_kmh')::real   as speed_kmh,
      public.try_float(e->>'heading_deg')::real as heading_deg,
      nullif(e->>'leg', '')                     as leg,
      public.try_timestamptz(e->>'recorded_at') as recorded_at
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
      tour_id, bus_id, contributor_id, lat, lng, accuracy_m,
      speed_kmh, heading_deg, leg, recorded_at
    )
    select p_tour_id, p_bus_id, p_contributor_id, v.lat, v.lng, v.accuracy_m,
           v.speed_kmh, v.heading_deg, v.leg, v.recorded_at
      from valid v
    on conflict (bus_id, contributor_id, recorded_at) do nothing
    returning 1
  )
  select count(*)::int into v_accepted from ins;

  return v_accepted;
end;
$$;

alter function public.insert_bus_location_fixes(uuid, uuid, uuid, jsonb) owner to postgres;
revoke all on function public.insert_bus_location_fixes(uuid, uuid, uuid, jsonb)
  from public, anon, authenticated;


-- ------------------------------------------------------------
-- 5. handler_push_locations — same guards as 047, then the shared insert
--    and a per-bus recompute. The handler's phone is one contributor among
--    the passengers on that bus, not a veto.
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
  v_tour_id     uuid;
  v_status      text;
  v_contributor uuid;
  v_accepted    int := 0;
  v_live        timestamp with time zone;
begin
  if not public.is_request_handler(p_request_id)
     or not public.handler_owns_bus(p_request_id, p_bus_id) then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'forbidden');
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  select t.status into v_status
    from public.tours t
   where t.id = v_tour_id;

  if v_status is distinct from 'locked' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'window_closed');
  end if;

  if p_fixes is null or jsonb_typeof(p_fixes) <> 'array' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'bad_payload');
  end if;

  select p.id into v_contributor
    from public.handler_ctx(p_request_id) ctx
    join public.passengers p
      on p.tour_id = ctx.tour_id
     and p.phone = ctx.customer_phone
     and p.is_handler = true
   limit 1;

  if v_contributor is null then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'forbidden');
  end if;

  v_accepted := public.insert_bus_location_fixes(
    v_tour_id, p_bus_id, v_contributor, p_fixes
  );
  v_live := public.recompute_bus_live_position(p_bus_id);

  return jsonb_build_object(
    'accepted',     v_accepted,
    'skipped',      jsonb_array_length(p_fixes) - v_accepted,
    'live_updated', v_live
  );
end;
$$;


-- ------------------------------------------------------------
-- 6. passenger_push_locations — any seated phone on a locked tour.
--
-- Authorised by the last 10 digits of the phone, the same match
-- seat_lookup_by_phone already uses. The phone must hold a seat on
-- p_bus_id, and that bus must belong to the passenger's tour. A phone
-- cannot write a different bus.
-- ------------------------------------------------------------
create or replace function public.passenger_push_locations(
  p_phone  text,
  p_bus_id uuid,
  p_fixes  jsonb
) returns jsonb
  language plpgsql
  security definer
  set search_path to 'public'
as $$
declare
  v_last10      text;
  v_tour_id     uuid;
  v_contributor uuid;
  v_status      text;
  v_accepted    int := 0;
  v_live        timestamp with time zone;
begin
  v_last10 := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  if v_last10 !~ '^\d{10}$' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'forbidden');
  end if;

  if p_fixes is null or jsonb_typeof(p_fixes) <> 'array' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'bad_payload');
  end if;

  select p.id, p.tour_id, t.status
    into v_contributor, v_tour_id, v_status
    from public.passengers p
    join public.tours t on t.id = p.tour_id
    join public.buses b on b.id = p_bus_id and b.tour_id = p.tour_id
   where right(regexp_replace(p.phone, '\D', '', 'g'), 10) = v_last10
     and t.status = 'locked'
     and exists (
       select 1
         from jsonb_array_elements(coalesce(p.assigned_seats, '[]'::jsonb)) seat
        where seat->>'busId' = p_bus_id::text
     )
   order by t.departure_date desc
   limit 1;

  if v_contributor is null or v_status is distinct from 'locked' then
    return jsonb_build_object('accepted', 0, 'skipped', 0, 'error', 'forbidden');
  end if;

  v_accepted := public.insert_bus_location_fixes(
    v_tour_id, p_bus_id, v_contributor, p_fixes
  );
  v_live := public.recompute_bus_live_position(p_bus_id);

  return jsonb_build_object(
    'accepted',     v_accepted,
    'skipped',      jsonb_array_length(p_fixes) - v_accepted,
    'live_updated', v_live
  );
end;
$$;

alter function public.passenger_push_locations(text, uuid, jsonb) owner to postgres;
revoke all on function public.passenger_push_locations(text, uuid, jsonb) from public;
grant execute on function public.passenger_push_locations(text, uuid, jsonb)
  to anon, authenticated, service_role;


-- ------------------------------------------------------------
-- 7. Which bus should this phone report for?
--
-- Every locked-tour seat this number holds, so the client can pick the
-- trip closest to now and, on that trip, the bus with more berths.
-- Completed tours are omitted: the trip is over, there is nothing to follow.
-- ------------------------------------------------------------
create or replace function public.location_share_target(p_phone text)
  returns jsonb
  language sql
  security definer
  set search_path to 'public'
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  seats as (
    select b.id as bus_id,
           t.departure_date
      from public.passengers p
      join public.tours t on t.id = p.tour_id
      cross join norm
      cross join lateral jsonb_array_elements(coalesce(p.assigned_seats, '[]'::jsonb)) seat
      join public.buses b
        on b.id::text = seat->>'busId'
       and b.tour_id = p.tour_id
     where norm.last10 ~ '^\d{10}$'
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status = 'locked'
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'bus_id', bus_id,
        'departure', departure_date,
        'seat_count', seat_count
      )
    ),
    '[]'::jsonb
  )
    from (
      select bus_id, departure_date, count(*)::int as seat_count
        from seats
       group by bus_id, departure_date
    ) counted;
$$;

alter function public.location_share_target(text) owner to postgres;
revoke all on function public.location_share_target(text) from public;
grant execute on function public.location_share_target(text)
  to anon, authenticated, service_role;
