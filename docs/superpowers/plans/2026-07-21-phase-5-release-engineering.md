# Phase 5 — Release Engineering (Dual Store) — Runbook

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to work this runbook task-by-task. This phase is **PROCEDURAL** (build / submit / verify), NOT TDD. Every step is an exact command or an explicit human/console action, each paired with a VERIFICATION (expected output). Steps use checkbox (`- [ ]`) syntax for tracking. Do not skip a verification — a failed check gates the next step.

**Goal:** Ship ONE release of Ugam Bus Booking — version **`1.1.0+26`** — to **Google Play** and the **Apple App Store** from a single reconciled source tree, with the Supabase schema in the live DB proven to match the repo.

**Architecture:** No product-code changes in this phase. It is (1) a one-line version bump in `pubspec.yaml` that flows to both platforms via Flutter build vars, (2) a Supabase migration-provenance reconciliation (rename duplicate files + capture live-only RPCs into the repo, **without re-running anything**), (3) pre-flight gates (`analyze`/`test`/exit-criteria/migration deploy confirmation), (4) an Android AAB build + Play Console upload, (5) an iOS IPA build + App Store Connect upload, and (6) git tagging + post-submit monitoring/rollback notes.

**Tech Stack:** Flutter build tooling (`C:\src\flutter\bin\flutter`), Gradle (`android/app/build.gradle.kts`, Flutter Gradle plugin), Xcode (macOS-only; `ios/Runner.xcodeproj`, automatic signing, `DEVELOPMENT_TEAM=LZKBLPJ282`), Google Play Console, Apple App Store Connect / TestFlight, Supabase (SQL editor, migrations run **by hand**). Repo root: `c:\WorkSpace\ugam-bus-booking`.

## Global Constraints

- **Migrations are run BY HAND, one file at a time, verifying each in the live DB before the next** — never `supabase db push` a batch. This is a standing project convention. The reconciliation in Task 2 does **not** re-run any already-deployed migration; renaming a file is a repo-bookkeeping change only.
- **Both stores ship the SAME version:** `1.1.0+26`. `versionName`/`CFBundleShortVersionString = 1.1.0`; `versionCode`/`CFBundleVersion = 26`. Build number **26** must be strictly greater than the last uploaded on each store (previous was `25`); this holds for both.
- **No secrets in the repo.** The Supabase key shipped in the client is the **publishable/anon** key (RLS-gated); all privileged secrets (WhatsApp Cloud API token, service-role key) live **server-side in Supabase Edge Functions**, never in the app bundle. `android/key.properties` + the upload keystore are git-ignored and supplied only on the release machine. iOS signing is via the Apple Developer account through Xcode. **Do not add, echo, or commit any of these.**
- **Run all Flutter commands from the repo root** in PowerShell, prefixing the path once per shell: `$env:Path = "C:\src\flutter\bin;$env:Path"`.
- **VERIFICATION means observed output**, not assumption. If a check fails, STOP and resolve before proceeding — a store rejection late in the pipeline is far more expensive than a failed local gate.
- **Ordering:** Task 3 (pre-flight) must pass before Task 4/5 (builds). Task 2 (migration reconciliation) can run in parallel with Task 1 but its **verification checklist must be green before any store build is uploaded** (a build that assumes a not-yet-deployed RPC is dead on arrival — see REL-1/2/3).

---

### Task 1: Version bump to `1.1.0+26`

Bump the single source of truth. `pubspec.yaml:19` currently reads `version: 1.0.21+25`. Flutter's Gradle plugin parses this line and exposes `flutter.versionName` (the part before `+`) and `flutter.versionCode` (the part after `+`); iOS reads the same two values as `$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`. **One edit reaches both platforms — no `build.gradle.kts` and no `project.pbxproj` edit is required.**

**Why `1.1.0+26` (MINOR bump), not `1.0.22+26` (patch):** Phases 1-4 add net-new user-facing capability — the handler cash-handover / settlement loop (§7.1), the billed-revenue snapshot (CALC-1), WhatsApp-settings reachability (AL-2), plus correctness and responsiveness work. New features → MINOR under semver, so `1.0.21 → 1.1.0`. The build number is a monotonic integer independent of semver and only has to increase: `25 → 26`.

