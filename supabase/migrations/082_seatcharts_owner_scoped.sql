-- ============================================================
-- 082_seatcharts_owner_scoped.sql
-- ------------------------------------------------------------
-- Defect register #14. Scope seat-charts storage to the owning operator.
--
-- APPLY 081 FIRST. This file closes the cross-tenant hole between signed-in
-- operators; 081 closes the unauthenticated one. They are separate migrations
-- so each can be reverted alone, but 081 is the more urgent of the two.
--
-- THE BUG
-- Two never-reconciled policies grant every authenticated caller full rights
-- over every object in the bucket, tested on the bucket name and nothing else:
--
--   011:146  create policy "charts_admin_rw" on storage.objects
--              for all to authenticated
--              using      (bucket_id in ('seat-charts', 'tour-broadcasts'))
--              with check (bucket_id in ('seat-charts', 'tour-broadcasts'));
--
--   009:67   create policy "wa_seatcharts_auth_write" on storage.objects
--              for all to authenticated
--              using (bucket_id = 'seat-charts')
--              with check (bucket_id = 'seat-charts');
--
-- `for all` is SELECT + INSERT + UPDATE + DELETE. So operator B can list every
-- operator's tour folders, download A's rosters (names and phones, bus by
-- bus), overwrite A's chart with a doctored image, or delete it outright.
-- storage.objects.owner is only stamped on insert, so an overwrite leaves no
-- attribution.
--
-- Compare the tenancy test used EVERYWHERE else in this schema --
-- collections_owner_all (004:80), tours_owner_all (database.sql:184-185),
-- passengers, booking_requests, buses -- all of which resolve
-- tours.owner_id = auth.uid(). Storage was simply opted out of it.
--
-- WHY IT HAPPENED
-- 009 shipped the buckets public with permissive policies. 011 made them
-- private and added a tighter-sounding policy, but dropped only its own name
-- and left 009's twin standing. 059 later got this exactly right for wa-media
-- and explained why -- "granting the app write access would let any signed-in
-- admin plant or delete an object in someone else's conversation" -- but the
-- reasoning was never carried back to these two buckets. Because permissive
-- policies are OR'd, rewriting either name alone is a COMPLETE NO-OP: a
-- reviewer who fixes charts_admin_rw, tests as themselves and sees their own
-- charts working will wrongly conclude the fix landed. Both must go together,
-- which is why this migration drops them in one transaction.
--
-- WHAT THIS FIX DOES
-- Replaces both with a single owner-scoped policy on seat-charts. Objects are
-- keyed '<tour_id>/<passenger_id>.png' (whatsapp_outbound.dart:258), so the
-- first path segment identifies the tour and joins to its owner -- the same
-- shape 059 already relies on for wa-media.
--
-- WHY THIS DOES NOT LOCK THE ORGANISER OUT OF THEIR OWN CHARTS
-- The new predicate is not more restrictive than the RLS the admin already
-- runs under. tours_owner_all (database.sql:184) lets an operator select only
-- their own tours; tour_controller.dart adds an explicit owner_id = adminId
-- filter on top; tour_controller.dart stamps owner_id = adminId on every tour
-- it creates and refuses to create one without a session. So for any tour
-- reachable from notify_screen or requests_screen, auth.uid() = tours.owner_id
-- holds by construction and the EXISTS resolves true.
--
-- THE POLICY MUST BE `for all` -- DO NOT NARROW IT.
-- All three verbs are load-bearing on the ONE legitimate write path:
--   * INSERT -- first upload of a chart.
--   * UPDATE -- uploadBinary runs upsert:true over a deterministic path, so
--     every re-send and every "seats changed since last notification" retry is
--     an UPDATE, not an INSERT.
--   * SELECT -- createSignedUrl resolves the object under the caller's RLS
--     before it can mint a URL. 011:143-144 says so in its own comment:
--     "reading is needed to MINT signed URLs".
-- A `for select, insert` variant would let the FIRST send succeed and break
-- only re-sends -- the hardest possible failure to diagnose in the field.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT apply the tour-id predicate to tour-broadcasts. That bucket's
--     objects are written to a FLAT key, 'broadcast_<epochms>.<ext>'
--     (create_tour_screen.dart:186), with no tenant segment -- and the upload
--     happens BEFORE createTour, so there is no tours row to join against even
--     if the key had one. Applying the same predicate there makes
--     split_part(name,'/',1) return the whole filename, which never equals a
--     uuid, so EVERY hero-image upload would 403. Worse, that failure is
--     swallowed into a warning toast (create_tour_screen.dart:190-195), so
--     tours would save posterless and nobody would report it as a permissions
--     bug. Scoping tour-broadcasts requires shipping a client change to an
--     '<auth.uid()>/...' key first; it is deliberately out of scope here.
--  2. Because charts_admin_rw is the policy that currently carries
--     tour-broadcasts WRITE authority, dropping it would leave that bucket
--     resting entirely on 009's wa_broadcasts_auth_write -- which was created
--     under an `if not exists` guard and may never have landed on a project
--     whose buckets predated 009 (exactly the silent no-op 051 exists to
--     repair). So this file first ensures an explicit tour-broadcasts write
--     policy exists, THEN drops charts_admin_rw. Net authority on
--     tour-broadcasts is unchanged.
--  3. It does NOT add `and t.deleted_at is null`. 054 added soft delete and
--     explicitly touched no RLS policy; an archived tour's charts must stay
--     re-sendable by their owner.
--  4. It does NOT add an `or t.owner_id is null` limb. That escape exists in
--     033/059 only for genuinely unrouted wa_conversations and has no analogue
--     here; adding it would re-open the bucket to every operator for any tour
--     whose owner happened to be null.
--  5. It does NOT touch wa_broadcasts_public_read, the anon read on
--     tour-broadcasts. That bucket is public by design (051:43) and the poster
--     is fetched by Meta and by every customer with no credentials.
--
-- HIDDEN COUPLING, worth knowing before a future hardening pass:
-- the predicate below runs as the CALLER, so it needs `authenticated` to
-- retain table-level SELECT on public.tours AND tours_owner_all to admit the
-- row. If a later migration revokes that grant or narrows that policy, every
-- seat-chart send starts failing with "Seat chart failed:" while this policy
-- still reads as perfectly correct. 059's wa_media_owner_read carries the
-- identical dependency on public.wa_conversations.
-- ============================================================

