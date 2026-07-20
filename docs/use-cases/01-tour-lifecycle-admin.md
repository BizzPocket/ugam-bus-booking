# Use Cases — Tour creation, edit, broadcast/notify, lock (admin)

**Area:** Tour lifecycle (admin) — Phases 1 (Create Tour), 2 (Broadcast/Notify), 8 (Lock & Notify)
**Actors:** ADMIN (tour agent / owner) only. Customers and handlers do not create, edit, broadcast, or lock tours.
**Single lock gate:** `Tour.acceptsBookings` (delegates to `TourStatus.acceptsBookings` → `false` once `locked` or `completed`).

Status machine (`lib/models/tour_status.dart`):
`planning → collecting → busBooked → assigning → locked → completed`.
- `planning → collecting` is AUTO (first passenger added).
- `collecting → busBooked` is AUTO (first bus added — verify in bus area).
- `busBooked → assigning` is AUTO (first real seat placement).
- `assigning → locked` is MANUAL (lock action; requires all-assigned + handler + ≥1 passenger).
- `locked → completed` is MANUAL ("Mark completed") OR auto-archive (>1 day past end).

Key files referenced throughout:
`lib/screens/create_tour_screen.dart`, `edit_tour_screen.dart`, `tours_screen.dart`, `tour_detail_screen.dart`, `tour_overview_screen.dart`, `notify_screen.dart`, `whatsapp_settings_screen.dart`, `dashboard_screen.dart`, `lib/controllers/tour_controller.dart`, `lib/models/tour.dart`, `tour_status.dart`, `trip_type.dart`, `lib/services/whatsapp_service.dart`, `lib/design/components/ugam_input.dart`.

> **Cross-cutting localization note:** Every user-facing string below is rendered via `tr('...')` and MUST exist in all three locale files (`assets/translations/en.json`, `gu.json`, `hi.json`). Namespaces touched here: `create_tour.*`, `edit_tour.*`, `tours.*`, `tour_detail.*`, `notify.*`, `bus_message.*`, `dashboard.*`, `enums.tour_status.*`, `settings_pages.whatsapp.*`, `errors.*`.

---

### UC-01TOURLIFECYCLEADMIN-1: Create a tour (happy path) and auto-open WhatsApp broadcast
- **Actor:** admin
- **Phase:** 1 (Create) → 2 (Broadcast)
- **Preconditions:** Admin is signed in (an authenticated admin session exists — `AuthController.currentAdmin` non-null). On Tours tab or Dashboard.
- **Steps:**
  1. Tap the circular "+" in the Tours app bar (`tours.create`) — or Dashboard quick action "Create" (`dashboard.qa_create`).
  2. Type a tour name, a From city, and a To city. Observe the live preview card update (~90ms debounce) and the route monogram (e.g. "S→M").
  3. Tap the start-date field and pick a departure date; optionally pick a departure time.
  4. Optionally pick a return date/time, a description (max 300), a broadcast message (max 600), and a broadcast image.
  5. Tap "Create & Broadcast" (`create_tour.action.create_broadcast`).
- **Expected:**
  - A success toast `create_tour.snackbar.created_title` / `created_body` (with `{route}`) appears.
  - App navigates (Cupertino transition, `Get.off`) to the new tour's `TourDetailScreen`.
  - The optimistic add makes the tour appear in the list instantly; status is `planning` until a passenger is added.
  - Immediately after navigation, WhatsApp's own broadcast/group picker opens with the announcement pre-filled AND the text copied to clipboard (`WhatsAppService.broadcastTour`, fire-and-forget via `unawaited`). The CTA label flips to `create_tour.action.creating` while saving.
  - `tour.pricePerSeat` is 0 at creation (price is set per-bus later).
- **Edge cases:**
  - If a broadcast image is attached but its upload fails, the tour is STILL created (image dropped) and a warning toast `create_tour.broadcast_image_upload_failed` shows.
  - If WhatsApp isn't installed, `broadcastTour` returns false silently here (no toast on this screen — message is still on the clipboard); the agent already left to the detail screen.
  - If the persist write fails, an error toast `create_tour.snackbar.error` shows and `_write` snaps the optimistic phantom back out.
