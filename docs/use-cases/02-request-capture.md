# Phase 3 — Request Capture & Review Use Cases

End-to-end, testable use cases for **customer request submission** and **admin request review/approval**. Grounded in the actual current code (not aspirational). Phase 3 in the 8-phase lifecycle is "Collect Requests"; this area spans the customer's in-app booking form, their "My Requests" tracker, and the admin's Requests workspace where new requests are triaged (New → Waitlist → Confirmed → Assigned).

Key behaviors verified in code:
- One phone can hold **multiple distinct requests per tour** — submitting again never overwrites a prior request (migration 030; `submit_booking_request` RPC inserts a fresh passenger + audit row per submission).
- The trip leg lives **per RequestLine** — a single request can mix legs (e.g. 1 Double Sofa round-trip + 1 Single Sofa GO-only).
- `Tour.acceptsBookings` (= status not `locked` and not `completed`) is the **single lock gate** enforced on every booking entry point AND at the `addPassenger` server-write chokepoint.
- Customer "My Requests" is a **device-local journal** (`CustomerRequestsStore`, SharedPreferences) refreshed per-row via RPC — the customer has no Supabase Auth session.
- Customer-side anti-abuse: a **15s cooldown** (`_cooldownMs`) hard-blocks rapid resubmits; an **exact-duplicate pending request** (same phone+tour+name+seat counts) soft-warns with submit-anyway.
- Seat **numbers stay hidden** until the tour is locked (`seatsVisible = tourLocked && hasSeatsAssigned`); before that the customer sees a "finalizing" state.

---

### UC-02REQUESTCAPTURE-1: Customer submits a new round-trip seat request from the booking form
- **Actor:** customer
- **Phase:** Phase 3 (Collect Requests)
- **Preconditions:** Customer app open; at least one public, non-completed tour is visible whose `acceptsBookings` is true (status before `locked`); tour has an organiser phone (`tour.createdBy` non-empty); WhatsApp installed.
- **Steps:**
  1. From the customer tour list, tap a tour row's **Book** pill (or open the detail and tap **Request to book**).
  2. On the booking form, enter a name and a valid 10-digit Indian mobile.
  3. On the **Full trip** leg tab, set Double Sofa = 1 (or any non-zero seat count).
  4. (Optional) tap **Add note** and type a note.
  5. Tap the bottom **Submit** CTA.
- **Expected:**
  - The sticky CTA shows a live "N seats" trailing value and (when `pricePerSeat > 0`) an estimated-total row above it (`seats × pricePerSeat`, formatted INR).
  - On submit, the `submit_booking_request` RPC inserts one passenger + one `booking_requests` audit row (`party_size` = total seats, `request_lines` = one line per non-empty cell).
  - A local `CustomerRequestEntry` with `status: 'pending'` is written to `CustomerRequestsStore`.
  - WhatsApp opens with the standard booking-request message to the organiser; the screen replaces itself with **My Requests** (`Get.offNamed`).
  - A success toast appears: `customer_booking.success_sent_wa` titled `success_title_submitted`.
- **Edge cases:**
  - **WhatsApp fails to open / not installed:** request is still saved server-side; toast switches to `customer_booking.success_saved_wa_failed`.
  - **No organiser phone on tour:** no WhatsApp attempt; toast is `customer_booking.success_sent_no_wa`.
  - **Rapid double-submit within 15s:** second attempt hard-blocked with `customer_booking.err_too_fast` (no network write).
  - **Network/RPC throws:** caught; friendly `customer_booking.err_save_failed` toast; saving spinner clears.
  - **RPC not deployed (PostgrestException `PGRST202`):** falls back to legacy two-write path (insert into `booking_requests` then plain `passengers` insert).
- **Screens/files:** `lib/screens/customer_booking_request_screen.dart`, `lib/widgets/booking_capture_form.dart`, `lib/services/customer_requests_store.dart`, `lib/services/whatsapp_service.dart`, `lib/utils/phone_normalize.dart`

