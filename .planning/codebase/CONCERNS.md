# Codebase Concerns

**Analysis Date:** 2026-06-06
**Auditor scope:** Security, Data Integrity, Performance, Tech Debt, Fragile Areas, Testing

---

## SECURITY

### SEC-1 — Supabase anon key committed to source code
**Severity: High**

- Files: `lib/config/supabase_config.dart` (lines 4–6)
- The `anonKey` (`sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP`) and project URL are compiled into the app binary as Dart constants. This is acknowledged in `RELEASE.md` as "publishable / safe to ship", which is true only while RLS is correctly configured on every table.
- **Why it matters:** If any RLS policy has a misconfiguration gap (e.g. future migration adds a table with no RLS), the key gives anonymous internet users SELECT/INSERT on that table. The key cannot be rotated without a new app release.
- **Suggested fix:** This is a Supabase-standard trade-off for mobile; accept it but make the risk explicit in a runbook. Enforce a CI gate that verifies `row level security` is enabled on every public table after each migration (parse `database.sql` for tables without `enable row level security`). Never use the service-role key in the client — confirm it lives only in Edge Function secrets.

---

### SEC-2 — `passengers_anon_select` leaks ALL passenger PII on any public tour
**Severity: High**

- Files: `database.sql` (lines 325–328)
- Policy:
  ```sql
  create policy "passengers_anon_select" on public.passengers
    for select to anon
    using (exists (select 1 from public.tours t
                   where t.id = passengers.tour_id and t.is_public = true));
  ```
- Any anonymous user who calls `supabase.from('passengers').select()` with a known (or brute-forced) `tour_id` gets back the full name, phone number, age group, payment status, seat assignments, and note for EVERY passenger on that tour. The comment says "used by the customer mode 'my requests' lookup if you add it later" — but that feature does not exist yet and the policy is already live.
- **Why it matters:** 300 passengers × N tours = large PII exposure to unauthenticated callers. Violates privacy policy ("data is protected by row-level security so each agent sees only their own data").
- **Suggested fix:** Until the "my requests" feature needs it, drop this policy entirely. When the feature lands, scope the SELECT to `phone = current_setting('request.jwt.claims')::jsonb->>'phone'` or use the existing SECURITY DEFINER RPCs (`get_booking_status`, `cancel_my_booking`) that already return only the caller's own rows.

---

### SEC-3 — `booking_requests_anon_insert` has no rate-limit guard
**Severity: Medium**

- Files: `database.sql` (line 427–428)
- Policy is `with check (true)` — any anonymous caller can insert unlimited booking request rows against any tour.
- **Why it matters:** Trivial to spam thousands of fake booking requests, filling the admin's Requests inbox and inflating passenger counts. No CAPTCHA, no rate-limit at the RLS layer.
- **Suggested fix:** Add a Supabase Edge Function in front of booking submission that enforces a per-IP or per-phone rate limit (e.g. 3 requests per phone per tour), or add a DB-level throttle via a trigger that counts recent inserts from the same phone.

---

### SEC-4 — Developer's personal email address in shipped binary
**Severity: Medium**

- Files: `lib/config/app_contact.dart` (line 18)
- `AppContact.supportEmail = 'zeel.shiyani68@gmail.com'` is a Dart constant compiled into every release build. It appears on the customer-facing Privacy Policy and "Contact" row.
- **Why it matters:** Surfaces the developer's personal Gmail in production for all users. Should be a brand/ops address. Also inconsistent with `admin_setup_screen.dart` which hardcodes a different address (`support@ugambooking.com`).
- **Suggested fix:** Settle on one brand support address (`support@ugambooking.com` or similar) and update `AppContact.supportEmail` to match. The inconsistency is also a UX trust issue.

---

### SEC-5 — Seat-chart PDFs uploaded to PUBLIC storage bucket with permanent URLs
**Severity: Medium**

