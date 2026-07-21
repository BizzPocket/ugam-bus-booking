# Ugam Bus Booking — Full-App Audit & Production-Readiness Report

**Date:** 2026-07-21
**Branch:** `feat/money-collection-settlement`
**App version:** `1.0.21+25`
**Goal:** Feature-complete all flows, verify every calculation, harden every screen (data + responsiveness), then ship a single release to **Google Play + Apple App Store**.

This is the shared source of truth and the fix backlog. It was produced by a 7-agent parallel read-only audit covering: customer/auth flow, handler flow, admin tour-lifecycle, admin seat/chart, admin money/comms, all calculations, and cross-cutting technical + dual-store release readiness. Static analysis (`flutter analyze`) is clean (6 info/warning items, 0 errors). Test suite: 78 files / ~680 cases.

---

## 1. Executive summary

| Flow | Completion | Health | Notes |
|---|---|---|---|
| Customer + auth | ~95% | Good | Mature, defensively coded. Localization polish + minor overflow only. |
| Handler | ~80% | Needs-work | Two structural gaps: no handler-side cash handover, and load-once/no-refresh. |
| Admin — tour lifecycle | ~90% | Good | Reactive, optimistic writes. Gaps: no form validation, one orphaned screen. |
| Admin — seat/chart | ~90% | Good | Shared engine, overflow-proof grids. Two count-overshoot bugs; tile text scaling. |
| Admin — money/comms | ~90% | Good | Aggregation sound. Notify tracker state bug; no loading/refresh on money screens. |
| Calculations | ~95% | Good | Core cash math sound & tested. One high-impact billed-profit display bug. |
| Cross-cutting / release | — | Close | Disciplined codebase; iOS 90% ready. iOS push entitlement + untested sync layer. |

**Overall verdict:** The codebase is unusually disciplined — one design-token system, a centralized optimistic-write/revert path, airtight i18n (en/gu/hi in sync), and a well-tested cash-math core. It is **close to a dual-store release** but **not shippable today**. The gating items are deployment/config (DB migrations, iOS push entitlement, signing) plus a handful of correctness/completeness fixes. There are **no crash-class blockers in the UI**; the blockers are backend-deploy ordering, one iOS entitlement, and the feature gaps you asked to close.

**Severity counts (this audit):** ~4 release blockers · 8 High · 24 Medium · 23 Low.

---

## 2. Release blockers (must clear before any build ships)

| ID | Blocker | Evidence | Action |
|---|---|---|---|
| REL-1 | **Migration `040_seat_notified_signature.sql` undeployed** — client always writes `seats_notified_sig` with no column whitelist, so every passenger insert/update fails `42703` without the column. Breaks the entire booking + seat-assignment write path. | `lib/models/passenger.dart:339` → `lib/services/sync_service.dart:429-449`; `supabase/migrations/040_*.sql` still `??` | Deploy 040 **before** shipping this client. |
| REL-2 | **Migration `041_seat_roster_for_request.sql` undeployed** — customer "Your Seat" sheet calls `bus_roster_for_request` directly with no graceful RPC-missing handling; whole sheet errors until it exists. | `lib/services/customer_requests_store.dart:543` → `lib/widgets/customer_seat_layout_sheet.dart:55-84` | Deploy 041. |
| REL-3 | **Migration `039_handler_lock_gate.sql` undeployed** — no crash, but handler can run money/attendance/messaging **before** the tour is locked (server-side auth gap). | `supabase/migrations/039_*.sql`; gates `is_request_handler` / `handler_requests_by_phone` | Deploy 039 (security). |
| REL-4 | **iOS APNs entitlement = `development`** — a store/TestFlight archive uses the production APNs gateway; a `development` entitlement means FCM→APNs pushes silently never arrive. All iOS push (booking + bus-message alerts) is dead on release. | `ios/Runner/Runner.entitlements:10` | Set `aps-environment` = `production` for Release; confirm APNs auth key in Firebase. |

**Conditional blocker:** Android release build **silently falls back to the debug signing key** when `android/key.properties` is absent — a debug-signed AAB is store-rejected. Fine on a keyed machine, but nothing fails loudly. `android/app/build.gradle.kts:64-70`.

**Deploy order (by hand, one file at a time, per project convention):** `039` → `040` → `041`, verify each in the live DB, then build.

