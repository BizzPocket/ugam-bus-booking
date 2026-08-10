-- ============================================================
-- 084_revoke_internal_ledger_primitives.sql
-- ------------------------------------------------------------
-- Take the internal ledger primitives and one-off repair tools OFF the public
-- PostgREST API.
--
-- THE BUG
-- This repo's universal idiom is
--     revoke all on function public.X(...) from public;
-- with a comment explaining that X is internal. That idiom does not do what it
-- looks like it does, and 043_handler_ctx_lock_down.sql already documents why,
-- with a captured production response:
--
--   "`revoke all on function ... from public` only drops the implicit PUBLIC
--    grant. Supabase ships a default-privileges rule that grants EXECUTE on
--    newly created functions in `public` to `anon` and `authenticated`
--    DIRECTLY, and a revoke aimed at PUBLIC does not touch a role-specific
--    grant. So handler_ctx landed on the live PostgREST API surface."
--
-- 043 then issued the only role-targeted revoke in the whole repo, for exactly
-- one function. Every other function relying on the same idiom is still
-- exposed. 071's header is independent in-repo corroboration: calling
-- finance_resync_all_fares() -- granted only `to authenticated` -- over
-- PostgREST AS THE ANON ROLE reached the function body and failed on data, not
-- on permissions.
--
-- Several of these functions are worse still: 062 issues NO revoke and NO
-- grant at all, so finance_post_delta and finance_resync_passenger_fare sit on
-- pure Supabase defaults.
--
-- THIS IS NO LONGER AN INFERENCE. 080_revoke_anon_from_money_writers.sql
-- captured the live ACLs and found exactly this:
--     backfill_post          | {anon,authenticated,postgres,service_role}
--     backfill_reverse       | {anon,authenticated,postgres,service_role}
--     record_online_payment  | {anon,authenticated,postgres,service_role}
-- The default-privileges mechanism is therefore confirmed on THIS project, not
-- merely argued from 043. Everything below follows from measured behaviour.
--
-- RELATIONSHIP TO 080 -- READ BEFORE APPLYING
-- 080 already closes backfill_post and backfill_reverse (and
-- record_online_payment, which this file leaves alone -- see below). Those two
-- names are retained in the list here deliberately, so that this file is
-- self-sufficient and correct whether or not 080 was applied on this database.
-- A revoke of a privilege that is already gone is a silent no-op, so running
-- 080 and then this file is safe and changes nothing twice. 080 revokes from
-- anon and authenticated; this file also revokes from PUBLIC, which is
-- strictly more thorough.
--
-- WHAT IS ACTUALLY EXPOSED
--   * backfill_post / backfill_reverse -- raw double-entry primitives. No
--     auth.uid(), no owner check, no tour scope. A caller names a tour_id, an
--     amount and two account codes and a balanced pair of finance_lines lands
--     in the append-only ledger. The deferred balance invariant passes,
--     because the attacker's pair sums to zero.
--   * finance_post_delta / finance_resync_passenger_fare -- the same, one
--     level up.
--   * backfill_finance_ledger(p_tour_id default null) and
--     finance_resync_all_fares(p_tour_id default null) -- NULL means EVERY
--     TOUR ON THE PLATFORM. Heavyweight cross-tenant writes in one
--     transaction; an availability event as much as an integrity one.
--   * finance_repair_online_double_post / finance_repair_cancelled_fares --
--     reverse confirmed entries and rewrite collections platform-wide. Even
--     the p_apply=false dry run RETURNS TABLE across every tenant.
--   * capture_finance_baseline / verify_finance_backfill -- snapshot and read
--     per-bus revenue, cash, ground costs and the rent paid to bus owners, for
--     every tenant, on demand.
--   * finance_set_actor / finance_actor_* -- let a caller choose the actor
--     stamp their own writes are recorded under, forging attribution.
--   * handler_owns_bus, chart_seat_slot_usage -- internal helpers.
--
-- WHAT THIS FIX DOES
-- Revokes EXECUTE from public, anon AND authenticated on each of them,
-- iterating pg_proc and revoking by oid::regprocedure. It resolves signatures
-- from the live catalogue rather than hardcoding argument lists, because a
-- hand-written signature that does not match live is a SILENT no-op on the
-- wrong overload -- and this repo has real overload history (backfill_post is
-- redefined in 058, 062 and 072, and carries OUT parameters that must be
-- excluded from the identity).
--
-- WHY THIS BREAKS NOTHING
-- Verified by exhaustive grep across lib/ and supabase/functions/ at the time
-- of writing: ZERO call sites for every name in the list below. Nothing in the
-- Flutter app or any Edge Function invokes them.
--
-- Their real callers are other SECURITY DEFINER functions and triggers, which
-- execute as the function OWNER and therefore keep EXECUTE regardless of what
-- anon and authenticated hold. Each caller was checked individually:
--   * finance_post_delta / finance_resync_passenger_fare <- the 062
--     write-through triggers (finance_sync_collection, _expense, _income,
--     _handover, _passenger, _bus_rent) -- ALL declared `security definer`.
--   * backfill_post / backfill_reverse <- backfill_finance_ledger and
--     finance_post_delta, both definer.
--   * finance_actor_kind / _label <- audit_row() (056:436) and backfill_post
--     (062:108, 072:121), all definer.
--   * finance_set_actor <- confirm_payment_claim and the repair paths
--     (060:273, 064:613, 069:165/320/421), all definer.
--   * handler_owns_bus <- the 046/047 handler RPCs, all definer.
--   * chart_seat_slot_usage <- chart_hold_seats (064:130, definer) and
--     chart_validate_bus_seats (068, definer) -- this is the anon customer
--     booking path, so it was checked with particular care.
-- No call site is a policy expression, a column default, or an invoker-mode
-- trigger, which are the three contexts that WOULD evaluate as the caller.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT revoke public.current_user_role(). That function is called
--     from 001-era RLS POLICY EXPRESSIONS on passengers, tours and bus_details
--     (001:149-204), and a policy expression is evaluated AS THE CALLER. If any
--     of those policies survives on this database, revoking EXECUTE would make
--     every authenticated read or write of passengers or tours fail with
--     "permission denied for function current_user_role". Those stale policies
--     need dropping first, as their own change, after enumerating pg_policies
--     on live. Note database.sql:37 drops the function with CASCADE in the
--     from-scratch build, which suggests they are already gone there -- but
--     that cannot be assumed of a hand-migrated database.
--  2. It does NOT revoke record_online_payment. That is a money-path change
--     needing an explicit service_role assertion so the payment webhook keeps
--     working, and it is already handled twice over -- by 080 and, as an
--     idempotent backstop, by 085. Keeping it out of this file means a
--     rollback of this file cannot re-open a payment-fraud hole.
--  3. It does NOT run `alter default privileges in schema public revoke
--     execute on functions from anon, authenticated`. That would be the real
--     root-cause fix, but it silently inverts the contract every migration in
--     this repo is written against: the next hand-applied file that creates an
--     anon-facing RPC and relies on the default grant would ship a function
--     PostgREST cannot call, with no error at apply time. Doing that safely
--     means auditing and explicitly granting every existing anon-facing RPC
--     first. It is a project, not a line.
--  4. It does NOT add owner scoping to any of these bodies. Revoking is
--     reversible and behaviour-preserving; rewriting a ledger primitive is
--     neither. If one of the repair tools must later be reachable from the
--     admin app, give it an explicit tours.owner_id check and a targeted grant
--     at that point.
--
-- NOTE ON DURABILITY: `create or replace function` PRESERVES an existing ACL,
-- so these revokes survive a later redefinition of the same signature. A
-- migration that DROPS and recreates a function gets fresh Supabase defaults
-- and silently re-opens it. Re-run this file after any such change.
-- ============================================================

