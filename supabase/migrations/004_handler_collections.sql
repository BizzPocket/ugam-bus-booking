-- ============================================================
-- 004  Handler collections (read manifest + record cash)
-- ------------------------------------------------------------
-- Extends the handler SECURITY DEFINER RPCs so an anonymous tour handler
-- (a passenger flagged is_handler = true, arriving as a booking request)
-- can see the tour's collection data and record cash on the ground.
--
--   handler_tour_manifest(p_request_id)  -> jsonb
--       Now also returns per-bus pricing, per-passenger trip_type /
--       request_lines, and a top-level "collections" array for the tour.
--
--   handler_upsert_collection(p_request_id, p_collection) -> jsonb
--       Inserts/updates one collections row (one per passenger+bus) and
--       returns it. Gated on the caller being a handler AND on the target
--       passenger + bus belonging to the handler's own tour.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- trip_type is read back in the manifest below; make sure it exists.
alter table public.passengers
  add column if not exists trip_type text;

alter table public.collections
  add column if not exists seat_id text not null default '';

-- READ: full tour manifest (all buses + all passengers + collections) for a
-- handler. Returns NULL for non-handler (or unknown) requests so the app can
-- treat "not a handler" and "no data" identically.
create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
  )
  select case
    when not public.is_request_handler(p_request_id) then null
    else jsonb_build_object(
      'buses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',                b.id,
                     'tour_id',           b.tour_id,
                     'name',              b.name,
                     'registration_no',   b.registration_no,
                     'bus_type',          b.bus_type,
                     'total_seats',       b.total_seats,
                     'layout',            b.layout,
                     'price_per_seat',    b.price_per_seat,
                     'single_sofa_price', b.single_sofa_price,
                     'double_sofa_price', b.double_sofa_price,
                     'seater_price',      b.seater_price
                   )
                   order by b.name
                 )
            from public.buses b
            join req on req.tour_id = b.tour_id
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',             p.id,
                     'tour_id',        p.tour_id,
                     'name',           p.name,
                     'phone',          p.phone,
                     'age_group',      p.age_group,
                     'assigned_seats', p.assigned_seats,
                     'is_handler',     p.is_handler,
                     'trip_type',      p.trip_type,
                     'request_lines',  p.request_lines
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
        ),
        '[]'::jsonb
      ),
      'collections', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              col.id,
                     'tour_id',         col.tour_id,
                     'bus_id',          col.bus_id,
                     'passenger_id',    col.passenger_id,
                     'seat_id',         col.seat_id,
                     'amount_due',      col.amount_due,
                     'amount_received', col.amount_received,
                     'amount_refunded', col.amount_refunded,
                     'note',            col.note,
                     'collected_by',    col.collected_by,
                     'created_at',      col.created_at,
                     'updated_at',      col.updated_at
                   )
                   order by col.created_at
                 )
            from public.collections col
            join req on req.tour_id = col.tour_id
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;

-- WRITE: a handler records cash for one (passenger, bus) pair.
-- Returns NULL when the caller is not a handler, or when the target
-- passenger / bus does not belong to the handler's own tour. The server
-- always uses its own resolved tour_id; p_collection->>'tour_id' is ignored.
create or replace function public.handler_upsert_collection(
  p_request_id uuid,
  p_collection jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id      uuid;
  v_bus_id       uuid;
  v_passenger_id uuid;
  v_seat_id      text;
  v_id           uuid;
  v_row          public.collections;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  v_bus_id       := (p_collection->>'bus_id')::uuid;
  v_passenger_id := (p_collection->>'passenger_id')::uuid;
  v_seat_id      := coalesce(nullif(p_collection->>'seat_id', ''), '');
  v_id           := coalesce(nullif(p_collection->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.passengers p
     where p.id = v_passenger_id and p.tour_id = v_tour_id
  ) then
    return null;
  end if;

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.collections (
    id, tour_id, bus_id, passenger_id, seat_id,
    amount_due, amount_received, amount_refunded, note, collected_by
  )
  values (
    v_id, v_tour_id, v_bus_id, v_passenger_id, v_seat_id,
    coalesce((p_collection->>'amount_due')::numeric, 0),
    coalesce((p_collection->>'amount_received')::numeric, 0),
    coalesce((p_collection->>'amount_refunded')::numeric, 0),
    nullif(p_collection->>'note', ''),
    nullif(p_collection->>'collected_by', '')
  )
  on conflict (passenger_id, bus_id, seat_id) do update set
    amount_due      = excluded.amount_due,
    amount_received = excluded.amount_received,
    amount_refunded = excluded.amount_refunded,
    note            = excluded.note,
    collected_by    = excluded.collected_by,
    updated_at      = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_collection(uuid, jsonb) from public;
grant execute on function public.handler_upsert_collection(uuid, jsonb)
  to anon, authenticated;
