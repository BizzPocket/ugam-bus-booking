# Use Cases — Tally Demand, Add Bus, Price Modes & Capacity (Phases 4–5, Admin)

Scope: how the tour agent (ADMIN) reads aggregate seat demand, decides how many
buses to book, adds/edits a bus through the 3-step Add-Bus wizard (identity →
capacity/layout → price), chooses a pricing mode, and reads honest leg-aware
capacity meters. All capacity figures route through the single engine helper
`computeTourCapacity` (file `lib/utils/tour_capacity.dart`); a bus's demand load
is `max(GO, RET)` per leg, never the merged sum.

Primary screens/files:
- `lib/screens/manage_buses_screen.dart` — bus list + per-bus meter + add CTA + per-bus menu/handler
- `lib/screens/add_bus_screen.dart` — 3-step add/edit wizard (identity, capacity, price)
- `lib/screens/bus_status_screen.dart` — read-only single-bus chart + tally
- `lib/screens/tour_overview_screen.dart` — Phase-4 demand summary + capacity banner ("what to book")
- `lib/models/bus_details.dart` — `Bus`, `PriceBand`, `berthPriceFor`, `effectiveBands`
- `lib/models/seat_layout.dart` — `BusLayout.generate` (seat engine, back-row toggle)
- `lib/models/bus_type.dart`, `lib/models/seat_type.dart`
- `lib/utils/tour_capacity.dart` — `computeTourCapacity`, `TourCapacity`, `BusCapacity`
- `lib/controllers/tour_controller.dart` — `addBus`, `updateBus`, `removeBus`, `unassignBus`, `setBusHandler`, `removeBusHandler`

> Localization note: every user-facing string in these screens is `tr('ns.key')`
> and MUST exist in all 3 files `assets/translations/{en,gu,hi}.json`. Namespaces
> touched here: `manage_buses.*`, `add_bus.*` (incl. `add_bus.step1/2/3.*`,
> `add_bus.price_mode.*`, `add_bus.band_sheet.*`, `add_bus.bands.*`,
> `add_bus.back_row_toggle.*`, `add_bus.overrides.*`, `add_bus.summary.*`,
> `add_bus.regenerate_*`, `add_bus.resize_*`), `bus_status.*`, `bus_handler.*`,
> `tour_overview.*` (capacity banner + requirements), `enums.bus_type.*`,
> `enums.seat_type.*`, `enums.seat_position.*`.

---

### UC-03BUSMANAGEMENT-1: Read aggregate seat demand to decide how many buses to book
- **Actor:** admin
- **Phase:** 4 (Tally & Book Bus)
- **Preconditions:** Tour exists with at least one captured request; admin is on the Tour Overview screen (`tour_overview_screen.dart`).
- **Steps:**
  1. Open the tour and view the top summary card.
  2. Read the "Bus requirements" / "what to book" section: the per-type unit counts (single sofa, double sofa, seater) and the `total_to_book` total.
  3. Read the seats-placed figure (`totalSeatsAssigned` over `totalBusSeats`) on the same summary card.
  4. Note that a Double Sofa counts as ONE unit (one tile) in the requirements list, not its two berths.
- **Expected:**
  - Requirements chips sum requested `requestLines.qty` per `seatType` across ALL passengers (waitlisted included in the chip counts).
  - `total_to_book` = singles + doubles + seaters (unit count, not berths).
  - Seats-placed reads `0/0` (or hides) when no bus is booked yet (`totalBusSeats == 0`).
  - Tapping "Edit requests" routes to the requests editor.