---

## 3. High-priority findings

| ID | Sev | Category | Finding | Evidence | Fix |
|---|---|---|---|---|---|
| CALC-1 | High | Calc | **"True billed" profit collapses for outbound-only riders after the GO leg completes.** `revenueBilled`/`netBilled` is recomputed live from seat assignments, but `completeOutboundLeg` clears those riders' seats → `amountDueFor` returns 0 → the "NET PROFIT (true billed)" headline understates by their fares, and `netBilled < netCollected` (a paradox). Cash settlement unaffected (display only). | `money_controller.dart:349-352` → `bus_details.dart:514-532` → `tour_controller.dart:729`; shown at `trip_pnl_screen.dart:193` | Compute billed revenue from a persisted per-seat billed snapshot (or from collection `amountDue` for retired riders), not live `assignedSeats`. |
| H-1 | High | Completeness | **No handler-side cash handover — settlement loop is one-directional.** `HandlerManifest` has no `handovers`; `inHand` never subtracts what the admin recorded as handed over; no `handlerUpsertHandover` RPC. Handler sees full "in hand" forever, can't mark cash remitted. | `handler_manifest.dart:16-42`, `handler_bus_money.dart:50`, `customer_requests_store.dart:636-725` | See §7 Settlement Gap Spec. |
| H-2 | High | Data | **Handler screen loads once — no refresh, no realtime, no retry.** Admin changes mid-shift (reassignments, lock/re-notify, recorded handover) are invisible; error card has no retry; offline not distinguished from error. | `handler_bus_chart_screen.dart:242,250,696-707,776-847` | Add pull-to-refresh + retry on error card; ideally realtime or re-fetch on resume. |
| AM-1 | High | Data | **Notify tracker shows everyone "Pending" / 0-sent after any reload.** Progress bar, filter counts, per-row badges derive from session-only `_sentIds` (cleared on restart/tour-switch), while the CTA correctly reads the persisted `seatsChangedSinceNotified`. Leads operator to re-broadcast **paid** WhatsApp to already-notified riders. | `notify_screen.dart:41,124-127,277-279,302,337` vs `:222` | Derive `isSent`/counts from `!p.seatsChangedSinceNotified` (persisted), not `_sentIds`. |
| AL-1 | High | Data | **Create/Edit tour forms do NO field validation.** `UgamInput` is a plain `TextField` (not a `FormField`), so `_formKey.currentState!.validate()` always returns true. A tour saves with empty title/from/to. | `create_tour_screen.dart:128`, `edit_tour_screen.dart:179`, `ugam_input.dart:13-128` | Use `TextFormField`+validators or explicit manual checks before the controller call. |
| AL-2 | High | Completeness | **WhatsApp settings screen is orphaned.** Registered route, never navigated to; the customer-facing WhatsApp handoff number + announcement signature can't be edited anywhere in-app. | `whatsapp_settings_screen.dart`, `app_routes.dart:34,105`; no entry in `settings_screen.dart` | Add a Settings row that pushes it, or remove the dead screen/route. |
| X-2 | High | Sync | **The entire write/retry/RPC layer (`sync_service`) is untested.** Every mutation funnels through `smartInsert/Update/Delete`, `applySeatAssignments`, `swapPassengerSeats` and the `_withRetry` idempotency policy — zero regression coverage of the insert-conflict fallback and non-idempotent swap predicate. | `lib/services/sync_service.dart` (no test file) | Add unit tests for `_isRetryable`, insert-conflict fallback (`:454-468`), swap pre-send predicate (`:609-616`) before release. |
| H-3 | High* | Data | **Seat-keyed collection lookup creates a duplicate collection row after a seat change**, double-counting cash. A paid rider who changed seats keeps their row on the old seat; tapping the new seat finds `existing==null` → a 2nd `Collection` is created. (*Medium per agent; raised for money impact.) | `handler_bus_chart_screen.dart:118-122,352-410` | Resolve `existing` by passenger+bus (seat-agnostic), rewrite `seatId` on save. |

---

## 4. Medium-priority findings

