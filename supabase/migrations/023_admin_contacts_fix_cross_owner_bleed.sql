-- ============================================================
-- 023  admin_contacts — fix cross-agent name bleed + guard against recurrence
-- ------------------------------------------------------------
-- SYMPTOM
--   An agent opens a number and sees the name ANOTHER agent saved for it.
--   `admin_contacts` is per-admin (RLS scopes every row to owner_id =
--   auth.uid()), so with each agent on their own login this can only come
--   from LEGACY DATA carrying the wrong / non-admin owner_id — see the
--   diagnosis in 021_admin_contacts_per_admin_cleanup.sql.
--
-- NOTE on A4 ("phones across multiple owners"): that count is INFORMATIONAL
--   and EXPECTED — two agents legitimately knowing the same number under
--   different names. It is NOT the bug and is left untouched here.
--
-- ROOT CAUSE (two shapes)
--   (a) ORPHAN rows  — owner_id is not a real admin (import junk).
--   (b) MISOWNED device rows — owner_id is a real admin but the WRONG one.
--       Device-synced contacts are regenerable: each agent's next login
--       re-reads their own phone book and re-inserts missing numbers under
--       their own owner_id, so deleting them lets the correct rows return.
--
-- WHAT THIS MIGRATION DOES (atomic — rolls back entirely on any error)
--   1. Deletes orphan rows                        (cures shape a)
--   2. Deletes source='device' rows               (cures shape b via re-sync)
--   3. Adds an FK owner_id -> admins(id)           (prevents shape a forever)
--      `admins.id` already equals the auth-user id, so this is simply a
--      stricter, correct version of the existing owner_id -> auth.users FK.
--
-- BEFORE YOU RUN
--   * Run 021 PART A first. If A1 shows a HUGE 'manual' count piled on ONE
--     owner, the legacy import also poisoned manual rows — step 2 below will
--     NOT be enough; use 021 Option 3 (truncate) instead and skip step 2.
--   * 'manual' and 'booking' contacts are PRESERVED here (not regenerable).
-- ============================================================

begin;

-- ── 1. Remove orphan rows (owner is not a real admin) ──────────────────────
delete from public.admin_contacts ac
where not exists (
  select 1 from public.admins a where a.id = ac.owner_id
);

-- ── 2. Reset regenerable device contacts (rebuilt correctly on next login) ─
delete from public.admin_contacts
where source = 'device';

-- ── 3. Structural guard: a contact's owner MUST be a real admin ────────────
--    Idempotent: drop-if-exists then recreate. Safe to apply now because
--    step 1 has already removed every row that would violate it.
alter table public.admin_contacts
  drop constraint if exists admin_contacts_owner_admin_fk;

alter table public.admin_contacts
  add constraint admin_contacts_owner_admin_fk
  foreign key (owner_id) references public.admins(id) on delete cascade;

commit;


-- ============================================================
-- VERIFY  (read-only — run after COMMIT; expect orphan_rows = 0)
-- ============================================================
-- select 'orphan rows remaining' as report, count(*) as orphan_rows
-- from public.admin_contacts ac
-- where not exists (select 1 from public.admins a where a.id = ac.owner_id);
--
-- select 'rows by source after fix' as report, source, count(*) as rows
-- from public.admin_contacts group by source order by rows desc;