- **Edge cases:**
  - Zero requests → requirements show all zeros; the agent should not be told to book anything.
  - All requests waitlisted → requirements chips still count them, but `demandBerths` used for the capacity banner excludes held/waitlisted riders.
  - Language switch (en/gu/hi) → `tour_overview.bus_requirements`, `single_sofa`/`double_sofa`/`seater`, `total_to_book` must all be present in 3 files.
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_SummaryCard`), `lib/models/tour.dart` (`totalBusSeats`, `totalSeatsAssigned`), `lib/models/passenger.dart` (`requestLines`).

---

### UC-03BUSMANAGEMENT-2: Capacity banner warns when demand may exceed booked seats (engine-truth shortfall)
- **Actor:** admin
- **Phase:** 4 (Tally & Book Bus)
- **Preconditions:** Tour has requests whose berth demand the engine cannot fully seat, OR a generated plan already overflowed riders to the waitlist.
- **Steps:**
  1. On Tour Overview, observe the warm capacity banner that appears below the summary card.
  2. Read the title/message: either "N overflow" (post-fill, authoritative) or "short" with `demand`/`capacity`/`shortfall` numbers.
  3. Tap "Add a bus" to jump straight into the Add-Bus wizard, OR "Edit requests" / "Review waitlist".
- **Expected:**
  - `shortfall` is sourced from `computeTourCapacity(tour).needsDecision` (engine truth), NOT the raw `demandBerths − total` subtraction — so leg-sharing (two opposite one-way riders reusing one berth) is honored and the banner does not overstate the gap.
  - Banner only shows when `overflowCount > 0` OR `shortfall > 0`.
  - When overflow exists, the secondary action is "Review waitlist" → exceptions route; otherwise "Edit requests".
  - The banner and the per-bus meters never disagree (same `computeTourCapacity` plan).
- **Edge cases:**
  - Demand exactly equals capacity with all riders seatable → no banner.
  - A stranger-only Double Sofa half / leg-blocked rider that cannot be auto-seated surfaces as `needsDecision`, NOT as a phantom negative number.
  - No bus booked yet but requests exist → banner can still prompt "Add a bus".
  - All overflow riders already held on waitlist → `_decisionFilter` drops them, so the shortfall does not double-count held riders.
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_CapacityBanner`), `lib/utils/tour_capacity.dart` (`computeTourCapacity`, `_decisionFilter`).

---

### UC-03BUSMANAGEMENT-3: Add a new bus — Step 1 Identity
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** Admin opens `AddBusScreen(tourId: ...)` with no `existing` (add mode), e.g. via the Manage Buses sticky CTA or the capacity banner "Add a bus".
- **Steps:**
  1. Observe the read-only slot badge "Bus N" (N = `tour.buses.length + 1`), labelled auto-assigned.
  2. Optionally enter Bus name, Bus number (registration), toggle AC (default ON).
  3. Set boarding point and pick a departure time (time picker, default 9:00).
  4. Optionally enter driver name and driver phone.
  5. Tap Next to advance to Step 2.
- **Expected:**
  - Step 1 has NO hard-required field (`_canAdvance` returns true for case 0) — bus number is optional, can be filled later.
  - Slot badge is computed (never stored) and stays "Bus N" based on tour order.
  - Wizard progress bar shows 3 segments; Step 1 active.
  - Departure time, once picked, displays in canonical HH:mm via the picker field.
- **Edge cases:**
  - Leave everything blank → Next still works; on save the bus name falls back to the slot label ("Bus N").
  - Tour deleted/unknown mid-flow → subtitle empty; save later surfaces `add_bus.snackbar.error_tour_not_found`.
  - Language switch → all `add_bus.step1.*`, `add_bus.label.*`, `add_bus.hint.*`, `add_bus.group.*`, `add_bus.ac_toggle.*`, `add_bus.slot_*` keys in 3 files.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_Step1Identity`, `_slotPositionLabel`, `_pickDepartureTime`).

---

### UC-03BUSMANAGEMENT-4: Add a new bus — Step 2 Capacity & layout (seat engine)
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** Admin is on Step 2 of the add-bus wizard.
- **Steps:**
  1. Set total seats with the stepper (min 1, max 100; default 40).
  2. Set single-sofa count with the stepper (min 0, max = sleeper seats); read the summary line "X single sofas + Y double sofas".
  3. Optionally toggle "all-double last row" (default OFF = 3 single + 2 double back bench; ON = 4 double back row).
  4. Tap Next to advance to Step 3.
- **Expected:**
  - Every bus is a sleeper coach (`BusType.sleeper`); there is no bus-type picker.
  - The single-sofa summary derives doubles as `(totalSeats − singles) ~/ 2`; an odd leftover berth becomes one extra single.
  - The back-row toggle only reshapes the LAST row and conserves the total seat count (no seats added either way).
  - `BusLayout.generate` keeps lane pairs even (no ragged hole); odd-tail berths park in the centre aisle bench.
- **Edge cases:**
  - Single-sofa count > sleeper seats → `_singleSofaInvalid` true: inline `add_bus.snackbar.error_single_sofa` shown under the stepper and Next is BLOCKED (`_canAdvance` false).
  - Lowering total seats below current single count auto-clamps singles down to sleeper seats.
  - `totalSeats == 0` is impossible (min 1); single-sofa stepper section only renders when `sleeperSeats > 0`.
  - Toggle ON with fewer than 4 double cells → engine keeps the 4-double back row only when doubles allow, otherwise leaves a trailing half-bunk (never invents a single).
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_Step2Capacity`, `_singleSofaSummary`, `_StepperRow`), `lib/models/seat_layout.dart` (`BusLayout.generate`), `lib/models/bus_type.dart`.