| ID | Category | Finding | Evidence | Fix |
|---|---|---|---|---|
| AS-1 | Calc | **Charts fill count double-counts leg-shared seats** — can read past capacity (e.g. "40/37") and disagree with the grid. The assignment screen already fixed this; charts was never migrated. | `charts_screen.dart:192-196,391,396` | Use leg-aware `tour.occupiedBerthsFor(bus.id)`. |
| AS-2 | Calc | **Bus-status tally has the same leg-share overcount** (can read "100%"/past total). | `bus_status_screen.dart:98-101,410,425` | Use `tour.occupiedBerthsFor(bus.id)`. |
| CALC-2 | Calc | **`formatMoneyInr` renders tiny negative dust as "-₹0"** (sign taken from `amount<0` but magnitude rounds to 0). | `formatters.dart:22-26` | Derive sign after rounding. |
| AM-2 | Data | **Four money screens have no loading state → flash an all-₹0 "settled" board** during first fetch / after tour switch. `finance_screen` gates correctly; these don't. | `bus_money_screen.dart:69`, `collection_screen.dart:125`, `tour_money_board_screen.dart:102`, `trip_pnl_screen.dart:84` | Show skeleton when `isLoading && !loadedOnce`. |
| AM-3 | Data | **No refresh on money screens; stale vs another device.** MoneyController has no realtime and no pull-to-refresh; a handler's collections/handovers on another device don't appear. | (no `RefreshIndicator` in the four money screens) | Add pull-to-refresh (`refreshForTour`) and/or realtime subscription. |
| AM-4 | Data | **Collection/bus-money rows use a stale Tour snapshot while the summary uses the live tour** — header total can disagree with the sum of visible rows after a mid-session roster change. | `collection_screen.dart:72-97` vs `:135`; same in `bus_money_screen.dart` | Resolve tour/bus from `TourController.getTour(...)` inside the Obx. |
| AS-3 | Error-state | **Past-tour history stuck on skeleton forever if snapshot load throws** (`_load` has no try/catch; `_loading` only cleared on success). | `past_tour_seat_history_screen.dart:61-68` | try/catch + `finally { _loading=false }` + fall back to live/empty. |
| AS-4 | Responsive | **Seat tiles are fixed 68×74 px and ignore OS text scaling** — name/phone clip at large accessibility text; shrink to near-unreadable on dense bench rows on small phones. | `seat_chart_tile.dart:21-22,234`, `seat_occupant_label.dart:34-37` | Clamp effective `textScaler` per tile (or size from text metrics). |
| H-4 | Responsive | Whole seat grid is `FittedBox`-scaled → seat text shrinks below its "fixed" sizes on small phones / big coaches; no horizontal-scroll fallback. | `combined_seat_grid.dart:165` | Cap down-scale (min tile size) + horizontal scroll beyond that. |
| H-5 | UX | **Attendance treats "not yet marked" as "left behind"** — board opens showing full no-shows (e.g. "40 left behind"). UI default contradicts `Attendance` model default (`present=true`). | `handler_bus_chart_screen.dart:141-142,736-737,2949-2985`; `attendance.dart:41` | Add an "unmarked" state, or default present + count only explicit left-behind. |
| H-6 | UX | Attendance Switch is parent-controlled — no movement until the server round-trip returns; failure silently reverts. | `handler_bus_chart_screen.dart:185-216,3191` | Optimistic flip with rollback, or per-row pending indicator. |
| H-7 | Responsive | Attendance seat-id chip is unbounded/un-ellipsised — a multi-seat passenger's joined label can overflow the row. | `handler_bus_chart_screen.dart:3111-3146` | maxWidth + ellipsis, or show a count ("A1 +3"). |
| H-8 | Data | **Handler can delete admin-logged expenses/income** — manifest returns every row on the bus with a delete glyph; RPC gates only on "belongs to my tour". Corrupts reconciliation. | `handler_bus_chart_screen.dart:103-114,814-828,2213-2594`; `customer_requests_store.dart:687-725` | Mark row provenance; only allow delete/edit of handler-originated rows. |
| AL-3 | Data | Dashboard money-settlement alert only fires for the one loaded tour; outstanding handovers on other tours never surface. | `dashboard_screen.dart:223` | Compute outstanding-handover per tour from loaded tour data. |
| AL-4 | Data | Create-tour allows return date before departure (edit-tour guards this; create doesn't re-validate after departure change). | `create_tour_screen.dart:97-107,126-134` | Mirror edit-tour: reset/validate return ≥ departure. |
| AL-5 | i18n | Hardcoded English month abbreviations on tour cards (bypasses `tr()`/locale). | `tours_screen.dart:566-582` | Route through localized `Formatters` date helper. |
| AM-6 | Responsive | Bulk action bar packs up to 4 icon+label buttons in one Row — labels clip on ~360dp phones / large text. | `requests_screen.dart:1074-1126` | Icon-only below a width threshold, or wrap. |
| AM-5 | i18n | Two hardcoded English WhatsApp-failure snackbars in an otherwise localized screen. | `requests_screen.dart:299,1791` | Move to `tr()` keys with `namedArgs`. |
| CALC-4 | Calc | Attendance & collect-leg partitioning use coarse passenger `tripType`, not per-line legs — a mixed same-type one-way split lands on the wrong/both legs. Limited impact. | `handler_bus_chart_screen.dart:157-159`, `seat_occupants.dart:160-162` | Partition by `a.leg`/`legForSeat`. |
| X-3 | State | Cold-start "paint cached tours" path is **dead code** — `getCachedList` is a permanent no-op since the SQLite cache was removed; the comment promises behavior that can't run. | `tour_controller.dart:384-389`, `sync_service.dart:77-78` | Remove dead cache calls or reinstate a real cold-start cache; fix comments. |
| X-4 | Sync | Retry classification relies on substring-matching error message text (`network`/`timeout`) — fragile, locale/SDK-dependent. | `sync_service.dart:587-602,574-583` | Classify on typed exceptions/codes; unknown → non-retryable. |
| X-5 | Sync | Silent row-cap truncation (500 default / 2000 passengers) — over-cap reads are truncated and only `dev.log`-warned; roster/capacity/money then computed on partial data. | `sync_service.dart:88-89,134-142` | Paginate, or surface a visible "data truncated" state. |
| X-6 | Responsive | The fixed-pixel scale (`UgamScale`) is essentially unimplemented — only text scales app-wide; component chrome stays raw constants. | `ui_scale.dart:20-21` (3 refs only) | Apply `* s` in shared components, or drop the unfulfilled contract. |
| X-7 | iOS | `NSPhotoLibraryUsageDescription` absent while app uses `image_picker` gallery — low crash risk (PHPicker) but App Review commonly expects it; camera key correctly omitted. | `create_tour_screen.dart:73-74`; `ios/Runner/Info.plist` | Add the photo-library usage string defensively. |

---

## 5. Low-priority findings (polish backlog)

| ID | Category | Finding | Evidence |
|---|---|---|---|
| C-1 | i18n | Hardcoded English month names on "My Requests" date pills (breaks gu/hi). | `customer_my_requests_screen.dart:728-744` |
| C-2 | Responsive | Biometric-unlock row label not `Flexible` — overflow risk with long translations. | `login_screen.dart:186-198` |
| C-3 | Responsive | Tour-row price segment not flex-constrained — overflow under large text scale. | `customer_tour_list_screen.dart:656-705` |
| C-4 | Data | Account phone hardcodes "+91"; shows bare "+91 " if phone empty. | `account_details_screen.dart:131` |
| C-5 | Data | `add_return_ticket_sheet` `onAdded` fires on any dismiss (not only success). | `add_return_ticket_sheet.dart:26-32` |
| C-6 | Data | "My bookings" badge counts cancelled/rejected future requests. | `customer_tour_list_screen.dart:58-64` |
| C-7 | i18n | Brand hero label hardcoded (`'Ugam Foj'` / `'UGAM'`) — borderline. | `customer_more_screen.dart:170`, `login_screen.dart:106` |
| AL-6 | Data | Edit-tour price parses invalid input to 0 silently (no formatter/validator). | `edit_tour_screen.dart:200` |
| AL-7 | i18n | Hardcoded `'AC'` chip in tour-detail Buses tab (key exists elsewhere). | `tour_detail_screen.dart:1562` |
| AL-8 | Error-state | Double error snackbar on bus delete / price-sheet copy (raw `$e` concatenated). | `manage_buses_screen.dart:182-184`, `edit_tour_screen.dart:324-325` |
| AL-9 | Responsive | Pickup add-row: fixed 80px code field + non-flex button crowds name field. | `pickup_locations_screen.dart:226-255` |
| AL-10 | Responsive | Localized picker values in flex cells — confirm `UgamPickerField` ellipsizes. | `create_tour_screen.dart:326-387`, `edit_tour_screen.dart:509-570` |
| AL-11 | Data | Tour-groups create can partially apply on mid-loop failure (no rollback). | `tour_groups_screen.dart:150-170` |
| AL-12 | Data | Dashboard "Recent requests" lists all passengers, not new/pending requests. | `dashboard_screen.dart:338-347` |
| AS-5 | Error-state | No loading state on overview/charts → initial "not found"/empty flash. | `tour_overview_screen.dart:142-149`, `charts_screen.dart:136-180` |
| AS-6 | Responsive | Assignment dock reserves a fixed 244px; legend always off-fold; collapsed dock can grow past reserve on small/large-text screens. | `tour_seat_assignment_screen.dart:104,2099,3232-3497` |
| AS-7 | Error-state | `_toastBlocked` force-unwraps `_tour!` / `_selectedBus(_tour!)!` in a drop-rejected toast. | `tour_seat_assignment_screen.dart:1319-1323` |
| AS-8 | Completeness | PDF export can share a zero-page/blank document if all buses lack layouts. | `seat_chart_pdf.dart:126-150`, `tour_seat_assignment_screen.dart:1909,2009-2010` |
| H-9 | Data | Money fields accept multi-dot input and silently parse to 0 (collect "received" not guarded). | `handler_bus_chart_screen.dart:1931-1943,2381,2732` |
| H-10 | UX | Bus broadcast partial failure gives counts but no failed list and no resend. | `handler_bus_chart_screen.dart:599-609`; `whatsapp_cloud_service.dart:169-192` |
| H-11 | UX | Tapping an empty/free seat does nothing (haptic then silent return). | `handler_bus_chart_screen.dart:311-313,1005-1007` |
| H-12 | Docs | Collection cache-key comment drift (doc says `passengerId|busId`, code adds `seatId`). | `handler_bus_chart_screen.dart:73-74,96-97` |
| AM-7 | Data | Two different "net" figures on the money board (billed-net top vs cash-net capsule) with no disambiguating label. | `tour_money_board_screen.dart:209,655` |
| AM-8 | Data | Finance row net (cash) ≠ the board it opens (billed net) — confusing without cross-labeling. | `finance_screen.dart:93,542`; `tour_money_board_screen.dart:209` |
| AM-9 | Error-state | Finance pull-to-refresh fails silently after first success (error branch gated on `!loadedOnce`). | `finance_screen.dart:89-91`; `finance_controller.dart:120-125` |
| AM-10 | Completeness | Resolved driver phone plumbed to `notify_screen` but never rendered (dead affordance). | `notify_screen.dart:685,839-933` |
| CALC-3 | Calc | Collection "To collect" filter / shortfall row skip the ±0.005 money epsilon → dust-negative shows a "Mark paid ₹0". | `collection_screen.dart:106,621-624` |
| CALC-5 | Calc | Per-seat rounding lets two half-payers of a shared double exceed the whole-double price by ₹1 (odd prices). Documented trade-off. | `bus_details.dart:561` |
| CALC-6 | Test | Correct-but-untested admin `BusMoneySummary` seated-uncollected branch + `TourFinance`/`FinanceTotals` folds; "revenue" semantics diverge (cash vs billed) across P&L screens. | `money_summary.dart:103-117,266-283`; `tour_finance.dart`; `finance_controller.dart:67-70` vs `trip_pnl_screen.dart:243` |
| X-8 | Android | Release build silently debug-signs without `key.properties`. | `build.gradle.kts:64-70` |
| X-9 | Responsive | Global max-width clamp (540) is admin-only; customer flow sprawls edge-to-edge on tablets/foldables. | `main_shell.dart:79,147,175`; `customer_tour_list_screen.dart:258` |
| X-10 | i18n | Dead formatters with wrong currency/locale (`$`, `en_US`) — landmines if a call site adopts them. | `formatters.dart:4-8,15-17` |
| X-11 | iOS | Privacy manifest cites removed deps (sqflite/path_provider) — inaccurate, harmless. | `PrivacyInfo.xcprivacy:66-74` |
| X-12 | State | `isLoading/hasError` contract absent in `inbox_controller`/`pickup_controller` — those screens can't render the shared error/retry state. | (5 controllers have it, 2 don't) |

