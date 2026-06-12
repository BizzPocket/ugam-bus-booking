-- ============================================================
-- 010  Handler expenses (read in manifest + add/edit/delete on the ground)
-- ------------------------------------------------------------
-- The handler already collects cash per passenger (004_handler_collections).
-- To "manage the bus's expenses while on the trip" they also need to LOG
-- expenses (fuel, toll, food, …) for their bus. This adds:
--
--   handler_tour_manifest(p_request_id) -> jsonb
--       Re-created from the 007 body. Two additions:
--         • passengers now carry group_id / priority_status / priority_reason
--           (006 added the columns but never re-exposed them here, so the
--           handler chart's group rings + priority stars were always blank).
--         • a top-level "expenses" array for the whole tour (read-only, the
--           same way "collections" is exposed).
--
--   handler_upsert_expense(p_request_id, p_expense) -> jsonb
--       Inserts/updates one expenses row for the handler's own tour and
--       returns it. Gated on is_request_handler AND the target bus belonging
--       to the handler's tour. The server always uses its own resolved
--       tour_id; p_expense->>'tour_id' is ignored.
--
--   handler_delete_expense(p_request_id, p_expense_id) -> boolean
--       Deletes one expense the handler logged on their own tour. Returns
--       true when a row was removed, false otherwise.
--
-- Must run AFTER 007 (it re-creates handler_tour_manifest from the 007 body).
-- Idempotent. Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

-- READ: full tour manifest (buses + passengers + collections + expenses) for a
-- handler. Identical to 007 except: passengers expose group_id / priority_*,
-- and a top-level "expenses" array is added.
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
                     'seater_price',      b.seater_price,
                     'rear_rows',         b.rear_rows,
                     'rear_price',        b.rear_price,
                     'price_bands',       b.price_bands
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
            join req on req.tour_id = ex.tour_id
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;

-- WRITE: a handler logs (or edits) one expense for a bus on their own tour.
-- Returns NULL when the caller is not a handler, or when the target bus does
-- not belong to the handler's own tour. The server always uses its own
-- resolved tour_id; p_expense->>'tour_id' is ignored.
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

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

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

-- DELETE: a handler removes one expense from their own tour. Returns true when
-- a row was deleted. Gated on is_request_handler AND the expense's tour being
-- the handler's resolved tour, so a handler can never touch another tour's row.
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

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  delete from public.expenses ex
   where ex.id = p_expense_id and ex.tour_id = v_tour_id;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_expense(uuid, uuid) from public;
grant execute on function public.handler_delete_expense(uuid, uuid)
  to anon, authenticated;