---

### UC-03BUSMANAGEMENT-5: Add a new bus — Step 3 uniform pricing ("Same for all")
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** Admin is on Step 3; price mode pill is "Same for all" (default when the bus carries no price bands).
- **Steps:**
  1. Enter the full bus rent ("Bus price") — observe the per-seat field auto-fill as `busPrice / totalSeats`, with the auto-note "÷ N seats".
  2. Optionally override the per-seat price directly.
  3. Observe single-sofa and double-sofa override fields pre-seeded: single = base, double = 2 × base.
  4. Optionally hand-type a sofa override; tap Save.
- **Expected:**
  - Per-seat field auto-derives from bus price ÷ total seats; editing bus price re-seeds it AND the untouched sofa defaults (`_reseedSofaDefaults`).
  - Hand-typed sofa overrides are preserved across base changes (`_stillAuto` tolerance ~0.005); only still-auto fields re-seed.
  - On save: `pricePerSeat`, `busPrice`, `singleSofaPrice`, `doubleSofaPrice` persisted; `busPrice` is auto-counted later as a `busOwner` expense (not a manual DB row).
  - A whole Double Sofa = 2 × per-berth price; `doubleSofaPrice` is the WHOLE-sofa value, so one berth is half (`berthPriceFor`).
- **Edge cases:**
  - Bus price blank but per-seat set → per-seat is the base; sofa defaults derive from it.
  - Both blank → `_basePerSeat == 0`, sofa fields stay empty placeholders, and each sofa falls back to `pricePerSeat` at pricing time.
  - Per-seat blank on save → falls back to `tour.pricePerSeat`.
  - Money inputs accept only `[0-9.]`; language switch needs `add_bus.step3.*`, `add_bus.label.bus_price`/`price_per_seat`, `add_bus.overrides.*`, `add_bus.per_seat.auto_note`, `add_bus.price_mode.same_*` in 3 files.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_Step3Price`, `_buildFixedBody`, `_onBusPriceChanged`, `_reseedSofaDefaults`), `lib/models/bus_details.dart` (`berthPriceFor`, `tripFactor`).

---

### UC-03BUSMANAGEMENT-6: Add a new bus — Step 3 price-bands mode (per-row pricing)
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** Admin is on Step 3 and switches the price-mode pill to "Price bands".
- **Steps:**
  1. Tap "Price bands" pill; observe the bands editor body.
  2. Tap "Add band"; in the sheet enter a label, From row, optional To row (blank = single-row band), and per-person price.
  3. Save the band; it appears as a row showing label, 1-based range, and ₹price.
  4. Add more bands, edit one (tap the row), or remove one (× icon); tap Save on the wizard.
- **Expected:**
  - The mode is either/or: choosing "Same for all" stashes bands and persists `priceBands = []`; switching back restores the stash (`_onModeChanged`, `_stashedBands`).
  - Rows are displayed 1-based but stored 0-based; blank "To row" makes a single-row band (`from == to`).
  - Each band's price is PER BERTH/per-person; a whole double sofa inside a band costs 2 × band price.
  - Bands win over per-type overrides for the rows they cover; on overlap the FIRST band in the list wins (`bandForRow`, `effectiveBands`).
  - The "Price bands" pill shows a count badge equal to the number of bands.
- **Edge cases:**
  - Add mode: layout not yet built, so the band row range cannot be clamped to a concrete grid — `add_bus.bands.rows_clamped_note` is shown and bands are clamped to the bus's row count at save (`_sanitizedBands`).
  - A band with price ≤ 0 is dropped on save; a band entered backwards (toRow < fromRow) is normalised.
  - Band sheet Add/Save CTA is disabled until from/to/price are valid (`valid`).
  - Out-of-range rows clamp to `[0, rows−1]`; language switch needs `add_bus.price_mode.bands_*`, `add_bus.band_sheet.*`, `add_bus.bands.*`, `add_bus.band_row.*` in 3 files.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_buildBandsBody`, `_openBandSheet`, `_BandRow`, `_sanitizedBands`), `lib/models/bus_details.dart` (`PriceBand`, `effectiveBands`, `bandForRow`).