do $$
declare
  v_names   text[] := array[
    -- raw double-entry primitives (058 / 062 / 072)
    'backfill_post',
    'backfill_reverse',
    'finance_post_delta',
    'finance_resync_passenger_fare',
    -- platform-wide backfill / resync (058 / 070)
    'backfill_finance_ledger',
    'finance_resync_all_fares',
    -- one-off repair tools (069)
    'finance_repair_online_double_post',
    'finance_repair_cancelled_fares',
    -- cross-tenant baseline snapshot + reader (053 / 058)
    'capture_finance_baseline',
    'verify_finance_backfill',
    -- actor stamp: lets a caller forge the attribution on their own writes (056)
    'finance_set_actor',
    'finance_actor_kind',
    'finance_actor_label',
    'finance_actor_pid',
    -- internal helpers (046 / 064)
    'handler_owns_bus',
    'chart_seat_slot_usage'
  ];
  v_roles   text;
  v_found   int := 0;
  v_revoked int := 0;
  n         text;
  r         record;
begin
  -- Build the role list from the catalogue so this cannot fail on a project
  -- where one of the Supabase roles is absent or renamed.
  select string_agg(quote_ident(rolname), ', ')
    into v_roles
    from pg_roles
   where rolname in ('anon', 'authenticated');

  v_roles := concat_ws(', ', 'public', v_roles);

  foreach n in array v_names
  loop
    for r in
      select p.oid::regprocedure::text as sig
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public'
         and p.proname  = n
       order by 1
    loop
      v_found := v_found + 1;
      execute format('revoke execute on function %s from %s', r.sig, v_roles);
      v_revoked := v_revoked + 1;
      raise notice '084: revoked execute on % from %', r.sig, v_roles;
    end loop;

    if not exists (
      select 1 from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = n
    ) then
      raise notice '084: % not present on this database -- skipped.', n;
    end if;
  end loop;

  if v_found = 0 then
    raise notice '084: none of the listed functions exist here. Nothing to do.';
  else
    raise notice '084: % function overload(s) found, % revoke statement(s) issued. '
                 'Re-running this file is safe and is a no-op.', v_found, v_revoked;
  end if;
