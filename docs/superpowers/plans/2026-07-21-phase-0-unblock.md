# Phase 0 — Unblock (deploy + config) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Clear the four deploy/config release blockers (REL-1/REL-2/REL-3/REL-4) plus the fail-loud Android signing guard (X-8) so the current binary builds, installs, writes against the live database without `42703` failures, and iOS push works on the production APNs gateway.

**Architecture:** Three pending Supabase migrations (039/040/041) are deployed BY HAND, one file at a time, in the live SQL editor, each verified before the next; nothing here runs from CI or app code. Two source edits follow: one XML entitlement flip for iOS APNs, and one Kotlin-DSL Gradle guard that aborts a release build when the upload keystore is missing. A final exit-verification task proves the app builds, installs, writes to the live DB, and registers iOS push against production.

**Tech Stack:** Supabase (Postgres migrations), iOS entitlements, Android Gradle (Kotlin DSL), Flutter.

## Global Constraints
- Migrations run BY HAND, one file at a time, in the live Supabase SQL editor, in numeric order; each header says "Run THIS FILE ALONE"; idempotent.
- Do NOT auto-run migrations from CI or code.

---

## File / change map

| # | Deliverable | Path | Kind |
|---|---|---|---|
| Task 1 | Deploy migration 039 (handler lock gate, REL-3) | `supabase/migrations/039_handler_lock_gate.sql` | Procedural DB deploy |
| Task 2 | Deploy migration 040 (`passengers.seats_notified_sig`, REL-1) | `supabase/migrations/040_seat_notified_signature.sql` | Procedural DB deploy |
| Task 3 | Deploy migration 041 (`bus_roster_for_request`, REL-2) | `supabase/migrations/041_seat_roster_for_request.sql` | Procedural DB deploy |
| Task 4 | iOS `aps-environment` = `production` (REL-4) | `ios/Runner/Runner.entitlements:9-10` | Config edit + manual check |
| Task 5 | Android fail-loud release signing guard (X-8) | `android/app/build.gradle.kts:63-83` | Code edit + verification |
| Task 6 | Phase 0 exit verification | — | End-to-end verification |

**Cross-migration dependencies (already live from earlier migrations — do NOT re-create):** 041 calls `public.booking_request_tour_locked(uuid)` (025/027-era) and the customer sheet still calls the live-only `bus_layouts_for_request`; 039 redefines the 003-era `is_request_handler` and the 028-era `handler_requests_by_phone`; 040's column is written by `Passenger.toMap`/`fromMap`. If any Task's verification errors with "function does not exist" for a *dependency* (not the object being created), STOP — the live schema is further out of sync than assumed (see Open Questions).

---

### Task 1: Deploy migration 039 — handler lock gate (REL-3)

**Files:**
- Source (read-only, copy verbatim): `supabase/migrations/039_handler_lock_gate.sql`
- Target: live Supabase project, SQL editor

**What it does:** Redefines two SECURITY DEFINER functions so handler access opens only AFTER a tour is `locked` (or `completed`). `is_request_handler(uuid)` — the single gate every handler RPC and the bus-message Edge Function funnel through — gains a join to `public.tours` and a `t.status in ('locked','completed')` filter, so pre-lock it returns false and every handler write dead-ends. `handler_requests_by_phone(text)` gains the same status filter so the "Manage as handler" entry never appears before lock. Security fix, no client change, no crash if undeployed.

- [ ] **Step 1: Open the file and copy its full contents**

Open `supabase/migrations/039_handler_lock_gate.sql`. Confirm the header line `-- Run THIS FILE ALONE in the Supabase SQL editor`. Copy the entire file.

- [ ] **Step 2: Paste and run THIS FILE ALONE in the live Supabase SQL editor**

Paste and execute exactly this (verbatim from the migration file):