---

### UC-03BUSMANAGEMENT-7: Save a new bus persists it and advances tour status
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** Add-bus wizard complete; admin taps Save on Step 3.
- **Steps:**
  1. Complete all 3 steps and tap "Save" (CTA shows add icon; "Saving…" while in flight).
  2. Observe the success toast `add_bus.snackbar.added` and return to the bus list.
  3. Confirm the new bus appears in Manage Buses with its meter.
- **Expected:**
  - `TourController.addBus` writes optimistically to local state then persists to the `buses` table (`smartInsert`), binding `tourId` and `owner_id`.
  - If the tour status was `collecting`, adding the first bus advances it to `busBooked` (Phase 4 → 5 transition).
  - The layout is built once via `BusLayout.generate` with the chosen capacity + single count + back-row toggle.
  - Empty registration is persisted as NULL (partial unique index treats `''` as a real collision).
- **Edge cases:**
  - Tour not found at save → error toast `add_bus.snackbar.error_tour_not_found`, no write.
  - Persist failure → `add_bus.snackbar.error_save`, optimistic state should roll back per `_write`.
  - Two unfilled-registration buses on the same tour must not collide (NULL handling).
  - Offline → optimistic add shows immediately; sync replays the insert when back online.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_save`), `lib/controllers/tour_controller.dart` (`addBus`, `updateStatus`), `lib/models/bus_details.dart` (`toMap`).

---

### UC-03BUSMANAGEMENT-8: Edit a bus without touching capacity preserves seat assignments
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** A bus already exists with passengers seated on it; admin opens `AddBusScreen(existing: bus)` (edit mode).
- **Steps:**
  1. Open the bus edit flow (Manage Buses menu → Edit, or Bus Status → "Edit bus").
  2. Change a NON-capacity field only (driver name, phone, boarding point, AC, price, bands).
  3. Tap "Save changes".
- **Expected:**
  - Because `_capacityChanged` is false and "Regenerate layout" was not tapped, the saved layout is reused untouched — seat IDs and every existing assignment stay exactly as they were.
  - Edit mode seeds Step 2 capacity inputs from the saved layout (`_seedCapacityFromLayout`), inferring the back-row toggle from the last row.
  - Success toast `add_bus.snackbar.updated`.
  - Edit mode walks Step 1 → 2 → 3 (capacity step is included so the size is visible but unchanged).
- **Edge cases:**
  - Editing price/bands only must never renumber seats.
  - The resize warning banner does NOT appear when capacity is untouched and no one is seated.
  - Saving with no field changes still persists `updatedAt` bump (`updateBus`).
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_capacityChanged`, `_seedCapacityFromLayout`, `_save` edit branch), `lib/controllers/tour_controller.dart` (`updateBus`).

---

### UC-03BUSMANAGEMENT-9: Resize a bus with seated passengers — confirm-then-unassign
- **Actor:** admin
- **Phase:** 5 (Add Bus Details) — can also recur after lock during a reshuffle
- **Preconditions:** A bus has N passengers seated; admin opens it in edit mode and changes a capacity value (total seats, single-sofa count, or the back-row toggle).
- **Steps:**
  1. On Step 2, change total seats (or single count / toggle); observe the resize warning banner (`add_bus.resize_warning` with the seated count).
  2. Tap "Save changes".
  3. A destructive confirm appears (`add_bus.resize_confirm_title` / `_msg` with count); confirm to proceed.
