-- ============================================================
-- 087_finance_views_security_invoker.sql
-- ------------------------------------------------------------
-- Every finance view in this schema may be handing each operator every OTHER
-- operator's money.
--
-- THE MECHANISM
-- From PostgreSQL 15 a view is created with `security_invoker = false` unless
-- told otherwise. With that default, the view body executes with the
-- privileges of the view's OWNER, and row-level security on the underlying
-- tables is evaluated against the OWNER — not against the caller. The owner
-- here is the migration role, which owns finance_lines and finance_entries,
-- and RLS never applies to a table's owner unless FORCE is set.
--
-- Net effect: the owner-scoped policies at 056:173 and 056:210 are real and
-- correct on the TABLES, and are bypassed entirely when the same rows are read
-- through a view. A grep for `security_invoker` across every migration
-- (001-086) returns nothing, and no table has FORCE ROW LEVEL SECURITY.
--
-- WHAT READS THEM
-- lib/services/ledger_money_source.dart queries three of these directly over
-- PostgREST as the signed-in operator:
--     :80  finance_tour_summary
--     :108 finance_bus_summary      -- and fetchAllBusRollups() passes NO
--                                      tour filter at all
--     :124 finance_rider_balance
-- The docstring on fetchAllBusRollups reads "All bus rollups visible to the
-- signed-in owner (RLS)". That comment states the intended contract. This file
-- is about making it true.
--
-- finance_bus_summary carries collected_minor, billed_minor, rent_minor and
-- owner_unpaid_minor per bus; finance_rider_balance carries per-passenger
-- balances. Cross-tenant, unfiltered, that is a competitor's whole book.
--
-- HONESTY ABOUT WHAT IS PROVEN
-- The mechanism is documented Postgres behaviour and the absence of
-- security_invoker is verified in the files. What is NOT verified is the live
-- owner of each view and whether this project's Postgres is 15+. The pre-flight
-- below reports both as notices before changing anything — read them.
--
-- THE RISK OF THE FIX, STATED PLAINLY
-- Turning on security_invoker makes these views obey RLS as the caller. If the
-- underlying policies do not admit the operator to their OWN rows, the money
-- screens go to zero instead of showing another tenant's data. That is a
-- visible, immediate, single-line-revertible regression — and it is strictly
-- better than the alternative, which is silent cross-tenant disclosure.
--
-- DO NOT deploy this at the same time as anything else. Deploy it, open the
-- Finance screen and one tour's money board as a real operator, and confirm
-- the numbers are unchanged. If they are zero, revert with the line at the
-- bottom and tell me — that means the table policies need work before the
-- views can be tightened, which is a different job.
--
-- Idempotent. Changes no data.
-- ============================================================

-- ── Pre-flight: report, do not assume ────────────────────────
do $$
declare
  v_major int;
  r       record;
begin
  select current_setting('server_version_num')::int / 10000 into v_major;
  raise notice '087: PostgreSQL major version %', v_major;

  if v_major < 15 then
    raise exception
      '087 requires PostgreSQL 15+ for security_invoker. This server is %. '
      'On an older server the views must be replaced with security-definer '
      'functions instead — a different and larger change.', v_major;
  end if;

  for r in
    select c.relname,
           pg_get_userbyid(c.relowner) as owner,
           coalesce((
             select option_value from pg_options_to_table(c.reloptions)
              where option_name = 'security_invoker'
           ), 'false') as security_invoker
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
       and c.relname like 'finance_%'
     order by 1
  loop
    raise notice '087: view % owner=% security_invoker=%',
      r.relname, r.owner, r.security_invoker;
  end loop;
end $$;


-- ── Apply ────────────────────────────────────────────────────
do $$
declare
  r       record;
  v_count int := 0;
begin
  -- Every finance_* view, discovered from the catalogue rather than listed:
  -- 053, 056, 063 and 076 each define one, and a hardcoded list would miss the
  -- next one somebody adds.
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
       and c.relname like 'finance_%'
     order by 1
  loop
    execute format(
      'alter view public.%I set (security_invoker = true)', r.relname);
    v_count := v_count + 1;
    raise notice '087: % now evaluates RLS as the CALLER', r.relname;
  end loop;

  if v_count = 0 then
    raise exception
      '087 found no finance_* views in schema public. Expected at least '
      'finance_balances, finance_bus_summary, finance_rider_balance, '
      'finance_baseline_tour and finance_tour_summary. Nothing changed.';
  end if;

  raise notice '087: % view(s) switched to security_invoker.', v_count;
end $$;


-- ============================================================
-- VERIFY — do all four. The first two are not sufficient on their own.
--
-- 1. The setting took:
--
--      select c.relname,
--             (select option_value from pg_options_to_table(c.reloptions)
--               where option_name = 'security_invoker') as security_invoker
--        from pg_class c join pg_namespace n on n.oid = c.relnamespace
--       where n.nspname = 'public' and c.relkind = 'v'
--         and c.relname like 'finance_%' order by 1;
--      -- expect 'true' on every row
--
-- 2. AS A REAL OPERATOR, in the app: open Finance and one tour's money board.
--    Every figure must be UNCHANGED from before this migration. If anything
--    reads zero, revert (below) — the table policies, not the views, are the
--    problem.
--
-- 3. THE ACTUAL TEST — cross-tenant. With two operator accounts, or one
--    account and a tour it does not own:
--
--      -- as operator A, note the count
--      select count(*) from public.finance_bus_summary;
--      -- as operator B
--      select count(*) from public.finance_bus_summary;
--
--    Before 087 these were probably EQUAL and equal to the whole table. After,
--    each must see only their own tours. If they are still equal and non-zero,
--    the leak is elsewhere — check the view owner from the pre-flight notice.
--
-- 4. Confirm the app still writes money correctly: record one collection and
--    one handover. The ledger write path goes through SECURITY DEFINER
--    functions and does not read these views, so this should be unaffected —
--    verify rather than assume.
--
-- ROLLBACK (single line per view; restores the previous behaviour INCLUDING
-- the cross-tenant read, so treat using it as an incident to be followed up):
--
--   alter view public.finance_bus_summary   set (security_invoker = false);
--   alter view public.finance_rider_balance set (security_invoker = false);
--   alter view public.finance_tour_summary  set (security_invoker = false);
--   alter view public.finance_balances      set (security_invoker = false);
--   alter view public.finance_baseline_tour set (security_invoker = false);
-- ============================================================
