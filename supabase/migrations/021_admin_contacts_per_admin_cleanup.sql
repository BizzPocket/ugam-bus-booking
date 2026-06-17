-- ============================================================
-- 021  admin_contacts — per-admin contact cleanup
-- ------------------------------------------------------------
-- WHY
--   `admin_contacts` is meant to be PER ADMIN: each agent sees the name
--   THEY saved for a phone number. The current app + RLS already enforce
--   this (every row is scoped to owner_id = auth.uid(); reads filter by
--   owner_id; the display lookup only ever holds the logged-in admin's
--   rows). See database.sql §6 and lib/services/user_service.dart.
--
--   But agents still saw "another agent's name" for a number. With each
--   agent on their OWN login, the only way that happens is LEGACY DATA:
--   rows imported from the old shared "users" collection (pre-Supabase)
--   that carry the WRONG owner_id, or rows owned by an id that is not a
--   real admin. New writes are correct; the bad rows are historical.
--
-- THE FIX
--   Device-synced contacts are REGENERABLE: on every admin login the app
--   re-reads that agent's phone book and re-inserts any missing numbers
--   under their own owner_id (UserController.syncDevicePhonebook). So the
--   clean cure is to remove the contaminated / regenerable rows and let
--   each agent's device re-populate correctly. Manually-typed and
--   booking-derived contacts are NOT regenerable, so they are preserved
--   by the recommended option.
--
-- HOW TO RUN
--   This file is SAFE TO APPLY AS-IS: it only runs the read-only
--   diagnostics in PART A. The destructive cleanup in PART B is commented
--   out. Run PART A first (Supabase SQL editor shows the output), decide
--   which option fits, then uncomment exactly one option in PART B and run
--   it. Re-run PART A afterwards to confirm.
-- ============================================================


-- ============================================================
-- PART A — DIAGNOSE  (read-only, safe)
-- ============================================================

-- A1. Totals by source. A huge 'manual'/'device' count concentrated on a
--     single owner is the tell-tale of a legacy bulk import.
select 'A1 totals by source' as report, source, count(*) as rows
from public.admin_contacts
group by source
order by rows desc;

-- A2. Rows per owner, joined to the admins table. Any owner_id with a
--     null admin name is an ORPHAN (owner is not a real admin) — those
--     rows are unreachable junk and safe to delete.
select 'A2 rows per owner' as report,
       ac.owner_id,
       a.name        as admin_name,
       a.phone       as admin_phone,
       count(*)      as contact_rows
from public.admin_contacts ac
left join public.admins a on a.id = ac.owner_id
group by ac.owner_id, a.name, a.phone
order by contact_rows desc;

-- A3. Orphan rows — owner_id does not match any admin. Always safe to purge.
select 'A3 orphan rows' as report, count(*) as orphan_rows
from public.admin_contacts ac
where not exists (select 1 from public.admins a where a.id = ac.owner_id);

-- A4. Same phone saved under >1 owner. In a healthy per-admin world this
--     is EXPECTED and FINE (two agents legitimately know the same number
--     by different names). Shown only so the numbers make sense — do NOT
--     dedupe across owners.
select 'A4 phones across multiple owners (informational)' as report,
       count(*) as phones_shared_across_owners
from (
  select phone
  from public.admin_contacts
  group by phone
  having count(distinct owner_id) > 1
) t;


-- ============================================================
-- PART B — CLEANUP  (DESTRUCTIVE — uncomment ONE option, then run)
-- ============================================================

-- ── Option 1 (surgical, always safe): delete orphan rows only ──────────
--    Removes rows whose owner is not a real admin. Keeps every real
--    admin's data untouched. Run this regardless of which other option
--    you choose.
--
-- delete from public.admin_contacts ac
-- where not exists (select 1 from public.admins a where a.id = ac.owner_id);


-- ── Option 2 (RECOMMENDED): reset regenerable device contacts ──────────
--    Deletes device-synced rows so each agent's NEXT login rebuilds their
--    phone book cleanly under their own owner_id. Preserves manually-typed
--    ('manual') and booking-derived ('booking') contacts, which cannot be
--    regenerated from the device. This is the cure for "I see another
--    agent's name" — the wrong device rows are removed and replaced by the
--    correct ones from each agent's own phone.
--
--    NOTE: the app only INSERTS phones it doesn't already have, so simply
--    deleting the bad rows (rather than trying to update them) is what lets
--    the re-sync put the right name back.
--
-- delete from public.admin_contacts where source = 'device';


-- ── Option 3 (nuclear): wipe ALL contacts, full rebuild from devices ───
--    Use only if the legacy import also corrupted 'manual'/'booking' rows
--    (e.g. everything was imported with source = 'manual'). Every agent
--    re-syncs from their own phone on next login. Contacts that exist ONLY
--    as manual/booking entries (not in any phone book) will be lost.
--
-- truncate table public.admin_contacts;
