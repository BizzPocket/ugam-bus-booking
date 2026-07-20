# Customer Experience — End-to-End Use Cases

Area: Customer journey — browse public tours, submit a seat request, track request status, view assigned seat once the tour is locked, find a seat by phone, switch language, contact organiser.

Actor in this area is almost always **CUSTOMER** — a passenger with NO Supabase Auth session. The customer app is reached automatically: `SplashScreen._routeWhenReady()` sends any non-admin (or logged-out) session to `/customer-home` (`CustomerTourListScreen`). There is no sign-in. The customer's "account" is purely a device-local journal (`CustomerRequestsStore`, a `SharedPreferences` JSON list keyed `customer_requests_v1`) plus per-row server status refreshes via anonymous `SECURITY DEFINER` RPCs.

Key concepts a tester must understand:
- **Device-local requests** — "My Requests" only shows requests submitted *from this device*. A fresh install / cleared app data shows an empty list even if the same phone has live bookings server-side. (The phone-keyed "Find my seat" path exists precisely to cover that gap.)
- **Seat visibility gate** — `CustomerRequestEntry.seatsVisible == tourLocked && hasSeatsAssigned`. Seat NUMBERS and the seat-layout sheet are hidden until the organiser LOCKS the tour. Before lock, an assigned request shows a neutral "being finalized" state.
- **Booking lock gate** — `Tour.acceptsBookings`. When false (tour locked/completed) the "Book" affordance disappears and submit is re-checked against the live tour and blocked.
- **Trip-aware seats / sofas** — booking captures Double Sofa + Single Sofa counts per leg (Full trip / Go only / Return only) via the shared `BookingCaptureForm`.
- **WhatsApp handoff** — after a create, the request is saved server-side first, THEN WhatsApp is opened with a prefilled message to the organiser; the success copy is honest about whether WhatsApp actually launched.
- **Full localization** — every user-facing string is `tr('ns.key')`; namespaces `customer_tour_list`, `customer_tour_detail`, `customer_my_requests`, `customer_more`, `find_seat`, `customer_booking`, `booking_form` must have en/gu/hi parity (verified: all at parity at time of writing).

---

### UC-08CUSTOMEREXPERIENCE-1: Browse the public tour list (happy path)
- **Actor:** customer
- **Phase:** 2 Broadcast/Notify → 3 Collect Requests (customer entry point)
- **Preconditions:** App launched as a non-admin/logged-out session (lands on `/customer-home`). At least one tour exists that is `isPublic`, not `completed`, and whose end date (`returnDate ?? departureDate`) is today or later.
- **Steps:**
  1. Open the app (or it auto-routes from splash to the explore screen).
  2. Observe the "Explore" header, the My-Requests ticket icon, the search icon, and the menu icon.
  3. Read the two groups: "Upcoming" (departs within 30 days) and "Later" (departs after 30 days).
  4. Scroll the list; pull down to refresh.
- **Expected:**
  - Tours render as 88-px photo rows: bus backdrop with route monogram (e.g. "S→M"), date pill, title, `from → to`, price-per-seat (only if `pricePerSeat > 0`).
  - Each row shows a capacity chip: "N left" (good) when seats remain, "Full" (warm) when `capacity - assigned <= 0`, or "Open for requests" (neutral) when capacity is 0 (no bus booked yet).
  - Each unlocked, non-full row shows an accent "Book" pill; a full row shows a muted arrow; a locked tour shows a lock glyph (no Book affordance).
  - Groups sort by departure date ascending; group header shows a count badge.
  - Pull-to-refresh calls `tourCtrl.refreshTours()` with an accent spinner.
