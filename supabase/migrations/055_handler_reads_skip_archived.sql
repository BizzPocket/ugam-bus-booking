-- ============================================================
-- 055_handler_reads_skip_archived.sql   —   completes P1
-- ------------------------------------------------------------
-- After 054, an admin archiving a money row leaves it in the table. The
-- handler's read RPCs still aggregate straight off the base tables, so a
-- handler would keep seeing a row the admin already deleted — worse than
-- today, where the row genuinely disappears for both of them.
--
-- WHY THIS FILE PATCHES LIVE SOURCE INSTEAD OF RE-EMITTING
-- `handler_tour_manifest` is ~190 lines of SECURITY DEFINER SQL and the live
-- definitions have diverged from these migration files. Re-emitting from the
-- files would silently overwrite live with an older shape. Confirmed by the
-- live dump: `handler_bus_handovers` comes from 046 and looks NOTHING like
-- 045 — it has no `my_buses` CTE at all, authorising via
-- `handler_owns_bus(p_request_id, h.bus_id)` instead.
--
-- WHY IT PATCHES THE `FROM`, NOT THE `WHERE`
-- The first version matched one specific WHERE shape and correctly refused on
-- the live function. Chasing predicate shapes is a losing game, and injecting
-- into a WHERE is unsafe anyway: prefixing `x AND` onto `A OR B` silently
-- rebinds to `(x AND A) OR B` and archived rows leak back through the OR.
--
-- So each table reference is replaced with a pre-filtered subquery:
--     from public.collections col
--  -> from (select * from public.collections where deleted_at is null) col
--
-- That is precedence-proof, shape-agnostic, and works no matter how the
-- predicate is written. Postgres pulls the simple restriction up, so the
-- partial indexes from 054 are still used.
--
-- SAFETY: a bare `from public.X alias` pattern would also match
-- `delete from public.expenses ex` in the handler_delete_* functions and
-- produce `delete from (select ...) ex`, which is not valid SQL. Volatility is
-- not a usable guard (handler_tour_manifest is VOLATILE despite being
-- read-only), so each function is checked for write statements against the
-- specific table before it is touched.
--
-- Idempotent. Refuses loudly and changes nothing if a target no longer
-- matches. Requires 054.
-- Apply in the Supabase SQL editor, isolated, AFTER 054.
-- ============================================================

-- ── 0. Precondition: 054 must be live first ──────────────────
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'collections'
       and column_name  = 'deleted_at'
  ) then
    raise exception
      '055 requires 054_soft_delete.sql to be applied FIRST — collections.deleted_at does not exist yet'
      using hint = 'Run 054_soft_delete.sql in the SQL editor, then re-run this file.';
  end if;
end $$;


-- ── 1. Patch every handler READ of a money table ─────────────
do $$
declare
  -- (function, table, alias) as they appear in the live source.
  v_targets jsonb := '[
    {"fn":"handler_tour_manifest", "table":"collections",   "alias":"col"},
    {"fn":"handler_tour_manifest", "table":"expenses",      "alias":"ex"},
    {"fn":"handler_tour_manifest", "table":"incomes",       "alias":"inc"},
    {"fn":"handler_bus_handovers", "table":"bus_handovers", "alias":"h"}
  ]'::jsonb;

  v_t         jsonb;
  v_fn        text;
  v_table     text;
  v_alias     text;
  v_oid       oid;
  v_src       text;
  v_new       text;
  v_repl      text;
  v_done      int := 0;
  v_skipped   int := 0;
begin
  for v_t in select jsonb_array_elements(v_targets)
  loop
    v_fn    := v_t->>'fn';
    v_table := v_t->>'table';
    v_alias := v_t->>'alias';

    select p.oid into v_oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
     limit 1;

    if v_oid is null then
      raise notice '055: %() not present, skipping', v_fn;
      continue;
    end if;

    v_src  := pg_get_functiondef(v_oid);
    v_repl := 'from (select * from public.' || v_table ||
              ' where deleted_at is null) ' || v_alias;

    -- Already patched?
    if position(lower(v_repl) in lower(v_src)) > 0 then
      raise notice '055: %() . % already skips archived rows', v_fn, v_table;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Never rewrite a FROM that belongs to a write statement — the rewrite
    -- would emit `delete from (select ...)`, which will not parse.
    if v_src ~* ('delete\s+from\s+public\.' || v_table)
       or v_src ~* ('insert\s+into\s+public\.' || v_table)
       or v_src ~* ('update\s+public\.' || v_table) then
      raise exception
        '055: %() writes to public.% — refusing to rewrite its FROM clause. '
        'Money reads and writes must live in separate functions before this can '
        'be applied.', v_fn, v_table;
    end if;

    v_new := regexp_replace(
      v_src,
      'from\s+public\.' || v_table || '\s+' || v_alias || '(\s|$)',
      v_repl || '\1',
      'gi'
    );

    if v_new is not distinct from v_src then
      raise exception
        '055: could not find "from public.% %" in %(). Nothing was changed; '
        'inspect with: select pg_get_functiondef(''public.%''::regproc);',
        v_table, v_alias, v_fn, v_fn;
    end if;

    execute v_new;
    v_done := v_done + 1;
    raise notice '055: %() . % now skips archived rows', v_fn, v_table;
  end loop;

  raise notice '055: done — % patched, % already in place', v_done, v_skipped;
end $$;


-- ============================================================
-- VERIFY (each handler money read must be guarded):
--
--   select p.proname,
--          (select count(*) from regexp_matches(
--             pg_get_functiondef(p.oid), 'where deleted_at is null', 'gi')) as guards
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('handler_tour_manifest','handler_bus_handovers');
--
-- Expect handler_tour_manifest = 3  (collections, expenses, incomes)
--        handler_bus_handovers = 1
--
-- Then confirm a handler stops seeing an archived row:
--   update public.expenses set deleted_at = now() where id = '<an expense id>';
--   select jsonb_array_length(public.handler_tour_manifest('<request id>')->'expenses');
-- ============================================================