### UC-02REQUESTCAPTURE-2: Customer submits a mixed-leg request (round-trip + one-way lines)
- **Actor:** customer
- **Phase:** Phase 3
- **Preconditions:** Booking form open on an open tour.
- **Steps:**
  1. On the **Full trip** tab, set Double Sofa = 1.
  2. Switch to the **Go only** tab; set Single Sofa = 1.
  3. (Optional) switch to **Return only**; set another count.
  4. Observe each leg tab's badge reflects its own per-leg seat count, and the "N seats total" line sums across legs.
  5. Submit.
- **Expected:**
  - The collected payload produces **one `RequestLine` per non-empty (leg, type) cell** — here a Double Sofa round-trip line and a Single Sofa outbound-only line — each carrying its own `leg` storageKey.
  - The derived `tripType` summary is `roundTrip` (because legs are mixed), but per-line legs are the source of truth.
  - In My Requests the row shows the seat breakdown chips; one-way lines surface a GO/RET one-way chip.
- **Edge cases:**
  - All lines on a single one-way leg → derived `tripType` is that one-way leg (not roundTrip).
  - A one-way line weighs 0.5 per berth in seat-load accounting (trip-aware counting), but assignment completeness stays physical.
- **Screens/files:** `lib/widgets/booking_capture_form.dart` (`_LegTabs`, `collect`, `_summaryTripType`), `lib/models/request_line.dart`, `lib/models/passenger.dart` (`seatLoad`, `goBerths`, `retBerths`)

### UC-02REQUESTCAPTURE-3: Customer submits a SECOND distinct request from the same phone on the same tour
- **Actor:** customer
- **Phase:** Phase 3
- **Preconditions:** Customer already has at least one pending request on a tour (visible in My Requests).
- **Steps:**
  1. Open **My Requests**.
  2. On an existing request row, tap **Add another request**.
  3. A BLANK create form opens for that row's tour (`existing` is null → create mode).
  4. Enter a different traveller name and/or a different seat mix; submit.
- **Expected:**
  - A new passenger + new `booking_requests` row is inserted with a fresh UUID — the earlier request is NOT overwritten/collapsed (migration 030).
  - Both requests now appear as separate rows in My Requests and as separate cards on the admin Requests screen.
- **Edge cases:**
  - **Same name AND same seat counts as the existing pending request** → soft duplicate warning (`warn_duplicate_*`) with submit-anyway; a DIFFERENT name or seat mix is NOT treated as a duplicate.
  - **Within the 15s cooldown** → hard-blocked with `err_too_fast` regardless of distinctness.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart` (`_openAddAnother`), `lib/screens/customer_booking_request_screen.dart` (`_preflightCreate`)

### UC-02REQUESTCAPTURE-4: Customer is blocked from booking a locked tour
- **Actor:** customer
- **Phase:** Phase 3 (boundary into Phase 8 lock)
- **Preconditions:** A tour the customer can see has been locked by the admin (`status == locked`, so `acceptsBookings` false).
- **Steps:**
  1. From the customer tour list, locate the locked tour row.
  2. Observe the trailing Book affordance.
  3. Open the tour detail and observe the bottom CTA.
  4. (If a stale form is reachable, e.g. via an Add-another / edit deep-link) attempt to submit.
- **Expected:**
  - On the list row, the **Book** pill renders a non-actionable **lock** chip (`_BookPill` with `closed: !tour.acceptsBookings`); the row still opens detail.
  - On the detail screen, the sticky CTA reads `customer_tour_detail.cta_bookings_closed` with a lock icon and `onTap` null.
  - If a submit is forced, `_submit` re-checks the LIVE tour and aborts with `customer_booking.err_bookings_closed`.
- **Edge cases:**
  - Lock state is re-checked against the **live tour** (via `TourController.getTour`), not the possibly-stale `widget.tour`, so a request opened before the lock can't slip through.
  - A completed tour is also `acceptsBookings == false` and behaves the same.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart` (`_BookPill`), `lib/screens/customer_tour_detail_screen.dart` (`_StickyBookCta`), `lib/screens/customer_booking_request_screen.dart` (`_submit` live re-check), `lib/models/tour_status.dart` (`acceptsBookings`)

