-- ============================================================
-- 078_ota_config_buckets.sql
-- ------------------------------------------------------------
-- Somewhere to put the two things the app can now change without a store
-- release: the flag document (force-update, maintenance, kill switches,
-- tunables) and the translation deltas.
--
-- Both clients already know how to read them — RemoteFlagsService and
-- RemoteTranslationLoader shipped dormant, waiting on a URL. This file creates
-- the place that URL points at.
--
-- WHY SUPABASE STORAGE AND NOT A TABLE
-- A public storage object is fetchable over plain HTTPS with NO apikey header
-- and no Supabase client:
--
--     https://PROJECT.supabase.co/storage/v1/object/public/app-config/flags.json
--
-- so the clients can read it with a bare HttpClient on the boot path, without
-- waiting for Supabase.initialize and without the PostgREST layer being
-- healthy. Storage is a different subsystem from the database API, which
-- matters for the one flag whose whole job is to be readable while the
-- database is unwell.
--
-- It is not fully independent — a total project outage takes both down. If that
-- ever matters enough, move these two objects to any static host and change
-- one --dart-define. The clients do not care where the URL points.
--
-- WHY PUBLIC IS CORRECT HERE
-- Neither object contains anything private. The flag document is operational
-- config; the translation deltas are UI copy that ships in the APK anyway.
-- Making them public is what lets the app read them BEFORE it has a session —
-- which is the point, since the force-update gate must work for a logged-out
-- user on a build too old to log in.
--
-- WRITES ARE DELIBERATELY NOT GRANTED TO ANYONE.
-- No insert/update/delete policy is created, so only the service role — the
-- Supabase dashboard, or a CI job holding the service key — can publish. These
-- files steer every installed client; the app itself must never be able to
-- rewrite them, and neither should a logged-in organiser.
--
-- NOT RELATED TO the seat-charts bucket finding in the 2026-08-10 defect
-- register (#11). That bucket holds passenger PII and its anon policy is a bug.
-- These two hold public config and their readability is the feature. Fixing
-- #11 must not sweep these up.
--
-- Idempotent. Creates no rows beyond the two bucket records.
-- ============================================================

do $$
begin
  if to_regclass('storage.buckets') is null then
    raise exception '078 requires the storage extension (Supabase Storage)';
  end if;
end $$;


-- ── 1. The buckets ───────────────────────────────────────────
insert into storage.buckets (id, name, public)
values
  ('app-config', 'app-config', true),
  ('i18n',       'i18n',       true)
on conflict (id) do update
  set public = true,
      name   = excluded.name;


-- ── 2. Read policies ─────────────────────────────────────────
-- `public = true` already serves these through the public object endpoint, but
-- an explicit SELECT policy keeps the intent legible next to every other
-- storage policy, and makes the listing behaviour deliberate rather than
-- inherited.
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'ota_config_public_read'
  ) then
    create policy ota_config_public_read
      on storage.objects for select
      to anon, authenticated
      using (bucket_id in ('app-config', 'i18n'));
    raise notice '078: created ota_config_public_read';
  else
    raise notice '078: ota_config_public_read already present';
  end if;
end $$;


-- ============================================================
-- HOW TO PUBLISH
--
-- flags.json  ->  bucket `app-config`
--
--   {
--     "min_supported_build":  0,        // block builds strictly below this; 0 = nobody
--     "recommended_build":    0,        // soft nudge below this;            0 = nobody
--     "maintenance_mode":     false,
--     "kill":     { "upi_payment": false },
--     "tunables": { "hold_ttl_seconds": 300 }
--   }
--
--   Every field is optional and every default is the "nothing is wrong" value,
--   so an empty {} is a valid, harmless document. A malformed one is ignored by
--   the client and the last good copy is kept.
--
-- gu.json / en.json / hi.json  ->  bucket `i18n`
--
--   A DELTA of changed keys only, merged over the bundled catalogue. Not the
--   whole file. Capped at 64KB client-side; anything larger is refused.
--
--   { "launch_block": { "maintenance_body": "Back by 6pm." } }
--
-- Then point the app at them ONCE, at build time:
--
--   flutter build appbundle \
--     --dart-define=REMOTE_FLAGS_URL=https://PROJECT.supabase.co/storage/v1/object/public/app-config/flags.json \
--     --dart-define=I18N_OVERLAY_BASE_URL=https://PROJECT.supabase.co/storage/v1/object/public/i18n
--
-- After that build ships, both channels are live: editing flags.json changes
-- every installed client on next foreground, and editing a locale delta changes
-- its copy on next launch. No further release is needed for either.
--
-- ============================================================
-- VERIFY
--
--   -- Both buckets exist and are public:
--   select id, public from storage.buckets where id in ('app-config','i18n');
--
--   -- Readable with no credentials at all. From a terminal, NOT the dashboard
--   -- (the dashboard is authenticated and would prove nothing):
--   --   curl -i https://PROJECT.supabase.co/storage/v1/object/public/app-config/flags.json
--   -- expect 200 and the JSON body, with no apikey header sent.
--
--   -- Writes are refused for ordinary roles. As an authenticated organiser,
--   -- uploading to app-config must FAIL — only the service role may publish.
-- ============================================================
