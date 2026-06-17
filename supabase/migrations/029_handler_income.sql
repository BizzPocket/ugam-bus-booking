-- ============================================================
-- 029  Handler income (read in manifest + add/edit/delete on the ground)
-- ------------------------------------------------------------
-- The handler logs the bus's EXPENSES on the trip (010_handler_expenses) and
-- collects cash per passenger (004_handler_collections). They also take in
-- miscellaneous INCOME on the ground — cabin (driver/cabin) fares, gallery
-- (luggage rack) charges, and other one-off receipts — that isn't a per-seat
-- passenger collection. This adds an income layer alongside expenses (010) and
-- attendance (024):
--
--   * incomes        one row per receipt for a bus: category + label + amount,
--                    plus who received it and a free-text note. category is
--                    'cabin' / 'gallery' / 'other'.
--
--   handler_tour_manifest(p_request_id) -> jsonb
--       Re-created from the 024 body VERBATIM except for one addition: a
--       top-level "incomes" array scoped to my_buses, the same way
--       "collections", "expenses" and "attendance" are exposed.
--
--   handler_upsert_income(p_request_id, p_income) -> jsonb
--       Inserts/updates one incomes row for the handler's own tour and returns
--       it. Gated on is_request_handler AND the target bus belonging to the
--       handler's tour. The server always uses its own resolved tour_id;
--       p_income->>'tour_id' is ignored.
--
--   handler_delete_income(p_request_id, p_income_id) -> boolean
--       Deletes one income the handler logged on their own tour. Returns true
--       when a row was removed, false otherwise.
--
-- ADDITIVE + idempotent-friendly: uses `create table if not exists`,
-- `create index if not exists`, `drop policy if exists` + recreate, and
-- `create or replace function`. Must run AFTER 024 (it re-creates
-- handler_tour_manifest from the 024 body).
--
-- RLS follows the repo's tour-scoped child-table pattern (see attendance in
-- 024_handler_attendance.sql and collections / expenses in
-- 004_money_collection.sql): a row is visible/writable to the authenticated
-- agent who owns the parent tour. Handler writes go through the SECURITY
-- DEFINER RPCs below, so the table's own policy only needs to let the tour's
-- admin read their own rows.
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================


-- ------------------------------------------------------------
-- 1. incomes — one row per receipt for a bus.
-- ------------------------------------------------------------

create table if not exists public.incomes (
  id           uuid primary key default gen_random_uuid(),
  tour_id      uuid not null references public.tours(id) on delete cascade,
  bus_id       uuid not null references public.buses(id) on delete cascade,
  category     text not null default 'other',
  label        text,
  amount       numeric not null default 0,
  received_by  text,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists incomes_tour_idx on public.incomes(tour_id);
create index if not exists incomes_bus_idx  on public.incomes(bus_id);

alter table public.incomes enable row level security;

drop policy if exists "incomes_owner_all" on public.incomes;
create policy "incomes_owner_all" on public.incomes
  for all to authenticated
  using (exists (select 1 from public.tours t
                 where t.id = incomes.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                      where t.id = incomes.tour_id and t.owner_id = auth.uid()));


-- ------------------------------------------------------------
-- 2. handler_tour_manifest — re-created from the 024 body, adding a top-level
--    "incomes" array scoped to my_buses. Everything else is byte-identical to
--    024.
-- ------------------------------------------------------------

create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
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
-- 3. handler_upsert_income — a handler logs (or edits) one income for a bus on
--    their own tour. Returns NULL when the caller is not a handler, or when the
--    target bus does not belong to the handler's own tour. The server always
--    uses its own resolved tour_id; p_income->>'tour_id' is ignored.
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

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

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
-- 4. handler_delete_income — a handler removes one income from their own tour.
--    Returns true when a row was deleted. Gated on is_request_handler AND the
--    income's tour being the handler's resolved tour, so a handler can never
--    touch another tour's row.
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

  select br.tour_id into v_tour_id
    from public.booking_requests br
   where br.id = p_request_id;

  delete from public.incomes inc
   where inc.id = p_income_id and inc.tour_id = v_tour_id;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function public.handler_delete_income(uuid, uuid) from public;
grant execute on function public.handler_delete_income(uuid, uuid)
  to anon, authenticated;


-- ------------------------------------------------------------
-- 5. Realtime — let the app subscribe to incomes changes, the same way
--    attendance / collections / expenses are published.
-- ------------------------------------------------------------

do $$
begin
  alter publication supabase_realtime add table public.incomes;
exception when duplicate_object then null;
end $$;