```sql
-- ── 1. The shared handler gate: role AND the tour is locked/completed ──
create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.booking_requests br
        join public.passengers p
          on p.tour_id = br.tour_id
         and p.phone   = br.customer_phone
        join public.tours t
          on t.id = br.tour_id
       where br.id = p_request_id
         and p.is_handler = true
         and t.status in ('locked', 'completed')
    ),
    false
  );
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;

-- ── 2. Phone -> handler-request bridge: only locked/completed tours ────
create or replace function public.handler_requests_by_phone(p_phone text)
returns jsonb
language sql security definer set search_path = public
as $$
  with norm as (
    select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10) as last10
  ),
  refs as (
    select distinct on (t.id)
           br.id             as request_id,
           t.id              as tour_id,
           t.title           as tour_title,
           t.from_city       as from_city,
           t.to_city         as to_city,
           t.departure_date  as departure_date,
           t.status          as status
      from public.passengers p
      cross join norm
      join public.tours t
        on t.id = p.tour_id
      join public.booking_requests br
        on br.tour_id = p.tour_id
       and right(regexp_replace(br.customer_phone, '\D', '', 'g'), 10) = norm.last10
     where norm.last10 <> ''
       and p.is_handler = true
       and right(regexp_replace(p.phone, '\D', '', 'g'), 10) = norm.last10
       and t.status in ('locked', 'completed')
     order by t.id, br.created_at, br.id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'request_id',     refs.request_id,
        'tour_id',        refs.tour_id,
        'tour_title',     refs.tour_title,
        'from_city',      refs.from_city,
        'to_city',        refs.to_city,
        'departure_date', refs.departure_date,
        'status',         refs.status
      )
      order by refs.departure_date desc
    ),
    '[]'::jsonb
  )
    from refs;
$$;

revoke all on function public.handler_requests_by_phone(text) from public;
grant execute on function public.handler_requests_by_phone(text)
  to anon, authenticated;
```

Expected: `CREATE FUNCTION` / `GRANT` success, no error.

- [ ] **Step 3: VERIFY both functions exist and are SECURITY DEFINER**

Run:

```sql
select proname, prosecdef
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('is_request_handler', 'handler_requests_by_phone')
order by proname;
```

Expected: exactly 2 rows; `prosecdef = true` for both.

- [ ] **Step 4: VERIFY the lock gate is present in the definition**

Run:

```sql
select pg_get_functiondef('public.is_request_handler(uuid)'::regprocedure)
       ilike '%t.status in (''locked'', ''completed'')%' as has_lock_gate;
```

Expected: `has_lock_gate = t` (true).

- [ ] **Step 5: VERIFY functional smoke — no error, safe defaults**

Run:

```sql
select public.is_request_handler('00000000-0000-0000-0000-000000000000'::uuid) as gate,
       public.handler_requests_by_phone('0000000000')                          as bridge;
```

Expected: `gate = false`, `bridge = []` (empty jsonb array), no exception.

---

### Task 2: Deploy migration 040 — `passengers.seats_notified_sig` (REL-1)

**Files:**
- Source (read-only, copy verbatim): `supabase/migrations/040_seat_notified_signature.sql`
- Target: live Supabase project, SQL editor

**Interfaces:**
- Produces: the `passengers.seats_notified_sig text` column that `Passenger.toMap` (`lib/models/passenger.dart:339`) always writes and `sync_service.dart:429-449` sends with no column whitelist. Without it EVERY passenger insert/update fails Postgres `42703` (undefined column), breaking the entire booking + seat-assignment write path.

**What it does:** Adds one nullable `text` column, `seats_notified_sig`, to `public.passengers`. Existing rows read NULL = "never notified" (correct — the first seat-allocation WhatsApp send stamps the signature). No RLS change; rides on the existing owner-scoped passengers policies.

- [ ] **Step 1: Open the file and confirm it is standalone**

Open `supabase/migrations/040_seat_notified_signature.sql`. Confirm header `-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.`

- [ ] **Step 2: Paste and run THIS FILE ALONE in the live Supabase SQL editor**

Paste and execute exactly this (verbatim from the migration file):

```sql
alter table public.passengers
  add column if not exists seats_notified_sig text;
```

Expected: `ALTER TABLE` success (no-op if already present — idempotent), no error.

- [ ] **Step 3: VERIFY the column exists with the right type**

Run:

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'passengers'
  and column_name  = 'seats_notified_sig';