- **Screens/files:** `lib/screens/create_tour_screen.dart`, `lib/controllers/tour_controller.dart::createTour`, `lib/services/whatsapp_service.dart::broadcastTour`, `lib/models/tour.dart`.

---

### UC-01TOURLIFECYCLEADMIN-2: Create-tour blocks only on a missing departure date (title/from/to are NOT enforced)
- **Actor:** admin
- **Phase:** 1 (Create)
- **Preconditions:** On the Create Tour screen, signed in.
- **Steps:**
  1. Leave the tour name, From, and To fields EMPTY.
  2. Do NOT pick a departure date.
  3. Tap "Create & Broadcast".
  4. Now pick only a departure date and tap "Create & Broadcast" again (still empty name/route).
- **Expected:**
  - Step 3: an inline date error `create_tour.validation.select_start_date` appears under the date row; no tour is created.
  - Step 4: the tour IS created with an empty title and an empty "→ " route. (`UgamInput` is a plain `TextField`, not a `TextFormField`, so `_formKey.currentState!.validate()` enforces nothing — the only hard gate is `_departureDate == null`.)
  - The preview card shows fallbacks while empty: `create_tour.preview.untitled`, hint cities, `create_tour.preview.pick_date`.
- **Edge cases:**
  - This is a real gap worth flagging: an "untitled, route-less" tour can be persisted; downstream lists render it with empty title and a bare "→".
  - Date picker `firstDate` is today, so past departure dates cannot be chosen on create.
  - Return date picker's `firstDate` is the departure date (or now) — a return before departure cannot be picked.
- **Screens/files:** `lib/screens/create_tour_screen.dart::_submit`, `lib/design/components/ugam_input.dart` (no validator), `lib/controllers/tour_controller.dart::createTour`.

---

### UC-01TOURLIFECYCLEADMIN-3: Create-tour refused without an admin session
- **Actor:** admin (unauthenticated / session lost)
- **Phase:** 1 (Create)
- **Preconditions:** No authenticated admin session (`AuthController.currentAdmin.value == null`) — e.g. anonymous viewer, or session dropped.
- **Steps:**
  1. Reach the Create Tour screen and fill valid fields + a date.
  2. Tap "Create & Broadcast".
- **Expected:**
  - An error toast `errors.sign_in_to_create_tour` (title `errors.sign_in_required`) appears.
  - `createTour` throws `StateError` and NO row is queued (guard prevents a null `owner_id` insert that RLS would reject on every retry).
  - The screen's catch shows `create_tour.snackbar.error`; `_saving` resets.
- **Edge cases:**
  - RLS on `tours` requires `owner_id = auth.uid()`; this guard is the client-side mirror so the insert is never even attempted.
- **Screens/files:** `lib/controllers/tour_controller.dart::createTour`, `lib/screens/create_tour_screen.dart`.

---

### UC-01TOURLIFECYCLEADMIN-4: Edit an existing tour (dirty-state, cancel-changes, save)
- **Actor:** admin
- **Phase:** 1 (Create/Edit) — applies in any non-terminal status
- **Preconditions:** A tour exists; admin opens it.
- **Steps:**
  1. From `TourDetailScreen`, open the hero overflow ("⋮") → "Edit tour" (`tour_detail.edit_tour`) — or use the Buses/edit affordances that route to `EditTourScreen`.
  2. Change the title (and/or route, dates, price, description).
  3. Observe the sticky bar now shows a "Cancel changes" button (`edit_tour.cancel_changes`) alongside "Save changes".
  4. Tap "Cancel changes" to revert all fields to originals; then change again and tap "Save changes" (`edit_tour.btn_save_changes`).
