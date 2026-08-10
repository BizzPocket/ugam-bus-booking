-- ============================================================
-- 085_record_online_payment_service_role_only.sql
-- ------------------------------------------------------------
-- Make record_online_payment reachable only by the service role, as 049
-- always intended and never enforced.
--
-- OVERLAP WITH 080 -- READ FIRST.
-- 080_revoke_anon_from_money_writers.sql also revokes this function, and it
-- did so on the strength of a captured LIVE ACL:
--     record_online_payment | {anon,authenticated,postgres,service_role}
-- If 080 has been applied here, this file is a no-op and can be skipped. It is
-- kept as an idempotent backstop for two reasons: the two files may not travel
-- together, and this one additionally revokes from PUBLIC and ASSERTS the
-- service_role grant rather than relying on the platform default surviving.
-- Running both, in either order, is safe.
--
-- THE BUG
-- 049_online_advance_payment.sql:287 ends with:
--
--     revoke all on function public.record_online_payment(
--       text, text, bigint, text, text, text, jsonb
--     ) from public;
--     -- Deliberately NOT granted to anon: only the Edge Functions (service
--     -- role) may mark money as received.
--
-- The comment asserts an access control the SQL does not implement. Per the
-- mechanism 043 verified against production, `revoke ... from public` does not
-- remove Supabase's default role-specific EXECUTE grant to anon and
-- authenticated. So the function that MARKS MONEY AS RECEIVED is on the public
-- PostgREST API, callable with the publishable key that ships in the APK.
--
-- The body flips a payment_attempts row to status='paid' with the caller's
-- chosen paid_paise and verified_by. It performs no HMAC/signature check, no
-- Razorpay callback verification and no auth.uid() check -- correctly, because
-- it was designed to be called only by a trusted webhook that had already done
-- that work. Being reachable by anon removes the only thing that made those
-- omissions safe.
--
-- THE ATTACK
--   1. Start a real checkout in the customer app. The client legitimately
--      receives its own rzp_order_id -- that is how the Razorpay handoff works.
--   2. Abandon the payment.
--   3. POST /rest/v1/rpc/record_online_payment with the anon key:
--        {"p_rzp_order_id":"<own order id>","p_rzp_payment_id":"fake",
--         "p_paid_paise":1,"p_verified_by":"webhook"}
--   4. The row flips to paid, stamped verified_by='webhook' -- the value the
--      code treats as authoritative over the client callback -- and
--      paid_paise is whatever the caller passed. A 5,000 rupee advance can be
--      recorded as one paisa.
-- The organiser reconciles against an advance that never arrived.
--
-- WHAT THIS FIX DOES
-- Revokes EXECUTE from public, anon and authenticated, then grants it to
-- service_role, which is the role the Edge Function key carries. Signatures
-- are resolved from the live catalogue rather than hardcoded, so an overload
-- that drifted from the file cannot be missed silently.
--
-- WHY THIS IS SAFE
-- record_online_payment has ZERO callers in the repo: exhaustive grep across
-- lib/ and supabase/functions/ returns nothing, and the only other mention
-- anywhere is a comment in 060:29 describing it as "the verified path". The
-- Flutter client never calls it and must never be able to -- a client that
-- could mark its own order paid is the whole defect.
--
-- The webhook that legitimately calls it is deployed out of band (there is no
-- razorpay function directory in supabase/functions/), so its access must be
-- preserved by the explicit service_role grant below rather than assumed.
-- Note that service_role does NOT bypass function EXECUTE privileges the way
-- it bypasses RLS -- it is an ordinary role for this purpose and currently
-- holds EXECUTE only via the same Supabase default that this file strips from
-- anon. Removing that default WITHOUT the grant would break the webhook. That
-- is precisely why this is its own migration and not folded into 084.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT add signature/HMAC verification to the body. That belongs in
--     the webhook, which is where the Razorpay secret lives, and it is not a
--     database change.
--  2. It does NOT bound p_paid_paise or validate p_verified_by. Once only the
--     webhook can call this, those are its inputs to get right. Bounding them
--     here would be a behavioural change to a money path with no caller in
--     this repo to test against.
--  3. It does NOT touch payment_attempts RLS (049:222-223), which is already
--     correctly owner-scoped, or razorpay_webhook_events (049:241), which is
--     already RLS-on-with-no-policies -- the pattern this file is moving
--     record_online_payment towards.
-- ============================================================