```

Expected: exactly 1 row — `seats_notified_sig | text | YES`.

- [ ] **Step 4: VERIFY a read of the column no longer raises `42703`**

Run:

```sql
select id, seats_notified_sig
from public.passengers
limit 1;
```

Expected: returns a row (or zero rows on an empty table) WITHOUT the `column "seats_notified_sig" does not exist` (42703) error. This is the exact failure the client hits on every write until this migration lands.

---

### Task 3: Deploy migration 041 — `bus_roster_for_request` (REL-2)

**Files:**
- Source (read-only, copy verbatim): `supabase/migrations/041_seat_roster_for_request.sql`
- Target: live Supabase project, SQL editor

**Interfaces:**
- Consumes (must already exist in live): `public.booking_request_tour_locked(uuid)` — the lock gate.
- Produces: `public.bus_roster_for_request(uuid) returns jsonb`, called directly by `customer_requests_store.dart:543` and rendered by `customer_seat_layout_sheet.dart:55-84`. The customer "Your Seat" sheet has NO graceful RPC-missing handling, so the whole sheet errors until this function exists.

**What it does:** Adds a SECURITY DEFINER function returning, per assigned seat on the tour behind a request, `{bus_id, seat_id, name, phone}` as a jsonb array. Lock-gated (returns `[]` until the tour is `locked`/`completed`); excludes cancelled passengers. PRIVACY NOTE (intentional for this group-travel app): it returns every assigned rider's name + phone to an anonymous caller holding a booking on a locked tour — do not reuse elsewhere. Deliberately does NOT touch the live-only `bus_layouts_for_request`; the sheet merges this roster on top by `(busId, seatId)`.

- [ ] **Step 1: Open the file and confirm it is standalone**

Open `supabase/migrations/041_seat_roster_for_request.sql`. Confirm header `-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.`

- [ ] **Step 2: Paste and run THIS FILE ALONE in the live Supabase SQL editor**

Paste and execute exactly this (verbatim from the migration file):

```sql
create or replace function public.bus_roster_for_request(p_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id
      from public.booking_requests br
     where br.id = p_id
  )
  select case
    when not public.booking_request_tour_locked(p_id) then '[]'::jsonb
    else coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object(
                   'bus_id',  seat->>'busId',
                   'seat_id', seat->>'seatId',
                   'name',    p.name,
                   'phone',   p.phone
                 )
               )
          from public.passengers p
          join req on req.tour_id = p.tour_id
          cross join lateral jsonb_array_elements(
            coalesce(p.assigned_seats, '[]'::jsonb)
          ) as seat
         where p.cancelled_at is null
           and coalesce(seat->>'busId', '')  <> ''
           and coalesce(seat->>'seatId', '') <> ''
      ),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.bus_roster_for_request(uuid) from public;
grant execute on function public.bus_roster_for_request(uuid)
  to anon, authenticated;
```

Expected: `CREATE FUNCTION` / `GRANT` success, no error. If it errors with `function public.booking_request_tour_locked(uuid) does not exist`, STOP (see Open Questions) — the lock-gate dependency is missing from live.

- [ ] **Step 3: VERIFY the function exists and is SECURITY DEFINER**

Run:

```sql
select proname, prosecdef
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname = 'bus_roster_for_request';
```

Expected: exactly 1 row; `prosecdef = true`.

- [ ] **Step 4: VERIFY functional smoke — safe default, no error**

Run:

```sql
select public.bus_roster_for_request('00000000-0000-0000-0000-000000000000'::uuid) as roster;
```

Expected: `roster = []` (empty jsonb array), no exception. (Passing a non-locked / unknown request id exercises the `booking_request_tour_locked` gate and confirms that dependency resolves.)

---

### Task 4: iOS `aps-environment` = `production` for Release (REL-4)

**Files:**
- Modify: `ios/Runner/Runner.entitlements:9-10`

**What it does:** A store/TestFlight archive uses the PRODUCTION APNs gateway; a `development` entitlement means FCM→APNs pushes silently never arrive, so all iOS push (booking + bus-message alerts) is dead on release. Flip the entitlement to `production`. The APNs auth key upload to Firebase is a backend prerequisite verified manually.

- [ ] **Step 1: Confirm the current value**

Read `ios/Runner/Runner.entitlements`. Line 9-10 currently read:

```xml
	<key>aps-environment</key>
	<string>development</string>
```

- [ ] **Step 2: Edit the entitlement value to `production`**

Change the `<string>` on line 10 so the pair reads:

```xml
	<key>aps-environment</key>
	<string>production</string>