- Files: `lib/services/whatsapp_outbound.dart` (line 91–96), `lib/services/whatsapp_cloud_service.dart` (lines 125–137)
- `WhatsAppCloudService.uploadPublic` calls `getPublicUrl` (not a signed URL). PDFs at `seat-charts/{tourId}/{busId}.pdf` are permanently accessible to anyone who knows or guesses the path. The bucket name is a constant in `WhatsAppCloudConfig.seatChartBucket`.
- **Why it matters:** The PDF contains the full seating chart with every passenger's name and seat number. Once uploaded it never expires. The path is predictable (UUID tour_id + UUID bus_id, so not easily brute-forced, but it is permanent once shared).
- **Suggested fix:** Use signed URLs with a short TTL (e.g. 7 days) instead of public-bucket URLs. Meta's Cloud API will fetch the URL once at send time; the link in WhatsApp chat can then expire. If WhatsApp requires a persistent URL, move to a private bucket + a short-lived signed URL generated per-send.

---

### SEC-6 — Handler auth is entirely absent (designed, not built)
**Severity: Medium**

- Files: `database.sql` comment at `bus_handovers` table; `docs/superpowers/specs/2026-06-01-money-collection-settlement-design.md` line 243
- Comment: "Handler login / handler role / per-handler RLS (designed-for, not built)."
- The handler sees a chart (via `handler_bus_chart_screen.dart`) that contains every passenger's name, phone, seat, and money collected. Currently, the handler's access path is unclear — there is no login screen for handlers, no handler auth token, and no per-handler RLS filtering.
- **Why it matters:** If the handler chart is accessible without authentication, the entire passenger manifest is unprotected. Even if it requires an admin session it is over-privileged (handlers should see their bus only).
- **Suggested fix:** Block ship of the handler-facing chart behind a clear "requires admin session or handler login" gate. Implement per-handler RLS (or a SECURITY DEFINER RPC scoped to `bus_id`) before any production rollout.

---

## DATA INTEGRITY

### DI-1 — `swapSeats` is a two-step non-atomic write — inconsistency window
**Severity: High**

- Files: `lib/controllers/tour_controller.dart` (lines 1067–1085)
- `swapSeats` writes passenger A's update to Supabase, then writes passenger B's. If the process crashes or loses connectivity between the two writes, the DB holds a state where A has B's seat but B still has A's seat — both own the same physical berth. There is no transaction wrapping the two `UPDATE` calls.
- **Why it matters:** A realtime event fired after the first write and before the second will deliver an inconsistent seat map to any connected admin device. The failure path calls `refreshTours()` which reads back the half-committed state.
- **Suggested fix:** Wrap both passenger updates in a SECURITY DEFINER Postgres RPC `swap_passenger_seats(p_a uuid, p_b uuid, ...)` that runs in a single transaction. The client becomes one network round-trip and atomicity is guaranteed.

---

### DI-2 — `fillTour` persists N passengers sequentially — partial application leaves inconsistent seating plan
**Severity: High**

- Files: `lib/controllers/tour_controller.dart` (lines 714–753)
- `fillTour` runs the engine (`SeatingEngine.propose`), diffs, then calls `assignSeats` in a serial `for` loop — one `await` per changed passenger. If the 3rd of 20 writes fails (network, RLS, timeout), passengers 1–2 are committed with the new plan, passengers 4–20 are not. The local in-memory state was also speculatively mutated before the loop started.
- **Why it matters:** The seating state in DB is now inconsistent with what the engine proposed. The next `fillTour` call may produce a different plan (because locked berths from the partial first run are now in the DB). The agent sees a mixed state.
- **Suggested fix:** Either (a) collect all seat updates into a single Postgres RPC that applies them in one transaction, or (b) sequence the writes fully and on any failure call `refreshTours()` + surface a specific "Auto-fill partially applied — please retry" error. Currently the catch in `assignSeats` calls `refreshTours()` per failure but the loop continues, compounding the divergence.

---

### DI-3 — `offline_database.dart` deleted but stubs still in SyncService hide real fetch failures as silent `[]`
**Severity: Medium**

- Files: `lib/services/sync_service.dart` (lines 57–64, 80–90)
- `smartFetch` swallows every exception and returns `[]`. The caller (`TourController._loadTours`) only raises `hasError` when `tours.isEmpty`, so a returning user (who already has tours in memory) never learns that the refresh failed.
- The comment in `SyncService` says "callers follow [invalidateCache] with a live refresh" but `getCachedList` and `invalidateCache` are no-ops since the local cache was removed.
- **Why it matters:** A transient server error silently shows stale tour data. An RLS misconfiguration that returns `[]` (e.g. `owner_id` mismatch after re-login) would be invisible to the user.
- **Suggested fix:** Surface a non-blocking warning toast whenever a smartFetch fails for an already-loaded list, not only when the list is empty. Remove the now-meaningless `cacheKey` / `maxAge` parameters from call sites (or keep but document as dead) so the contract is honest.