do $$
declare
  v_revoke_roles text;
  v_found        int := 0;
  r              record;
begin
  if not exists (
    select 1 from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.proname = 'record_online_payment'
  ) then
    raise notice '085: public.record_online_payment does not exist here -- 049 not '
                 'applied. Nothing to do.';
    return;
  end if;

  select string_agg(quote_ident(rolname), ', ')
    into v_revoke_roles
    from pg_roles
   where rolname in ('anon', 'authenticated');

  v_revoke_roles := concat_ws(', ', 'public', v_revoke_roles);

  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.proname  = 'record_online_payment'
     order by 1
  loop
    v_found := v_found + 1;

    execute format('revoke execute on function %s from %s', r.sig, v_revoke_roles);
    raise notice '085: revoked execute on % from %', r.sig, v_revoke_roles;

    -- Re-grant to the webhook's role. Guarded: on a project without
    -- service_role we must NOT silently leave the function uncallable by
    -- anyone, so say so loudly.
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute format('grant execute on function %s to service_role', r.sig);
      raise notice '085: granted execute on % to service_role', r.sig;
    else
      raise warning '085: role service_role does NOT exist -- % is now callable by '
                    'no application role. If a payment webhook uses this, grant it '
                    'the appropriate role before taking payments.', r.sig;
    end if;
  end loop;

  raise notice '085: % overload(s) of record_online_payment locked to service_role. '
               'Re-running this file is safe and is a no-op.', v_found;
end $$;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. Expect exactly one row per overload: service_role. Expect NO anon and NO
--    authenticated.
--
--   select p.oid::regprocedure as fn, r.rolname
--     from pg_proc p
--     join pg_namespace ns on ns.oid = p.pronamespace
--     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
--     join pg_roles r on r.oid = a.grantee
--    where ns.nspname = 'public'
--      and p.proname = 'record_online_payment'
--      and a.privilege_type = 'EXECUTE'
--    order by 1, 2;
--
-- 2. ATTACKER VIEW -- must now be denied. Use a REAL order id from your own
--    test checkout so that a 200 would be unambiguous evidence of the hole.
--    Expect HTTP 404 with code 42883, or 403/42501 -- anything but success.
--
--   curl -s -X POST \
--     -H "apikey: <publishable key>" \
--     -H 'Content-Type: application/json' \
--     -d '{"p_rzp_order_id":"<a real test order id>","p_rzp_payment_id":"probe",
--          "p_paid_paise":1,"p_verified_by":"webhook"}' \
--     "https://<project>.supabase.co/rest/v1/rpc/record_online_payment"
--
-- 3. Confirm that probe changed nothing:
--
--   select id, status, paid_paise, verified_by, updated_at
--     from public.payment_attempts
--    where rzp_order_id = '<the same test order id>';
--   -- status must NOT be 'paid'
--
-- 4. SMOKE TEST -- the real money path must still complete end to end. There
--    is no substitute for this one, because the legitimate caller is deployed
--    out of band and is not in this repo:
--    a. Run one genuine online advance payment through the customer app to
--       completion.
--    b. Confirm the payment_attempts row reaches status='paid' with the
--       correct paid_paise.
--    c. Confirm the advance appears against the booking in the organiser's
--       money view.
--    If (b) fails, the webhook is not running as service_role. Find the role
--    it actually uses and grant EXECUTE to that role -- do NOT re-grant to
--    anon.
--
-- ROLLBACK (only if the webhook cannot be fixed quickly and payments are
-- blocked -- this restores the vulnerability, so treat it as an incident):
--   grant execute on function public.record_online_payment(
--     text, text, bigint, text, text, text, jsonb) to authenticated;
-- ============================================================
