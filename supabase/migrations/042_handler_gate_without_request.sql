-- ============================================================
-- 042  A handler is authorised by their PASSENGER row, not a booking_request
-- ------------------------------------------------------------
-- A handler the organiser adds BY HAND is today permanently locked out of every
-- handler surface. Adding a handler manually writes a `passengers` row with
-- is_handler = true and nothing else — that person never filled the customer
-- booking form, so they have NO `booking_requests` row. Every handler gate,
-- however, starts from booking_requests and INNER-JOINs passengers on the
-- request's own phone:
--
--     from public.booking_requests br
--     join public.passengers p on p.tour_id = br.tour_id
--                             and p.phone   = br.customer_phone
--
-- With no br row that join has nothing to start from, so:
--   * is_request_handler(...)        -> false for any id they could pass,
--   * handler_requests_by_phone(...) -> [] (its br join is also inner), so the
--                                       "Manage as handler" entry never appears,
--   * handler_tour_manifest(...)     -> null, and all six write RPCs dead-end.
--
-- The join was wrong because booking_requests is a CUSTOMER artefact — proof
-- that someone asked for seats. It was only ever being used as a convenient
-- (tour_id, phone) carrier. Handler AUTHORITY has always lived on the passenger
-- row (`passengers.is_handler`), and the buses point at the handler by
-- `buses.handler_passenger_id` — a passenger id, never a request id. The
-- booking_request in the middle was an accident of how the first handlers
-- happened to be created, not part of the authorisation model.
--
-- This migration decouples the two by introducing ONE resolver:
--
--   handler_ctx(p_id uuid) -> (tour_id, customer_phone)
--       Resolves EITHER a booking_requests.id OR a handler passengers.id to the
--       tour plus the handler's phone. A booking_request always wins when both
--       could match, so existing in-app handlers resolve exactly as they do
--       today and their behaviour is unchanged.
--
-- Every gate is then rebuilt on top of it. The opaque "request id" the client
-- passes around becomes just that — OPAQUE. It is a booking_request id for an
-- in-app handler and a passenger id for a manually-added one, and no caller
-- needs to know which. Because Postgres cannot rename an input parameter with
-- CREATE OR REPLACE — and because the Flutter client (customer_requests_store)
-- and the bus-message Edge Function call these by NAMED parameter — the
-- parameter stays `p_request_id` even though it now accepts either id. Return
-- JSON shapes are byte-identical; the Dart models (handler_manifest.dart,
-- handler_tour_ref.dart) parse the same keys as before.
--
-- The 039 lock gate is preserved everywhere it exists today: tour status must
-- still be in ('locked','completed') in both is_request_handler and
-- handler_requests_by_phone. A manually-added handler gains exactly the access
-- an in-app handler already had — no more, and not one moment earlier.
--
-- NOT changed by this migration: a PHONE NUMBER remains the only handler
-- credential. handler_requests_by_phone still hands the handler entry to
-- anyone who can type the right last-10 digits, and the RPCs remain SECURITY
-- DEFINER and open to anon because handlers are unauthenticated. This file only
-- fixes WHICH ROW proves handlership; real handler authentication is tracked
-- separately.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (the numbered migration
-- history is out of sync with live). Idempotent — pure create-or-replace.
-- ============================================================


-- ------------------------------------------------------------
-- 1. handler_ctx — the single resolver every gate below funnels through.
--    booking_requests takes precedence over passengers.
--
--    Precedence is made deterministic with an explicit rank column and an
--    ORDER BY. A bare `union all ... limit 1` would NOT be enough: SQL gives no
--    ordering guarantee for the branches of a UNION ALL (the planner is free to
--    append them in either order, or in parallel), so LIMIT 1 without an ORDER
--    BY could return the passenger row even when a booking_request exists.
--
--    Both branches read a primary key, so each yields at most one row.
--
--    Deliberately NOT granted to anon/authenticated: it is only ever called
--    from inside the SECURITY DEFINER functions below, which execute as the
--    owner and therefore always have execute rights on it. Leaving it ungranted
--    keeps a (uuid -> phone number) lookup off the public API surface.
-- ------------------------------------------------------------

