-- ============================================================
-- 054_soft_delete.sql   —   P1 of the finance rebuild
-- ------------------------------------------------------------
-- Nothing in the money system is ever destroyed again.
--
-- Today a tour delete CASCADES to its buses, passengers, collections,
-- expenses, incomes and handovers — the entire financial history of a trip
-- disappears on one tap, with no record that it ever existed. Every money row
-- is likewise hard-deleted by `smartDelete`. The ledger (P2) cannot reference
-- rows that can vanish underneath it, so this has to land first.
--
-- SCOPE — the seven tables the books depend on:
--   tours, buses, passengers,
--   collections, expenses, incomes, bus_handovers
-- Config tables (pickup_locations, passenger_groups) keep hard delete for now;
-- they carry no money and no history worth keeping.
--
-- THE TRAP THIS FILE EXISTS TO HANDLE: a soft-deleted row still occupies its
-- unique key. Without the partial predicates below, deleting a collection
-- would permanently prevent that rider ever being collected on for that seat
-- again — and deleting a passenger would permanently burn their phone number
-- for the tour. All four affected indexes are narrowed to live rows only.
--
-- Narrowing a unique index can never fail on existing data (it only ever
-- matches fewer rows), so the drop/recreate below is safe on live data. There
-- is a sub-second window with no uniqueness enforcement; at this app's write
-- volume that is acceptable.
--
-- ADDITIVE + idempotent. Re-runnable: `add column if not exists`,
-- `drop index if exists` + recreate, `create index if not exists`.
-- No existing RLS policy is touched — the live policy set has diverged from
-- these files before, so read filtering is done in the client's single fetch
-- path instead of by rewriting policies blind.
--
-- Apply in the Supabase SQL editor, isolated. Do NOT `db push`.
-- ============================================================


-- ── 1. The columns ───────────────────────────────────────────
-- `deleted_at` null  = live. Non-null = deleted, and the row is retained
-- forever. `deleted_by` is auth.uid() for an admin, or the handler's passenger
-- id — resolved by whoever performs the delete, never trusted blindly.

alter table public.tours          add column if not exists deleted_at timestamptz;
alter table public.tours          add column if not exists deleted_by uuid;
alter table public.buses          add column if not exists deleted_at timestamptz;
alter table public.buses          add column if not exists deleted_by uuid;
alter table public.passengers     add column if not exists deleted_at timestamptz;
alter table public.passengers     add column if not exists deleted_by uuid;
alter table public.collections    add column if not exists deleted_at timestamptz;
alter table public.collections    add column if not exists deleted_by uuid;
alter table public.expenses       add column if not exists deleted_at timestamptz;
alter table public.expenses       add column if not exists deleted_by uuid;
alter table public.incomes        add column if not exists deleted_at timestamptz;
alter table public.incomes        add column if not exists deleted_by uuid;
alter table public.bus_handovers  add column if not exists deleted_at timestamptz;
alter table public.bus_handovers  add column if not exists deleted_by uuid;


-- ── 2. Unique indexes narrowed to live rows ──────────────────
-- Each of these would otherwise be permanently poisoned by a soft delete: the
-- archived row keeps occupying its key forever.
--
-- THIS MUST WORK OFF THE LIVE DEFINITION, NOT OFF THESE FILES.
-- The migration files are not authoritative — `passengers_tour_phone_unique`
-- is declared in database.sql but does NOT exist on the live database (one
-- phone legitimately holds several bookings per tour). A blind
-- `drop + create` therefore tried to INTRODUCE uniqueness that live never had
-- and failed on real duplicate data.
--
-- So: read each index's actual definition, inject the predicate into whatever
-- WHERE it already has, and recreate. An index that is absent is SKIPPED —
-- this file narrows existing uniqueness and never invents any. Absent is a
-- valid answer, not an error.
--
-- Atomic: a DO block is one statement, so if the recreate fails the drop rolls
-- back with it and the original index survives.

do $$
declare
  v_names text[] := array[
    'collections_passenger_bus_seat_unique',
    'passengers_tour_phone_unique',
    'buses_owner_reg_unique',
    'buses_tour_reg_unique'
  ];
  v_name text;
  v_def  text;
  v_new  text;
begin
  foreach v_name in array v_names loop
    select indexdef into v_def
      from pg_indexes
     where schemaname = 'public' and indexname = v_name;

    if v_def is null then
      raise notice '054: % absent on this database — skipped (not created)', v_name;
      continue;
    end if;

    if v_def ~* 'deleted_at\s+is\s+null' then
      raise notice '054: % already narrowed to live rows', v_name;
      continue;
    end if;

    -- Extend an existing WHERE, or add one. Parenthesise the original
    -- predicate so `a OR b` cannot bind loosely against the new AND.
    if v_def ~* '\swhere\s' then
      v_new := regexp_replace(v_def, '\swhere\s+(.*)$',
                              ' WHERE (\1) AND deleted_at IS NULL', 'i');
    else
      v_new := v_def || ' WHERE deleted_at IS NULL';
    end if;

    execute format('drop index if exists public.%I', v_name);
    execute v_new;
    raise notice '054: narrowed %', v_name;
  end loop;