- **Expected:**
  - "Cancel changes" only appears while `_isDirty` is true (any field differs from its captured original).
  - Cancel restores every field (title/from/to/price/desc/dates/times) to the values captured at `initState`.
  - Save persists via `editTour`, shows `edit_tour.snack_updated`, and pops back. The CTA shows `edit_tour.btn_saving` while saving.
  - Editing preserves status, handler, buses, passengers (status is carried through unchanged).
- **Edge cases:**
  - If departure date is cleared/missing on save, inline error `edit_tour.error_select_start_date` blocks the save.
  - Edit screen's date picker allows BACK-dated departures (`firstDate` = now − 365 days), unlike create — a deliberate difference for fixing a mis-entered past tour.
  - Changing the departure date to AFTER an existing return date auto-clears the return date/time.
  - Save failure shows `edit_tour.snack_save_failed` and re-enables the form.
  - Edit screen exposes a price field; note tour-level `pricePerSeat` is otherwise 0 from create and pricing is normally per-bus.
- **Screens/files:** `lib/screens/edit_tour_screen.dart`, `lib/controllers/tour_controller.dart::editTour`.

---

### UC-01TOURLIFECYCLEADMIN-5: Delete a tour (with cascade warning + memory capture)
- **Actor:** admin
- **Phase:** any
- **Preconditions:** A tour exists (optionally with passengers/buses).
- **Steps:**
  1. From `EditTourScreen` tap the trash app-bar action, OR from `TourDetailScreen` hero overflow → "Delete tour", OR Tours-list swipe is N/A (delete lives in detail/edit).
  2. Read the confirm dialog; it lists the tour title and a `· N passengers · M buses` detail line.
  3. Confirm delete.
- **Expected:**
  - Destructive confirm dialog `edit_tour.delete.title` / `delete.message` (or `tour_detail.delete_confirm_*`) with a `delete` confirm label.
  - On confirm: returning-customer memory (priority + companions) is snapshotted first (best-effort) via `CustomerMemoryController.captureFromTour`, then the tour is optimistically removed and deleted server-side.
  - Success toast (`edit_tour.delete.deleted` with `{title}`, or `tour_detail.snack_tour_deleted`) and navigation back to root (`Get.until(isFirst)` from edit, `AppNav.pop` from detail).
- **Edge cases:**
  - Buses are described as "unlinked" (`edit_tour.delete.buses_unlinked_*`), not destroyed wording, in the dialog detail.
  - Delete failure: `deleteTour` surfaces its own `errors.delete_tour` toast; the detail-screen path swallows the re-throw.
  - Singular/plural keys must exist for both passengers and buses (`*_one` / `*_other`).
- **Screens/files:** `lib/screens/edit_tour_screen.dart::_confirmAndDelete`, `lib/screens/tour_detail_screen.dart::_confirmDelete`, `lib/controllers/tour_controller.dart::deleteTour`.

---

### UC-01TOURLIFECYCLEADMIN-6: Broadcast a tour to WhatsApp from the tour workspace (Phase 2)
- **Actor:** admin
- **Phase:** 2 (Broadcast / collect requests)
- **Preconditions:** A tour exists and is open on `TourDetailScreen` (Overview tab).
- **Steps:**
  1. Scroll to the "Broadcast this tour" card (`tour_detail.broadcast_this_tour`).
  2. Tap the tonal "Send broadcast on WhatsApp" button (`tour_detail.send_broadcast_whatsapp`).
  3. Alternatively tap the small copy icon (`tour_detail.copy_broadcast_message`).
- **Expected:**
  - Send: WhatsApp's broadcast/group picker opens with the announcement pre-filled; on success toast `tour_detail.snack_broadcast_opened`. The button shows `tour_detail.sending_broadcast` while in flight.
  - If WhatsApp is unavailable: warning toast `tour_detail.snack_broadcast_copied_only` (title `whatsapp_unavailable_title`) — message is still on the clipboard.
  - Copy: toast `tour_detail.snack_broadcast_copied`, light haptic.
  - The exact same `_TourBroadcast.send` path also drives the empty-Passengers-tab "Share to collect riders" CTA (`tour_detail.share_to_collect_riders`).