**Files:**
- Modify: `pubspec.yaml` (line 19)

- [ ] **Step 1 — Edit the version line.** Change `pubspec.yaml:19` from `version: 1.0.21+25` to:
  ```yaml
  version: 1.1.0+26
  ```
- [ ] **Step 2 — Re-resolve so the build vars regenerate.** Run:
  ```powershell
  $env:Path = "C:\src\flutter\bin;$env:Path"; flutter pub get
  ```
  VERIFICATION: exits `0`, prints `Got dependencies!` (or `Resolving dependencies...` then no error). This regenerates `android/local.properties` / Flutter tool state with `flutter.versionName=1.1.0`, `flutter.versionCode=26`.
- [ ] **Step 3 — Confirm the Android wiring is untouched and correct.** Read `android/app/build.gradle.kts:48-49`; VERIFICATION: it still reads `versionCode = flutter.versionCode` and `versionName = flutter.versionName` (no literals). No edit needed — the pubspec value flows through.
- [ ] **Step 4 — Confirm the iOS wiring.** Read `ios/Runner/Info.plist:21-26`; VERIFICATION: `CFBundleShortVersionString = $(FLUTTER_BUILD_NAME)` and `CFBundleVersion = $(FLUTTER_BUILD_NUMBER)`. Read `ios/Runner.xcodeproj/project.pbxproj`; VERIFICATION: the **Runner** target's `CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)"` (lines ~503/695/727). NOTE: `MARKETING_VERSION = 1.0` appears only on the **RunnerTests** targets (lines ~533/551/567) — that is the test bundle, NOT the shipped app, and needs no change. No pbxproj edit needed.
- [ ] **Step 5 — Grep-verify the edit landed.** Run:
  ```powershell
  Select-String -Path pubspec.yaml -Pattern "^version:"
  ```
  VERIFICATION: prints exactly `version: 1.1.0+26`.

---

### Task 2: Migration provenance reconciliation (duplicates + live-only RPC drift)

The repo has **duplicate migration numbers** and **live-only RPCs not present in the repo**, so the migration folder does not equal the deployed schema. This task makes the repo an honest mirror of live **without re-running any deployed migration**. Migrations are run by hand and there is no `supabase db push` history table gating re-apply — so renaming files is pure bookkeeping, safe by construction. Use `git mv` to preserve history.

**Observed drift (from reading `supabase/migrations/`):**
- Two `004_*`: `004_money_collection.sql` (its internal header even says "003 Money collection" — it **creates** `collections`, `expenses`, `bus_handovers` + per-seat pricing) and `004_handler_collections.sql` (**extends** the handler RPCs to read those tables — depends on them).
- Two `006_*`: `006_handler_manifest_rear_zone.sql` (re-creates `handler_tour_manifest` with rear-zone fields; its header says "Must run AFTER 005" and it rebuilds the function last set in `004_handler_collections`) and `006_seat_groups_priority.sql` (independent — adds `passenger_groups`, `passengers.group_id`, priority columns).
- Live-only RPCs referenced by the client but absent from the repo: `bus_layouts_for_request(p_id uuid)` (called at `lib/services/customer_requests_store.dart:521`) and `booking_request_status_lookup(p_id uuid)` (called at `customer_requests_store.dart:370`). (`bus_roster_for_request` is now in the repo as `041`.)

**True deployed order** (reconstructed from headers + hard dependencies):
1. `004_money_collection.sql` — creates the money tables (must be first of the pair).
2. `004_handler_collections.sql` — extends handler RPCs onto those tables.
3. `005_bus_rear_zone_pricing.sql` — adds `buses.rear_rows` / `rear_price`.
4. `006_seat_groups_priority.sql` — independent groups/priority tables.
5. `006_handler_manifest_rear_zone.sql` — rebuilds the manifest with rear fields (after 005 + after `004_handler_collections`).

**Files:**
- Rename (git mv): `supabase/migrations/004_money_collection.sql`, `004_handler_collections.sql`, `006_seat_groups_priority.sql`, `006_handler_manifest_rear_zone.sql`
- Edit (comment only): the renamed `004a` file's header
- Create: `supabase/migrations/044_live_rpc_capture.sql`
- Create: `supabase/migrations/README-provenance.md` (the deployed-order ledger)