create or replace function public.handler_ctx(p_id uuid)
returns table (tour_id uuid, customer_phone text)
language sql stable security definer set search_path = public
as $$
  select c.tour_id, c.customer_phone
    from (
      -- A real booking_request: the in-app handler path (rank 0 = wins).
      select br.tour_id         as tour_id,
             br.customer_phone  as customer_phone,
             0                  as src_rank
        from public.booking_requests br
       where br.id = p_id
      union all
      -- A handler passenger added by hand, with no booking_request at all.
      select p.tour_id  as tour_id,
             p.phone    as customer_phone,
             1          as src_rank
        from public.passengers p
       where p.id = p_id
         and p.is_handler = true
    ) c
   order by c.src_rank
   limit 1;
$$;

revoke all on function public.handler_ctx(uuid) from public;


-- ------------------------------------------------------------
-- 2. is_request_handler — the shared gate every handler RPC and the
--    bus-message Edge Function funnel through. Identical to 039 except that the
--    (tour_id, phone) pair now comes from handler_ctx instead of a hard
--    booking_requests lookup. The passengers + tours joins, the
--    `p.is_handler = true` requirement and the 039 lock filter are unchanged.
-- ------------------------------------------------------------

create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.handler_ctx(p_request_id) ctx
        join public.passengers p
          on p.tour_id = ctx.tour_id
         and p.phone   = ctx.customer_phone
        join public.tours t
          on t.id = ctx.tour_id
       where p.is_handler = true
         and t.status in ('locked', 'completed')
    ),
    false
  );
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 3. handler_requests_by_phone — the phone -> handler-ref bridge behind the
--    "Manage as handler" entry on the Find-my-seat screen.
--
--    Identical to 039 except the booking_requests join is now a LEFT JOIN and
--    the emitted ref is `coalesce(br.id, p.id)`: an in-app handler still gets
--    their booking_request id (byte-identical output to today), while a
--    manually-added handler gets their PASSENGER id as the opaque ref — which
--    handler_ctx above resolves just as well. The 039 lock filter stays.
--
--    The inner `order by` must lead with t.id for `distinct on (t.id)`, and is
--    made deterministic when br is null by explicit `nulls last` plus a final
--    p.id tiebreaker. (`nulls last` is the default for ascending sorts, so this
--    changes nothing for handlers that do have requests.) The outer
--    `order by refs.departure_date desc` inside jsonb_agg is unchanged.
-- ------------------------------------------------------------