### UC-02REQUESTCAPTURE-5: Customer is blocked from booking a full bus from the list row (but can still join via detail/waitlist)
- **Actor:** customer
- **Phase:** Phase 3
- **Preconditions:** Tour has a bus with capacity, and `totalSeatsAssigned >= totalBusSeats` (seatsLeft ≤ 0); tour still `acceptsBookings`.
- **Steps:**
  1. On the customer tour list, find the full tour row.
  2. Observe its capacity chip and Book affordance.
  3. Open the detail and observe its CTA.
- **Expected:**
  - List row shows a **warm "Full"** chip (`customer_tour_list.chip_full`) and the Book pill renders a muted non-actionable arrow (no tappable Book) — `_BookPill` with `full: true`.
  - The detail CTA switches to **Join waitlist** (`customer_tour_detail.cta_join_waitlist`) which still opens the booking form (booking a full bus is allowed only through the detail/waitlist path, not the row pill).
- **Edge cases:**
  - A tour with **no bus yet** (`capacity == 0`) shows the neutral **"Open"** chip (`chip_open`) and a tappable Book pill — demand can be collected before a bus exists.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart` (`_TourRow`, `_BookPill`), `lib/screens/customer_tour_detail_screen.dart` (`_StickyBookCta`)

### UC-02REQUESTCAPTURE-6: Booking form validation (name / phone / seats)
- **Actor:** customer (same rules for admin add/edit)
- **Phase:** Phase 3
- **Preconditions:** Booking form open.
- **Steps:**
  1. Leave name blank, phone blank, seats at 0; tap Submit.
  2. Enter a 9-digit or non-mobile-leading phone (e.g. starting with 1–5); submit.
  3. Enter a junk run like `9999999999` or `9876543210`; submit.
  4. Fix all fields with a valid name, valid 10-digit 6–9-leading number, and ≥1 seat; submit.
- **Expected:**
  - Inline errors appear without any network call: name → `booking_form.err_name_required`; phone (wrong length) → `booking_form.err_phone_invalid`; seats=0 → `booking_form.err_no_seats`.
  - Plausibility-failing phones (wrong leading digit, all-same-digit, or trivial ascending/descending run) → `booking_form.err_phone_fake` (`isPlausibleIndianMobile`).
  - `collect()` returns null while invalid, so `_submit` early-returns before any RPC.
  - Once valid, phone is normalised to `+91XXXXXXXXXX` for storage.
- **Edge cases:**
  - Phone field is digits-only and length-limited by the input; leading `+91`/spaces are stripped by `normalisePhone` (last 10 digits).
  - This validation is **client-side deterrence only**, not ownership verification.
- **Screens/files:** `lib/widgets/booking_capture_form.dart` (`collect`), `lib/utils/phone_normalize.dart` (`isPlausibleIndianMobile`, `normalisePhone`)

### UC-02REQUESTCAPTURE-7: Customer edits a pending request before seats are assigned
- **Actor:** customer
- **Phase:** Phase 3
- **Preconditions:** Customer has a request with `status == 'pending'` and no seats assigned (`canEdit` true → the row shows an **Edit** button).
- **Steps:**
  1. Open My Requests; tap **Edit request** on a pending row (or tap the row body, which routes to edit when `canEdit`).
  2. The form opens pre-filled (`BookingCaptureInitial` from the entry: name, phone, trip type, seat counts, note).
  3. Change seat counts / name / note; tap **Update**.
- **Expected:**
  - `booking_request_customer_update` RPC is called (atomically updates both tables and stamps `customer_edited_at`).
  - On success, the local entry is updated with `customerEditedAt = now`; the row gains an **"Edited"** chip (`wasEdited`).
  - An "updated request" WhatsApp variant is sent (`isUpdate: true`) so the organiser sees it's not a fresh ping; success toast `customer_booking.success_updated_wa`.
  - The screen pops back to My Requests, which refreshes.
- **Edge cases:**
  - **RPC returns not-true (edit blocked server-side, e.g. tour locked / seats now assigned):** warning toast `customer_booking.warn_edit_blocked` titled `warn_title_edit_blocked`; the entry is refreshed from server to resync state. No local mutation.
  - **No organiser phone:** no WhatsApp; toast `customer_booking.success_updated_no_wa`.
  - Editing on a now-locked tour also hits the `_submit` live `acceptsBookings` re-check → `err_bookings_closed`.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart` (`_openEdit`, `_onRowTap`), `lib/screens/customer_booking_request_screen.dart` (`_submitEdit`), `lib/services/customer_requests_store.dart`