```

Leave the surrounding comment and plist structure untouched. (Note: `production` is correct for TestFlight/App Store. On-device DEBUG push testing against the APNs sandbox may require temporarily flipping back to `development` locally — do NOT commit that; the committed value stays `production`. The cleaner long-term fix is adding the Push Notifications capability in Xcode so it manages the value per build configuration, but the entitlement flip is what unblocks Phase 0.)

- [ ] **Step 3: VERIFY the file now says `production` (Windows-side, repo grep)**

Run (PowerShell):

```powershell
Select-String -Path ios/Runner/Runner.entitlements -Pattern 'aps-environment' -Context 0,1
```

Expected: the matched block shows `<key>aps-environment</key>` immediately followed by `<string>production</string>`.

- [ ] **Step 4: MANUAL CHECKLIST — APNs auth key uploaded to Firebase (backend, not in repo)**

This cannot be verified from the repo. Confirm by hand and check the box only when done:
- [ ] In the Firebase console → Project settings → Cloud Messaging → "Apple app configuration", an **APNs Authentication Key (.p8)** is uploaded for bundle id `com.occubitsolution.ugambooking` (Key ID + Team ID filled in). Without it, FCM cannot deliver to APNs even with the correct entitlement.

- [ ] **Step 5: MANUAL CHECKLIST — archive-time entitlement (Mac, at build time)**

iOS archives are produced on a Mac; verify there. Check the box only when confirmed:
- [ ] After archiving the Release build, the embedded entitlement is production: `codesign -d --entitlements :- <Runner.app>` (or Xcode Organizer → the archive's entitlements) shows `aps-environment = production`.

---

### Task 5: Android — fail loudly instead of debug-signing a release (X-8)

**Files:**
- Modify: `android/app/build.gradle.kts:63-83` (the `buildTypes { release { … } }` block, then add a top-level task-graph guard after the `android { }` block)

**What it does:** Today, when `android/key.properties` is absent, the release build silently falls back to the DEBUG signing key — producing a debug-signed AAB/APK that the Play Store rejects, with nothing failing loudly. This change keeps DEBUG builds working without a keystore but makes any Release-artifact build (`assembleRelease` / `bundleRelease`) throw a `GradleException` when the upload keystore is missing. `GradleException` is in the Gradle Kotlin DSL default imports — no import statement needed.

- [ ] **Step 1: Confirm the current release block**

Read `android/app/build.gradle.kts`. Lines 63-83 currently read:

```kotlin
    buildTypes {
        release {
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Fallback so local --release builds work without the upload key.
                signingConfigs.getByName("debug")
            }
            // Shrink + obfuscate the Java/Kotlin (plugin/engine) layer and
            // strip unused Android resources for a smaller, harder-to-reverse
            // store build. Dart is AOT-compiled and unaffected; the keep rules
            // in proguard-rules.pro guard the reflection-using bits.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}
```

- [ ] **Step 2: Apply the fail-loud guard (before → after)**

Replace the block above (lines 63-83, `buildTypes { … }` through the closing `}` of the `android { }` block) with this — note the new top-level `gradle.taskGraph.whenReady { … }` guard placed AFTER the `android { }` block closes:

**AFTER:**

```kotlin
    buildTypes {
        release {
            // A real upload keystore is REQUIRED to sign a release artifact. When
            // key.properties is absent we still assign the debug config here as a
            // configuration-time placeholder so DEBUG builds keep configuring, but
            // the taskGraph guard below ABORTS the build before any release
            // artifact is produced — we never silently debug-sign a store upload.
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Shrink + obfuscate the Java/Kotlin (plugin/engine) layer and
            // strip unused Android resources for a smaller, harder-to-reverse
            // store build. Dart is AOT-compiled and unaffected; the keep rules
            // in proguard-rules.pro guard the reflection-using bits.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Fail loudly instead of debug-signing a release. If a release artifact
// (assembleRelease / bundleRelease) is in the resolved task graph but no upload
// keystore is configured, abort the build: a debug-signed AAB/APK is rejected by
// the Play Store, and nothing else here fails on its own. DEBUG builds have no
// release task in the graph, so they are unaffected.
gradle.taskGraph.whenReady {
    val assemblingRelease = allTasks.any { task ->
        task.name.contains("Release") &&
            (task.name.startsWith("assemble") || task.name.startsWith("bundle"))
    }
    if (assemblingRelease && !hasKeystore) {
        throw GradleException(
            "Release build aborted: android/key.properties and the upload keystore " +
                "are missing, so this artifact would be debug-signed and rejected by " +
                "the Play Store. Provide key.properties + the keystore, or build a " +
                "debug variant instead."
        )
    }
}
```

- [ ] **Step 3: VERIFY a release build FAILS LOUDLY without the keystore**

On this machine `android/key.properties` is ABSENT (git-ignored), so no rename is needed. (If YOUR machine has it, first `Rename-Item android/key.properties android/key.properties.bak`.) From the repo root, run (PowerShell):

```powershell
cd android; .\gradlew.bat :app:assembleRelease --console=plain; cd ..
```

Expected: BUILD FAILED with the message `Release build aborted: android/key.properties and the upload keystore are missing …`. Confirm it is THIS `GradleException`, not an unrelated failure.

- [ ] **Step 4: VERIFY a debug build still SUCCEEDS without the keystore**

From the repo root, run (PowerShell):

```powershell
cd android; .\gradlew.bat :app:assembleDebug --console=plain; cd ..
```

Expected: BUILD SUCCESSFUL — the guard does not fire for debug (no `Release` assemble/bundle task in the graph). (If you renamed key.properties in Step 3, restore it now: `Rename-Item android/key.properties.bak android/key.properties`.)

- [ ] **Step 5: Commit**

```powershell
git add android/app/build.gradle.kts ios/Runner/Runner.entitlements
git commit -m @'
fix(release): fail-loud Android signing guard + iOS aps-environment=production

X-8: abort assembleRelease/bundleRelease when key.properties is absent instead
of silently debug-signing a store-rejected artifact; debug builds unaffected.
REL-4: flip iOS aps-environment to production so store/TestFlight APNs pushes
are delivered.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

Expected: one commit created on the current branch.

---

### Task 6: Phase 0 exit verification (end-to-end)

**Files:** — (verification only; no code change)

**What it does:** Proves the Phase 0 exit criteria from audit §9: the current binary builds and installs, a passenger create/update succeeds against the live DB (the `42703` blocker is gone), and iOS push registers against production.

- [ ] **Step 1: All three migrations confirmed live**

Re-run the one-shot check:

```sql
select
  to_regprocedure('public.is_request_handler(uuid)')          is not null as has_039_gate,
  exists (select 1 from information_schema.columns
           where table_schema='public' and table_name='passengers'
             and column_name='seats_notified_sig')            as has_040_column,
  to_regprocedure('public.bus_roster_for_request(uuid)')      is not null as has_041_roster;
```

Expected: all three columns `true`.

- [ ] **Step 2: App builds and installs**

Build and install the current binary on a real device (a keyed machine required for a signed release; a debug/profile install is acceptable for this smoke). Run (PowerShell):

```powershell
flutter build apk --debug
flutter install
```

Expected: build succeeds, app launches on the device.

- [ ] **Step 3: Live passenger create/update succeeds (the REL-1 gate)**

In the running app, as an organiser: open a tour, add or edit a passenger, and save (this drives `Passenger.toMap` → `sync_service` write including `seats_notified_sig`). Confirm the save completes with NO error toast and the row persists after a refresh.

Cross-check server-side that the write landed and the column is populated by real traffic:

```sql
select id, name, seats_notified_sig, updated_at
from public.passengers
order by updated_at desc
limit 3;
```

Expected: the just-saved passenger appears; no `42703` occurred during the save.

- [ ] **Step 4: iOS push registers against production**

On a Mac, run the Release (or TestFlight) build on a device and confirm: the app obtains an APNs token, FCM registration succeeds, and a test push (send from the Firebase console or trigger a booking/bus-message alert) is DELIVERED. Confirm the archive's entitlement is `aps-environment = production` (Task 4, Step 5) and the APNs auth key is present in Firebase (Task 4, Step 4).

Expected: a test notification arrives on the physical iOS device from the production gateway.

- [ ] **Step 5: Record Phase 0 done**

All boxes above checked → Phase 0 exit criteria met: writes no longer break, iOS push works, no debug-signed release can be produced. Proceed to Phase 1 (feature completion).

---

## Self-review notes
- **Spec coverage:** REL-3 → Task 1; REL-1 → Task 2; REL-2 → Task 3; REL-4 → Task 4; X-8 → Task 5; §9 Phase 0 exit → Task 6. All Phase 0 items covered.
- **Order:** Migrations deployed in numeric order 039 → 040 → 041 per Global Constraints and audit §2, one file at a time, each verified before the next.
- **No placeholders:** every SQL block is copied verbatim from the actual migration files; the Gradle before/after is the real file content; the entitlement edit is the real two-line pair.