create or replace function public.handler_requests_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  refs as (
    select distinct on (t.id)
           coalesce(br.id, p.id) as request_id,
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
      left join public.booking_requests br
        on br.tour_id = p.tour_id
       and right(regexp_replace(br.customer_phone, '\D', '', 'g'), 10) = norm.last10
     where norm.last10 <> ''
       and p.is_handler = true
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status in ('locked', 'completed')
     order by t.id, br.created_at nulls last, br.id nulls last, p.id
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


-- ------------------------------------------------------------
-- 4. handler_tour_manifest — reproduced VERBATIM from 029_handler_income.sql
--    (buses / passengers / collections / expenses / attendance / incomes),
--    with exactly one change: the `req` CTE now reads from handler_ctx instead
--    of booking_requests. Its output columns keep the same names (tour_id,
--    customer_phone) so every downstream CTE is untouched.
-- ------------------------------------------------------------

create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select ctx.tour_id, ctx.customer_phone
      from public.handler_ctx(p_request_id) ctx
  ),
  -- The handler passenger behind this request (same match as is_request_handler).
  handler_p as (
    select p.id
      from public.passengers p
      join req on req.tour_id = p.tour_id
     where p.phone = req.customer_phone
       and p.is_handler = true
     limit 1
  ),
  -- Only the bus(es) this handler owns. Empty when they own none.
  my_buses as (
    select b.id
      from public.buses b
      join req on req.tour_id = b.tour_id
     where b.handler_passenger_id in (select id from handler_p)
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
                     'bus_price',         b.bus_price,
                     'boarding_point',    b.boarding_point,
                     'departure_time',    b.departure_time,
                     'single_sofa_price', b.single_sofa_price,
                     'double_sofa_price', b.double_sofa_price,
                     'seater_price',      b.seater_price,
                     'rear_rows',         b.rear_rows,
                     'rear_price',        b.rear_price,
                     'price_bands',       b.price_bands,
                     'driver_name',       b.driver_name,
                     'driver_phone',      b.driver_phone,
                     'handler_passenger_id', b.handler_passenger_id
                   )
                   order by b.name
                 )
            from public.buses b
           where b.id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              p.id,
                     'tour_id',         p.tour_id,
                     'name',            p.name,
                     'phone',           p.phone,
                     'age_group',       p.age_group,
                     'assigned_seats',  p.assigned_seats,
                     'is_handler',      p.is_handler,
                     'trip_type',       p.trip_type,
                     'request_lines',   p.request_lines,
                     'group_id',        p.group_id,
                     'priority_status', p.priority_status,
                     'priority_reason', p.priority_reason
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
           where
             -- always include the handler themselves
             p.id in (select id from handler_p)
             -- plus anyone seated on one of this handler's buses
             or exists (
               select 1
                 from jsonb_array_elements(p.assigned_seats) seat
                where (seat->>'busId') in (
                        select id::text from my_buses
                      )
             )
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
           where col.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'expenses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',         ex.id,
                     'tour_id',    ex.tour_id,
                     'bus_id',     ex.bus_id,
                     'category',   ex.category,
                     'label',      ex.label,
                     'amount',     ex.amount,
                     'paid_by',    ex.paid_by,
                     'note',       ex.note,
                     'created_at', ex.created_at,
                     'updated_at', ex.updated_at
                   )
                   order by ex.created_at
                 )
            from public.expenses ex
           where ex.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'attendance', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',           at.id,
                     'tour_id',      at.tour_id,
                     'bus_id',       at.bus_id,
                     'passenger_id', at.passenger_id,
                     'leg',          at.leg,
                     'present',      at.present,
                     'marked_by',    at.marked_by,
                     'marked_at',    at.marked_at,
                     'created_at',   at.created_at
                   )
                   order by at.created_at
                 )
            from public.attendance at
           where at.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      ),
      'incomes', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',          inc.id,
                     'tour_id',     inc.tour_id,
                     'bus_id',      inc.bus_id,
                     'category',    inc.category,
                     'label',       inc.label,
                     'amount',      inc.amount,
                     'received_by', inc.received_by,
                     'note',        inc.note,
                     'created_at',  inc.created_at,
                     'updated_at',  inc.updated_at
                   )
                   order by inc.created_at
                 )
            from public.incomes inc
           where inc.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 5. handler_upsert_collection — reproduced VERBATIM from
--    004_handler_collections.sql; only the v_tour_id lookup now goes through
--    handler_ctx.
-- ------------------------------------------------------------

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

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

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


