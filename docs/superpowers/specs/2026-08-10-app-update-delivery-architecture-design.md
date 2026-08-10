# App update delivery architecture — shipping changes without a store release

**Date:** 2026-08-10
**Status:** Design — not started
**Branch:** `feat/money-collection-settlement`
**Research:** 12-agent audit (4 web research, 4 codebase, 3 adversarial verify, 1 synthesis). All three
optimistic claims were refuted; this document reflects the corrected position.

## The question this answers

> "After this one update, do we still have to give new updates through the Play Store?"

**Yes. Always. Forever.** No mechanism removes store releases — they reduce how *often* you need one.

The nearest proof is already on the calendar. `targetSdk = 35` (`android/app/build.gradle.kts:47`), and
from **31 August 2026** every update submitted to Google Play must target API 36. A `targetSdk` bump is a
native build change. No over-the-air channel can carry it. That release is mandatory and imminent.

### The permanent forced-release calendar

These will pull you into a store release no matter what this plan builds:

| Trigger | Cadence | Notes |
| --- | --- | --- |
| Google Play target API bump | **Annually, ~31 Aug** | API 36 due 2026-08-31; extension to 2026-11-01 on request |
| Apple minimum SDK / Xcode requirement | Roughly annually | Must build against a recent SDK to submit at all |
| Flutter SDK / engine upgrade | As needed | `.metadata` pins `84fc5cbb`; also invalidates every outstanding patch |
| Any native plugin add / remove / upgrade | As needed | 18 native plugins on Android, 15 on iOS |
| Security patch in a native dependency | Unpredictable | Not optional when it lands |
| `Info.plist`, entitlements, permissions | As needed | Includes the APNs fix in W1 |
| App icon, launch screen, app name, bundle ID | Rare | |
| New bundled asset, new Material icon | As needed | Icon tree-shaking makes icons assets |

**Realistic outcome of this plan: roughly 4–6 store releases per year instead of one per bug fix.** That
is the honest prize, and it is a large one. It is not zero.

## What we are actually building

Five delivery channels, each with a fixed role. The discipline is the architecture: every change has
exactly one correct channel, decided before the work starts.

| # | Channel | iOS | Android | Carries | Latency |
| --- | --- | --- | --- | --- | --- |
| 1 | Postgres migrations / RPCs | ✅ | ✅ | Fares, holds, settlement, eligibility, validation, workflow rules | Instant |
| 2 | Remote translations overlay | ✅ | ✅ | Every user-visible string, all three locales | Next launch |
| 3 | Remote config / kill switches | ✅ | ✅ | Values compiled code already reads; force-update; maintenance | Next foreground |
| 4 | Store release (staged) | ✅ | ✅ | Everything else | 1 day–1 week |
| 5 | Android sideload prompt | ❌ | ✅ | APK updates outside Play, for sideloaded installs | Next launch |

**Channel 1 already exists and is under-used.** 42 distinct RPCs across 75 migrations already make money
server-authoritative. Three of the last four commits were SQL-only and shipped with no app release at all.
This is the strongest lever in the repo and it is already built.

### Why remote translations rank so high

Across the full 257-commit history:

- **55.6% (143 commits)** touched only Dart/test code
- **20.2% (52 commits)** were blocked by nothing but `assets/translations/{en,gu,hi}.json`
- **~11%** were genuine store-build blockers

On the last 30 commits, patchability goes **33% → 60%** with a remote translation overlay alone. It is pure
data, sits outside App Store Guideline 2.5.2 entirely, needs no vendor and no policy argument, and works
identically on both platforms. Best value-to-risk item in this document.

## What we are deliberately NOT doing: Shorebird code push

### It is currently impossible, not merely risky

`scripts/build_ios_release.sh:36` runs `flutter build ipa`. Shorebird requires `shorebird release ios`
**instead**. A binary from the current script contains no Shorebird engine and no updater — `isAvailable`
returns false and it can never be patched. **Every install of the currently-shipping 1.0.22 is permanently
unpatchable.** Code push is a decision made *before* the release you later want to hotfix.