- [ ] **Step 1 — Disambiguate the duplicate numbers with sortable `a`/`b` suffixes (repo-only rename, NO SQL run).** The `a`/`b` suffix encodes true order, keeps the files adjacent, and disturbs neither `005` nor `007+`. Run from repo root:
  ```powershell
  git mv supabase/migrations/004_money_collection.sql      supabase/migrations/004a_money_collection.sql
  git mv supabase/migrations/004_handler_collections.sql   supabase/migrations/004b_handler_collections.sql
  git mv supabase/migrations/006_seat_groups_priority.sql   supabase/migrations/006a_seat_groups_priority.sql
  git mv supabase/migrations/006_handler_manifest_rear_zone.sql supabase/migrations/006b_handler_manifest_rear_zone.sql
  ```
  VERIFICATION: `git status` shows four `renamed:` entries (not delete+add). A `Glob supabase/migrations/*.sql` shows no remaining duplicate stem; the sequence reads `...003, 004a, 004b, 005, 006a, 006b, 007...`.
- [ ] **Step 2 — Fix the stale internal header on the money file (comment-only, no DDL change).** In `supabase/migrations/004a_money_collection.sql:2`, change the title line `-- 003  Money collection ...` to `-- 004a  Money collection ...` so the header matches the filename. VERIFICATION: `Select-String -Path supabase/migrations/004a_money_collection.sql -Pattern "^-- 004a"` prints the line; no `create`/`alter` line was touched (`git diff` shows only the comment line changed).
- [ ] **Step 3 — Extract the EXACT live definitions of the two live-only RPCs (do NOT hand-write them from the client call).** In the **Supabase SQL editor** (human action — requires project DB access), run:
  ```sql
  select pg_get_functiondef('public.bus_layouts_for_request(uuid)'::regprocedure);
  select pg_get_functiondef('public.booking_request_status_lookup(uuid)'::regprocedure);
  ```
  VERIFICATION: each returns one `CREATE OR REPLACE FUNCTION public.<name>(p_id uuid) ... ` body. Copy both verbatim. If either errors with `function ... does not exist`, STOP — the client at `customer_requests_store.dart:370/521` would be broken against live and this is a bigger problem than a capture migration.
- [ ] **Step 4 — Write the capture migration.** Create `supabase/migrations/044_live_rpc_capture.sql`. Header block, then paste the two verbatim definitions (they are already `create or replace`, so they are no-ops against live and idempotent). Preserve the live `revoke`/`grant` lines if `pg_get_functiondef` did not include them — capture the grants from the live DB too (`select ... from information_schema.role_routine_grants where routine_name in (...)`). Template:
  ```sql
  -- ============================================================
  -- 044  Capture live-only RPCs into the repo (NO behavior change)
  -- ------------------------------------------------------------
  -- These two SECURITY DEFINER functions exist ONLY in the live DB and were
  -- never committed. Bodies below are the VERBATIM output of pg_get_functiondef
  -- from live (Task 2, Step 3) — create-or-replace, so re-running is a no-op and
  -- changes nothing. This file exists so the repo == live.
  --   bus_layouts_for_request(p_id uuid)        -> customer_requests_store.dart:521
  --   booking_request_status_lookup(p_id uuid)  -> customer_requests_store.dart:370
  -- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
  -- ============================================================

  -- <paste verbatim create-or-replace + grants for bus_layouts_for_request>

  -- <paste verbatim create-or-replace + grants for booking_request_status_lookup>
  ```
  VERIFICATION: the file contains two `create or replace function public.` statements with signature `(p_id uuid)` matching the client `params: {'p_id': ...}`.