-- ── PRE-FLIGHT (read-only; refuses rather than half-applying) ──
do $$
declare
  v_public      boolean;
  v_null_owners int;
  v_orphans     int;
begin
  if not exists (select 1 from storage.buckets where id = 'seat-charts') then
    raise exception '082: bucket seat-charts is missing -- refusing to apply.';
  end if;

  select public into v_public from storage.buckets where id = 'seat-charts';
  if v_public then
    raise exception '082: seat-charts is PUBLIC. The /object/public/ route ignores '
                    'RLS entirely, so this policy would be decorative. Apply 081 first.';
  end if;

  if to_regclass('public.tours') is null then
    raise exception '082: public.tours is missing -- refusing to apply.';
  end if;

  -- Informational only. A null-owner tour is ALREADY invisible to every admin
  -- (tours_owner_all + the client-side owner filter), so it cannot be notified
  -- today either -- this fix removes no capability that currently exists.
  execute 'select count(*) from public.tours where owner_id is null'
     into v_null_owners;
  if v_null_owners > 0 then
    raise notice '082: NOTE -- % tour(s) have a null owner_id. Their charts will be '
                 'reachable by service_role only. They are already unreachable from '
                 'the admin app, so this is not a new regression.', v_null_owners;
  end if;

  -- Objects whose first path segment is not a live tour (charts left behind by
  -- tours hard-deleted before 054 added tours_forbid_hard_delete).
  select count(*) into v_orphans
    from storage.objects o
   where o.bucket_id = 'seat-charts'
     and not exists (
       select 1 from public.tours t
        where t.id::text = lower(split_part(o.name, '/', 1)));
  if v_orphans > 0 then
    raise notice '082: NOTE -- % orphan seat-chart object(s) have no matching tour. '
                 'They become service_role-only. Nothing in lib/ deletes storage '
                 'objects, so no feature regresses; sweep them with the service key.',
                 v_orphans;
  end if;

  if exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and cmd in ('SELECT','ALL')
       and coalesce(qual,'') like '%seat-charts%'
       and (roles && array['anon']::name[] or roles = array['public']::name[])
  ) then
    raise notice '082: NOTE -- an anon-readable seat-charts policy is still present. '
                 'This migration does not remove it; apply 081.';
  end if;
end $$;


begin;

-- ── 1. Preserve tour-broadcasts write authority BEFORE removing the policy
--       that currently carries it. Idempotent and independent of whether
--       009's wa_broadcasts_auth_write ever landed on this project.
do $$
begin
  if exists (select 1 from storage.buckets where id = 'tour-broadcasts') then
    drop policy if exists "tour_broadcasts_auth_write" on storage.objects;
    create policy "tour_broadcasts_auth_write" on storage.objects
      for all to authenticated
      using      (bucket_id = 'tour-broadcasts')
      with check (bucket_id = 'tour-broadcasts');
    raise notice '082: ensured tour_broadcasts_auth_write exists (flat object keys '
                 'mean this bucket cannot be owner-scoped until the client ships an '
                 'auth.uid()-prefixed path).';
  else
    raise notice '082: bucket tour-broadcasts absent -- skipping its write policy.';
  end if;