---

### DI-4 — Hard-coded row limits (500 tours, 2000 passengers) will silently truncate large operators
**Severity: Medium**

- Files: `lib/services/sync_service.dart` (lines 107, 126, 143, 150, 156)
- `.limit(2000)` on passengers, `.limit(500)` on tours/buses/groups. No pagination or cursor-based loading.
- **Why it matters:** An operator with a popular tour (2000+ passengers) or many tours (500+) will receive a silently truncated list with no warning. The seating engine will compute a plan over an incomplete data set.
- **Suggested fix:** Add pagination or raise the limit to a safe upper bound with a visible warning when results are capped. At minimum, log a warning when `results.length == limit`.

---

### DI-5 — `_pruneExpiredTours` runs automatically on every load — data loss without confirmation
**Severity: Medium**

- Files: `lib/controllers/tour_controller.dart` (lines 350–368)
- On every `_loadTours`, if the current date is past `(returnDate ?? departureDate) + 1 day`, the tour and ALL its cascade-deleted data (passengers, seat assignments, money collections, expenses) are deleted silently. No confirmation dialog. No recycle bin.
- **Why it matters:** Clock drift, a mis-entered date, or a tour with no return date that ran long will cause permanent deletion of financial and passenger records on the next app open. There is no undo.
- **Suggested fix:** Move pruning to an explicit admin-triggered action ("Archive expired tours"), or at minimum show a confirmation dialog listing which tours will be removed. Consider a soft-delete (`archived_at` column) rather than hard-cascade delete.

---

### DI-6 — `passenger_groups` changes are NOT covered by realtime subscription
**Severity: Low**

- Files: `lib/services/realtime_service.dart` (lines 114–117); `LibTable` enum has no `passengerGroups` entry
- Group creates/deletes from another device are never delivered as live events; the second device only learns about them on the next full reload (`refreshTours`).
- **Why it matters:** If two agents are on the same tour simultaneously (possible with multi-device use), group changes made by one will be invisible to the other until they pull-to-refresh.
- **Suggested fix:** Add `passenger_groups` to `LiveTable` and wire it in `_ensureAdminChannel`. Handle the event in `_applyRealtimeEvent` similarly to buses.

---

## PERFORMANCE

### PERF-1 — `SeatsScreen` mounts all three seat bodies simultaneously via `IndexedStack`
**Severity: High**

- Files: `lib/screens/seats_screen.dart` (lines 80–91)
- `IndexedStack` renders all three children (`TourOverviewScreen`, `TourSeatAssignmentScreen`, `SeatAssignmentScreen`) on first build. Their total source is ~6500 lines combined. Each contains its own `Obx` observers and computes heavy derived state (seat grid, occupancy, exceptions).
- **Why it matters:** On open, the GPU renders three complete widget trees simultaneously (only one is visible). Every `tours.refresh()` call in `TourController` fires all active `Obx` widgets across all three bodies at once, even on the two hidden tabs. On a 50-passenger tour with 2 buses, this means rebuilding the full seat grid and occupancy maps 3× per realtime event.
- **Suggested fix:** Replace `IndexedStack` with lazy initialization: use `_mode == i ? child : const SizedBox.shrink()` and lift per-mode state into the parent with `AutomaticKeepAliveClientMixin`, or use `TabBarView` with `lazy: true`. Alternatively, wrap each body in `KeepAlive(keepAlive: _mode == i, ...)` so unmounted tabs don't hold live Obx subscriptions.

---

### PERF-2 — `seat_detail_screen.dart` is 3074 lines — single monolithic build method
**Severity: Medium**

- Files: `lib/screens/seat_detail_screen.dart`
- **Why it matters:** Flutter profiles rebuild cost at the widget level. A 3074-line file with flat widget nesting means a single `setState` or `Obx` fire rebuilds the entire tree instead of a focused subtree. The file has only 2 `Obx` observers; any `tours.refresh()` triggers both, which together re-evaluate the full occupancy map and group-color logic for the tour.
- **Suggested fix:** Extract the seat grid, the occupant sheet, and the action toolbar into separate stateless widget classes. Each can then be rebuilt independently. The file should ideally be under 600 lines.

