-- ============================================================
-- 086_audit_log_deny_read.sql
-- ------------------------------------------------------------
-- Defect register #12. Close the cross-tenant read on public.audit_log.
--
-- THE BUG
-- 056_finance_ledger.sql:398 shipped the audit trail with:
--
--     create policy "audit_log_read" on public.audit_log
--       for select to authenticated using (true);
--
-- `using (true)` with no tenant predicate, on a table that stores WHOLE-ROW
-- before/after jsonb snapshots. public.audit_row() (056:401) does
-- `to_jsonb(old)` / `to_jsonb(new)` with no column allowlist and is attached to
-- six money tables: collections, expenses, incomes, bus_handovers and buses
-- (056:443-458) plus payment_claims (060:392). So one unfiltered GET returns,
-- for EVERY operator on the platform:
--   * payment_claims  -> payer_name, payer_phone, upi_ref, amount_paise
--   * buses           -> driver_name/phone, owner_name/phone, registration_no,
--                        bus_price (the rent), the whole price_bands jsonb and
--                        the entire seat `layout`
--   * collections     -> amount_due / received / online / refunded per seat
--   * expenses/incomes/bus_handovers -> every amount, note and payer
-- ...plus op, at and txid, so the reader reconstructs a rival's complete
-- trading history over time, including superseded and deleted values. That is
-- strictly worse than reading the live tables.
--
-- WHY IT HAPPENED
-- audit_log has no tenant key. There is no tour_id and no owner_id on the
-- table, so there was nothing convenient to scope by, and `using (true)` was
-- the path of least resistance next to a comment reading "Read-only to the
-- app". It is the ONLY `using (true)` in 056 — every sibling object in that
-- same file (finance_settlements :120, finance_entries :173, finance_lines
-- :210, finance_entries_held :364) correctly resolves tours.owner_id.
--
-- WHAT THIS FIX DOES
-- Removes every SELECT policy from the table and leaves RLS ENABLED with no
-- policies at all. That is deny-by-default: nobody but service_role (and the
-- SQL editor) can read it. This is the exact pattern 049:241 already uses for
-- razorpay_webhook_events, and the repo documents it there as correct.
--
-- It drops EVERY policy the live table actually carries, not just the one name
-- 056 created. Postgres ORs permissive policies, so dropping one name while an
-- out-of-band duplicate survives would change nothing -- and this repo has
-- documented drift (043 caught a production grant contradicting its own
-- migration's intent).
--
-- NOTHING READS THIS TABLE. Verified by exhaustive grep at the time of
-- writing: `audit_log` appears in exactly two files repo-wide -- its definition
-- in 056 and the defect register markdown. Zero hits in lib/, zero in test/,
-- zero in supabase/functions/. It is in no view, no RPC body, no realtime
-- publication (realtime_service.dart carries only tours/passengers/buses/
-- bookingRequests) and no sync projection. Dropping the policy costs no
-- feature.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT set `force row level security`. This is the important one.
--     audit_row() is SECURITY DEFINER and owned by the same role that owns the
--     table, so it writes by owner exemption. There is NO insert policy on this
--     table and never has been. Adding FORCE would subject the owner to RLS and
--     abort every audited write -- meaning every collection, expense, income,
--     handover, bus edit and payment claim would fail, for the admin app AND
--     the handler app, mid-trip, presenting as an unexplained save failure. The
--     table comment below records that prohibition permanently.
--     Proof the owner bypass is what is holding writes up today: RLS is already
--     enabled with no INSERT policy, so if it were not, every money write would
--     already be failing. They are not.
--  2. It does NOT add an owner_id column or a tenant-scoped read policy. That
--     is a schema change plus an audit_row() rewrite, and it is only worth
--     doing if an in-app audit-history UI is actually wanted. None exists and
--     none is planned. Read the trail out-of-band with the service key.
--  3. It does NOT touch the six audit triggers or audit_row() itself. The trail
--     keeps recording exactly as before; only the read door closes.
--
-- SAFETY OF THE REVOKE BELOW: a SELECT policy gates only SELECT and the USING
-- half of UPDATE/DELETE. audit_row()'s INSERT (056:431-437) has no RETURNING,
-- no ON CONFLICT and no read-back, so it never consults a SELECT policy under
-- any ownership. The table-level REVOKE is defence in depth for the day someone
-- accidentally re-enables a permissive policy or disables RLS; owner privileges
-- are implicit and are not removable by a role-targeted revoke, and the
-- audit_log_id_seq USAGE the trigger needs is likewise owner-implicit.
-- ============================================================

do $$
declare
  v_dropped int := 0;
  r         record;
begin
  -- Guard: nothing to do if 056 has not been applied here.
  if to_regclass('public.audit_log') is null then
    raise notice '086: public.audit_log does not exist -- 056 not applied. Nothing to do.';
    return;
  end if;

  -- RLS must be on, or the policies are irrelevant and the table is wide open.
  if not (select c.relrowsecurity
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname = 'audit_log') then
    alter table public.audit_log enable row level security;
    raise notice '086: row level security was OFF on audit_log -- enabled it.';
  end if;

  -- Drop every policy actually present, whatever it is called.
  for r in
    select policyname
      from pg_policies
     where schemaname = 'public' and tablename = 'audit_log'
     order by policyname
  loop
    execute format('drop policy %I on public.audit_log', r.policyname);
    v_dropped := v_dropped + 1;
    raise notice '086: dropped policy % on public.audit_log', r.policyname;
  end loop;

  if v_dropped = 0 then
    raise notice '086: audit_log already has no policies -- already deny-by-default. No change.';
  else
    raise notice '086: % policy/policies removed. audit_log is now service_role-only.', v_dropped;
  end if;
end $$;


-- Defence in depth at the grant layer. Supabase's default privileges hand
-- SELECT on new public tables to anon and authenticated; RLS is the only thing
-- holding that back today. Roles are looked up so this cannot fail on a
-- project where one of them is absent.
do $$
declare
  v_roles text;
begin
  if to_regclass('public.audit_log') is null then
    return;
  end if;

  select string_agg(quote_ident(rolname), ', ')
    into v_roles
    from pg_roles
   where rolname in ('anon', 'authenticated');

  if v_roles is null then
    raise notice '086: neither anon nor authenticated exists -- skipping table revoke.';
  else
    execute format('revoke all on table public.audit_log from %s', v_roles);
    raise notice '086: revoked all table privileges on audit_log from %.', v_roles;
  end if;
end $$;


-- Pin the reasoning where the next maintainer will actually find it.
do $$
begin
  if to_regclass('public.audit_log') is null then
    return;
  end if;

  comment on table public.audit_log is
    'Append-only change history for the money tables. Written ONLY by '
    'public.audit_row() (SECURITY DEFINER, owned by the table owner and '
    'therefore exempt from RLS). There is NO insert policy by design, and RLS '
    'is deliberately enabled with ZERO policies so no app role can read it '
    '(migration 086; the table has no tenant key to scope by). Read it '
    'out-of-band with service_role or the SQL editor. '
    'DO NOT set FORCE ROW LEVEL SECURITY on this table: with no insert policy '
    'that would abort every audited money write -- admin and handler both.';
end $$;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. Expect ZERO rows. Any row here is a surviving read door.
--
--   select policyname, roles, cmd, qual, with_check
--     from pg_policies
--    where schemaname = 'public' and tablename = 'audit_log';
--
-- 2. Expect rls_enabled = t and rls_forced = f. If rls_forced is t, STOP and
--    turn it off -- money writes are failing right now.
--
--   select c.relrowsecurity      as rls_enabled,
--          c.relforcerowsecurity as rls_forced,
--          pg_get_userbyid(c.relowner) as table_owner
--     from pg_class c
--     join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relname = 'audit_log';
--
-- 3. Confirm the writer is still a definer owned by the table owner. Expect
--    prosecdef = t and fn_owner = the table_owner from step 2.
--
--   select p.proname, p.prosecdef, pg_get_userbyid(p.proowner) as fn_owner
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'audit_row';
--
-- 4. Confirm the six triggers are untouched. Expect collections, expenses,
--    incomes, bus_handovers, buses, payment_claims. Anything EXTRA here (esp.
--    passengers or booking_requests) means the exposure was wider than the
--    files show -- worth knowing, does not change this fix.
--
--   select tgrelid::regclass as audited_table, tgname
--     from pg_trigger
--    where tgfoid = 'public.audit_row'::regproc and not tgisinternal
--    order by 1;
--
-- 5. Confirm no out-of-repo reader exists. Expect only `audit_row`.
--
--   select viewname from pg_views where definition ilike '%audit_log%';
--   select p.proname
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.prosrc ilike '%audit_log%';
--
-- 6. SMOKE TEST -- the trail must still be WRITTEN. Record a collection from
--    the admin app (or a handler_upsert_collection from the handler app), then:
--
--   select count(*) from public.audit_log where at > now() - interval '10 minutes';
--   -- expect > 0. Zero means writes are broken: check step 2's rls_forced.
--
-- 7. With a plain authenticated JWT (not service_role), this must now come back
--    empty or 401/403:
--
--   GET /rest/v1/audit_log?select=*
-- ============================================================