- [ ] **Step 5 — Run 044 against live to confirm it is a true no-op** (human action, Supabase SQL editor). Paste the whole `044` file, run once. VERIFICATION: succeeds with no error; a follow-up `select pg_get_functiondef(...)` for each returns a body byte-identical to Step 3 (create-or-replace of the same body changes nothing).
- [ ] **Step 6 — Write the deployed-order ledger.** Create `supabase/migrations/README-provenance.md` documenting: (a) the true deployed order list from this task's preamble, (b) that `004a`/`004b`/`006a`/`006b` are historical files already applied — do NOT re-run, (c) that `044` captured previously-live-only RPCs, (d) the by-hand-one-file-at-a-time convention. VERIFICATION: file lists all migrations `001 → 044` in deployed order with the two live-only RPCs marked "captured in 044".
- [ ] **Step 7 — VERIFICATION CHECKLIST: repo migrations == live DB.** In the Supabase SQL editor, enumerate every `public` function and every table/column, then reconcile against the repo:
  ```sql
  -- (a) all public functions + identity args
  select p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' order by 1, 2;

  -- (b) all public tables + columns
  select table_name, column_name, data_type
    from information_schema.columns
   where table_schema = 'public' order by 1, 2;
  ```
  Confirm each row:
  - [ ] Every function name in result (a) appears in a `create ... function public.<name>` in some repo migration (grep the folder). No live function is unaccounted for.
  - [ ] `bus_layouts_for_request` and `booking_request_status_lookup` now appear in BOTH live (a) AND repo (`044`).
  - [ ] `bus_roster_for_request` appears in both live and repo (`041`) — confirms REL-2's migration is deployed.
  - [ ] `seats_notified_sig` column present on `passengers` in (b) — confirms `040` is deployed (REL-1 gate).
  - [ ] No table/column exists in (b) that no repo migration creates.
  - [ ] `git status` shows only renames + `044` + `README-provenance.md` + the `004a` header comment — no accidental edits to deployed SQL bodies.

---

### Task 3: Pre-flight verification (gates the builds)

Prove the tree is green and the backend is deployed before spending build/upload cycles. All commands from repo root with the Flutter path exported.

- [ ] **Step 1 — Static analysis clean.**
  ```powershell
  $env:Path = "C:\src\flutter\bin;$env:Path"; flutter analyze
  ```
  VERIFICATION: `No issues found!` — or at most the small set of pre-existing info/warning items the audit already logged (§ audit intro: "6 info/warning items, 0 errors"). **Zero errors** is the gate. Any new error blocks the release.
- [ ] **Step 2 — Full test suite passes.**
  ```powershell
  flutter test
  ```
  VERIFICATION: ends `All tests passed!` (baseline is ~78 files / ~680 cases per the audit). Any failure blocks the release.
- [ ] **Step 3 — Confirm Phase 0-4 exit criteria are met** (cross-phase dependency — see "Cross-phase assumptions" at the end). Check each:
  - [ ] **Phase 0:** `ios/Runner/Runner.entitlements:10` `aps-environment` = `production` (currently `development` in the repo — Phase 0 must have flipped it; **verify before an iOS archive**, REL-4). Android fail-loud signing guard present in `build.gradle.kts`.
  - [ ] **Phase 1:** migrations `042_handler_handover.sql` and `043_billed_snapshot.sql` exist in `supabase/migrations/` and the handler-handover + billed-snapshot code is merged.
  - [ ] **Phase 2-4:** their exit criteria per audit §9 (no money double-count, notify-tracker persisted state, tour-form validation, sync tests, cross-cutting themes) are signed off on the release branch.
- [ ] **Step 4 — Confirm migrations 039-043 are deployed to live** (human action, Supabase SQL editor). Using the Task 2 Step 7 enumeration, confirm each object exists in live:
  - [ ] `039_handler_lock_gate` — `is_request_handler` / `handler_requests_by_phone` gated (REL-3).
  - [ ] `040_seat_notified_signature` — `passengers.seats_notified_sig` column exists (REL-1).
  - [ ] `041_seat_roster_for_request` — `bus_roster_for_request(uuid)` function exists (REL-2).
  - [ ] `042_handler_handover` — `handler_upsert_handover` function + `bus_handovers` reachable via manifest (Phase 1).
  - [ ] `043_billed_snapshot` — `passengers.billed_amount` column exists (Phase 1 / CALC-1).
  VERIFICATION: all five present. If any is missing, deploy it by hand (one file, verify) BEFORE building — shipping the client without them reproduces the REL-1/2/3 write-path breakage.

---

### Task 4: Android release build + Play Console upload

Build a release-signed AAB and stage it through internal testing before production. The keystore is **not** on this dev machine (verified: no `android/key.properties`, no `.jks`) — these steps assume the designated **release machine** that holds the upload key.