---

### PERF-3 — `setHandler` writes every passenger row to Supabase (N+1 writes)
**Severity: Medium**

- Files: `lib/controllers/tour_controller.dart` (lines 1112–1136)
- `setHandler` iterates `tour.passengers` and calls `_sync.smartUpdate` for **every** passenger to flip their `isHandler` flag. For a 60-passenger tour that is 60 sequential HTTP round-trips in a 12-second timeout window.
- **Why it matters:** The handler flag is stored on the passenger row (`isHandler: bool`) rather than solely on the tour row (`handlerId`). On a slow connection this blocks the UI for up to 720 seconds (60 × 12s) before timing out. The write errors in the middle of the loop leave a partially-updated state.
- **Suggested fix:** The `handlerId` on the tour row is already the authoritative field. Remove `isHandler` from the passenger rows (derive it at read time: `p.id == tour.handlerId`), and `setHandler` becomes a single tour row update.

---

### PERF-4 — Realtime channel subscribed to ALL rows on `passengers`, `buses`, `tours` without filter
**Severity: Low**

- Files: `lib/services/realtime_service.dart` (lines 93–118)
- The single admin channel listens to `PostgresChangeEvent.all` on all four tables with no `filter` parameter. Each event carries the full row payload.
- **Why it matters:** As tour count and passenger count grow, every INSERT/UPDATE on any passenger anywhere fans out to every connected admin device. At 300 passengers × active writes during seat-fill, 300 events fire in one session.
- **Suggested fix:** Add a `filter: 'owner_id=eq.$uid'` clause on the `tours` and `buses` subscriptions. For `passengers`, filter by `tour_id=in.(...)` once tour IDs are loaded, or subscribe through a DB view scoped to the admin's tours. This is a Supabase Realtime standard pattern.

---

## TECH DEBT

### TD-1 — Diagnostic `dev.log` block marked "temporary — remove after…" is still live in production code
**Severity: Medium**

- Files: `lib/controllers/tour_controller.dart` (lines 292–306)
- Block explicitly comments `// ── DIAGNOSTIC (temporary — remove after "customer sees no tours") ──` and logs the Supabase session role, filter, and raw fetched count on every tour load. This fires in production release builds.
- **Why it matters:** `dart:developer` `log()` calls are included in release builds and visible via `flutter logs` / device consoles. It leaks admin UID and tour count. It also incurs string-formatting cost on every cold start.
- **Suggested fix:** Remove the block. The underlying issue ("customer sees no tours") should be verified resolved and the diagnostic dropped.

---

### TD-2 — `TODO(seat-ui)` stubs pointing at screens that have already shipped
**Severity: Low**

- Files: `lib/screens/tour_detail_screen.dart` (lines 95, 256); `lib/screens/tour_overview_screen.dart` (lines 116, 121)
- Comments read "TODO(seat-ui): entry point into SLICE 1 — the Tour…" and "TODO(seat-ui): groups entry." / "TODO(seat-ui): money entry." These features now exist (`tour_overview_screen.dart`, `tour_groups_screen.dart`, `tour_money_board_screen.dart`).
- **Why it matters:** Stale TODO comments mislead future developers into thinking these are unimplemented paths.
- **Suggested fix:** Delete the stale TODO comments and verify the entry-point buttons are wired to the live screens.

---

### TD-3 — `handler_bus_chart_screen.dart` is 2549 lines with local `_collections` / `_expenses` maps managed entirely in `setState`
**Severity: Medium**

- Files: `lib/screens/handler_bus_chart_screen.dart`
- The screen manages its own `Map<String, Collection>` and `Map<String, Expense>` in local `State`, loaded from `MoneyController` but then mutated in-place via `setState`. No `Obx`/reactive binding means realtime changes from `MoneyController` do not automatically repaint the chart.
- **Why it matters:** If another device adds a collection while the handler has this screen open, the chart shows stale numbers until the user navigates away and back.
- **Suggested fix:** Replace local maps with direct `Obx` observers on `MoneyController.collections` / `.expenses`. The screen can shrink significantly.

---

### TD-4 — Widespread hardcoded English strings in all recently-added seat screens
**Severity: Low**