- **Edge cases:**
  - Empty list (no visible tours) → `event_busy` empty state with "pull to refresh" body, still pull-to-refreshable.
  - Loading with no cached tours → skeleton shimmer.
  - Fetch error with no cached tours → `cloud_off` error state showing `tourCtrl.errorMessage` + a Retry CTA.
  - A round trip that departed yesterday but returns next week STAYS visible (cutoff uses `returnDate ?? departureDate`).
  - Completed tours and non-public tours are never listed; there is no "Past" group for customers.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart`, `lib/controllers/tour_controller.dart`, `lib/screens/splash_screen.dart`

### UC-08CUSTOMEREXPERIENCE-2: Search/filter the tour list
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** On the explore screen with several visible tours.
- **Steps:**
  1. Tap the search (magnifier) icon to reveal the search field (auto-focuses).
  2. Type a query (matches tour title, fromCity, or toCity — case-insensitive).
  3. Clear the query or tap the close (X) icon to collapse search.
- **Expected:**
  - The field animates open (`AnimatedSize`); typing filters within both groups live.
  - A query with no matches shows the `search_off` empty state with body `no_matches_body` interpolating the query `{q}`.
  - Toggling search closed clears the query and restores the full list.
- **Edge cases:**
  - Whitespace-only query is trimmed to empty (shows full list).
  - Search matches partial city names ("mum" matches "Mumbai").
  - Language switch: hint text `customer_tour_list.search_hint` and empty-state strings must exist in en/gu/hi.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart`

### UC-08CUSTOMEREXPERIENCE-3: Open a tour's detail (About + Schedule)
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** A visible tour exists.
- **Steps:**
  1. Tap a tour ROW (not the Book pill) to open `CustomerTourDetailScreen`.
  2. Read the 320-px hero: backdrop, back chevron, status chip (uppercase `tour.status.displayName`), share chevron, and the overhanging summary card (title, route, date, price, seats-left chip).
  3. Tap the "About" tab: see Trip Summary info card (route, departure date+time, return date+time if any, price), an "About this tour" description block (only if `tour.description` non-empty), a Bus card (only if `tour.buses` non-empty), and a "Contact organiser" row (only if `tour.createdBy` non-empty).
  4. Tap the "Schedule" tab: see a vertical timeline — departure-from, arrive-in, and return-to (only when `returnDate != null`).
- **Expected:**
  - The seats-left chip mirrors the list logic ("Tour full" warm / "N seats left" good / "Open for requests" accent when capacity 0).
  - Departure/return rows append time-of-day only when set (`formatHhMm`); date-only otherwise.
  - The Bus card shows `bus.customerLabel`, bus type, boarding point · departure time (when present), an AC chip (if `bus.isAC`), and a seats chip.
- **Edge cases:**
  - No description → "About this tour" section is omitted entirely.
  - No bus booked yet → Bus section omitted; seats chip reads "Open for requests".
  - No organiser number → Contact organiser row omitted.
  - No return date → only two timeline events; no "Return" info row.
- **Screens/files:** `lib/screens/customer_tour_detail_screen.dart`

### UC-08CUSTOMEREXPERIENCE-4: Share a tour announcement to clipboard
- **Actor:** customer
- **Phase:** 2 Broadcast/Notify
- **Preconditions:** On a tour's detail screen.
- **Steps:**
  1. Tap the share (iOS-share) chevron in the hero top-right.
- **Expected:**
  - `WhatsAppService().copyAnnouncementToClipboard(tour)` runs (light haptic). The announcement text is placed on the clipboard for the customer to paste/forward.
- **Edge cases:**
  - This is a copy-to-clipboard action, NOT a system share sheet — verify no share dialog appears.
- **Screens/files:** `lib/screens/customer_tour_detail_screen.dart`, `lib/services/whatsapp_service.dart`

### UC-08CUSTOMEREXPERIENCE-5: Contact the organiser on WhatsApp from the detail screen
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** On a tour's About tab; the tour has a non-empty `createdBy` (organiser phone).
- **Steps:**
  1. Tap the "Contact organiser" row.
- **Expected:**
  - Opens a WhatsApp chat to the organiser with a prefilled greeting interpolating `{tour}` (title) and `{code}` (`WhatsAppService.tourCode(tour.id)`).
  - On failure to open WhatsApp, an error snackbar shows `contact_error_title` / `contact_error_body`.
- **Edge cases:**
  - Organiser number empty/whitespace → row is not rendered (so this path is unreachable).
  - WhatsApp not installed → error snackbar (verify both title and body strings exist in en/gu/hi).
- **Screens/files:** `lib/screens/customer_tour_detail_screen.dart`, `lib/services/whatsapp_service.dart`