### UC-02REQUESTCAPTURE-8: Customer My-Requests status tracking, filtering, and seat reveal gating
- **Actor:** customer
- **Phase:** Phase 3 → 8 (tracking across lifecycle)
- **Preconditions:** Customer has several requests in varied states (pending, seats-assigned-but-unlocked, locked-with-seats, organiser-deleted).
- **Steps:**
  1. Open My Requests; pull-to-refresh (or tap the circle refresh action).
  2. Observe the status pills: All / Pending / Confirmed / Cancelled with counts.
  3. Switch between tabs.
  4. Tap a row whose tour is NOT yet locked but has seats assigned.
  5. Tap a row whose tour IS locked with seats assigned.
- **Expected:**
  - `refreshAll` re-pulls each entry via `booking_request_status_lookup` + `booking_request_tour_locked`.
  - **Pending** tab = `status == 'pending' && !hasSeatsAssigned`; **Confirmed** = `hasSeatsAssigned || status == 'accepted'`; **Cancelled** = `status == 'rejected'`.
  - A request whose tour is assigned-but-unlocked shows a **warm "Finalizing"** chip (`chip_seats_finalizing`) — tapping it shows `seats_pending_toast` info, NOT seat numbers.
  - A request on a **locked** tour with seats shows a **green "Seats assigned"** chip and the actual seat IDs; tapping opens the seat-layout sheet (`seatsVisible`).
  - **Past trips** (departure date passed) are hidden from the live list entirely.