### Even after adoption, it cannot ship our most common change

Asset patching is unsupported (`shorebirdtech/shorebird#318`, open; `--allow-asset-diffs` silences the
warning but transmits no bytes). Translations are bundled JSON assets loaded by easy_localization's default
`RootBundleAssetLoader` via `pubspec.yaml:124`. **The single largest category of blocked change is exactly
the category Shorebird cannot carry.**

### It cannot be the money safety net

Shorebird's auto-rollback fires only for crashes between snapshot load and Dart VM creation. A patch that
mis-rounds a settlement does not crash — it silently writes bad money across ~3,460 lines of money Dart and
15 minor-unit conversion sites, into a ledger carrying the audit invariants from
`071_ledger_invariant_sees_all_lines`. With zero crash telemetry today, the detection loop is "a handler
complains."

### Further costs

- iOS runs patched code in an **interpreter, ~100x slower than AOT**; worst-10% link is 77% on Flutter 3.44.
  The seat-chart PDF path (`pdf ^3.12.0` + `printing ^5.14.3` + four Noto faces read as raw bytes per glyph)
  would become a multi-minute hang on a low-end handler phone.
- No new Material icon can appear in a patch — tree-shaking makes icons assets and no `--no-tree-shake-icons`
  flag is set anywhere. It renders as a tofu box.
- Requires a macOS machine with a **pinned Xcode version for each release's entire life**, and a physical
  arm64 iPhone per patch (Simulator unsupported). The dev box is Windows 11.
- +2.01MB Android / +4.67MB iOS app size.
- Percentage rollout is **not** built in (`shorebirdtech/shorebird#3782`, open, zero comments) — it is DIY.

### Policy position

Apple's DPLA §3.3.1(B) affirmatively permits downloading interpreted code, and Shorebird ships Dart through
its own interpreter, never touching the native layer. But **Guideline 2.5.2's plain text contains no
interpreted-code carve-out**, and 2.5.2 is what reviewers cite. The carve-out is an appeal argument, not a
safe harbour. Apple has never blessed any OTA tool by name. Google Play is clearer: the Device and Network
Abuse restriction explicitly excludes code running in a VM or interpreter.

### Revisit when

All four must hold: (a) crash telemetry shipped and trusted; (b) server-side ledger alerting live;
(c) a dedicated macOS machine available on demand; (d) an install base large enough that a 24-hour Apple
review is genuinely too slow. **None hold today.** Apple committed to the UK CMA (effective 2026-04-01) to
decide 90% of submissions within 24 hours — review latency is roughly one day, not one week.

## The plan

Sequenced so **nothing that can change behaviour remotely ships before the signal that would catch it
going wrong.**

### Phase 0 — Reconcile and observe (11 days)

Prerequisite for everything. No remote control before observability.

| ID | Work | Days | Risk |
| --- | --- | --- | --- |
| W0 | Reconcile repo with what is shipping; land or shelve the four in-flight programs | 2 | med |
| W1 | Fix iOS APNs entitlement + verify the two unverified prerequisites | 2 | med |
| W2 | Crash/error telemetry; delete the release-mode stack dump | 4 | med |
| W3 | Server-side ledger invariant alerting (migration `073`) | 3 | low |

**W0** — `pubspec.yaml:19` reads `1.0.21+25`; the App Store serves `1.0.22`. The source tree does not
correspond to the shipped binary. The seeding release must be strictly greater than the live store version
on both platforms, verified against the Apple lookup API and the Play listing *before* the gate ships.
Otherwise the force-update gate locks out users who are already current.

**W1** — `ios/Runner/Runner.entitlements:10` reads `aps-environment=development`. TestFlight and App Store
archives use the production APNs gateway, so **iOS push has been silently dead since launch**. Add the
capability in Xcode (per-configuration) rather than hand-editing the shared file, so debug sandbox push
survives. Prove both directions before merging.