- **Edge cases:**
  - Send error path shows `tour_detail.snack_broadcast_error` (with `{error}`) / title `send_failed_title`.
  - Broadcast is available regardless of status (even on a locked/completed tour the card is present); it's a free deep-link, not the Cloud API.
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_BroadcastCard`, `_TourBroadcast`, `_PassengersEmptyState`), `lib/services/whatsapp_service.dart::broadcastTour` / `copyAnnouncementToClipboard`.

---

### UC-01TOURLIFECYCLEADMIN-7: Lock gate checklist blocks lock until all three conditions are met (Phase 8)
- **Actor:** admin
- **Phase:** 8 (Lock & Notify) — pre-lock gate
- **Preconditions:** Tour is NOT yet locked; opened on `NotifyScreen` (via Tours-row swipe "Lock & notify", tour Overview "Lock/Send" tool, or Dashboard "ready to lock" attention → Notify tab).
- **Steps:**
  1. Observe the lock-gate checklist card with three checks: at least one passenger (`notify.check_has_passengers`), all passengers fully assigned (`notify.check_all_assigned`), a handler picked (`notify.check_has_handler`).
  2. With one or more unmet, look at the sticky bottom CTA.
- **Expected:**
  - The sticky CTA is DISABLED and labeled `notify.lock_btn_disabled` ("Finish setup to lock") while any condition is unmet.
  - A reason line above the CTA names the FIRST missing condition: `notify.lock_reason_no_passengers` / `lock_reason_unassigned` / `lock_reason_no_handler` (priority order: passengers → assigned → handler).
  - Each met check flips to a green check icon; unmet checks show an empty circle.
  - `canLock = allSeatsAssigned && handlerId != null && passengers.isNotEmpty`.
- **Edge cases:**
  - `allSeatsAssigned` ignores `journeyDone` (GO-finished) riders, so a completed-GO leg never blocks lock.
  - `allSeatsAssigned` requires at least one active rider AND every active rider fully assigned — an empty active roster is NOT "all assigned".
  - Each reason string and the two CTA labels must exist in en/gu/hi.
- **Screens/files:** `lib/screens/notify_screen.dart` (`_buildLockGate`, `_LockStickyCTA`, `_Check`), `lib/models/tour.dart::allSeatsAssigned`.

---

### UC-01TOURLIFECYCLEADMIN-8: Lock the tour and auto-send seat allocations (Phase 8 happy path)
- **Actor:** admin
- **Phase:** 8 (Lock & Notify)
- **Preconditions:** All three lock-gate checks pass (≥1 passenger, all active assigned, handler set). On `NotifyScreen`.
- **Steps:**
  1. Tap the enabled "Lock Tour" CTA (`notify.lock_btn`).
  2. Confirm the lock dialog (`notify.lock_dialog_title` / `lock_dialog_body` with `{count}`, confirm `notify.lock_dialog_lock`).
  3. After lock, the seat-allocation send dialog appears (`notify.alloc_dialog_title` / `alloc_dialog_body` with `{count}`); confirm send (`notify.alloc_dialog_send`).
- **Expected:**
  - Tour status flips to `locked` (`TourController.lockTour`).
  - `Tour.acceptsBookings` becomes false — NEW requests are blocked everywhere (see UC-9).
  - The screen switches from lock-gate mode to TRACKER mode (hero summary card, progress card, filter pills, passenger list, "Send to all pending" CTA).
  - A non-dismissible progress dialog shows "preparing X of N" (`notify.alloc_preparing`) then "sending now" (`notify.alloc_sending_now`); the `seat_allotment` Cloud API template (highlighted seat-chart image + boarding/departure/handler body) goes to each seated passenger.
  - On full success: toast `notify.alloc_sent_title` / `alloc_sent_body` (`{count}`); successfully-notified riders are marked sent (status dot flips to `notify.row_sent`), and the pending count + "Send all pending" CTA update/hide.
  - No green "locked" toast — the locked status card + sticky CTA convey the state (intentional, per code comment).
- **Edge cases:**
  - If no passenger actually has seats at send time (stale snapshot), error toast `notify.no_seated_passengers` and bail. The send re-fetches the FRESHEST tour to avoid this.
  - Partial/total send failure → summary dialog (`notify.alloc_partial_*` / `alloc_failed_*`) with a one-tap RETRY (`notify.alloc_retry` with `{count}`) that re-sends only the failed recipients; the first Meta error reason (e.g. `(#131030)…`) is appended.
  - Recipients not on Meta's allowed list fail per-recipient (test number sandbox).
- **Screens/files:** `lib/screens/notify_screen.dart` (`_lockTour`, `_sendSeatAllocations`, `_dispatchSeatAllocations`, `_SendProgressDialog`), `lib/controllers/tour_controller.dart::lockTour`, `lib/services/whatsapp_outbound.dart`.

---

### UC-01TOURLIFECYCLEADMIN-9: Locked tour closes bookings everywhere (single lock gate)
- **Actor:** admin / handler / customer
- **Phase:** 8 (post-lock)
- **Preconditions:** A tour is `locked`.
- **Steps:**
  1. As admin/handler, attempt to add a new request/passenger from any "Add request" surface.
  2. As customer, attempt to book the locked tour from the customer list/form.
- **Expected:**
  - `addPassenger` rejects at the single chokepoint with error toast `errors.bookings_closed` (because `existing.acceptsBookings == false`), and no passenger row is written.
  - Every book/add-request entry point gates on the same `Tour.acceptsBookings` → `TourStatus.acceptsBookings` rule, so the block is consistent across customer + admin + handler surfaces.
- **Edge cases:**
  - The deliberate escape hatch: `addPassenger(..., overrideLock: true)` is allowed ONLY for booking a NEW return-only ticket into a freed seat during the return phase (skips the `acceptsBookings` gate, nothing else).
  - A `completed` tour is also closed (same rule).
  - Note: the gate is enforced in `addPassenger`; other passenger writes (edit/seat/payment) are not blocked by it.
- **Screens/files:** `lib/controllers/tour_controller.dart::addPassenger`, `lib/models/tour.dart::acceptsBookings`, `lib/models/tour_status.dart::acceptsBookings`.

---

### UC-01TOURLIFECYCLEADMIN-10: Post-lock notification tracker — re-send to one rider, filter, reset sent
- **Actor:** admin
- **Phase:** 8 (post-lock tracking)
- **Preconditions:** Tour is `locked` with seated passengers; on `NotifyScreen` tracker.
- **Steps:**
  1. Use the filter pills All / Pending / Notified (`notify.filter_all` / `filter_pending` / `filter_notified`) with live counts.
  2. Tap a single rider's chat button to re-send their seat allocation (`_dispatchSeatAllocations` scoped to one id).
  3. Tap "Send to all pending" (`notify.send_all_pending`, trailing count) to batch-send the remaining.
  4. Tap the app-bar refresh ("reset sent", `notify.reset_sent`) to clear this session's sent markers.
- **Expected:**
  - The progress card shows `sent / total` and "All notified" (`notify.progress_all_notified`) when done; bar turns green.
  - Sent markers (`_sentIds`) are SESSION-only (reset on app restart) — they track who was messaged this run, not a persisted column.
  - "Send to all pending" CTA hides when pending hits 0.
  - Per-rider re-send fires the SAME `seat_allotment` template, not a generic deep-link.
  - Search (collapsible, app-bar) filters by name/phone within the current filter.
- **Edge cases:**
  - Empty tracker (locked but nobody seated): `notify.empty_no_seats` / `notify.assign_first`.
  - No matches under search: `notify.no_matches` (with `{query}`) / `notify.nothing_here`.
  - Reset-sent only appears when `_sentIds` is non-empty.
- **Screens/files:** `lib/screens/notify_screen.dart` (`_buildTracker`, `_NotifyRow`, `_ProgressCard`).

---

### UC-01TOURLIFECYCLEADMIN-11: Per-bus free-text announcement after lock (F4)
- **Actor:** admin
- **Phase:** 8 (post-lock)
- **Preconditions:** Locked tour with at least one bus and seated riders; on `NotifyScreen` tracker.
- **Steps:**
  1. Tap the "Message this bus" card (`bus_message.card_title`).
  2. In the composer sheet, pick a bus (auto-selected when there's only one — selector hidden) and type a message.
  3. Tap Send (`bus_message.send_btn`).
- **Expected:**
  - The recipient count chip (`bus_message.recipient_count` with `{count}`) reflects riders seated on the chosen bus.
  - Send routes free text to every seated passenger on that bus via the Cloud API; success `bus_message.sent_title` / `sent_body` (`{count}`).
- **Edge cases:**
  - Empty text → `bus_message.empty_text` error, no send.
  - Bus with 0 recipients → Send disabled; if attempted, `bus_message.no_recipients`.
  - Partial send → `bus_message.partial_*` warning with first error; total failure → `bus_message.failed_*`.
  - All `bus_message.*` strings must exist in 3 languages.
- **Screens/files:** `lib/screens/notify_screen.dart` (`_BusMessageCard`, `_BusMessageComposer`, `_openBusMessageComposer`), `lib/services/whatsapp_outbound.dart::sendBusMessage`.

---

### UC-01TOURLIFECYCLEADMIN-12: Mark a locked tour completed (close-out)
- **Actor:** admin
- **Phase:** 8 → terminal
- **Preconditions:** Tour is `locked` (and, if it has only round-trip/return riders, NOT in an unresolved return phase — see UC-15).
- **Steps:**
  1. On `TourDetailScreen` Overview, the Next-Action card shows "Mark completed" (`tour_detail.action_complete_*`).
  2. Tap it; confirm the dialog (`tour_detail.complete_confirm_*` with `{title}`).
- **Expected:**
  - `completeTour` freezes the GO and RETURN seat snapshots (best-effort) then flips status to `completed`.
  - The tour drops out of active lists/Notify (Notify only lists non-completed tours) and stops appearing in Dashboard attention.
  - Tours-list shows it under "Past" (only when searching) with a neutral status dot; its Seats tool now opens the frozen `PastTourSeatHistoryScreen` instead of the live editor.
- **Edge cases:**
  - Auto-archive: on app load, any non-completed tour whose `(returnDate ?? departureDate)+1 day` is past is auto-completed (soft archive, never hard-deleted) — admin-only, best-effort per tour.
  - A `completed` tour still accepts no new bookings and is fully viewable (chart/money/passengers intact).
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `_runKind::markCompleted`), `lib/controllers/tour_controller.dart::completeTour`, `_archiveExpiredTours`.

---

### UC-01TOURLIFECYCLEADMIN-13: Status-driven next-action card stays in lock-step across the lifecycle
- **Actor:** admin
- **Phase:** 1–8 (whole lifecycle, read on Overview)
- **Preconditions:** A tour at any stage; open `TourDetailScreen` Overview.
- **Steps:**
  1. Walk a tour through stages and re-read the Next-Action card each time: no bus → "Add bus"; bus + pending seats → "Assign seats"; all assigned + no handler → "Pick handler"; all assigned + handler + not locked → "Lock & notify"; locked w/ outbound-only active → "Complete GO leg"; return phase → "Add return ticket" (+ secondary "Mark completed"); locked → "Mark completed"; else "All set / done".
- **Expected:**
  - The card title/subtitle/icon/tone come from `_nextActionFor(tour)` and the card is tappable, firing the SAME `_runKind` as the relevant sticky CTA.
  - The lower "Tour actions" grid (Requests / Seats / Money + More: Buses / Groups / Lock-Send) routes to the same destinations; the Lock/Send row highlights green and the "More tools" expander opens by default when ready-to-lock or locked.
  - Tours-list rows mirror this with a swipe-to-run "next step" eyebrow (`tours.action.add_bus` / `seats.title` / `tours.action.pick_handler` / `tours.action.lock_notify`); locked/completed rows have NO swipe action.
- **Edge cases:**
  - "Assign seats" subtitle uses ACTIVE-only totals so a finished GO rider neither inflates the fraction nor resurfaces as pending.
  - Tours-list row capacity badge `assigned/capacity` uses leg-aware `occupiedBerths` (never the double-counted total).
  - Each next-action title/subtitle/CTA string set must exist in 3 languages (one/other plural variants too).
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `_NextActionCard`, `_ActionsGrid`, `_StickyAction`), `lib/screens/tours_screen.dart` (`_actionFor`, `_runRowAction`).