### UC-08CUSTOMEREXPERIENCE-6: Submit a booking request (one-tap "Book" → form → save → WhatsApp)
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** A visible, unlocked, non-full tour. Organiser number set on the tour.
- **Steps:**
  1. From the list, tap the accent "Book" pill (jumps straight to the form, skipping detail), OR from detail tap the sticky "Request to book" CTA.
  2. Fill the shared `BookingCaptureForm`: name, phone (10-digit Indian mobile), pick leg tab (Full trip / Go only / Return only), set Double/Single Sofa counts, optionally add a note.
  3. Observe the sticky CTA showing live seat count and (when price > 0) the estimated total.
  4. Tap Submit.
- **Expected:**
  - Server write happens first via `submit_booking_request` RPC (atomic passenger + booking_requests row); on `PGRST202` it falls back to two legacy inserts.
  - The request is added to the device-local `CustomerRequestsStore` with status `pending`.
  - WhatsApp opens to the organiser with the prefilled request message; the app navigates (`Get.offNamed`) to My Requests so the customer immediately sees the tracked ticket.
  - Success snackbar copy is honest: `success_sent_wa` (WhatsApp opened), `success_saved_wa_failed` (saved but WhatsApp did not open), or `success_sent_no_wa` (no organiser number).
  - The My-Requests badge count on the explore top bar increases.
- **Edge cases:**
  - Invalid input → `BookingCaptureForm.collect()` returns null and shows inline errors (name required / phone invalid / phone fake / no seats); no network call.
  - Rapid re-submit within 15 s cooldown → hard block with `err_too_fast`.
  - Exact duplicate pending request (same tour + phone + name + seat counts) → soft warn dialog `warn_duplicate_*`; customer may "submit anyway". A different name or seat mix is NOT a duplicate.
  - Tour locked between opening the form and submitting → re-check against live tour blocks it with `err_bookings_closed`.
  - Save failure (exception) → `err_save_failed` snackbar; logs print the real cause.
  - No organiser number → request still saved; success copy uses the no-WhatsApp variant.
- **Screens/files:** `lib/screens/customer_booking_request_screen.dart`, `lib/widgets/booking_capture_form.dart`, `lib/services/customer_requests_store.dart`, `lib/services/whatsapp_service.dart`, `lib/routes/app_routes.dart`

### UC-08CUSTOMEREXPERIENCE-7: Try to book a FULL or LOCKED tour
- **Actor:** customer
- **Phase:** 3 Collect Requests / 8 Lock & Notify
- **Preconditions:** A full tour (seats-left ≤ 0) and a locked tour (`acceptsBookings == false`).
- **Steps:**
  1. On the list, observe the Book pill state for a full tour vs a locked tour.
  2. Open the full tour's detail and read the sticky CTA.
  3. Open the locked tour's detail and read the sticky CTA.
- **Expected:**
  - List: full tour → muted non-actionable arrow chip (row still opens detail); locked tour → lock glyph (no Book).
  - Detail full tour → CTA label `cta_join_waitlist` (hourglass icon) that STILL opens the booking form (waitlist request allowed).
  - Detail locked tour → CTA label `cta_bookings_closed` (lock icon), `onTap == null` (disabled).
- **Edge cases:**
  - A full-but-unlocked tour can still receive a waitlist request via detail CTA, but NOT from the list Book pill — verify this asymmetry.
  - Submitting on a tour that locks mid-flow is blocked at `_submit` (see UC-6).
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart`, `lib/screens/customer_tour_detail_screen.dart`

### UC-08CUSTOMEREXPERIENCE-8: View "My Requests" and filter by status
- **Actor:** customer
- **Phase:** 3 Collect Requests → tracking
- **Preconditions:** At least one request submitted from THIS device.
- **Steps:**
  1. Tap the ticket icon on the explore top bar.
  2. Observe the status filter pills (All / Pending / Confirmed / Cancelled), each with a count.
  3. Tap a pill to filter; pull to refresh; tap the trailing refresh action.
- **Expected:**
  - Bootstraps from cache, then `refreshAll()` fires per-row `booking_request_status_lookup` + `booking_request_tour_locked` RPCs.
  - Rows show backdrop+date, title, route, a status dot, and a seats label (e.g. "1 Double sofa + 1 Single sofa", or "N seats" fallback).
  - Status chip mapping: seats visible (locked + assigned) → "Seats assigned" good; assigned but not locked → "Seats finalizing" warm; `accepted` → "Confirmed" good; `rejected` → "Cancelled" warm; else → "Pending" warm.
  - Filter buckets: Pending = `pending && !hasSeatsAssigned`; Confirmed = `hasSeatsAssigned || accepted`; Cancelled = `rejected`.
  - Only LIVE (non-past) tickets are shown; a past trip's ticket is hidden.
- **Edge cases:**
  - No requests on this device → `inbox` empty state (`empty_title`/`empty_body`).
  - A filter with zero matches (but other live tickets exist) → `filter_alt_off` empty state (`empty_filter_*`).
  - Refresh while offline → cached list remains usable; refresh swallows errors.
  - A request whose tour/request the organiser deleted → flagged `rejected` on refresh and moved to the Cancelled tab (stale seats cleared via `markCancelled`).
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/services/customer_requests_store.dart`

