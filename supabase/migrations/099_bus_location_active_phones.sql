-- ============================================================
-- 099  Bus location — only phones that are still reporting vote
-- ------------------------------------------------------------
-- 095 let every phone's newest fix from the last 10 minutes vote. A
-- passenger whose app closed (foreground-only permission, phone pocketed)
-- kept voting for the full 10 minutes from where it stopped. Three such
-- phones at a dhaba outvoted the handler's live phone driving away: the
-- dot stayed at the dhaba, and its speed came from a stale fix ("Parked").
--
-- Two changes, nothing else:
--
--   * a phone whose newest fix trails the bus's newest fix by more than
--     3 minutes has stopped reporting and is left out. A live phone uploads
--     every 2 minutes and a parked one heartbeats, so it is never that far
--     behind.
--   * speed and heading come from a fix that HAS a speed (then finest, then
--     newest). A phone without a speed no longer blanks out one with it.
--
-- Same signature as 095; CREATE OR REPLACE only. Safe to re-run.
-- The Dart twin is lib/services/bus_location_consensus.dart
-- (busLocationActiveLag). Keep the two in step.
-- ============================================================

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

  with latest_all as (
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
  latest as (
    select *
      from latest_all
     where recorded_at >= (select max(recorded_at) from latest_all)
                          - interval '3 minutes'
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
    select c.accuracy_m, c.leg
      from cluster c
     order by coalesce(c.accuracy_m, 80) asc, c.recorded_at desc
     limit 1
  ),
  motion as (
    select c.speed_kmh, c.heading_deg
      from cluster c
     order by (c.speed_kmh is null) asc,
              coalesce(c.accuracy_m, 80) asc,
              c.recorded_at desc
     limit 1
  )
  select centre.lat,
         centre.lng,
         greatest(coalesce(finest.accuracy_m, 80), coalesce(spread.radius, 0))::real,
         motion.speed_kmh,
         motion.heading_deg,
         finest.leg,
         centre.recorded_at,
         centre.n
    into v_lat, v_lng, v_acc, v_speed, v_heading, v_leg, v_recorded, v_count
    from centre
    cross join spread
    cross join finest
    cross join motion;

  if v_count is null or v_count = 0 or v_lat is null then
    return null;
  end if;

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