---

### UC-01TOURLIFECYCLEADMIN-14: Tours list — empty, search, no-match, and error states
- **Actor:** admin
- **Phase:** any (browse)
- **Preconditions:** On the Tours tab.
- **Steps:**
  1. With no tours, observe the empty state.
  2. With tours present, tap the search icon, type a query matching nothing, then a query matching a tour.
  3. Simulate a load failure with no cache (offline cold start).
- **Expected:**
  - No tours → `tours.empty.title` / `empty.subtitle` with a "Create" CTA (`tours.empty.cta`).
  - Tours grouped by time: "This week" / "Next 30 days" / "Later" (`tours.group.*`); "Past" group ONLY appears while searching.
  - No-match query → `tours.no_matches_title` / `no_matches_body` (with `{query}`).
  - Load error with empty cache → `UgamEmpty` (cloud-off) showing `errorMessage` (`errors.load_tours`) and a Retry CTA.
- **Edge cases:**
  - Search matches title OR fromCity OR toCity (case-insensitive).
  - A tour is "Past" once its end day (returnDate ?? departureDate) is before today — multi-day trips stay active until they actually end.
  - Refresh failure with a non-empty list keeps the list and warns (`errors.refresh_showing_saved` / `refresh_showing_cached`), never blanks it.
  - Pull-to-refresh invalidates the 2-minute cache.
