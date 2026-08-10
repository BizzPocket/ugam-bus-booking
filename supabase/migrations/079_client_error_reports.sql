-- ============================================================
-- 079_client_error_reports.sql
-- ------------------------------------------------------------
-- Somewhere for the app to say "I broke".
--
-- A repo-wide grep for crashlytics|sentry|bugsnag returns nothing. There is no
-- FlutterError.onError, no PlatformDispatcher.onError and no runZonedGuarded
-- anywhere in lib/. When something fails in the field, the detection mechanism
-- is a handler telephoning the organiser.
--
-- That is the single thing standing between this app and being operable. Every
-- remote lever built recently — the kill switches, the force-update gate, the
-- translation overlay — is a way to REACT, and none of them is worth anything
-- without a signal to react to. A staged rollout with no crash telemetry is
-- just a slower way to break everyone.
--
-- WHY A TABLE AND NOT CRASHLYTICS
-- Crashlytics is the better tool and should still be adopted. It is also a
-- federated NATIVE plugin — a store build on both platforms plus Firebase
-- console work — and it needs a macOS machine for the iOS half. This table
-- needs none of that and can ship in the next build that was going out anyway.
-- Take the signal now; take the better tool when the console work happens.
--
-- What this deliberately does NOT do: native crashes. A Dart-level reporter
-- cannot see a SIGSEGV in a plugin, and it cannot symbolicate. It catches Dart
-- exceptions, which is what nearly every finding in the 2026-08-10 defect
-- register actually is.
--
-- ANON MAY INSERT, AND THAT IS DELIBERATE
-- The app is frequently unauthenticated when it breaks — a cold-start failure
-- happens before any session exists, and the customer surface has no login at
-- all. A reporter that only works for signed-in admins would miss exactly the
-- crashes that matter most.
--
-- The cost is a public write endpoint. It is bounded rather than eliminated:
-- every text column has a length CHECK, there is no UPDATE or DELETE policy,
-- and anon cannot SELECT — so this is write-only for the public and readable
-- only by the tour owners. The worst case is junk rows, not disclosure. See
-- the retention note at the bottom; this table needs a broom, not a lock.
--
-- NO PII BY CONSTRUCTION. The client sends a message, a stack, and a small
-- context object of ids and screen names. Passenger names, phone numbers and
-- amounts must never be put in here — a crash report is not a place to leak the
-- data the crash was about.
--
-- Idempotent, re-runnable.
-- ============================================================

create table if not exists public.client_errors (
  id            uuid primary key default gen_random_uuid(),
  occurred_at   timestamptz not null default now(),

  -- Which build is breaking. Without this a spike is unattributable and a
  -- staged rollout cannot be halted on evidence.
  app_version   text,
  build_number  text,
  platform      text,

  -- 'flutter_error' (framework), 'zone_error' (uncaught async),
  -- 'widget_build' (a build() that threw), or whatever a future caller adds.
  kind          text,

  message       text,
  stack         text,

  -- Screen, route, role, tour id. Ids and names only.
  context       jsonb,

  -- Set when a session happened to exist. Null is the common case and is fine.
  reported_by   uuid,

  created_at    timestamptz not null default now(),

  -- Bounds, not validation. A public insert endpoint with unbounded text is a
  -- storage bill waiting to happen.
  constraint client_errors_message_len  check (message  is null or length(message)  <= 2000),
  constraint client_errors_stack_len    check (stack    is null or length(stack)    <= 8000),
  constraint client_errors_version_len  check (app_version is null or length(app_version) <= 40),
  constraint client_errors_build_len    check (build_number is null or length(build_number) <= 40),
  constraint client_errors_platform_len check (platform is null or length(platform) <= 40),
  constraint client_errors_kind_len     check (kind     is null or length(kind)     <= 40),
  constraint client_errors_context_len  check (context  is null or length(context::text) <= 4000)
);

create index if not exists client_errors_occurred_idx
  on public.client_errors (occurred_at desc);

-- The query an operator actually runs: "is this build worse than the last one?"
create index if not exists client_errors_build_idx
  on public.client_errors (build_number, occurred_at desc);

alter table public.client_errors enable row level security;


-- ── Write-only for the public ────────────────────────────────
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_errors'
       and policyname = 'client_errors_anyone_insert'
  ) then
    create policy client_errors_anyone_insert
      on public.client_errors for insert
      to anon, authenticated
      with check (true);
    raise notice '079: created client_errors_anyone_insert';
  end if;

  -- Readable by anyone who owns a tour, i.e. the operators. Deliberately not
  -- scoped per tour: a cold-start crash has no tour, and those are the reports
  -- most worth reading.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_errors'
       and policyname = 'client_errors_owner_read'
  ) then
    create policy client_errors_owner_read
      on public.client_errors for select
      to authenticated
      using (exists (select 1 from public.tours t where t.owner_id = auth.uid()));
    raise notice '079: created client_errors_owner_read';
  end if;
end $$;

-- No UPDATE and no DELETE policy anywhere: a report is append-only, and the
-- broom below runs as the table owner, which RLS does not restrict.

grant insert on public.client_errors to anon, authenticated;
grant select on public.client_errors to authenticated;

comment on table public.client_errors is
  'Dart-level error reports from the app. Write-only for the public, readable '
  'by tour owners. No PII by convention — ids and screen names only. Not a '
  'substitute for Crashlytics: no native crashes, no symbolication.';


-- ============================================================
-- OPERATING IT
--
--   -- Is the build I just shipped worse than the one before it?
--   select build_number, kind, count(*), max(occurred_at) as latest
--     from public.client_errors
--    where occurred_at > now() - interval '24 hours'
--    group by 1, 2
--    order by 3 desc;
--
--   -- What is actually breaking, most common first?
--   select left(message, 120) as msg, count(*), max(occurred_at)
--     from public.client_errors
--    where occurred_at > now() - interval '7 days'
--    group by 1 order by 2 desc limit 20;
--
-- RETENTION. Nothing prunes this table. Run periodically, or schedule it with
-- pg_cron once the volume is known:
--
--   delete from public.client_errors where occurred_at < now() - interval '30 days';
--
-- If the public insert endpoint is ever abused, the fastest mitigation is to
-- drop the anon half of the insert policy — the app degrades to reporting only
-- for signed-in users, which is worse but not broken:
--
--   drop policy client_errors_anyone_insert on public.client_errors;
--   create policy client_errors_anyone_insert on public.client_errors
--     for insert to authenticated with check (true);
--
-- ============================================================
-- VERIFY
--
--   -- Anon can write:
--   insert into public.client_errors (kind, message, app_version, build_number)
--   values ('smoke', 'hello from 079', '1.0.23', '26');
--
--   -- Anon canNOT read (run as anon; expect 0 rows, not an error):
--   select count(*) from public.client_errors;
--
--   -- An owner can read:
--   select id, kind, message from public.client_errors order by occurred_at desc limit 5;
--
--   -- Bounds bite:
--   insert into public.client_errors (message) values (repeat('x', 2001));
--   -- expect: violates check constraint "client_errors_message_len"
-- ============================================================