---

## 6. Cross-cutting themes (fix once, benefits many screens)

1. **Data staleness / no refresh** — Handler screen (H-2) and the four money screens (AM-3) load once with no realtime and no pull-to-refresh; cross-device changes are invisible. **Fix pattern:** add `RefreshIndicator` + `refreshForTour`, and consider extending realtime (currently only `TourController`) to `MoneyController` + the handler manifest.
2. **Missing loading states → wrong-data flash** — Money screens (AM-2), overview/charts (AS-5) show ₹0/empty/"not found" before first fetch resolves. **Fix pattern:** the `isLoading && !loadedOnce → skeleton` gate that `finance_screen` already uses.
3. **Leg-shared seat overcounting** — `charts_screen` (AS-1) and `bus_status_screen` (AS-2) fold raw assignments instead of `occupiedBerthsFor`. **Fix pattern:** migrate both to the leg-aware count the assignment screen uses.
4. **i18n date/currency leaks** — hardcoded English month arrays and a couple of raw snackbars (C-1, AL-5, AM-5, AL-7) puncture an otherwise airtight i18n. **Fix pattern:** one shared localized month/date helper; grep out the arrays.
5. **Fixed-size chrome vs text scaling** — seat tiles (AS-4, H-4) and the unimplemented `UgamScale` (X-6) mean large-accessibility-text users get clipped content. **Fix pattern:** clamp per-tile `textScaler`; honor the scale contract in shared components.
6. **Snapshot-vs-live divergence** — screens holding a constructor `Tour`/`Bus` snapshot (AM-4) drift from live-computed summaries. **Fix pattern:** resolve from `TourController.getTour(...)` inside the Obx.
7. **Optimistic-write UX** — controlled toggles/fields that wait for the round-trip (H-6) feel unresponsive in the field. **Fix pattern:** optimistic flip + rollback.