- **Screens/files:** `lib/screens/tours_screen.dart`, `lib/controllers/tour_controller.dart::_loadTours` / `refreshTours`.

---

### UC-01TOURLIFECYCLEADMIN-15: Return-leg phase after GO completion (locked tour, mixed legs)
- **Actor:** admin
- **Phase:** post-lock RETURN-LEG track
- **Preconditions:** Tour is `locked`; it has outbound-only and/or round-trip riders; GO leg about to be completed.
- **Steps:**
  1. While locked with outbound-only active riders, the Next-Action card shows "Complete GO leg" (`tour_detail.action_complete_go_*`). Tap and confirm (`tour_detail.complete_go_confirm_*` with `{count}`).
  2. After GO is done, re-open Overview: Next-Action becomes "Add return ticket" (`tour_detail.action_return_leg_*` showing `{free}` free return seats) with secondary "Mark completed".
  3. Tap "Add return ticket" to book a return-only rider into a freed seat.
- **Expected:**
  - `completeOutboundLeg` frees outbound-only riders' seats and flags them `journeyDone`; success toast `tour_detail.complete_go_done` (`{count}`). The GO chart is frozen first.
  - `journeyDone` riders are excluded from `pendingSeatsToAssign` so completing GO never re-shows "allocate N".
  - `isReturnPhase = locked && goLegCompleted` drives the return next-action; freed seats become resellable as return tickets.
  - Adding a return ticket uses `overrideLock: true` to bypass the locked booking gate (the only sanctioned bypass).