**W2** — A repo-wide grep for `crashlytics|sentry|bugsnag` returns nothing. A staged rollout is only as safe
as the signal telling you to halt it. Also replace — do not delete — the `ErrorWidget.builder` override at
`main.dart:42-61`, which currently ships a raw exception and stack trace to users in release. The
replacement keeps swallowing the exception, renders branded copy, reports to the crash backend, and sets the
launch-failure marker.

**W3** — The characteristic failure here is not a crash; it is a wrong number in `finance_lines`. Client
telemetry cannot see it. Build on `070_one_fare_formula` and `071` with a scheduled check for imbalanced
settlements, double-posted collections and orphaned claims. Write it idempotent and tolerant of columns it
does not find — migrations are applied by hand and the repo's migration set is provably incomplete.

### Phase 1 — Remote control (18 days)

| ID | Work | Days | Risk | Depends |
| --- | --- | --- | --- | --- |
| W4 | Remote config transport: cached, fail-open, hard-bounded | 4 | high | W0, W2 |
| W5 | Force-update / maintenance / kill-switch overlay | 5 | high | W4 |
| W6 | Rewrite splash + bootstrap test harnesses | 2 | low | W5 |
| W7 | Close the three gate bypass paths | 2 | med | W5 |
| W8 | Remote translations overlay | 5 | high | W2, W4 |

**W4** — `firebase_remote_config` with generous compiled-in `setDefaults`, last-known-good cached in
SharedPreferences, its own 2–3s timeout, fail-open on timeout/error/parse failure. Warm it fire-and-forget
as the first statement of `_bootstrap()` (`main.dart:105`). Register in `AppBinding` (`app.dart:96`).

**W5** — Implement as an **overlay wrapped in `GetMaterialApp.builder`** (`app.dart:55-88`), not a `GetPage`.
Resolve the decision once at `splash_screen.dart:89`, after the mounted guard and before the role fork at
`:90-94`, folding the already-warm config read into the existing `Future.wait` at `splash_screen.dart:70`.
Do not name it "gate" — `lib/screens/party_gate_screen.dart` owns that word.

**W8** — Custom easy_localization `AssetLoader` merging a versioned/hashed network JSON **over** the
rootBundle catalogue, activating on the next launch rather than blocking first paint. The bundled 576KB
stays in `pubspec.yaml:124` permanently as the offline floor. There is no `http`/`dio` dependency in the repo
today — use `dart:io` or add one (pure Dart, no native cost).

### Phase 2 — The pivot release (9 days)

| ID | Work | Days | Risk | Depends |
| --- | --- | --- | --- | --- |
| W9 | Wire the Android sideload prompt to the manifest CI already publishes | 3 | med | W5 |
| W10 | Execute the Phase 5 dual-store release | 6 | high | W1,W2,W3,W5,W6,W7,W8 |

**W9** — The publisher half already runs on every tag: `.github/workflows/release.yml:64-77` writes
`dist/latest.json` with `apk_url`. Nothing in `lib/` has ever read it. `lib/services/app_updater.dart` and
`lib/utils/update_prompt.dart` were added in `75ce7ab` and later **deleted** — find out why before
rebuilding. Only offer the APK path to sideloaded installs; Play users get a Play deep link. CI holds no
signing secrets, so builds fall back to debug signing (`INTEGRATIONS.md:230`) — a debug-signed APK cannot
update a release-signed install at all.

**W10** — One clean release carrying fixed push, telemetry, the gate, and remote translations. This also
satisfies the **API 36 deadline**, so bump `targetSdk` to 36 here. The Phase 5 runbook exists and has never
been run: 0 of 52 boxes checked. Verify migrations 039/040/041 are actually deployed first. Play staged
rollout starting at 20% with halt as the abort lever; App Store phased release with pause — noting Apple's
phased release **cannot roll back, only halt**, and users can download the new version manually regardless.

Never archive with plain `flutter build ipa` — `scripts/build_ios_release.sh` and its `flutter clean` +
`vtool` verification loop is the only thing preventing the `objective_c.framework` simulator-slice App Store
validation failure.