- **Edge cases:**
  - **Organiser deleted the request/tour:** refresh's status-lookup returns empty rows → entry is `markCancelled` (status `rejected`, seats + lock cleared) and surfaces under **Cancelled**, not as a live "allocated" card.
  - **Empty journal (no requests):** `UgamEmpty` with `empty_title`/`empty_body`.
  - **All entries filtered out by a tab:** filter-empty state (`empty_filter_title`/`empty_filter_body`).
  - Refresh failure leaves the cached list usable (errors swallowed per-row).
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart` (`_visible`, `_statusFor`, `_onRowTap`), `lib/services/customer_requests_store.dart` (`refreshAll`, `seatsVisible`, `markCancelled`)

### UC-02REQUESTCAPTURE-9: Admin reviews incoming requests in the New tab and triages by status
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** Admin signed in; a tour exists with pending passengers (`!waitlisted && !confirmed && !fullyAssigned`).
- **Steps:**
  1. Open the **Requests** tab; if multiple active tours, pick one from the selector pills.
  2. Observe the **New / Waitlist / Confirmed / Assigned** status tabs with counts and the collapsible capacity banner.
  3. On a New card, read name, tappable phone, time-ago, seat-berth chip, request-line chip, one-way/priority/group chips, and any note.
  4. Tap the card's circle **Waitlist** action; confirm the card moves to the Waitlist tab.
- **Expected:**
  - The New list is `!isWaitlisted && !isConfirmed && !isFullyAssigned`, ordered **newest-first** (no sort control).
  - `journeyDone` passengers are excluded from the active roster across all tabs.
  - Waitlisting fires `setWaitlisted(...,true)` and toasts `requests.snack.moved_to_waitlist`.
  - The seat chip counts **berths** (a Double Sofa line = 2 seats), and one-way is flagged with a warm trip chip.
- **Edge cases:**
  - **No active tours:** `requests.empty_no_tours` empty state; Add/Groups actions disabled.
  - **Empty tab:** per-tab empty state (`empty_new` / `empty_waitlist` / `empty_confirmed` / `empty_assigned`).
  - **Search active with no match:** `empty_search` with the query echoed.
  - Sticky **Seats** CTA is hidden when there are no live (non-`journeyDone`) requests (BUG-003 guard).
- **Screens/files:** `lib/screens/requests_screen.dart` (`_buildBody`, `_RequestCard`, `_CardActions`)

### UC-02REQUESTCAPTURE-10: Admin confirms a request (auto-sends Cloud confirmation template)
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** A New or Waitlisted passenger, not yet assigned.
- **Steps:**
  1. On a New/Waitlist card, open the overflow menu and choose **Confirm** (plain confirm, no seating).
  2. (Alternative) tap the primary **Confirm & seat** chip.
- **Expected:**
  - `setConfirmed(...,true)` flips `isConfirmed` true and CLEARS any waitlist flag (`isWaitlisted: false`); the card moves to the **Confirmed** tab.
  - The dedicated Cloud `seat_allocation` confirmation template is auto-sent (`WhatsAppOutbound.sendConfirmed`) — confirming IS messaging, no manual WhatsApp tap.
  - Success toast `requests.snack.confirm_sent_*`; **Confirm & seat** stays on the Requests list (per user request it no longer auto-navigates to seat allocation).
- **Edge cases:**
  - **Template send fails (Meta rejection):** error toast surfaces the actual Cloud API reason (unknown template / wrong language / param mismatch), not a generic failure.
  - **Already fully assigned passenger** (in a bulk confirm) is skipped — past the confirm stage.
- **Screens/files:** `lib/screens/requests_screen.dart` (`_confirm`, `_confirmAndSeat`, `_sendConfirmationMessage`), `lib/controllers/tour_controller.dart` (`setConfirmed`), `lib/services/whatsapp_outbound.dart`

### UC-02REQUESTCAPTURE-11: Admin bulk-triages requests via long-press selection
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** Tour with several requests in the active tab.
- **Steps:**
  1. Long-press a request card to enter selection mode (top bar shows selected count + close-X).
  2. Tap additional cards to add them to the selection.
  3. Use the bottom bulk-action bar: **Waitlist** (or **Promote** on the Waitlist tab) / **Confirm** / **Send WA** / **Decline**.
- **Expected:**
  - **Bulk Waitlist:** each selected → `setWaitlisted(true)`; toast `requests.snack.bulk_waitlisted`.
  - **Bulk Confirm:** each non-assigned → `setConfirmed(true)` + auto-send confirmation; toast reports confirmed + sent counts (or partial with failures).
  - **Bulk Send WA:** opens an ack message per selected passenger; toast reports how many opened.
  - **Bulk Promote** (Waitlist tab only): each → `setWaitlisted(false)`; toast `requests.bulk.promoted`.
  - **Bulk Decline:** single confirm dialog (destructive) then `removePassenger` for each; toast `requests.bulk.declined`.
  - Exiting selection clears the selected set and restores the sticky CTA.
- **Edge cases:**
  - **Confirm slot hidden on the Assigned tab** (`canConfirm: false`); Send-WA becomes the accent primary there.
  - Deselecting the last item auto-exits selection mode.
  - Cancel/close lives in the top bar (the close-X), not the bulk bar.
- **Screens/files:** `lib/screens/requests_screen.dart` (`_BulkActionBar`, `_bulkWaitlist`, `_bulkConfirm`, `_bulkSendWA`, `_bulkPromote`, `_bulkDecline`)

### UC-02REQUESTCAPTURE-12: Admin adds a request manually (direct-add for an off-app customer)
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** Selected tour is open (`acceptsBookings` true).
- **Steps:**
  1. On Requests, tap the **person-add** top-bar action.
  2. In the Add-request sheet, optionally **Pick from contacts** or type a name (autocomplete from saved contacts) + phone + seat counts.
  3. Tap **Save**.
- **Expected:**
  - A new `Passenger` is built from the shared form and persisted via `TourController.addPassenger` (the single server-write chokepoint).
  - The customer is remembered in the admin directory (`rememberContact`) for future autocomplete.
  - Success toast `requests.snack.added_one`/`added_many`; sheet closes.
  - A first add transitions a `planning` tour to `collecting`.
- **Edge cases:**
  - **Locked/completed tour:** the person-add tap is intercepted before opening the sheet with `errors.bookings_closed`; even if reached, `addPassenger` re-guards on `acceptsBookings` (unless `overrideLock` — the return-leg escape hatch).
  - **Save throws:** error toast `requests.snack.add_error`.
  - Contact picker handles **permission denied** (`booking_form.contacts_denied`) and empty/loading states.
- **Screens/files:** `lib/screens/requests_screen.dart` (`_AddRequestForm`, `_openAddRequest`), `lib/controllers/tour_controller.dart` (`addPassenger`), `lib/widgets/booking_capture_form.dart` (contact picker)

### UC-02REQUESTCAPTURE-13: Admin edits an existing request (seat counts / legs / note), auto-releasing over-assigned seats
- **Actor:** admin
- **Phase:** Phase 3 (and after partial assignment)
- **Preconditions:** A passenger card exists; some may already have seats assigned.
- **Steps:**
  1. From a card's overflow menu choose **Edit request**.
  2. The Edit sheet opens pre-filled from the passenger's request lines (each line lands on its stored leg tab); phone is **locked**.
  3. Reduce a seat count below the number already assigned; tap **Save**.
- **Expected:**
  - Non-sofa lines (e.g. Seater) the form doesn't show are **preserved** and merged back, so editing sofa counts never silently drops them.
  - If the new requested total is fewer than currently assigned seats, the excess seats are **auto-released** (trailing assignments trimmed); success toast plus an `edit_request.auto_released[_many]` notice.
  - Persisted via `TourController.updatePassenger`.
- **Edge cases:**
  - **Save throws:** `edit_request.snack_error`.
  - Phone cannot be changed (identity-key guard, `lockPhone: true`).
  - Already-assigned count is shown as an `N / total` hint at the top of the sheet.
- **Screens/files:** `lib/widgets/edit_request_sheet.dart`, `lib/widgets/booking_capture_form.dart` (`BookingCaptureInitial.fromLines`), `lib/controllers/tour_controller.dart` (`updatePassenger`)

### UC-02REQUESTCAPTURE-14: Admin declines (deletes) a request
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** A request card in any non-assigned state (decline appears in New/Waitlist/Confirmed menus).
- **Steps:**
  1. Open a card's overflow menu and choose **Decline request**.
  2. Confirm the destructive dialog.
- **Expected:**
  - A `UgamDialog.confirm` (destructive, close icon) gates the action; on confirm, `removePassenger` deletes the passenger.
  - Success toast `requests.snack.declined_*`; the card disappears from the list.
  - The customer's My-Requests entry will flip to **Cancelled** on its next refresh (server lookup returns empty → `markCancelled`).
- **Edge cases:**
  - Cancelling the dialog is a no-op.
  - Assigned cards expose **Unassign all** instead of Decline in their menu (decline is for pre-assignment states).
- **Screens/files:** `lib/screens/requests_screen.dart` (`_confirmDecline`), `lib/controllers/tour_controller.dart` (`removePassenger`), `lib/services/customer_requests_store.dart` (`markCancelled`)

### UC-02REQUESTCAPTURE-15: Admin sets/clears priority and assigns a request to a cross-booking group from the card
- **Actor:** admin
- **Phase:** Phase 3
- **Preconditions:** A request card.
- **Steps:**
  1. Tap the **star** circle on a card to toggle priority.
  2. Confirm the priority alert when turning it ON.
  3. From the overflow menu choose **Add to group / Change group**.
- **Expected:**
  - Turning priority ON shows `priority.alert_*` and (per its contract) confirms first; `setPassengerPriority` flips `priorityStatus` to approved; a warm **PRIORITY** chip appears. Turning OFF is a direct toggle.
  - Group assignment opens `AssignGroupSheet` (group CREATION still lives in the Groups & Priority manager — no duplicated logic); the card shows a group dot + label badge.
- **Edge cases:**
  - Priority is **requested by customer, approved by agent** — age never auto-derives priority.
  - Only `approved` priority influences the seating engine (front/sofa first).
- **Screens/files:** `lib/screens/requests_screen.dart` (`_togglePriority`, `groupItem`, `_PriorityBadge`, `_GroupBadge`), `lib/models/priority_status.dart`, `lib/controllers/tour_controller.dart` (`setPassengerPriority`)

### UC-02REQUESTCAPTURE-16: Admin reads the capacity banner while triaging (demand vs engine-truth free seats)
- **Actor:** admin
- **Phase:** Phase 3 / 4 (Tally)
- **Preconditions:** Tour with active requests; may or may not have a bus.
- **Steps:**
  1. On Requests, observe the collapsed capacity banner glance line.
  2. Tap to expand it.
  3. (If present) tap the "needs your decision" line.
- **Expected:**
  - **No bus yet:** banner tints warm and shows per-leg demand `Need {go} going · {ret} returning` (whole seats per leg, never a fractional `1.5`).
  - **With a bus:** shows the two-leg `UgamCapacityMeter` (placed/cap/free as whole seats per leg, never a percentage), driven by `computeTourCapacity` (engine-truth free, not naive capacity−demand).
  - Expanded view adds an opposite-leg reclaim hint (`reclaim_go`/`reclaim_ret`) and a free-by-type pill row when the bus mixes seat types.
  - A **needs-your-decision** count (riders the engine can't auto-seat) routes to the seating-exceptions screen.
- **Edge cases:**
  - Over-demand for a seat type surfaces as `needsDecision`, never a phantom negative free count.
  - Waitlisted and `journeyDone` riders are excluded from demand.
- **Screens/files:** `lib/screens/requests_screen.dart` (`_CapacityBanner`, `_TypeFreePill`), `lib/utils/tour_capacity.dart` (`computeTourCapacity`), `lib/design/components/ugam_capacity_meter.dart`

### UC-02REQUESTCAPTURE-17: Language switch — all request-capture strings render in en/gu/hi
- **Actor:** customer or admin
- **Phase:** Phase 3 (cross-cutting)
- **Preconditions:** App supports en/gu/hi via easy_localization; a request flow open.
- **Steps:**
  1. With the booking form / My Requests / Requests screen visible, switch app language to Gujarati, then Hindi, then back to English.
  2. Trigger toasts (submit success, too-fast, duplicate warning, edit-blocked) in each language.
- **Expected:**
  - All visible labels, chips, empty states, dialogs, and toasts resolve via `tr(...)` keys with no missing-key fallbacks.
  - Verified present in all three files (`assets/translations/{en,gu,hi}.json`): `customer_booking.*` (incl. `err_bookings_closed`, `err_too_fast`, `warn_duplicate_*`, `success_sent_wa`, `success_saved_wa_failed`, `success_sent_no_wa`, `warn_edit_blocked`, `success_updated_wa`), `customer_my_requests.*`, `customer_tour_list.*`, `requests.*`, `booking_form.*`, `edit_request.*`, `errors.bookings_closed`.
- **Edge cases:**
  - **String-parity rule:** any new user-facing string added to this flow MUST exist in all three JSON files or it falls back/breaks in gu/hi.
  - Pluralised keys (e.g. `requests.chip.seats_unit`, `cta_seat_count[_one]`) need their plural forms localized too.
- **Screens/files:** `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json`, all screens above

### UC-02REQUESTCAPTURE-18: Customer searches the tour list and handles empty/error/offline states
- **Actor:** customer
- **Phase:** Phase 2→3 boundary (finding a tour to request)
- **Preconditions:** Customer app on the tour list.
- **Steps:**
  1. Tap the search circle; type a query that matches a tour title/from/to city.
  2. Clear it and type a query that matches nothing.
  3. Pull-to-refresh while offline / with a backend error.
- **Expected:**
  - Search filters by title/from-city/to-city (case-insensitive); results split into **Upcoming** (≤30 days) and **Later** groups, each date-sorted.
  - No matches → `customer_tour_list.no_matches_*` with the query echoed.
  - No visible tours at all → `customer_tour_list.empty_title` + pull-to-refresh hint.
  - Load error with empty cache → `cloud_off` error state with a **Retry** CTA (`tourCtrl.refreshTours`).
  - The My-Requests top-bar badge shows the device-local request count (capped "9+").
- **Edge cases:**
  - Only **public, non-completed** tours whose end date (returnDate ?? departureDate) hasn't passed are listed.
  - Long-press on the "Explore" title is a hidden admin login entry point (customer-invisible).
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart` (`_visibleTours`, `_group`, `_TopBar`, `_refreshable`)