- **Expected:**
  - On confirm, `unassignBus(tourId, busId)` frees every seat on this bus; the passengers' request lines stay intact, so they reappear as "needs assignment" and can be re-seated.
  - The layout is regenerated (seat IDs renumbered) and the bus saved with the new size; `totalSeatsLegacy` updated only on a structural change.
  - Cancelling the confirm aborts the save and leaves assignments intact (`_saving` reset).
  - A "structural change" requires the new seat-ID set to differ from the old (count or membership), not merely a re-run that yields identical IDs.
- **Edge cases:**
  - Resizing a bus with NO seated passengers → no confirm dialog, layout just regenerates.
  - `unassignBus` calls `_revertLockOnUnseat` — if the tour was locked, freeing seats can revert the lock state.
  - Changing only the back-row toggle (same total) still counts as a capacity change and can trigger the unassign flow if seat IDs shift.
  - Language switch needs `add_bus.resize_warning`, `add_bus.resize_confirm_*` in 3 files.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_seatedOnThisBus`, `_ResizeWarning`, `_save` structural branch), `lib/controllers/tour_controller.dart` (`unassignBus`, `_revertLockOnUnseat`).

---

### UC-03BUSMANAGEMENT-10: Regenerate layout to migrate a bus onto the current seat engine
- **Actor:** admin
- **Phase:** 5 (Add Bus Details)
- **Preconditions:** A bus whose layout was saved under an older seat engine; admin opens it in edit mode (Step 2).
- **Steps:**
  1. On Step 2, tap "Regenerate layout" (edit-mode-only row).
  2. Confirm the destructive dialog (`add_bus.regenerate_confirm_title`; message varies by whether passengers are seated).
- **Expected:**
  - `_forceRegenerate` is set and `_save` runs, building a fresh layout from the current capacity + single count + toggle even when no capacity field was touched.
  - When passengers are seated, the regenerate button shows its OWN destructive warning, so `_save` does NOT double-prompt (the in-flow resize prompt is skipped because `_forceRegenerate` is true).
  - After any save attempt (success, cancel, or error) `_forceRegenerate` resets to false so a later plain edit never regenerates.
  - The "Regenerate layout" row is hidden in add mode (`onRegenerate` null).
- **Edge cases:**
  - Regenerate on an empty bus → `add_bus.regenerate_confirm_msg_empty` (no seated count).
  - Declining the regenerate confirm aborts before any layout rebuild.
  - Error during save still clears `_forceRegenerate` in the `finally` block.
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_regenerateLayout`, `_RegenerateLayoutButton`, `_forceRegenerate`).

---

### UC-03BUSMANAGEMENT-11: Read per-bus and tour-wide leg-aware capacity meters
- **Actor:** admin
- **Phase:** 4–5 (Tally & Book / Add Bus)
- **Preconditions:** Tour has at least one bus with a layout and some seats assigned across GO/RET legs.
- **Steps:**
  1. Open Manage Buses; read the app-bar subtitle "N buses · X free of Y".
  2. Read each bus card's two-leg meter ("Go x/n · Ret y/n" + free count over one thin bar).
  3. Open a bus's Bus Status; read the tally ("assigned/total" + percentage bar).
- **Expected:**
  - The whole screen uses ONE engine snapshot `computeTourCapacity(tour)`: the app-bar "free" = `cap.free`, each card uses `cap.byBus[bus.id]`.
  - A bus's load is the busier leg `max(goOccupied, retOccupied)`; free = `capacity − occupied` (empty on BOTH legs, sellable as round-trip).
  - A berth shared by two opposite one-way riders counts ONCE in occupancy.
  - The per-bus meter is skipped when the bus has no engine slice yet (no layout) — `busCap == null` or `capacity == 0`.
  - The app-bar leads with FREE seats (the number the agent acts on), never a raw assigned/total or a percentage.
- **Edge cases:**
  - Symmetric legs (or no return leg) → meter can collapse to a single bar (`BusCapacity.symmetric` / `legsSymmetric`).
  - `totalBusSeats == 0` (no booked buses) → seats-free subtitle hidden, only the bus count shows.
  - Bus Status `_Tally` is a simpler raw assigned/total over total cells (occupant entries), distinct from the leg-aware meter — a double sofa with 2 riders counts both entries there.
  - Language switch needs `manage_buses.subtitle_buses`/`subtitle_seats_free`, `bus_status.legend_booked` in 3 files.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (`_BusListItem`, `UgamCapacityMeter.bus`), `lib/screens/bus_status_screen.dart` (`_Tally`), `lib/utils/tour_capacity.dart` (`BusCapacity`, `TourCapacity`).