**This is the pivot.** Everything before it is preparation; everything after depends on it having reached
users.

### Phase 3 — Deferred (Shorebird, 19 days)

Not scheduled. Retained for the record: W11 adoption (6), W12 patch-aware `AppInfo` (2), W13 launch watchdog
(5), W14 DIY percentage rollout (3), W15 physical-device runbook (3). Revisit only when all four conditions
above hold.

## Effort and calendar

| Scope | Person-days |
| --- | --- |
| Phase 0 + 1 + 2 (recommended) | **38** |
| Phase 3 (Shorebird, deferred) | +19 |
| **Full plan** | **57** |

**Calendar is the harder number.** At the observed cadence — 2 part-time committers, 20 distinct commit days
in the last 90 — 38 person-days is **2–4 months**, not two weeks.

**Minimum viable slice: W8 + W4 + W5 ≈ 14 days.** Remote translations plus the config gate. Combined with
the migrations channel that already exists, this covers most of what OTA was hoped to provide.

**Hard constraint:** W0, W1, W2 and the `targetSdk` bump must land before 31 Aug 2026 regardless of
everything else, or Play stops accepting updates.

## Non-negotiable engineering rules

These are the disciplines that prevent this work from breaking the app. Each was verified against the
codebase, not assumed.

1. **No network future ever enters `main.dart:107-115`.** That `Future.wait` has no timeout, and
   `_BootstrapError` (`main.dart:139-143`) fires only on `hasError`, never on a hang. A stalled TLS
   handshake on a 2G link leaves the splash up forever with no retry affordance. Offline cold start works
   today only because none of the four bootstrap inits is a live network call.
2. **The block is an overlay, never a route.** Three paths never touch the splash:
   `push_service.dart:227-243` fires `Get.offAllNamed(AppRoutes.home)` from a post-frame callback armed at
   `main.dart:123` *before* the splash mounts; `auth_controller.dart:320` and `:396` both do
   `Get.offAllNamed('/')` post-login.
3. **Never gate on `isOnline`.** `connectivity_plus` reports `none` for a beat on cold start and previously
   blanked Home on healthy Wi-Fi (`sync_service.dart:228-234`).
4. **Never reuse `SyncService` for config.** `isCellular` defaults true (`sync_service.dart:109`) giving a
   28s read timeout, and the 2-slot cellular read gate can queue the config fetch behind the tour load.
5. **Stay under 1s added latency on the cached path.** `auth_controller.dart:182-190` polls 40×50ms for
   `TourController` then gives up **silently** — exceed it and the confirmed-admin owner-scope re-fetch dies
   with no error, just a wrongly-scoped tour list. `CustomerMemoryController`'s 2200ms deferral timer starts
   at `AppBinding` time, not at Home paint.
6. **The block screen must be localized.** `startLocale` is pinned to `gu` (`main.dart:151`,
   `i18n_config.dart:17`). Anything rendered above `GetMaterialApp` cannot call `tr()`.
7. **Supply an `errorWidget:` at `main.dart:147-154` in the same commit as W8.** When a loader throws,
   EasyLocalization renders `errorWidget ?? ErrorWidget(...)`, and `ErrorWidget.builder` is globally
   redefined as the red "UI ERROR" dump. A CDN blip would otherwise become a full-screen crash-looking page
   for the entire user base.
8. **Queue push deep links, do not drop them.** Notification tap-through is the admin's primary path into
   Requests and works from a killed state. When the overlay clears, the pending link replays.
9. **Fail open, always.** A cached last-known-good value beats a live fetch; an absent config means normal
   operation. `AppInfo.load()` already swallows `PackageInfo` failures leaving empty strings — the gate must
   never block on an empty identity.
10. **Money bugs are fixed with a migration, never a client release.** Channel 1 is instant, reviewless, and
    works identically on both platforms.

## Test baseline

**1260 pass / 1 pre-existing fail** (`handler_bus_chart_screen_test.dart` — concurrent-agent territory; do
not attribute it to this work).