- **Edge cases:**
  - Cancel a return seat: a round-trip rider is demoted to outbound-only + `journeyDone` (record kept, berth freed); a return-only rider who never rode is removed outright (`cancelReturnSeat`).
  - One-way (no return) tours skip the return phase entirely and just offer "Mark completed".
  - `free` count comes from `computeTourCapacity(tour).returnSeatsFree`.
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `_runKind::completeGoLeg` / `addReturnTicket`), `lib/controllers/tour_controller.dart::completeOutboundLeg` / `cancelReturnSeat`, `lib/models/tour.dart::isReturnPhase` / `goLegCompleted`, `lib/models/trip_type.dart`.

---

### UC-01TOURLIFECYCLEADMIN-16: WhatsApp handoff settings (number + signature) used by broadcasts
- **Actor:** admin
- **Phase:** supporting (affects Phase 2/8 messaging)
- **Preconditions:** Signed-in admin; Settings → WhatsApp.
- **Steps:**
  1. Open `WhatsAppSettingsScreen` (`settings.whatsapp_title`).
  2. Edit the WhatsApp number customers are handed off to and the custom signature appended to announcements.
  3. Tap Save (`settings_pages.save`).
- **Expected:**
  - Save persists to the admin profile (`AuthController.saveAdmin` — `whatsappNumber`, `waHandoffTemplate`); success toast `settings_pages.saved`, then pops.
  - The number hint shows the login phone as the fallback when blank (`settings_pages.whatsapp.number_hint` with `{phone}`).
