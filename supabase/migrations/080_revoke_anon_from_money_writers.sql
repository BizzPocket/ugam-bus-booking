-- ============================================================
-- 080_revoke_anon_from_money_writers.sql
-- ------------------------------------------------------------
-- URGENT. Three money-writing functions are executable by `anon` on the live
-- database. Confirmed, not inferred:
--
--   proname                | can_execute
--   -----------------------+------------------------------------------------
--   backfill_post          | {anon,authenticated,postgres,service_role}
--   backfill_reverse       | {anon,authenticated,postgres,service_role}
--   record_online_payment  | {anon,authenticated,postgres,service_role}
--
-- `anon` here is not an abstraction. The publishable key is a compile-time
-- constant at lib/config/supabase_config.dart:5 and ships inside every APK and
-- IPA, so the credential is available to anyone who downloads the app and
-- unzips it. No account, no session, no booking.
--
-- WHAT THAT ALLOWS TODAY
--   record_online_payment — mark any Razorpay order as paid, without paying.
--   backfill_post         — write arbitrary double-entry rows against any
--                           tenant's ledger.
--   backfill_reverse      — reverse any entry, on any tenant.
--
-- The ledger TABLES are correctly owner-scoped for SELECT (056:173, 056:210).
-- These are SECURITY DEFINER functions, so they bypass that entirely — the
-- grant IS the boundary, and the boundary was open.
--
-- WHY IT HAPPENED, AND WHY IT WILL HAPPEN AGAIN
-- The intent was already correct. 049:287-290 reads:
--
--     revoke all on function public.record_online_payment(...) from public;
--     -- Deliberately NOT granted to anon: only the Edge Functions (service role)
--
-- The comment is right and the code does not achieve it. In Supabase, `anon`
-- and `authenticated` hold EXECUTE through their own grants, applied by the
-- platform's default privileges — NOT through PUBLIC. `revoke ... from public`
-- removes a grant those roles never relied on and leaves theirs untouched.
--
-- Every migration in this repo that says `revoke all ... from public` and then
-- grants to a narrower role has the same hole wherever the platform default
-- reached first. This file closes the three that move money. The VERIFY block
-- at the bottom enumerates the rest for triage — do not blanket-revoke them:
-- several are legitimately anon-callable (customer booking, the handler gate,
-- claim_upi_advance_for_hold) and revoking those would take the app down.
--
-- BLAST RADIUS: NONE.
--   - Zero callers in lib/ (grep across every .dart: no hits).
--   - Zero callers in supabase/functions/.
--   - Every real caller is another SECURITY DEFINER function — 049, 058, 060,
--     062, 064, 069, 072, 073, 077 — and an internal call executes as the
--     function OWNER, not as the session role. Grants to anon are irrelevant
--     to those paths.
--   - service_role and postgres keep EXECUTE, so the Edge Functions that were
--     always the intended caller of record_online_payment are unaffected.
--
-- Revoking from `authenticated` as well as `anon`: none of the three has an
-- authenticated caller either, and a signed-in tour operator has no business
-- hand-posting ledger rows or settling orders.
--
-- Idempotent, re-runnable, changes no data.
-- ============================================================

do $$
declare
  r       record;
  v_count int := 0;
begin
  -- Loop over pg_proc rather than naming signatures: these functions have long
  -- argument lists and at least one has been re-issued with a changed shape.
  -- A hardcoded signature that no longer matches would silently revoke nothing
  -- and this file would report success while the hole stayed open.
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'record_online_payment',
         'backfill_post',
         'backfill_reverse'
       )
  loop
    execute format('revoke execute on function %s from anon', r.sig);
    execute format('revoke execute on function %s from authenticated', r.sig);
    raise notice '080: revoked anon/authenticated EXECUTE on %', r.sig;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception
      '080 matched no functions. Expected record_online_payment, backfill_post '
      'and backfill_reverse in schema public. Nothing was changed — check the '
      'names before assuming this is fixed.';
  end if;
end $$;


-- ============================================================
-- VERIFY
--
-- 1. The hole is closed. anon and authenticated must be GONE from all three:
--
--      select p.proname, p.oid::regprocedure as sig,
--             array_agg(distinct a.rolname) as can_execute
--        from pg_proc p
--        join pg_namespace n on n.oid = p.pronamespace
--        left join aclexplode(p.proacl) ac on true
--        left join pg_roles a on a.oid = ac.grantee
--       where n.nspname = 'public'
--         and p.proname in ('record_online_payment','backfill_post','backfill_reverse')
--       group by 1,2;
--
--    expect {postgres,service_role} — NOT anon, NOT authenticated.
--
-- 2. Money still flows. Confirm a UPI claim end to end: confirm_payment_claim
--    calls backfill_post internally and must still succeed, because a definer
--    function executes as its owner.
--
--      select public.confirm_payment_claim('<a pending claim id>');
--
--    If this now fails with "permission denied for function backfill_post",
--    the assumption above is wrong for this database and 080 must be reverted:
--      grant execute on function public.backfill_post(...) to authenticated;
--
-- 3. TRIAGE THE REST. This is the important one — 080 fixes three functions,
--    not the pattern. List every SECURITY DEFINER function anon can execute:
--
--      select p.proname, p.oid::regprocedure as sig
--        from pg_proc p
--        join pg_namespace n on n.oid = p.pronamespace
--       where n.nspname = 'public'
--         and p.prosecdef                        -- SECURITY DEFINER only
--         and has_function_privilege('anon', p.oid, 'EXECUTE')
--       order by 1;
--
--    Then decide each one deliberately. Several SHOULD be there — customer
--    booking, the handler gate, claim_upi_advance_for_hold, the public tour
--    reads. Blanket-revoking this list will take the app down. The question
--    for each is: "if a stranger with the APK calls this with arbitrary
--    arguments, what is the worst that happens?"
-- ============================================================
