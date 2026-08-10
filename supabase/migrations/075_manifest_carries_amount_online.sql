-- ============================================================
-- 075_manifest_carries_amount_online.sql
-- ------------------------------------------------------------
-- `handler_tour_manifest` builds its collections array key by key, and
-- `amount_online` is not one of the keys. So the handler app receives every
-- online UPI advance as though it were cash in the handler's pocket.
--
-- WHAT THAT COSTS
-- The figure flows into the handler's "in hand" and "outstanding", and into the
-- pre-filled amount on the handover sheet — the number the handler is asked to
-- physically produce. Meanwhile `finance_bus_summary` (063) restricts
-- `collected_minor` to `cash.handler` receipts, so the LEDGER already excludes
-- the online take. The two disagree by exactly the online amount, and they
-- disagree at the moment cash changes hands.
--
-- The Dart side of this fix (Collection.amountOnline, the netCash getter, the
-- direct PostgREST projection) is in the same commit as this file. This
-- migration is the half that feeds the handler surface, which reads the RPC
-- rather than the table.
--
-- WHY A TEXT PATCH AND NOT A REDEFINITION
-- Same reason 055 gave: this function is ~190 lines of SECURITY DEFINER SQL and
-- the live body has drifted from what any single migration file says. 044
-- defines the projection, but 055 has already rewritten the live source in
-- place, and the repo's own notes record that the remote migration history is
-- empty and files are applied by hand. Re-issuing 044's body would silently
-- revert 055's soft-delete filter and anything else applied since. So: find the
-- key that is definitely there, insert the new one beside it, and refuse loudly
-- if the anchor is missing rather than guessing.
--
-- Idempotent: re-running detects the key is already present and does nothing.
-- Changes no data.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'collections'
       and column_name  = 'amount_online'
  ) then
    raise exception
      '075 requires the collections.amount_online column (069_online_payment_'
      'single_post.sql) to be applied FIRST';
  end if;
end $$;


do $$
declare
  v_oid    oid;
  v_src    text;
  v_new    text;
  -- The anchor: the key immediately before the one being added. Present in
  -- every version of this function since 044.
  c_anchor constant text := '''amount_received'', col.amount_received,';
  c_added  constant text :=
    '''amount_received'', col.amount_received,' || E'\n' ||
    '                     ''amount_online'',   col.amount_online,';
begin
  select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'handler_tour_manifest'
   limit 1;

  if v_oid is null then
    raise exception
      '075: handler_tour_manifest() is not present. It is the handler app''s '
      'only read path; apply 044_handler_manifest_pickup.sql first.';
  end if;

  v_src := pg_get_functiondef(v_oid);

  if position('''amount_online''' in v_src) > 0 then
    raise notice '075: handler_tour_manifest already carries amount_online';
    return;
  end if;

  if position(c_anchor in v_src) = 0 then
    raise exception
      '075: could not find the amount_received key in handler_tour_manifest(). '
      'Nothing was changed. Inspect the live body with: '
      'select pg_get_functiondef(''public.handler_tour_manifest''::regproc);';
  end if;

  v_new := replace(v_src, c_anchor, c_added);

  if v_new is not distinct from v_src then
    raise exception '075: patch produced no change; refusing to continue';
  end if;

  execute v_new;
  raise notice '075: handler_tour_manifest now carries amount_online';
end $$;


-- ============================================================
-- VERIFY
--
--   -- The key is in the live body (0 before this file, 1 after):
--   select count(*) from pg_proc
--    where proname = 'handler_tour_manifest'
--      and prosrc like '%amount_online%';
--
--   -- 055's soft-delete filter must have SURVIVED the rewrite. If this is 0,
--   -- the patch clobbered it and 055 needs re-applying:
--   select count(*) from pg_proc
--    where proname = 'handler_tour_manifest'
--      and prosrc like '%where deleted_at is null) col%';
--
--   -- End to end: a rider with a UPI advance must come back with the online
--   -- slice separated, not folded into amount_received alone.
--   select jsonb_path_query(
--            public.handler_tour_manifest('<request id>'),
--            '$.collections[*] ? (@.amount_online > 0)');
-- ============================================================