Four of five realistic gate shapes fail the existing harness, verified empirically:

- a Supabase-reading gate fails the `supabase.dart:45` init assertion (the harness never calls
  `Supabase.initialize`)
- `Get.offAllNamed('/gate')` fails with a null-check error in `get/route_middleware.dart:200` — the harness
  at `splash_screen_test.dart:23-31` registers only `AppRoutes.customerHome`
- `Get.find<GateService>()` fails "not found" — grep for `AppBinding` across `test/` returns zero hits
- a 2s-timeout gate fails with "Pending timers"

Only an inert, instant, zero-I/O gate passes untouched. **Budget W6 for it.** Keep the gate's future resolved
synchronously in tests via an injected fake so the splash's dawn-bloom opacity-at-offset assertions
(t=0, 500ms, 900ms, 1000ms) stay untouched.

## Defects found — fix regardless of this plan

1. **iOS push dead since launch** — `ios/Runner/Runner.entitlements:10` (W1).
2. **Auth tokens in plain SharedPreferences** — `main.dart:110-113` passes no `authOptions`, so
   `supabase_flutter` defaults to `SharedPreferencesLocalStorage`, despite `flutter_secure_storage ^9.2.2`
   being a dependency. Not in scope here; should be its own task.
3. **Raw stack traces ship in release** — `main.dart:42-61`, self-labelled "DIAGNOSTIC (temporary)" (W2).
4. **Repo behind the store** — `pubspec.yaml:19` vs live `1.0.22` (W0).
5. **`targetSdk = 35`** with a hard Play deadline of 2026-08-31 (W10).
6. **Orphaned update manifest** — CI publishes `dist/latest.json` that no client reads (W9).

## Decisions required

1. **Confirm Shorebird is deferred.** Recommendation: yes, defer.
2. **Where does gate config live?** A Supabase-hosted maintenance flag is unreadable during the exact
   Supabase outage it exists for. `supabase_config.dart` hardcodes one URL and anon key as compile-time
   consts — no `--dart-define`, no staging environment. Recommendation: Firebase Remote Config, because it
   is independent of the backend it guards.
3. **Fail-open policy.** Recommendation: fail open with a cached last-known-good value. A misconfigured
   config server must not brick the app; the cost is that the kill switch is weakest exactly when the
   backend is unhealthy.
4. **Can a user log out during a maintenance window?** Logout does `Get.offAllNamed('/splash')`
   (`auth_controller.dart:455`) so the block re-runs, and the login screen is reachable only by long-pressing
   the customer tour-list header (`customer_tour_list_screen.dart:380`). Blocking traps users; allowing
   strands them.
5. **Why were `app_updater.dart` and `update_prompt.dart` deleted after `75ce7ab`,** while `release.yml` kept
   publishing the manifest they consumed? Most relevant prior art for W9 and it is recorded nowhere.
6. **Who owns the macOS machine and is it available on demand?** W1, W10 and all of Phase 3 need it. The dev
   box is Windows 11 and `ios/Podfile.lock` has never existed in this checkout.
7. **Declare the gate and remote translations in App Review Notes?** Guideline 2.3.1 bans hidden and dormant
   features. Both are benign; declaring costs nothing and converts a possible 2.5.2 conversation into a
   documented one. Recommendation: declare.

## Sources

- [Google Play — Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/16559646)
- [Google Play — Target API level requirements](https://support.google.com/googleplay/android-developer/answer/11926878)
- [Google Play — Staged rollouts](https://support.google.com/googleplay/android-developer/answer/6346149)
- [Apple — App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Shorebird — Overview](https://docs.shorebird.dev/code-push/), [FAQ](https://docs.shorebird.dev/code-push/faq/), [Percentage-based rollouts](https://docs.shorebird.dev/code-push/guides/percentage-based-rollouts/)
- [Android — A/B seamless updates](https://source.android.com/docs/core/ota/ab) (architectural model for the patch state machine)