end $$;


-- ── 3. Live-row indexes ──────────────────────────────────────
-- The existing indexes stay (the archive needs them too). These partial
-- variants keep the hot path — "the rows that still count" — selective as the
-- archive grows.

create index if not exists collections_tour_live_idx
  on public.collections(tour_id) where deleted_at is null;
create index if not exists collections_bus_live_idx
  on public.collections(bus_id)  where deleted_at is null;
create index if not exists expenses_tour_live_idx
  on public.expenses(tour_id)    where deleted_at is null;
create index if not exists expenses_bus_live_idx
  on public.expenses(bus_id)     where deleted_at is null;
create index if not exists incomes_tour_live_idx
  on public.incomes(tour_id)     where deleted_at is null;
create index if not exists incomes_bus_live_idx
  on public.incomes(bus_id)      where deleted_at is null;
create index if not exists bus_handovers_tour_live_idx
  on public.bus_handovers(tour_id) where deleted_at is null;
create index if not exists bus_handovers_bus_live_idx
  on public.bus_handovers(bus_id)  where deleted_at is null;
create index if not exists buses_tour_live_idx
  on public.buses(tour_id)       where deleted_at is null;
create index if not exists passengers_tour_live_idx
  on public.passengers(tour_id)  where deleted_at is null;
create index if not exists tours_owner_live_idx
  on public.tours(owner_id)      where deleted_at is null;


-- ── 4. Cascade protection ────────────────────────────────────
-- Soft delete only works if nothing hard-deletes a PARENT. A tour delete today
-- cascades to every child; once the client soft-deletes instead, that path is
-- unused — but a stray hard delete (an old build, a manual SQL DELETE) would
-- still destroy the books silently.
--
-- This trigger makes that impossible. Deleting a tour that still holds money
-- rows raises instead of cascading. The app is expected to soft-delete; this
-- is the backstop for everything that isn't the app.

create or replace function public.forbid_tour_hard_delete()
returns trigger
language plpgsql set search_path = public as $$
declare
  v_rows bigint;
begin
  select
      (select count(*) from public.collections   where tour_id = old.id)
    + (select count(*) from public.expenses      where tour_id = old.id)
    + (select count(*) from public.incomes       where tour_id = old.id)
    + (select count(*) from public.bus_handovers where tour_id = old.id)
    into v_rows;

  if v_rows > 0 then
    raise exception
      'tour % holds % money row(s) and cannot be hard-deleted; set deleted_at instead',
      old.id, v_rows
      using hint = 'update public.tours set deleted_at = now() where id = ...';
  end if;
  return old;
end $$;

drop trigger if exists tours_forbid_hard_delete on public.tours;
create trigger tours_forbid_hard_delete
  before delete on public.tours
  for each row execute function public.forbid_tour_hard_delete();


-- ── 5. Archive readback ──────────────────────────────────────
-- The ONLY sanctioned way to see deleted rows. Owner-scoped, read-only, and
-- explicit — so no ordinary screen can surface an archived tour by accident.

create or replace function public.deleted_tours()
returns table (
  id uuid, title text, deleted_at timestamptz, deleted_by uuid,
  money_rows bigint
)
language sql stable security definer set search_path = public as $$
  select t.id, t.title, t.deleted_at, t.deleted_by,
         (select count(*) from public.collections   c where c.tour_id = t.id)
       + (select count(*) from public.expenses      e where e.tour_id = t.id)
       + (select count(*) from public.incomes       i where i.tour_id = t.id)
       + (select count(*) from public.bus_handovers h where h.tour_id = t.id)
    from public.tours t
   where t.owner_id = auth.uid()
     and t.deleted_at is not null
   order by t.deleted_at desc;
$$;

revoke all on function public.deleted_tours() from public;
grant execute on function public.deleted_tours() to authenticated;


-- ============================================================
-- VERIFY AFTER APPLYING (all four must report `deleted_at IS NULL`):
--
--   select indexname, indexdef from pg_indexes
--    where indexname in ('collections_passenger_bus_seat_unique',
--                        'passengers_tour_phone_unique',
--                        'buses_owner_reg_unique',
--                        'buses_tour_reg_unique');
--
-- CONFIRM THE BACKSTOP BITES (must raise, not delete):
--
--   delete from public.tours where id = '<a tour that has collections>';
-- ============================================================
