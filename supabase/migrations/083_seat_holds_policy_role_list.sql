-- ============================================================
-- 083_seat_holds_policy_role_list.sql
-- ------------------------------------------------------------
-- Add the missing TO clause to seat_holds_owner_all.
--
-- THE BUG
-- 064_seat_holds_chart_finalize.sql:66 created the policy without a role list:
--
--     create policy "seat_holds_owner_all" on public.seat_holds
--       for all using (
--         exists (select 1 from public.tours t
--                  where t.id = seat_holds.tour_id and t.owner_id = auth.uid())
--       )
--       with check ( ...same... );
--
-- An omitted TO clause defaults to PUBLIC, which includes anon. Every sibling
-- policy in this codebase names `to authenticated` explicitly:
-- collections_owner_all (004:81), expenses_owner_all (004:116),
-- bus_handovers_owner_all (004:147), attendance_owner_all (024:62),
-- incomes_owner_all (029:70), payment_attempts_owner_all (049:223),
-- payment_claims_owner_all (060:88), customer_memory_owner_all (066:51).
-- This one is the only omission.
--
-- seat_holds carries phone, name, gender, note and pickup_location_name per
-- hold -- customer PII for people who have not completed a booking.
--
-- HONEST SEVERITY: THIS IS NOT CURRENTLY EXPLOITABLE.
-- For anon, auth.uid() is NULL, so the EXISTS is false and no row qualifies.
-- The boundary holds today -- but it holds by arithmetic coincidence rather
-- than by the role list, and it is one edit away from not holding. It becomes
-- live the moment anyone:
--   * adds a second permissive policy on seat_holds (Postgres ORs them), or
--   * adds an `or ... is null` limb of the kind already present in 033:91 and
--     059:88, or
--   * introduces an anon-facing path where auth.uid() resolves.
-- 047:180 shows this project does grant table privileges to anon
-- (`grant all on table public.bus_live_positions to anon, ...`), so the
-- precedent for a wide grant sitting behind a single policy already exists.
--
-- Fix it while it is free.
--
-- WHAT THIS FIX DOES
-- Drops and recreates the policy with `to authenticated`. The predicate is
-- byte-identical; only the role list changes. Effective access for every
-- existing caller is unchanged, because anon already matched zero rows.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT change the predicate. Same EXISTS, same tours.owner_id join,
--     same USING and WITH CHECK.
--  2. It does NOT add `force row level security`. The customer hold path
--     (chart_hold_seats, 064:130) and the finalize path both run SECURITY
--     DEFINER under an ANON jwt where auth.uid() is NULL, so they write past
--     this policy by owner exemption. FORCE would subject the owner to RLS and
--     abort every customer seat hold -- the entire public booking funnel.
--  3. It does NOT touch the seat-hold rate/quota question (unbounded anon
--     holds, and the 24h extension in 074). That is a behavioural change to
--     chart_hold_seats and belongs in its own migration with its own product
--     decision about the cap.
-- ============================================================

do $$
declare
  v_roles name[];
begin
  -- Guard: 064 may not have been applied here.
  if to_regclass('public.seat_holds') is null then
    raise notice '083: public.seat_holds does not exist -- 064 not applied. Nothing to do.';
    return;
  end if;

  select roles into v_roles
    from pg_policies
   where schemaname = 'public'
     and tablename  = 'seat_holds'
     and policyname = 'seat_holds_owner_all';

  if v_roles is null then
    raise notice '083: policy seat_holds_owner_all not found. Creating it scoped to authenticated.';
  elsif v_roles = array['authenticated']::name[] then
    raise notice '083: seat_holds_owner_all already targets {authenticated} only. No change needed.';
    return;
  else
    raise notice '083: seat_holds_owner_all currently targets % -- retargeting to {authenticated}.', v_roles;
  end if;

  drop policy if exists "seat_holds_owner_all" on public.seat_holds;

  create policy "seat_holds_owner_all" on public.seat_holds
    for all to authenticated
    using (
      exists (select 1 from public.tours t
               where t.id = seat_holds.tour_id and t.owner_id = auth.uid())
    )
    with check (
      exists (select 1 from public.tours t
               where t.id = seat_holds.tour_id and t.owner_id = auth.uid())
    );

  raise notice '083: seat_holds_owner_all recreated with `to authenticated`.';
end $$;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. Expect exactly one row: seat_holds_owner_all | {authenticated} | ALL
--
--   select policyname, roles, cmd, qual, with_check
--     from pg_policies
--    where schemaname = 'public' and tablename = 'seat_holds';
--
-- 2. Sweep for any OTHER policy in this schema still missing its role list --
--    this is the class of bug, not just the instance. `{public}` here means
--    the TO clause was omitted.
--
--   select schemaname, tablename, policyname, cmd, roles
--     from pg_policies
--    where schemaname in ('public','storage')
--      and roles = array['public']::name[]
--    order by 1, 2, 3;
--
-- 3. Confirm RLS is still enabled and NOT forced (forced would kill the anon
--    customer hold path, which writes via SECURITY DEFINER with a null uid):
--
--   select c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
--     from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relname = 'seat_holds';
--   -- expect: t | f
--
-- 4. SMOKE TEST -- both sides of the boundary:
--    a. As a customer in the app (anon), hold seats on a public tour from the
--       seat chart. The hold must succeed and the seats must show as taken to
--       a second device. This proves the definer write path is intact.
--    b. As the owning operator, open the tour and confirm the pending holds
--       are visible. This proves the authenticated read path is intact.
-- ============================================================