---

### UC-03BUSMANAGEMENT-12: Empty states — no buses booked yet
- **Actor:** admin
- **Phase:** 4–5
- **Preconditions:** Tour exists with zero buses.
- **Steps:**
  1. Open Manage Buses for the tour.
  2. Observe the empty state.
  3. Tap the sticky "Add bus" CTA.
- **Expected:**
  - Manage Buses shows the empty illustration with `manage_buses.empty_title` / `empty_body`; app-bar subtitle shows only the bus count.
  - On Tour Overview, the `_NoBuses` placeholder shows instead of the bus list.
  - The sticky "Add bus" CTA always routes to `AddBusScreen(tourId)` (add mode).
- **Edge cases:**
  - Tour not found (deleted) → `manage_buses.tour_not_found` empty state.
  - Opening Bus Status for a bus with no layout → `bus_status.no_layout` empty state (no chart).
  - Language switch needs `manage_buses.empty_*`, `manage_buses.tour_not_found`, `bus_status.no_layout` in 3 files.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (empty branch), `lib/screens/tour_overview_screen.dart` (`_NoBuses`), `lib/screens/bus_status_screen.dart` (no-layout branch).

---

### UC-03BUSMANAGEMENT-13: Per-bus actions menu — edit, call driver, re-broadcast, delete
- **Actor:** admin
- **Phase:** 5
- **Preconditions:** A bus exists on the tour; admin taps the kebab (⋮) on the bus card in Manage Buses.
- **Steps:**
  1. Tap ⋮ to open the per-bus action sheet (titled with `bus.displayLabel`).
  2. Choose "Edit" → opens the Add-Bus wizard in edit mode.
  3. Choose "Call driver" (only present when `driverPhone` is non-empty) → dials the number.
  4. Choose "Re-broadcast" → opens WhatsApp to the driver with the assignment message.
  5. Choose "Delete" → confirm destructive dialog → bus removed.
