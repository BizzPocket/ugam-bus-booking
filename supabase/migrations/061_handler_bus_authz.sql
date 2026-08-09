-- ============================================================
-- 061_handler_bus_authz.sql   —   close the handler cross-bus gap
-- ------------------------------------------------------------
-- THE HOLE, confirmed against the live schema dump:
--
--   handler_upsert_expense / handler_upsert_income authorise the TOUR, not the
--   BUS. Both contain exactly this:
--
--       if not exists (
--         select 1 from public.buses b
--          where b.id = v_bus_id and b.tour_id = v_tour_id
--       ) then return null; end if;
--
--   `is_request_handler()` only proves the caller handles SOME bus on the tour.
--   So any handler can post an expense or an income against ANY OTHER
--   handler's bus, moving costs onto someone else's books and changing what
--   that handler is expected to hand over.
--
--   handler_delete_expense / handler_delete_income are worse: tour-scoped AND
--   a hard DELETE, so one handler can destroy another's money row outright.
--
-- The newer functions already do this correctly — handler_upsert_handover uses
-- `handler_owns_bus(p_request_id, v_bus_id)` and handler_delete_handover uses
-- `handler_owns_bus(p_request_id, h.bus_id)`. This file brings the older four
-- up to that same standard, and completes 054 by making the two deletes
-- ARCHIVE instead of destroy.
--
-- Patches the LIVE source (pg_get_functiondef + targeted regex) rather than
-- re-emitting from the migration files, for the reason 055 documents: the live
-- definitions have diverged from the files before. Each patch must change
-- something or the whole block RAISEs and nothing is applied.
--
-- Idempotent. Requires 054. Apply in the SQL editor, isolated.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_entries') is null then
    raise exception '061 expects the finance rebuild chain (053-058) applied first';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='handler_owns_bus') then
    raise exception '061 requires handler_owns_bus() (migration 046)';
  end if;
end $$;


-- ── 1. Bus-scope the two upserts ─────────────────────────────
do $$
declare
  v_fn      text;
  v_oid     oid;
  v_src     text;
  v_new     text;
  v_done    int := 0;
  v_already int := 0;
begin
  foreach v_fn in array array['handler_upsert_expense','handler_upsert_income']
  loop
    select p.oid into v_oid from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname = v_fn limit 1;
    if v_oid is null then
      raise notice '061: %() absent, skipping', v_fn; continue;
    end if;

    v_src := pg_get_functiondef(v_oid);

    if v_src ~* 'handler_owns_bus' then
      raise notice '061: %() already bus-scoped', v_fn;
      v_already := v_already + 1;
      continue;
    end if;

    -- Narrow the existing tour check with an ownership test. Appending to the
    -- predicate is safe here because it is a bare AND-chain with no OR.
    v_new := regexp_replace(
      v_src,
      '(where\s+b\.id\s*=\s*v_bus_id\s+and\s+b\.tour_id\s*=\s*v_tour_id)',
      E'\\1\n       and public.handler_owns_bus(p_request_id, v_bus_id)',
      'gi'
    );

    if v_new is not distinct from v_src then
      raise exception
        '061: could not find the tour-only bus check in %(). Nothing changed; '
        'inspect with: select pg_get_functiondef(''public.%''::regproc);', v_fn, v_fn;
    end if;

    execute v_new;
    v_done := v_done + 1;
    raise notice '061: %() is now scoped to the caller''s own bus', v_fn;
  end loop;

  raise notice '061: upserts — % patched, % already correct', v_done, v_already;
end $$;


-- ── 2. Make the two deletes archive, and bus-scope them ──────
-- Completes 054 for the handler paths: `smartDelete` on the admin side already
-- archives, but these RPCs still destroyed the row outright.
do $$
declare
  t         record;
  v_oid     oid;
  v_src     text;
  v_new     text;
  v_done    int := 0;
  v_already int := 0;
begin
  for t in
    select * from (values
      ('handler_delete_expense', 'expenses', 'ex',  'p_expense_id'),
      ('handler_delete_income',  'incomes',  'inc', 'p_income_id')
    ) as v(fn, tbl, alias, param)
  loop
    select p.oid into v_oid from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname = t.fn limit 1;
    if v_oid is null then
      raise notice '061: %() absent, skipping', t.fn; continue;
    end if;

    v_src := pg_get_functiondef(v_oid);

    if v_src ~* 'deleted_at\s*=\s*now\(\)' and v_src ~* 'handler_owns_bus' then
      raise notice '061: %() already archives and is bus-scoped', t.fn;
      v_already := v_already + 1;
      continue;
    end if;

    -- delete ... where <alias>.id = <param> and <alias>.tour_id = v_tour_id
    --   ->  update ... set deleted_at = now() where <same> and not already
    --       archived and the caller owns the bus
    v_new := regexp_replace(
      v_src,
      'delete\s+from\s+public\.' || t.tbl || '\s+' || t.alias ||
      '\s+where\s+' || t.alias || '\.id\s*=\s*' || t.param ||
      '\s+and\s+' || t.alias || '\.tour_id\s*=\s*v_tour_id',
      'update public.' || t.tbl || ' ' || t.alias ||
      E'\n     set deleted_at = now()\n   where ' || t.alias || '.id = ' || t.param ||
      E'\n     and ' || t.alias || '.tour_id = v_tour_id' ||
      E'\n     and ' || t.alias || '.deleted_at is null' ||
      E'\n     and public.handler_owns_bus(p_request_id, ' || t.alias || '.bus_id)',
      'gi'
    );

    if v_new is not distinct from v_src then
      raise exception
        '061: could not find the hard-delete statement in %(). Nothing changed; '
        'inspect with: select pg_get_functiondef(''public.%''::regproc);', t.fn, t.fn;
    end if;

    execute v_new;
    v_done := v_done + 1;
    raise notice '061: %() now archives, scoped to the caller''s own bus', t.fn;
  end loop;

  raise notice '061: deletes — % patched, % already correct', v_done, v_already;
end $$;


-- ============================================================
-- VERIFY — all four must report true:
--
--   select p.proname,
--          pg_get_functiondef(p.oid) ~* 'handler_owns_bus' as bus_scoped,
--          pg_get_functiondef(p.oid) ~* 'delete\s+from'    as still_hard_deletes
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname='public'
--      and p.proname in ('handler_upsert_expense','handler_upsert_income',
--                        'handler_delete_expense','handler_delete_income')
--    order by p.proname;
--
-- Expect bus_scoped = true for all four, still_hard_deletes = false for the
-- two delete functions.
-- ============================================================