### UC-08CUSTOMEREXPERIENCE-9: Edit a pending request
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** A request in My Requests with `status == 'pending'` and no seats assigned yet (`canEdit == true`).
- **Steps:**
  1. Tap the "Edit request" pill in the row footer (or tap the row, which routes to edit when editable).
  2. Change name / seat counts / leg / note in the prefilled form.
  3. Tap Update.
- **Expected:**
  - `booking_request_customer_update` RPC atomically updates booking_requests + passengers and stamps `customer_edited_at`.
  - On success: local entry is upserted with the new values + `customerEditedAt`, screen pops, success snackbar (`success_updated_wa` if organiser, else `success_updated_no_wa`); an "updated request" WhatsApp variant is sent when an organiser number exists.
  - The row later shows an "Edited" chip (`wasEdited`).
- **Edge cases:**
  - RPC returns `ok != true` (e.g. seats were assigned server-side after the customer opened the form) → warning snackbar `warn_edit_blocked` / `warn_title_edit_blocked` and a silent refresh of the entry.
  - Tour locked mid-edit → blocked at `_submit` with `err_bookings_closed`.
  - An assigned-but-unlocked request is NOT editable; tapping the row shows the `seats_pending_toast` instead.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/screens/customer_booking_request_screen.dart`

### UC-08CUSTOMEREXPERIENCE-10: Add another distinct request from the same phone
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** A request row exists for a tour. (Migration 030 allows one phone to hold multiple requests per tour.)
- **Steps:**
  1. On a request row, tap the low-emphasis "Add another" button.
  2. Fill a BLANK create form for the same tour (different traveller / seat mix).
  3. Submit.
- **Expected:**
  - Opens the booking form in CREATE mode (`existing == null`) for that row's tour; a fresh passenger + booking_requests pair is inserted.
  - Both requests now appear as separate rows in My Requests.
- **Edge cases:**
  - The duplicate preflight only blocks an EXACT match (same name + seat counts); a genuinely different second request passes.
  - If `TourController` is registered the live tour is used; otherwise a minimal `Tour` is rebuilt from the entry (`_tourFromEntry`) — verify the form still works on a rebuilt stub.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`

### UC-08CUSTOMEREXPERIENCE-11: View assigned seat AFTER the tour is locked
- **Actor:** customer
- **Phase:** 8 Lock & Notify (post-lock)
- **Preconditions:** A request with seats assigned AND its tour locked (`seatsVisible == true`).
- **Steps:**
  1. In My Requests, tap a row whose status reads "Seats assigned".
  2. Inspect the seat-layout sheet.
- **Expected:**
  - `showCustomerSeatLayoutSheet` opens; it loads bus layouts via `bus_layouts_for_request` RPC.
  - For each bus: header with `customerLabel` + "Your seats: …", the actual seat grid (`CombinedSeatGrid`) with the customer's own seats highlighted in accent and ALL other seats anonymous/neutral (identities never shown), plus a 2-item legend (Mine / Others).
  - The row footer also shows a green "Seats: L1, L2" chip listing the actual seat ids.