- **Expected:**
  - "Call driver" tile is hidden when the bus has no driver phone.
  - Re-broadcast builds a localized message (tour title, bus label, departure date, from/to cities, this bus's own boarding + time); per-bus departure overrides tour-level.
  - Re-broadcast with empty/invalid phone → `manage_buses.snack_driver_phone_missing`; WhatsApp open failure → `manage_buses.snack_wa_failed`.
  - Delete confirm uses `manage_buses.delete_title`/`delete_body`; on confirm `removeBus` deletes the row and clears `tour.busId` if it pointed at this bus.
- **Edge cases:**
  - Deleting a bus that has seated passengers — `removeBus` does not itself unassign; passengers' assignments referencing the deleted bus become orphaned (covered by the engine ignoring missing buses). Verify behavior.
  - Delete persist failure → `manage_buses.snack_delete_failed`.
  - Re-broadcast routes through `WhatsAppService().openChat`; offline/no WhatsApp installed → failure toast.
  - Language switch needs `manage_buses.menu_*`, `manage_buses.wa_*`, `manage_buses.snack_*`, `manage_buses.delete_*` in 3 files.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (`_openBusMenu`, `_broadcastToDriver`, `_confirmDelete`), `lib/controllers/tour_controller.dart` (`removeBus`).

---

### UC-03BUSMANAGEMENT-14: Assign / clear a per-bus handler from the bus card
- **Actor:** admin
- **Phase:** 7 (Assign Handler) — surfaced on the bus-management surface
- **Preconditions:** A bus has at least one seated passenger.
- **Steps:**
  1. On the bus card, tap the handler row ("Set handler" when empty, or the current handler's name).
  2. In the picker, pick a seated passenger to set as handler; or tap "Remove" to clear the current handler.
- **Expected:**
  - The picker lists ONLY passengers holding at least one seat on THIS bus (`_seatedPassengers`) — a handler must be physically on board.
  - Picking sets `bus.handlerPassengerId` via `setBusHandler`; the current pick shows a check tick (re-reads the live bus so the highlight stays correct).
  - "Remove" (only shown when a handler exists) calls `removeBusHandler` and shows `bus_handler.remove_done`.
  - The handler row turns to the accent-tinted "set" state showing `bus_handler.row_current` with the name.
- **Edge cases:**
  - No seated passengers → tapping the row shows `bus_handler.none_seated` warning and does NOT open the picker.
  - Re-picking the already-current handler is a no-op (returns early).
  - Language switch needs `bus_handler.*` (`picker_title`, `picker_subtitle`, `none_seated`, `set_done`, `remove`, `remove_done`, `row_current`, `row_empty`) in 3 files.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (`_openHandlerPicker`, `_HandlerRow`, `_HandlerPickTile`), `lib/controllers/tour_controller.dart` (`setBusHandler`, `removeBusHandler`).

---

### UC-03BUSMANAGEMENT-15: Per-type free breakdown reads the engine plan, never a negative
- **Actor:** admin
- **Phase:** 4 (Tally & Book Bus)
- **Preconditions:** Tour has buses and requests where one seat type is over-demanded (e.g. more single-sofa requests than single-sofa berths).
- **Steps:**
  1. Open the Requests screen capacity banner (or Tour Overview) and read the "empty by type" breakdown.
  2. Compare against the requested demand for that type.
- **Expected:**
  - "Empty by type" comes from `cap.freeByType[st]` — `typeCap − max(goPlaced, retPlaced)` clamped to `[0, cap]`, read from the SAME engine plan as `free`.
  - An over-demanded type shows `0` free (clamped), never a negative like "Single Sofa −2"; the excess surfaces as `needsDecision`.
  - A Double Sofa cell contributes 2 berths to `capByType`.
- **Edge cases:**
  - A type the tour's buses do not have at all does not appear in the breakdown.
  - Leg-shared seats per type are counted once via `max(goByType, retByType)`.
  - Mixed-leg request lines charge each placed berth to its own type's leg (`legForSeatType`).
- **Screens/files:** `lib/utils/tour_capacity.dart` (`freeByType`, `capByType`), `lib/screens/requests_screen.dart` (`_CapacityBanner`), `lib/screens/tour_overview_screen.dart`.

---

### UC-03BUSMANAGEMENT-16: Pricing correctness — band vs override vs base, single vs double sofa, leg factor
- **Actor:** admin (verification of pricing data the money/collection track relies on)
- **Phase:** 5 (Add Bus Details) feeding the MONEY/SETTLEMENT track
- **Preconditions:** A saved bus with a mix of pricing config (base per-seat, a sofa override, and at least one price band) and passengers seated across whole/shared sofas and GO/RET legs.
- **Steps:**
  1. Configure base `pricePerSeat`, a `doubleSofaPrice` override, and a price band covering specific rows.
  2. Seat: a single-sofa rider, a whole double-sofa rider (both berths), a shared double (one berth), and a one-leg rider.
  3. Inspect the per-passenger amount due (e.g. on the collection/bus-money surfaces fed by `Bus.amountDueFor` / `amountDueForSeat`).
- **Expected:**
  - Band rows price every berth at the band's per-person price regardless of seat type (whole double in a band = 2 × band price); bands win over per-type overrides for covered rows.
  - Outside bands: a single sofa = `singleSofaPrice ?? pricePerSeat`; a double berth = `doubleSofaPrice/2` (or `pricePerSeat` with no override), so a whole double = 2 × per-berth.
  - A SHARED double (one berth held) is charged half a whole double; the whole-sofa collection record carries the FULL price (`amountDueForSeat` clamps berths to 1–2).
  - A single leg (outbound-only / return-only) pays HALF via `tripFactor` (0.5); round-trip pays full — applied per berth from the matching request line's leg.
- **Edge cases:**
  - Legacy rear-zone (`rearRows`/`rearPrice`) is synthesized as a trailing band via `effectiveBands`, so old buses price identically and explicit bands still win for overlapping rows.
  - Overlapping bands → FIRST band in the list wins (`bandForRow`).
  - No layout on the bus → `amountDueFor` returns 0 (no cells to price).
  - Verify pricing against LIVE data when changing this logic (data-derived).
- **Screens/files:** `lib/models/bus_details.dart` (`berthPriceFor`, `amountDueFor`, `amountDueForSeat`, `effectiveBands`, `bandForRow`, `tripFactor`), `lib/models/seat_layout.dart` (`isRearRow`).