- Files: `lib/screens/seat_detail_screen.dart` (e.g. lines 882, 994–995, 1022); `lib/screens/tour_overview_screen.dart`; `lib/screens/tour_seat_assignment_screen.dart`; `lib/screens/handler_bus_chart_screen.dart`; `lib/screens/seating_exceptions_screen.dart` (lines 244–247)
- The app ships three locales (en/hi/gu via EasyLocalization). All of the newer seat-UI screens were built in English and never had strings extracted to `assets/translations/*.json`. The `.tr()` call count on these screens is 0 (grep confirmed).
- **Why it matters:** Hindi/Gujarati users (the primary audience) see all seating-related UI in English. This affects every screen added in the last 10 commits.
- **Suggested fix:** Grep for `"[A-Z][a-z].*"` literals in all seat-UI screens, extract to translation keys in `en.json`, and add Gujarati/Hindi entries. Enforce via a lint rule or CI check that flags new non-`.tr()` UI strings.

---

### TD-5 — `AppContact.supportWhatsApp` is empty string — "Contact" row silently falls back with no warning to operator
**Severity: Low**

- Files: `lib/config/app_contact.dart` (line 15)
- `supportWhatsApp = ''` with a TODO comment. The "Contact" row on the customer "More" screen silently falls back to the support email.
- **Why it matters:** Customers expect a WhatsApp contact for a WhatsApp-native booking app. The empty string is not validated at startup, so the misconfiguration is silent.
- **Suggested fix:** Add a debug-mode assertion `assert(AppContact.supportWhatsApp.isNotEmpty, 'AppContact.supportWhatsApp not configured')` and document the expected format in the ops runbook.

---

## FRAGILE AREAS

### FRAG-1 — Seating engine's `sharedDoubleNeedsReview` / leg-aware rules have high cyclomatic complexity and constant churn
**Severity: High**

- Files: `lib/services/seating_engine.dart` (1857 lines, 5 rule-revision commits in recent history)
- The engine implements: (1) group co-seating, (2) priority-front-zone, (3) whole-double vs cross-fill, (4) leg-aware reuse (GO/RETURN slots), (5) `sharedDoubleNeedsReview` for unrelated singles, (6) pack-first bus ordering. The most recent commit (`c7d920c`) changed rule (5) in a subtle way (same-group + leg-disjoint are exempt). This is the highest-churn file in the codebase (5 logic commits in 2 weeks).
- **Why it matters:** The engine rules interact non-obviously. A test that passes for rule (5) isolation may silently break rule (3) interaction. Each new rule is additive, not refactored, so the control flow is deeply nested.
- **Suggested fix:** The engine already has a dedicated test file (`test/services/seating_engine_test.dart`, 1854 lines) — good. Ensure every rule change adds a regression test for the specific edge case. Consider splitting the file into focused sub-engines (group phase, priority phase, fill phase) that are individually testable and composed.

---

### FRAG-2 — `consolidateOntoDouble` adds `targetSeatId` twice unconditionally
**Severity: Medium**

- Files: `lib/controllers/tour_controller.dart` (lines 922–927)
- ```dart
  ..add(SeatAssignment(busId: busId, seatId: targetSeatId))
  ..add(SeatAssignment(busId: busId, seatId: targetSeatId));
  ```
  Two entries are appended for the target regardless of how many berths the passenger originally held. If the passenger originally had only one single-sofa berth being consolidated, they end up holding two berths on the double — a whole-double assignment — which may be intentional (the API comment says "exactly 2 entries are added") but is not validated against the passenger's original request count. If called with a single-berth request, it over-assigns.
- **Suggested fix:** Assert `sourceSeatIds.length == 2` at the start of `consolidateOntoDouble` (or document that the caller guarantees two sources), and add a unit test covering the single-source edge case.

---

### FRAG-3 — PDF generation silently falls back to no-font rendering on network failure
**Severity: Medium**

- Files: `lib/services/seat_chart_pdf.dart` (lines 32, 50–63)
- `PdfGoogleFonts.notoSansRegular()` is downloaded at send time; on network failure the whole `_loadTheme()` is swallowed and `null` is returned. The PDF is then built with the pdf package's default Latin-only font.
- **Why it matters:** Passenger names in Gujarati or Hindi are rendered as missing-glyph boxes on the final WhatsApp chart. There is no user warning; the send appears to succeed. The operator realizes the problem only when passengers report unreadable PDFs.
- **Suggested fix:** Bundle the Noto Sans font as an asset (`assets/fonts/`) rather than fetching from Google Fonts at runtime. This removes the network dependency and guarantees Gujarati/Hindi glyph coverage.