end $$;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. THE KEY CHECK. Expect ZERO rows. Any row is a function still callable
--    over PostgREST by anon or authenticated.
--
--   select p.oid::regprocedure as still_exposed, r.rolname
--     from pg_proc p
--     join pg_namespace ns on ns.oid = p.pronamespace
--     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
--     join pg_roles r on r.oid = a.grantee
--    where ns.nspname = 'public'
--      and a.privilege_type = 'EXECUTE'
--      and r.rolname in ('anon','authenticated')
--      and p.proname in (
--        'backfill_post','backfill_reverse','finance_post_delta',
--        'finance_resync_passenger_fare','backfill_finance_ledger',
--        'finance_resync_all_fares','finance_repair_online_double_post',
--        'finance_repair_cancelled_fares','capture_finance_baseline',
--        'verify_finance_backfill','finance_set_actor','finance_actor_kind',
--        'finance_actor_label','finance_actor_pid','handler_owns_bus',
--        'chart_seat_slot_usage')
--    order by 1, 2;
--
-- 2. FULL API SURFACE AUDIT -- what is still reachable by anon. Read this list
--    and confirm every entry is a DELIBERATE customer/handler API. This is the
--    single most valuable query in this migration set; run it and keep the
--    output.
--
--   select p.oid::regprocedure as anon_callable
--     from pg_proc p
--     join pg_namespace ns on ns.oid = p.pronamespace
--     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
--     join pg_roles r on r.oid = a.grantee
--    where ns.nspname = 'public'
--      and a.privilege_type = 'EXECUTE'
--      and r.rolname = 'anon'
--    order by 1;
--
-- 3. Direct negative test with the shipped publishable key -- must now fail
--    with 42501 / "permission denied", not with a data error:
--
--   curl -s -X POST -H "apikey: <publishable key>" \
--     -H 'Content-Type: application/json' -d '{}' \
--     "https://<project>.supabase.co/rest/v1/rpc/finance_resync_all_fares"
--
-- 4. SMOKE TEST -- every indirect caller must still work, because each one
--    reaches these functions through a SECURITY DEFINER boundary. Run all
--    five; 4d and 4e are the anon paths and matter most.
--    a. Admin: record a collection, an expense, an income and a handover.
--       Each must save (these fire the 062 write-through triggers ->
--       finance_post_delta).
--    b. Admin: edit a bus price band. Must save (buses_ledger_sync ->
--       finance_post_delta, and buses_audit -> finance_actor_kind).
--    c. Admin: confirm a UPI payment claim (-> finance_set_actor).
--    d. Customer (anon): hold seats from the public seat chart
--       (-> chart_hold_seats -> chart_seat_slot_usage).
--    e. Handler (anon): open the manifest and record cash on their own bus
--       (-> handler_upsert_* -> handler_owns_bus).
--
-- 5. Confirm the ledger still balances after 4a-4c:
--
--   select e.id, sum(l.amount_minor) as must_be_zero
--     from public.finance_entries e
--     join public.finance_lines l on l.entry_id = e.id
--    where e.created_at > now() - interval '30 minutes'
--    group by e.id having sum(l.amount_minor) <> 0;
--   -- expect zero rows
-- ============================================================
