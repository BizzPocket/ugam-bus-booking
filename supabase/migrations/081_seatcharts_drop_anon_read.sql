-- ============================================================
-- 081_seatcharts_drop_anon_read.sql
-- ------------------------------------------------------------
-- Defect register #11. Remove anon SELECT from the seat-charts bucket.
--
-- THE BUG
-- 009_whatsapp_broadcast.sql:59 created, inside an `if not exists` guard:
--
--     create policy "wa_seatcharts_public_read" on storage.objects
--       for select to anon, authenticated
--       using (bucket_id = 'seat-charts');
--
-- The predicate names a bucket and nothing else -- no path, no owner, no
-- tenant. Every object in the bucket qualifies, for the anon role.
--
-- Each object is not one rider's seat. It is a rendered bus roster: every
-- occupant's NAME and PHONE per berth, their pickup point, and the handler's
-- name and phone in the footer. Uploads use upsert:true and nothing ever
-- deletes, so the bucket holds a chart for every passenger of every tour ever
-- locked and notified, across every operator.
--
-- WHY THE PRIVATE BUCKET FLAG DOES NOT SAVE IT
-- 011:139 set the bucket private and 051 deliberately kept it private, calling
-- it "a rendered roster -- passenger NAMES and seat allocations, i.e. personal
-- data". That flag governs only the /object/public/<bucket>/<path> route. The
-- /object/<bucket>/<path> and /object/list/<bucket> routes are governed by RLS
-- on storage.objects, where this policy still says yes to anon. 051:19-20
-- records exactly this asymmetry measured against production for the sibling
-- bucket while IT was private: GET /object/tour-broadcasts/<file> + apikey
-- returned 200 and 136078 bytes, while the /object/public/ route returned 400.
--
-- WHY IT SURVIVED FOUR SECURITY MIGRATIONS
-- 011:145 drops only `charts_admin_rw` -- a name 009 never created -- and its
-- own comment says "If you already have storage policies for these buckets,
-- review for overlap." The review never happened. A grep for `wa_seatcharts`
-- across every migration returns hits only in 009. 078:41-44 independently
-- calls this policy a bug. Postgres ORs permissive policies, so the tighter
-- policies added later never narrowed it.
--
-- WHAT THIS FIX DOES
-- Drops every anon-readable policy whose predicate targets seat-charts. It
-- matches on the qual text rather than on one hardcoded name, because the live
-- policy set has drifted from these files before and a second copy under
-- another name would keep the door open.
--
-- NOTHING LEGITIMATE READS THIS BUCKET AS ANON. Verified by exhaustive grep:
-- `.storage` across every .dart and .ts in the repo returns only
-- whatsapp_cloud_service.dart (this bucket + tour-broadcasts),
-- whatsapp_inbox_service.dart (wa-media) and wa-webhook/index.ts (wa-media).
-- The customer app renders seats client-side from the 048/057 RPCs; the
-- handler app renders its chart in-app from handler_tour_manifest and makes no
-- storage call at all; the A4 share path (seat_chart_pdf.dart -> sharePdf) is
-- a purely local OS share sheet and never uploads. No RPC returns a seat-chart
-- URL and no column stores one.
--
-- MOST IMPORTANTLY: META IS NOT AFFECTED. The organiser's send path mints a
-- signed URL (whatsapp_cloud_service.dart uploadBinary -> createSignedUrl) and
-- Meta fetches /object/sign/<bucket>/<path>?token=<jwt>, which storage-api
-- authorises by validating the token signature -- no database role is
-- involved. This is proved inside this repo rather than assumed: 059 makes
-- wa-media private with a single `to authenticated` owner-scoped policy and NO
-- anon policy whatsoever, yet whatsapp_inbox_service.dart mints signed URLs
-- that conversation_screen.dart renders with Image.network, which sends no
-- apikey and no Authorization header. That path works in production today.
--
-- The stale docstring at whatsapp_cloud_service.dart:349-353 claims the
-- opposite ("Migration 009 makes both buckets public-read (Meta must fetch
-- template media by plain URL)"). It has been false since 011:139. It is the
-- single likeliest reason someone re-adds this policy, and it should be
-- corrected in the same commit as this migration.
--
-- WHAT THIS FIX DELIBERATELY DOES NOT DO
--  1. It does NOT touch the two `for all to authenticated` grants
--     (charts_admin_rw at 011:146 and wa_seatcharts_auth_write at 009:67).
--     Those are the cross-tenant defect (#14) and are handled separately in
--     082, because they need a REPLACEMENT policy rather than a removal and
--     they also carry the tour-broadcasts bucket. This file is a pure removal
--     and is safe to ship on its own, today, ahead of that work.
--  2. It does NOT touch tour-broadcasts. That bucket is public BY DESIGN
--     (051:43) so Meta and every customer can fetch the hero image with no
--     credentials, and its anon policy is redundant rather than wrong.
--  3. It does NOT touch `ota_config_public_read` (078:79) on the app-config
--     and i18n buckets. Those hold public config that must be readable with no
--     session at all -- it is what powers the force-update gate for a user too
--     out-of-date to sign in. 078:41-44 warns explicitly that fixing #11 must
--     not sweep them up. This is why the drop below is scoped by qual text and
--     why the VERIFY block asserts on seat-charts specifically instead of on
--     "no anon storage policies", which would be false on a correct database.
-- ============================================================

do $$
declare
  v_dropped int := 0;
  r         record;
begin
  -- Guard: is the bucket even here?
  if not exists (select 1 from storage.buckets where id = 'seat-charts') then
    raise notice '081: bucket seat-charts does not exist. Nothing to do.';
    return;
  end if;

  -- Drop any policy that lets anon (or PUBLIC, which includes anon) read
  -- seat-charts. Scoped by predicate text so a renamed duplicate is caught,
  -- and deliberately narrow so app-config / i18n / tour-broadcasts are safe.
  for r in
    select policyname, roles, cmd
      from pg_policies
     where schemaname = 'storage'
       and tablename  = 'objects'
       and cmd in ('SELECT', 'ALL')
       and coalesce(qual, '') like '%seat-charts%'
       and (roles && array['anon']::name[] or roles = array['public']::name[])
     order by policyname
  loop
    execute format('drop policy %I on storage.objects', r.policyname);
    v_dropped := v_dropped + 1;
    raise notice '081: dropped anon-readable seat-charts policy % (cmd=%, roles=%)',
                 r.policyname, r.cmd, r.roles;
  end loop;

  if v_dropped = 0 then
    raise notice '081: no anon-readable seat-charts policy found -- already closed. No change.';
  else
    raise notice '081: % anon read policy/policies removed from seat-charts.', v_dropped;
  end if;
end $$;


-- 051's lesson, learned the hard way: assert the bucket flag, never assume it.
-- 009 created this bucket with `on conflict (id) do nothing`, which silently
-- did nothing on a project where the bucket already existed by hand, leaving
-- the migration file looking correct while production disagreed for months.
do $$
declare
  v_public boolean;
begin
  select public into v_public from storage.buckets where id = 'seat-charts';

  if v_public is null then
    raise notice '081: bucket seat-charts absent -- skipping flag assertion.';
  elsif v_public is false then
    raise notice '081: seat-charts is already private. No change.';
  else
    update storage.buckets set public = false where id = 'seat-charts';
    raise notice '081: seat-charts was PUBLIC -- set to private.';
  end if;
end $$;


-- ============================================================
-- VERIFY
-- ------------------------------------------------------------
-- 1. Expect ZERO rows. NOTE the `qual like '%seat-charts%'` filter: do NOT run
--    this without it. A bare "no anon storage policies" assertion is FALSE on
--    a correct database -- ota_config_public_read (078) and
--    wa_broadcasts_public_read (009) both legitimately grant anon SELECT, and
--    dropping them breaks the force-update gate and the tour poster.
--
--   select policyname, roles, cmd, qual
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and cmd in ('SELECT','ALL')
--      and coalesce(qual,'') like '%seat-charts%'
--      and (roles && array['anon']::name[] or roles = array['public']::name[]);
--
-- 2. Expect: seat-charts | f
--
--   select id, public from storage.buckets where id = 'seat-charts';
--
-- 3. Full picture, for the record -- confirm ota_config_public_read and
--    wa_broadcasts_public_read are still present and untouched:
--
--   select policyname, roles, cmd, qual
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--    order by policyname;
--
-- 4. ATTACKER VIEW. With the publishable key that ships in the APK
--    (lib/config/supabase_config.dart), this must now return an empty list.
--    Before this migration it returned every tour-id folder.
--
--   curl -s -X POST \
--     -H "apikey: <publishable key>" \
--     -H 'Content-Type: application/json' \
--     -d '{"prefix":"","limit":100}' \
--     "https://<project>.supabase.co/storage/v1/object/list/seat-charts"
--   -> []
--
-- 5. SMOKE TEST -- the organiser's send path must be unaffected. In order:
--    a. Lock a test tour and run the seat-allocation send from notify_screen.
--       Expect deliveries. The string "Seat chart failed:" in the summary
--       dialog (whatsapp_outbound.dart:267) is the upload/sign failure marker
--       -- if you see it, roll back and investigate.
--    b. Confirm a single booking request in requests_screen and verify the
--       WhatsApp image header arrives. THIS is the step that proves Meta can
--       still redeem the signed URL.
-- ============================================================