**Files (release machine only, git-ignored — never commit):**
- `android/key.properties` (four keys: `storePassword`, `keyPassword`, `keyAlias`, `storeFile`)
- the upload keystore `.jks` referenced by `storeFile`

- [ ] **Step 1 — Confirm the signing material is present** (human action / credentials). On the release machine, `android/key.properties` must exist with:
  ```properties
  storePassword=<from release owner — NOT in repo>
  keyPassword=<from release owner — NOT in repo>
  keyAlias=<upload key alias>
  storeFile=<absolute or android/-relative path to the .jks>
  ```
  VERIFICATION: `Test-Path android/key.properties` → `True`, and `Test-Path <storeFile path>` → `True`. If `key.properties` is ABSENT, `build.gradle.kts:64-70` **silently falls back to the debug key** and the AAB will be store-rejected — this is the conditional blocker (X-8). Do not proceed without it.
- [ ] **Step 2 — Clean build the app bundle.**
  ```powershell
  $env:Path = "C:\src\flutter\bin;$env:Path"; flutter clean; flutter pub get; flutter build appbundle --release
  ```
  VERIFICATION: ends `√ Built build\app\outputs\bundle\release\app-release.aab`. That path is the artifact to upload.
- [ ] **Step 3 — Prove the AAB is RELEASE-signed, not debug-signed.** Inspect the signing certificate:
  ```powershell
  keytool -printcert -jarfile build\app\outputs\bundle\release\app-release.aab
  ```
  VERIFICATION: the certificate `Owner:` is your upload key's DN — it must **NOT** be `CN=Android Debug, O=Android, C=US`. A debug DN means Step 1 failed; rebuild with the keystore. (Under Play App Signing, Google re-signs with the app key on their side; the upload AAB must carry the **upload** key, which this check confirms.)