---

## 7. Feature-completion work (the "complete everything" scope)

### 7.1 Handler settlement / cash-handover loop (closes H-1)

Close the handler side against the **existing `bus_handovers` table** the admin already writes (`bus_money_screen.dart` / `MoneyController.recordHandover`) — no new table, so both sides read/write the same rows.

- **Model:** add `List<BusHandover> handovers` to `HandlerManifest` (parse in `fromJson`). Add `handedOver` (Σ this bus's handovers) + getters `expectedHandover => inHand` and `outstandingHandover => expectedHandover - handedOver` to `HandlerBusMoney`; fold `handedOver` in `compute`.
- **RPC / API:** add SECURITY DEFINER `handler_upsert_handover(p_request_id uuid, p_handover jsonb)` (+ optional `handler_delete_handover`), mirroring `handler_upsert_collection`: verify `is_request_handler` + bus-on-tour, upsert into `bus_handovers`, return the row. Extend `handler_tour_manifest` to include a tour-scoped `handovers` array. **One new migration** (functions + manifest change; table already exists). Optionally add a nullable `source text` ('handler'/'admin') for provenance.
- **UI:** under the summary hero, a "Hand over cash" CTA → sheet pre-filled with `expected = summary.inHand`, editable amount + note, live "Outstanding: ₹X"; on save call the RPC, cache the returned `BusHandover`, re-render hero as "Handed over ₹A / Outstanding ₹B". Show existing handover rows as a read-back list.
- **Reconciliation:** by construction the handler's "Outstanding" equals the admin's `outstandingHandover` (both = `netCollected − Σ handed_over`), so the two devices agree. **This also fixes H-8's provenance need** if `source` is added.

### 7.2 Other completion items
- **WhatsApp settings reachability** (AL-2) — wire the orphaned screen into Settings.
- **Billed-revenue snapshot** (CALC-1) — persist per-seat billed amount so completed legs don't erase earned revenue; this is the one calculation that needs a data-model change, not just a formula tweak.
- **Handler ledger provenance** (H-8) — mark handler- vs admin-originated expense/income rows; hide destructive affordances on admin rows.
- **New API surface implied:** one migration for 7.1 (handover RPCs + manifest), plus whatever CALC-1's billed snapshot needs (likely a column + backfill). Also reconcile the duplicate migration numbers (two `004_`, two `006_`) and the live-only RPC drift (`bus_layouts_for_request`, `booking_request_status_lookup` exist only in live) before cutting the release API.

---

## 8. iOS dual-store readiness checklist

| Item | Status | Note |
|---|---|---|
| Bundle id / display name / version wiring | OK | `com.occubitsolution.ugambooking`, "Ugam Booking", Flutter build vars |
| NSContacts / NSFaceID usage strings | OK | present; match `flutter_contacts` + `local_auth` |
| NSCamera usage | OK (n/a) | correctly absent — gallery only |
| **NSPhotoLibrary usage** | **Missing** | image_picker gallery; recommended for review (X-7) |
| LSApplicationQueriesSchemes | OK | `whatsapp`, `https` |
| ITSAppUsesNonExemptEncryption | OK | `false` |
| UIBackgroundModes remote-notification | OK | present |
| **aps-environment (push entitlement)** | **Needs-work** | `development` → must be `production` (REL-4) |
| APNs key in Firebase | Unknown | backend config, verify manually |
| PrivacyInfo.xcprivacy | OK | present; prune stale sqflite reason (X-11) |
| Deployment target / signing / icons / launch | OK | iOS 15.0, automatic signing, full icon set |

**Android:** Ready to sign+upload (targetSdk 35, minify+shrink+proguard, backup off, cleartext off, google-services.json present) — except the debug-key fallback footgun (X-8).
**Metadata:** `store_assets/` has icons + feature graphic + 4 screenshots, but **no** fastlane/listing text/release-notes tooling — fully manual.

---

## 9. Prioritized remediation plan (phases)

**Phase 0 — Unblock (deploy/config, no app code):** REL-1/2/3 (migrations 039→040→041), REL-4 (iOS aps-environment), X-8 (fail-loud signing guard). *Exit: current binary can be built and installed without breaking writes; iOS push works.*

**Phase 1 — Feature completion:** §7.1 handler settlement loop (+ migration), CALC-1 billed-revenue snapshot (+ migration), AL-2 WhatsApp settings wiring, H-8 ledger provenance. *Exit: both flows are functionally complete; no one-directional/erasing money paths.*

**Phase 2 — High-severity correctness:** H-2 (handler refresh/retry), H-3 (duplicate collection row), AM-1 (notify tracker persisted state), AL-1 (tour form validation), X-2 (sync_service tests). *Exit: no money double-count, no paid-message re-blast, no invalid tour records, write layer covered.*

**Phase 3 — Medium correctness + responsiveness themes:** AS-1/AS-2 (leg-share counts), AM-2/AM-3/AM-4 (loading/refresh/snapshot), AS-3 (past-tour crash), AS-4/H-4 (tile text scaling), H-5/H-6/H-7 (attendance UX), CALC-2/CALC-4, X-3/X-4/X-5 (sync hardening), X-7 (iOS photo string). *Exit: cross-cutting themes §6 resolved.*

**Phase 4 — Low-severity polish:** i18n date/currency leaks, minor overflow, dead code, snackbar dedup, untested-branch coverage (CALC-6), X-9 tablet clamp, X-11 privacy prune.

**Phase 5 — Release engineering:** version bump, store metadata/release notes for both stores, migration-provenance reconciliation, live-RPC drift resolution, build + internal-track validation → production.

---

## 10. What's genuinely good (don't touch)

- **Cash-math core** — per-seat fares, collection balance/change/shortfall with a shared ±0.005 epsilon, and the handler↔admin settlement chain are arithmetically consistent and well-tested. Reconciliation can be trusted.
- **State vocabulary** — `UgamEmpty`/`UgamEmpty.error`/`UgamSkeleton` + `smartFetch`'s `failed` flag + the single `_write()` optimistic-then-revert helper give loading/empty/error/offline a shared language.
- **Realtime reconciliation** — writes reliably refresh UI via incremental apply + coalesced `tours.refresh()`.
- **i18n** — en/gu/hi in sync; ~1847 `tr()` calls; effectively no hardcoded UI strings beyond the specific date-pill leaks noted.
- **Seat-grid overflow safety** — every grid is wrapped in a scale-down `FittedBox`; horizontal overflow is structurally prevented.
- **iOS is far more ready than expected** — privacy manifest, entitlements, permission strings, icons, 15.0 target all present.