- **Edge cases:**
  - Layout RPC returns no buses → `event_seat` empty state (`layout_empty_*`).
  - Layout load error → `cloud_off` error state (`layout_load_error_*`).
  - A bus with null/zero-cell layout → "layout unavailable" text instead of a grid.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/widgets/customer_seat_layout_sheet.dart`, `lib/services/customer_requests_store.dart`

### UC-08CUSTOMEREXPERIENCE-12: Seats assigned but tour NOT yet locked (provisional state)
- **Actor:** customer
- **Phase:** 6 Assign Seats (pre-lock)
- **Preconditions:** A request with seats assigned server-side but its tour still unlocked (`hasSeatsAssigned == true`, `tourLocked == false`, so `seatsVisible == false`).
- **Steps:**
  1. In My Requests, find the row; read its status chip.
  2. Tap the row.
- **Expected:**
  - Status chip reads "Seats finalizing" (warm); the footer shows a neutral "finalizing" chip, NOT seat numbers.
  - Tapping does NOT open the layout sheet; instead an info toast `seats_pending_toast` explains seats are still provisional.
  - The Confirmed filter still counts this request (because `hasSeatsAssigned`), but no numbers leak.
- **Edge cases:**
  - This is the critical privacy/no-lie gate — verify NO provisional seat numbers ever render before lock, in either the row footer or via tap.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/services/customer_requests_store.dart`

### UC-08CUSTOMEREXPERIENCE-13: One-way request chips (leg display)
- **Actor:** customer
- **Phase:** 3 Collect Requests
- **Preconditions:** A request submitted as outbound-only or return-only.
- **Steps:**
  1. Submit (or already have) a request with `tripType` outbound-only or return-only.
  2. View it in My Requests.
- **Expected:**
  - Row footer shows a warm chip: `chip_oneway_out` for outbound-only, `chip_oneway_return` for return-only.
  - Round-trip requests show no leg chip.
- **Edge cases:**
  - Mixed-leg requests (e.g. 1 Double round-trip + 1 Double go-only) derive a round-trip summary `tripType` (`_summaryTripType`), so the one-way chip is NOT shown — verify mixed-leg requests render as round-trip at the summary level.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/widgets/booking_capture_form.dart`

### UC-08CUSTOMEREXPERIENCE-14: Find my seat by phone (no in-app ticket)
- **Actor:** customer (or a manually-added passenger with no booking request)
- **Phase:** 8 Lock & Notify (post-lock)
- **Preconditions:** The customer's tour is locked and a seat is held under their phone. They may have NO device-local ticket (fresh install, or were added manually by the agent).
- **Steps:**
  1. Open menu → "Find my seat" (`FindMySeatScreen`).
  2. Enter a mobile number; tap Find.
- **Expected:**
  - Runs `seat_lookup_by_phone` + `handler_requests_by_phone` in parallel (phone matched on last 10 digits server-side, so +91/spaces don't matter).
  - For each resolved ticket: a card with tour title, route, passenger name, an accent "Your seats: …" chip, and the bus diagram(s) with the rider's seats highlighted (everyone else anonymous).
  - If the queried phone is also the tour's handler, a "Manage as handler" CTA appears inline (and a handler-only tour with no seat ticket gets its own `_HandlerEntryCard`).
- **Edge cases:**
  - Fewer than 10 digits entered → inline `error_short`, no network call.
  - Load failure → `error_load` shown under the field.
  - No tickets AND no handler tours → `event_seat` empty state (`empty_*`).
  - Bus with no layout → "layout unavailable" text.
  - Only LOCKED/completed tours return seats — an unlocked tour returns nothing (seats still provisional).
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`, `lib/services/customer_requests_store.dart`, `lib/models/seat_ticket.dart`, `lib/models/handler_tour_ref.dart`

### UC-08CUSTOMEREXPERIENCE-15: Switch app language (en/gu/hi)
- **Actor:** customer
- **Phase:** any
- **Preconditions:** On the customer "More" screen.
- **Steps:**
  1. Open menu → "More" (`CustomerMoreScreen`).
  2. Tap the Language row (subtitle shows the active language label).
  3. Pick a different language in the `LanguagePickerSheet`.
- **Expected:**
  - The picker switches locale; every customer string re-renders in the chosen language (list, detail, requests, find-seat, booking form, snackbars).
  - The Language row subtitle updates to the newly active language.
- **Edge cases:**
  - Verify all six customer namespaces + `booking_form` have en/gu/hi parity (counts confirmed equal at time of writing: customer_tour_list 21, customer_tour_detail 37, customer_my_requests 52, customer_more 20, find_seat 14, customer_booking 54).
  - Date/month labels use localized `app.month.short.*` keys; verify the date pill and schedule rows localize too.