end $$;


-- ── 2. Remove BOTH bucket-only authenticated grants. Dropping either one
--       alone is a no-op, because the other duplicates it.
do $$
declare
  v_dropped int := 0;
  r         record;
begin
  for r in
    select policyname
      from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname in ('charts_admin_rw', 'wa_seatcharts_auth_write')
     order by policyname
  loop
    execute format('drop policy %I on storage.objects', r.policyname);
    v_dropped := v_dropped + 1;
    raise notice '082: dropped bucket-only policy %', r.policyname;
  end loop;

  if v_dropped = 0 then
    raise notice '082: neither charts_admin_rw nor wa_seatcharts_auth_write present '
                 '-- already removed. No change.';
  end if;
end $$;


-- ── 3. Re-grant, scoped to the owner of the tour named by the first path
--       segment. FOR ALL is required -- see the header.
drop policy if exists "seat_charts_owner_rw" on storage.objects;
create policy "seat_charts_owner_rw" on storage.objects
  for all to authenticated
  using (
    bucket_id = 'seat-charts'
    and exists (
      select 1
        from public.tours t
       where t.id::text = lower(split_part(storage.objects.name, '/', 1))
         and t.owner_id = auth.uid()
    )
  )
  with check (
    bucket_id = 'seat-charts'
    and exists (
      select 1
        from public.tours t
       where t.id::text = lower(split_part(storage.objects.name, '/', 1))
         and t.owner_id = auth.uid()
    )
  );

commit;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. Expect exactly ONE seat-charts policy: seat_charts_owner_rw /
--    {authenticated} / ALL, with an owner_id predicate. Expect NO
--    charts_admin_rw and NO wa_seatcharts_auth_write.
--
--   select policyname, roles, cmd, qual
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--    order by policyname;
--
-- 2. Expect ZERO rows -- any bucket-only seat-charts grant that survived:
--
--   select policyname, cmd, roles, qual
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and coalesce(qual,'') like '%seat-charts%'
--      and coalesce(qual,'') not like '%owner_id%';
--
-- 3. Confirm tour-broadcasts still has a write policy (this is the collateral
--    that charts_admin_rw used to carry). Expect at least one ALL row:
--
--   select policyname, cmd, roles
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and coalesce(qual,'') like '%tour-broadcasts%';
--
-- 4. Orphans now reachable only by service_role (informational):
--
--   select o.name, o.created_at
--     from storage.objects o
--    where o.bucket_id = 'seat-charts'
--      and not exists (select 1 from public.tours t
--                       where t.id::text = lower(split_part(o.name,'/',1)))
--    order by o.created_at;
--
-- 5. SMOKE TEST -- run ALL of these, in this order. 5b is the one most likely
--    to catch a mistake, because it exercises UPDATE rather than INSERT.
--    a. As operator A, run a seat-allocation send from notify_screen on a
--       locked tour. Expect deliveries, NOT "Seat chart failed:".
--    b. As operator A, re-send the SAME tour (this overwrites via upsert).
--       Expect deliveries. A failure here means the policy lost UPDATE.
--    c. As operator A, confirm a single booking request in requests_screen and
--       verify the WhatsApp image header arrives (proves SELECT/signing works
--       and that Meta can still redeem the signed URL).
--    d. Create a tour WITH a hero image. The tour-broadcasts upload must still
--       succeed -- a missing poster here means step 1 removed too much.
--    e. As operator B, with B's own JWT:
--         POST /storage/v1/object/list/seat-charts  {"prefix":"<A's tour id>/"}
--           -> must return []
--         GET  /storage/v1/object/seat-charts/<A tour>/<A passenger>.png
--           -> must NOT return the image
--
-- ROLLBACK (if 5a-5d fail and you need the old behaviour back immediately):
--   drop policy if exists "seat_charts_owner_rw" on storage.objects;
--   create policy "charts_admin_rw" on storage.objects
--     for all to authenticated
--     using      (bucket_id in ('seat-charts', 'tour-broadcasts'))
--     with check (bucket_id in ('seat-charts', 'tour-broadcasts'));
--   -- note this restores the cross-tenant hole; investigate before re-applying.
-- ============================================================