- [ ] **Step 4 — Prepare release notes (minimal convention — there is NO fastlane/metadata tooling in this repo).** Create `store_assets/release_notes/en-US.txt` (≤500 chars, Play's "What's new" limit), plain text, e.g. one line per user-visible change. Reuse the same text for the App Store "What's New" (Task 5). VERIFICATION: file exists, ≤500 chars, no secrets/internal jargon. This becomes the durable convention for future releases (folder `store_assets/release_notes/<locale>.txt`).
- [ ] **Step 5 — Upload to the Internal testing track first** (human action, Play Console — https://play.google.com/console). Click-path: select app **Ugam Booking** → left nav **Test and release → Testing → Internal testing** → **Create new release** → **Upload** `app-release.aab` → paste `store_assets/release_notes/en-US.txt` into "Release notes" → **Next** → **Save and publish**. VERIFICATION: the release shows version **1.1.0 (26)**, status "Available to internal testers", and Play raises **no** "debug-signed"/"unsigned" error.
- [ ] **Step 6 — Confirm the store listing assets are attached** (human action, Play Console → **Grow → Store presence → Main store listing**). From `store_assets/`: app icon (`play_store_icon_512.png`), feature graphic (`feature_graphic.png`), and the 4 phone screenshots (`screen_1_browse.png`, `screen_2_seats.png`, `screen_3_booking.png`, `screen_4_requests.png`). VERIFICATION: all required slots filled (icon + feature graphic + ≥2 screenshots is Play's minimum; we have 4); "Main store listing" page shows a green check.
- [ ] **Step 7 — Validate on a real internal-tester device.** Install via the internal-testing opt-in link; smoke-test: login, browse a tour, seat sheet ("Your Seat"), a booking, and confirm a **push notification arrives** (booking/bus-message). VERIFICATION: no crash on cold start; writes succeed (proves 040 deployed); push received (proves FCM path). This is the last gate before production.
- [ ] **Step 8 — Promote to Production** (human action, Play Console). Click-path: **Test and release → Production → Create new release** → **Add from library** → pick the validated `1.1.0 (26)` bundle → paste the same release notes → **Next** → set a **staged rollout** (e.g. start at 20%) → **Save and publish** → **Send for review**. VERIFICATION: Production release status = "In review" (then "Live" after Google approves), version 1.1.0 (26), rollout percentage as set.

---

### Task 5: iOS release build + App Store Connect upload

**Requires macOS + Xcode + the Apple Developer account for team `LZKBLPJ282`.** This cannot be done from the current Windows dev machine — it is a hard prerequisite / open question (see end). Signing is **Automatic** (`CODE_SIGN_STYLE = Automatic`, `project.pbxproj:502/694/726`), bundle id `com.occubitsolution.ugambooking`.

- [ ] **Step 1 — Verify the push entitlement is production BEFORE archiving** (REL-4 gate). Read `ios/Runner/Runner.entitlements:9-10`. VERIFICATION: `<key>aps-environment</key>` value is `<string>production</string>`. If it still says `development` (the repo's current value), Phase 0 did not land — an archive built with a development entitlement means **all iOS push silently dies on release**. Fix before archiving.
- [ ] **Step 2 — Confirm the APNs auth key is configured in Firebase** (human action — Firebase console → Project settings → Cloud Messaging → Apple app configuration). VERIFICATION: an **APNs Authentication Key (.p8)** is uploaded for the app; without it FCM→APNs delivery fails even with the correct entitlement. (Backend config; the audit marks this "Unknown — verify manually", §8.)
- [ ] **Step 3 — Confirm export-compliance is pre-answered.** Read `ios/Runner/Info.plist:30-31`. VERIFICATION: `ITSAppUsesNonExemptEncryption` = `<false/>` — so App Store Connect will not prompt export-compliance per upload.
- [ ] **Step 4 — Build the IPA** (on macOS, from repo root):
  ```bash
  export PATH="$HOME/flutter/bin:$PATH"   # or the mac Flutter SDK path
  flutter clean && flutter pub get && flutter build ipa --release
  ```
  VERIFICATION: ends `Built IPA to build/ios/ipa`, producing `build/ios/ipa/*.ipa`. (Alternative: `flutter build ipa` then open `build/ios/archive/Runner.xcarchive` in Xcode Organizer, or `open ios/Runner.xcworkspace` → **Product → Archive**.) Automatic signing resolves the distribution cert/profile from the logged-in Apple ID on team `LZKBLPJ282`.
- [ ] **Step 5 — Upload to TestFlight** (human action). Either Xcode **Organizer → Distribute App → App Store Connect → Upload**, or:
  ```bash
  xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
  ```
  (App Store Connect API key — credential, from the release owner; or use the Transporter app.) VERIFICATION: the build appears under App Store Connect → **TestFlight** as version **1.1.0 (26)**, state "Processing" → "Ready to Test".
- [ ] **Step 6 — Fill the App Store listing + privacy nutrition labels** (human action, App Store Connect → https://appstoreconnect.apple.com → app **Ugam Booking**). Click-path: **App Store** tab → **+ Version or Platform → iOS**, version `1.1.0`. Attach the 1024px icon (`store_assets/app_store_icon_1024.png`) and screenshots (from `store_assets/`), paste "What's New" = `store_assets/release_notes/en-US.txt`. Then **App Privacy → Edit**: declare data collected — Contacts (`flutter_contacts`), phone numbers, and any usage/diagnostics; the app collects passenger names/phones for the booking function. VERIFICATION: version page shows no red "missing metadata" flags; App Privacy shows a completed questionnaire (not "Get Started").
- [ ] **Step 7 — Validate on TestFlight, then submit for review** (human action). Add the build to internal TestFlight testers, install, smoke-test login/browse/seat-sheet/booking + confirm a **production push arrives** (proves Steps 1-2). Then App Store Connect → version `1.1.0` → **Add Build** → select `1.1.0 (26)` → optionally enable **Phased Release for automatic updates** → **Add for Review → Submit for Review**. VERIFICATION: version state = "Waiting for Review", build 26 attached, push confirmed working on a real device before submission.

---

### Task 6: Post-submit — tag, monitor, rollback/hotfix

- [ ] **Step 1 — Tag the exact shipped commit** (only after BOTH stores accept the build; the tag marks the reconciled tree). From repo root:
  ```powershell
  git tag -a "v1.1.0+26" -m "Release 1.1.0 (26) — dual store (Play + App Store)"
  git push origin "v1.1.0+26"
  ```
  VERIFICATION: `git tag -l` lists `v1.1.0+26` (repo currently has **zero** tags — this establishes the convention `vMAJOR.MINOR.PATCH+BUILD`). The name is a valid git ref (`+` is allowed).
- [ ] **Step 2 — Monitor for the first 24-72h** (human action; NOTE: the app bundles no Crashlytics/analytics SDK — monitoring is store-console-side + Firebase for push). Check:
  - [ ] **Play Console → Test and release → App quality / Android vitals** for a crash-rate or ANR spike on 1.1.0 (26).
  - [ ] **App Store Connect → App Analytics** and **Xcode Organizer → Crashes** for iOS crash reports on 26.
  - [ ] **Firebase console → Cloud Messaging** delivery stats to confirm pushes are landing on both platforms (this is the REL-4 regression surface).
  VERIFICATION: crash-free rate holds near the prior baseline; push delivery non-zero on iOS (confirms production APNs).
- [ ] **Step 3 — Rollback / hotfix note (no code change now — reference for if monitoring goes red).**
  - **Android:** you cannot truly un-ship an installed version, but in **Play Console → Production** you can **halt the staged rollout** immediately (that's why Task 4 Step 8 starts at a fraction), then ship a hotfix as a **higher versionCode** (`1.1.1+27`).
  - **iOS:** you cannot roll back a live version. If Phased Release is on, **pause** it (App Store Connect → version → Phased Release → Pause). A fix requires a new build — bump to `1.1.1+27`, rebuild, and use **Expedited Review** if severe.
  - **Hotfix path (both):** branch from tag `v1.1.0+26`, fix, bump pubspec to `1.1.1+27` (Task 1 flow), re-run Task 3 gates, rebuild (Tasks 4-5), re-tag `v1.1.1+27`.
  VERIFICATION (dry-run only): confirm you can locate the "halt rollout" (Play) and "pause phased release" (App Store Connect) controls now, so they're one click away under pressure. No action unless a metric regresses.

---

## Cross-phase assumptions (must be TRUE from Phases 0-4 before this runbook ships)

- **Phase 0 flipped `aps-environment` to `production`** in `ios/Runner/Runner.entitlements` (repo still shows `development` — Task 3 Step 3 / Task 5 Step 1 re-verify; hard iOS-push blocker REL-4).
- **Phase 0 added the fail-loud Android signing guard** and the upload keystore exists on the release machine (Task 4 Step 1).
- **Migrations 039, 040, 041 are deployed to live** (REL-1/2/3) — else the client's passenger writes and customer seat sheet break on arrival.
- **Phase 1 produced and deployed migrations `042_handler_handover.sql` and `043_billed_snapshot.sql`** (they do NOT yet exist in the repo folder — only 039/040/041 do). Task 3 Step 4 confirms all of 039-043 live.
- **Phases 2-4 are merged and green** on the release branch: `flutter analyze` has 0 errors and `flutter test` is all-green at the commit being tagged.
- **`store_assets/` holds** the icon set + feature graphic + 4 screenshots (verified present); there is **no** fastlane/metadata tooling, so listing + release notes are manual (Task 4 Step 4 establishes `store_assets/release_notes/<locale>.txt`).

## Open questions (need a human decision / credential / environment)

1. **macOS + Xcode availability.** The current dev box is Windows; Task 5 (iOS build + upload) cannot run here. Who/what machine builds the iOS archive on team `LZKBLPJ282`? If none is available, the Android release can ship independently but "dual store" is blocked.
2. **Store credentials.** Play Console publishing access + the Android upload keystore & `key.properties` passwords; Apple ID with App Manager role + an App Store Connect API key (or Transporter). All are human-supplied and must never enter the repo.
3. **APNs auth key in Firebase** is marked "Unknown" in the audit (§8) — confirm the `.p8` is uploaded before the iOS submission, or production push stays dead.
4. **Live-only RPC bodies** (`bus_layouts_for_request`, `booking_request_status_lookup`) are captured verbatim via `pg_get_functiondef` (Task 2 Step 3). This assumes live DB read access; if the person running the build lacks it, the capture migration cannot be authored honestly.
5. **Release-notes copy.** `store_assets/release_notes/en-US.txt` content (the user-facing changelog for 1.1.0) needs sign-off — Phases 1-4 features summarized in ≤500 chars.
6. **No in-app crash/analytics SDK** — post-launch monitoring (Task 6 Step 2) depends entirely on store consoles + Firebase; if richer telemetry is wanted, that's a separate change, not part of this release.