- **Screens/files:** `lib/screens/customer_more_screen.dart`, `lib/widgets/language_picker_sheet.dart`, `assets/translations/{en,gu,hi}.json`

### UC-08CUSTOMEREXPERIENCE-16: More menu — About / Privacy / Terms / version
- **Actor:** customer
- **Phase:** any
- **Preconditions:** On the customer "More" screen.
- **Steps:**
  1. Tap About, then Privacy, then Terms.
  2. Scroll to the footer.
- **Steps notes:** Each opens `LegalDocumentScreen` with the corresponding `LegalContent` doc.
- **Expected:**
  - Brand hero shows "Ugam Foj" + tagline + logo.
  - Each legal row opens its document screen; footer shows `version` (interpolating `AppInfo.version`) and "made by" line.
  - No profile header / no sign-in (customer has no account).
- **Edge cases:**
  - Long-press handling and admin entry are NOT here — that hidden admin entry is the explore header long-press (see UC-17).
- **Screens/files:** `lib/screens/customer_more_screen.dart`, `lib/content/legal_content.dart`, `lib/config/app_info.dart`

### UC-08CUSTOMEREXPERIENCE-17: Hidden admin entry via long-press on the Explore header
- **Actor:** admin (using the customer build to reach login)
- **Phase:** cross-cutting (role gating)
- **Preconditions:** On the explore screen as a non-admin session.
- **Steps:**
  1. Long-press the "Explore" title in the top bar.
- **Expected:**
  - Medium haptic; navigates to the otherwise-unlinked `AppRoutes.login`.
  - There is no visible login button anywhere else in the customer flow.
- **Edge cases:**
  - A normal tap on the title does nothing; only long-press triggers it (the affordance is deliberately invisible to customers).
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart`, `lib/routes/app_routes.dart`

### UC-08CUSTOMEREXPERIENCE-18: Handler-customer sees "View full chart" from My Requests
- **Actor:** handler (a passenger appointed as conductor, viewing their own request)
- **Phase:** 7 Assign Handler → on-trip
- **Preconditions:** A request in My Requests whose phone is the tour's designated handler (`isRequestHandler` resolves true for the entry).
- **Steps:**
  1. Open My Requests; wait for handler status to resolve (cached per id).
  2. On the handler's row, tap "View full chart".
- **Expected:**
  - The handler-only `_HandlerChartButton` is rendered (only when `isRequestHandler == true`).
  - Tapping opens `HandlerBusChartScreen(requestId: entry.id)` — the full bus chart for on-trip management.
- **Edge cases:**
  - Non-handler rows never show this button.
  - `isRequestHandler` RPC failure is treated as not-a-handler (button hidden) — fail closed.
  - Same handler entry point is also reachable from "Find my seat" via the "Manage as handler" CTA (UC-14).
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/screens/handler_bus_chart_screen.dart`, `lib/services/customer_requests_store.dart`

---

## Notable cross-cutting behaviors for testers
- **Device-locality is the #1 surprise:** "My Requests" is empty after reinstall/clear-data even when bookings are live. Always reach for "Find my seat by phone" to verify a seat that wasn't booked from this device.
- **Seat reveal is gated on LOCK, not assignment.** Test both states explicitly (UC-11 vs UC-12). No provisional numbers should ever leak.
- **Submit is verified twice against the lock gate** (UI affordance hiding + `_submit` live re-check), so a tour locked mid-flow must hard-block.
- **WhatsApp is best-effort and post-save:** the request persists server-side regardless of whether WhatsApp launches; success copy must reflect the real outcome.
- **Anonymous RPCs everywhere:** customers have no auth session; every server read/write goes through `SECURITY DEFINER` RPCs (`submit_booking_request`, `booking_request_status_lookup`, `booking_request_tour_locked`, `bus_layouts_for_request`, `seat_lookup_by_phone`, `handler_requests_by_phone`, `is_request_handler`). Errors generally fail closed (treat as not-locked / not-handler).
- **All six customer namespaces are at en/gu/hi parity now;** any new string added to these screens must keep 3-file parity or a `tr()` key will render raw.