-- ------------------------------------------------------------
-- 6. handler_upsert_expense — reproduced VERBATIM from
--    010_handler_expenses.sql; only the v_tour_id lookup changed.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_expense(
  p_request_id uuid,
  p_expense jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_bus_id  uuid;
  v_id      uuid;
  v_row     public.expenses;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  v_bus_id := (p_expense->>'bus_id')::uuid;
  v_id     := coalesce(nullif(p_expense->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.expenses (
    id, tour_id, bus_id, category, label, amount, paid_by, note
  )
  values (
    v_id, v_tour_id, v_bus_id,
    coalesce(nullif(p_expense->>'category', ''), 'other'),
    coalesce(p_expense->>'label', ''),
    coalesce((p_expense->>'amount')::numeric, 0),
    nullif(p_expense->>'paid_by', ''),
    nullif(p_expense->>'note', '')
  )
  on conflict (id) do update set
    category   = excluded.category,
    label      = excluded.label,
    amount     = excluded.amount,
    paid_by    = excluded.paid_by,
    note       = excluded.note,
    updated_at = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_expense(uuid, jsonb) from public;
grant execute on function public.handler_upsert_expense(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 7. handler_delete_expense — reproduced VERBATIM from
--    010_handler_expenses.sql; only the v_tour_id lookup changed.
-- ------------------------------------------------------------

create or replace function public.handler_delete_expense(
  p_request_id uuid,
  p_expense_id uuid
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_deleted int;
begin
  if not public.is_request_handler(p_request_id) then
    return false;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  delete from public.expenses ex
   where ex.id = p_expense_id and ex.tour_id = v_tour_id;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_expense(uuid, uuid) from public;
grant execute on function public.handler_delete_expense(uuid, uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 8. handler_upsert_attendance — reproduced VERBATIM from
--    024_handler_attendance.sql; only the v_tour_id lookup changed.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_attendance(
  p_request_id uuid,
  p_attendance jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id      uuid;
  v_bus_id       uuid;
  v_passenger_id uuid;
  v_leg          text;
  v_id           uuid;
  v_row          public.attendance;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  v_bus_id       := (p_attendance->>'bus_id')::uuid;
  v_passenger_id := (p_attendance->>'passenger_id')::uuid;
  v_leg          := coalesce(nullif(p_attendance->>'leg', ''), 'go');
  v_id           := coalesce(nullif(p_attendance->>'id', '')::uuid, gen_random_uuid());

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

  insert into public.attendance (
    id, tour_id, bus_id, passenger_id, leg, present, marked_by, marked_at
  )
  values (
    v_id, v_tour_id, v_bus_id, v_passenger_id, v_leg,
    coalesce((p_attendance->>'present')::boolean, true),
    nullif(p_attendance->>'marked_by', ''),
    now()
  )
  on conflict (passenger_id, bus_id, leg) do update set
    present   = excluded.present,
    marked_by = excluded.marked_by,
    marked_at = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_attendance(uuid, jsonb) from public;
grant execute on function public.handler_upsert_attendance(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 9. handler_upsert_income — reproduced VERBATIM from 029_handler_income.sql;
--    only the v_tour_id lookup changed.
-- ------------------------------------------------------------

create or replace function public.handler_upsert_income(
  p_request_id uuid,
  p_income jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_bus_id  uuid;
  v_id      uuid;
  v_row     public.incomes;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  v_bus_id := (p_income->>'bus_id')::uuid;
  v_id     := coalesce(nullif(p_income->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.incomes (
    id, tour_id, bus_id, category, label, amount, received_by, note
  )
  values (
    v_id, v_tour_id, v_bus_id,
    coalesce(nullif(p_income->>'category', ''), 'other'),
    coalesce(p_income->>'label', ''),
    coalesce((p_income->>'amount')::numeric, 0),
    nullif(p_income->>'received_by', ''),
    nullif(p_income->>'note', '')
  )
  on conflict (id) do update set
    category    = excluded.category,
    label       = excluded.label,
    amount      = excluded.amount,
    received_by = excluded.received_by,
    note        = excluded.note,
    updated_at  = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.handler_upsert_income(uuid, jsonb) from public;
grant execute on function public.handler_upsert_income(uuid, jsonb)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 10. handler_delete_income — reproduced VERBATIM from 029_handler_income.sql;
--     only the v_tour_id lookup changed.
-- ------------------------------------------------------------

create or replace function public.handler_delete_income(
  p_request_id uuid,
  p_income_id uuid
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id uuid;
  v_deleted int;
begin
  if not public.is_request_handler(p_request_id) then
    return false;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  delete from public.incomes inc
   where inc.id = p_income_id and inc.tour_id = v_tour_id;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_income(uuid, uuid) from public;
grant execute on function public.handler_delete_income(uuid, uuid)
  to anon, authenticated;