---

### FRAG-4 — Broadcast fallback message is hard-coded in Gujarati; agent may not notice
**Severity: Low**

- Files: `lib/services/whatsapp_outbound.dart` (lines 61–67)
- The auto-composed fallback body (`_composeBroadcastBody`) emits `'રૂટ: ...'` and `'તારીખ: ...'` labels unconditionally in Gujarati, regardless of the operator's locale setting.
- **Why it matters:** An operator who primarily uses Hindi or English will send a Gujarati-language broadcast without realizing it. The template variable is agent-free-form, so the agent may not preview the composed body.
- **Suggested fix:** Expose the composed fallback in the broadcast preview UI before sending, and drive the label language from the admin's locale setting.

---

## TESTING / RELIABILITY GAPS

### TEST-1 — Zero tests for `TourController` — the highest-risk controller in the app
**Severity: High**

- Files: `lib/controllers/tour_controller.dart` (1561 lines); no corresponding test file found under `test/`
- `TourController` contains: optimistic mutations, rollback-on-failure logic, `fillTour` orchestration, `swapSeats`, `setHandler`, `_pruneExpiredTours`, and `_applyRememberedPriority`. Every one of these has subtle failure modes documented above.
- **Why it matters:** All the integrity concerns above (DI-1 through DI-5) can only be caught reliably by unit tests that mock `SyncService`. There are no such tests.
- **Suggested fix:** Create `test/controllers/tour_controller_test.dart`. Use a `FakeSyncService` (in-memory maps, injectable failure injection). Cover at minimum: `fillTour` partial failure rollback, `swapSeats` second-write failure, `_pruneExpiredTours` date boundary, and `setHandler` single-update path.

---

### TEST-2 — No tests for `SyncService` write paths (upsert fallback, unique-violation handling)
**Severity: High**

- Files: `lib/services/sync_service.dart` (lines 301–323)
- The `23505 unique_violation` → upsert fallback logic in `_writeToServer` is tested only by production traffic. This path is critical for idempotent re-runs of `fillTour`.
- **Suggested fix:** Add `test/services/sync_service_test.dart` with a mock Supabase client. Test: normal insert, `23505` with matching id → update, `23505` without matching id → rethrow, update of missing row → insert fallback.

---

### TEST-3 — `AdminAuthService.anyAdminExists()` is used for setup routing but never tested
**Severity: Medium**

- Files: `lib/services/admin_auth_service.dart` (lines 86–89)
- When `anyAdminExists()` returns `false` (network error or RLS denial), the app routes to admin setup — but both conditions look identical to the app. An admin who briefly goes offline on a fresh install could be shown the setup screen.
- **Suggested fix:** Add a test asserting the distinction between "genuinely no admin" (empty list) and "fetch failed" (exception). On exception, keep the existing session and show an error rather than redirecting to setup.

---

### TEST-4 — No integration or E2E tests for the WhatsApp broadcast + PDF upload flow
**Severity: Medium**

- Files: `lib/services/whatsapp_outbound.dart`, `lib/services/seat_chart_pdf.dart`, `lib/services/whatsapp_cloud_service.dart`
- The phase-8 "send seat allocation" flow is completely untested (no `test/services/whatsapp_outbound_test.dart`). It involves PDF generation, storage upload, and Cloud API dispatch in sequence. A regression in any step sends incomplete or blank messages to 200+ passengers.
- **Suggested fix:** Add a unit test with a mock `WhatsAppCloudService` that verifies: (a) one PDF upload per bus, (b) one message per seated passenger, (c) passengers with no seats are skipped, (d) the correct template variables are populated.

---

### TEST-5 — `seat_detail_screen_test.dart` references `consolidateOntoDouble` only in a comment; no actual consolidation test
**Severity: Low**

- Files: `test/screens/seat_detail_screen_test.dart` (line 151 — comment only)
- The most complex drag-drop operation (consolidate two singles onto a double) is called out in a comment but not tested.
- **Suggested fix:** Add widget test for consolidation: drag a single onto a free double, verify the passenger holds two berths on the target and zero on the source.

---

*Concerns audit: 2026-06-06*