- **Edge cases:**
  - A non-blank number that isn't exactly 10 digits → error `settings_pages.whatsapp.number_invalid`, no save.
  - No admin in session → `settings_pages.no_admin`.
  - Save failure → `settings_pages.save_error`.
  - Signature max length 240; number/signature strings must exist in 3 languages.
- **Screens/files:** `lib/screens/whatsapp_settings_screen.dart`, `lib/controllers/auth_controller.dart::saveAdmin`.

---

### UC-01TOURLIFECYCLEADMIN-17: Language switch re-renders all tour-lifecycle strings (en/gu/hi)
- **Actor:** admin
- **Phase:** cross-cutting
- **Preconditions:** App running; at least one tour exists.
- **Steps:**
  1. Switch app language (Settings) between English, Gujarati, Hindi.
  2. Revisit: Tours list (groups/status dots), Create Tour, Edit Tour, Tour Detail (next-action, tools, broadcast), Notify (lock gate + tracker), status enum labels.
- **Expected:**
  - Every label, hint, toast, dialog, status name (`enums.tour_status.*` displayName + description), and plural form re-renders in the chosen locale with no missing-key fallbacks or raw key strings.
  - Date formatting follows `context.locale.languageCode` (`Formatters.formatDate*`).
- **Edge cases:**
  - Plural keys (`*_one` / `*_other`) and `namedArgs` placeholders (`{count}`, `{route}`, `{n}`, `{query}`, `{free}`, `{title}`, `{phone}`) must be present and consistent across all three files.
  - The status enum `displayName` AND `description` are BOTH shown (list dot vs. hero), so both must be translated.
  - `gu.json` and `hi.json` were confirmed to contain `create_tour` blocks; verify the same parity for `notify.*`, `tour_detail.*`, `bus_message.*` keys named above.
- **Screens/files:** all listed screens; `lib/models/tour_status.dart`, `assets/translations/{en,gu,hi}.json`.

---

## Notable behaviors / gaps flagged for the assembler
- **No real form validation on create/edit.** `UgamInput` is a `TextField`, not a `TextFormField`; the `Form`/`_formKey.validate()` calls do nothing for title/from/to/description. Only `_departureDate == null` blocks submit. A title-less, route-less tour can be persisted (UC-2).
- **Sent-notification state is session-only.** `_sentIds` resets on app restart — there is no persisted "notified" column; the tracker reflects this run only (UC-10).
- **Lock has no green confirmation toast** by design — state is conveyed by the status card + sticky CTA (UC-8).
- **Auto-archive can silently complete tours** more than a day past their end on app load (admin-only, soft, never hard-deletes) — testers should not mistake this for a bug when an old tour leaves the active list (UC-12).
- **Return-phase `overrideLock`** is the only sanctioned bypass of the `acceptsBookings` lock gate (UC-9, UC-15).
- **Create vs. edit date pickers differ:** create forbids past departures; edit allows back-dating up to a year (UC-2, UC-4).
