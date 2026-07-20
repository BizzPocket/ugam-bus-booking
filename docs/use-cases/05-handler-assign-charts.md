# Use Cases — Handler Appointment + Read-Only Seat Charts (Phase 7 + Read Surfaces)

Area owner: Phase 7 (Assign Handler) plus every read-only seat-chart surface (the top-level **Charts** tab, the app-wide **Fullscreen chart**, and the read-only **occupant sheet**).

Key facts grounded in the code (read before testing):

- The **Charts** tab is an **ADMIN-only top-level tab** in the admin shell (`MainShell._adminPages` index 2; built from `buildAdminDockItems()`). Handlers are NOT in this shell — a handler reaches their own bus chart through the separate `HandlerBusChartScreen` / `handler_tour_manifest` RPC flow. Document Charts-tab use cases as ADMIN.
- "Handler appointment" in this area happens in **two places**: (1) the `OccupantActionSheet` in **action** mode (`occupant.make_handler` / `occupant.is_handler` toggle) opened from the editable assignment / bus-status charts; (2) the dedicated **handler picker** in `ManageBusesScreen._openHandlerPicker`. The handler is **per-bus** (`bus.handlerPassengerId`), and `passenger.isHandler` is kept true while they handle ANY bus. A legacy tour-wide `tours.handler_id` pointer is also maintained.
- Charts tab is **read-only by design**: tapping a booked seat opens `OccupantActionSheet` in `OccupantSheetMode.readOnly` (header + call row only, NO mutating actions). The single write hand-off is the copper **Edit seats** FAB → `AppRoutes.seatAssignment`.
- The chart renders the canonical `CombinedSeatGrid` + `SeatChartTile`; the same tile is blown up by `FullscreenChartScreen`. The shared 9-item `UgamSeatChartLegend` (Free · Booked · Priority · Held · Go · Return · ½ · Paid · Owing) sits below.
- Strings live in namespaces `charts.*`, `bus_handler.*`, `occupant.*`, `occupant_sheet.*`, `seat_legend.*`, `fullscreen_chart.*`, `main_shell.tab_charts` — every one must exist in **en / gu / hi** (verified parity at time of writing).

---

### UC-05HANDLERASSIGNCHARTS-1: Charts tab opens to nearest upcoming bus with zero extra taps
- **Actor:** admin
- **Phase:** Phase 7 (read surface; available from Phase 5 onward once a bus exists)
- **Preconditions:** At least one **active** tour has at least one bus with a layout; admin is logged in on the admin shell.
- **Steps:**
  1. Tap the **Charts** tab (table icon) in the bottom dock.
  2. Observe the screen with no further interaction.
- **Expected:**
  - The screen resolves the **nearest upcoming** eligible tour (active tours that carry ≥1 bus, sorted soonest departure first) and that tour's **first bus**, and renders its read-only seat chart immediately.
  - App bar shows `charts.title` with **no back affordance** (`showBack: false`).
  - A `_Tally` card shows `assigned/total` (e.g. `12/40`), the bus name uppercased, and a neutral (ink, not accent) fill bar; no percentage text.
  - The canonical seat grid renders with group/priority rings and GO/RET leg tints; the 9-item `UgamSeatChartLegend` shows below.
- **Edge cases:**
  - Selection is tracked by **tour id and bus id**, not index — realtime reordering/additions must not shift the visible chart.
  - If the previously selected tour scrolls out of the eligible set, selection falls back to the nearest upcoming tour (first of soonest-first list).
- **Screens/files:** `lib/screens/charts_screen.dart` (`_eligibleTours`, `_resolveTour`, `_resolveBus`), `lib/screens/main_shell.dart`, `lib/design/components/ugam_seat_chart_legend.dart`

### UC-05HANDLERASSIGNCHARTS-2: Charts empty state when no active tour has a bus
- **Actor:** admin
- **Phase:** Phase 7 (read surface / empty path)
- **Preconditions:** No active tour has any bus (either no active tours at all, or active tours all bus-less).
- **Steps:**
  1. Open the **Charts** tab.
  2. Read the empty state and tap its CTA.
- **Expected:**
  - `UgamEmpty` shows with `charts.empty.title` and `charts.empty.body`.
  - If at least one active tour exists, the CTA reads `add_bus.title` and routes into **AddBusScreen** for the nearest upcoming active tour.
  - If NO active tour exists, the CTA reads `create_tour.title` and pushes **CreateTourScreen** (never a dead end).
  - The `_Header` (Charts app bar) still renders above the empty state.
- **Edge cases:**
  - A tour exists but is in a non-active status → it is excluded from `activeTours`, so the empty state shows.
  - **i18n:** `charts.empty.title`/`charts.empty.body`, `add_bus.title`, `create_tour.title` must exist in en/gu/hi (note `charts.empty` is a NESTED object `{title, body}`, not a flat string).
- **Screens/files:** `lib/screens/charts_screen.dart` (empty branch), `lib/screens/add_bus_screen.dart`, `lib/screens/create_tour_screen.dart`

### UC-05HANDLERASSIGNCHARTS-3: Tour-pill and bus-pill selectors switch the visible chart
- **Actor:** admin
- **Phase:** Phase 7 (read surface)
- **Preconditions:** ≥2 eligible tours exist, and the selected tour has ≥2 buses.
- **Steps:**
  1. Open **Charts**.
  2. Tap a different **tour pill** in the top `UgamSelectorPills` row.
  3. Tap a different **bus pill** in the second pills row.
- **Expected:**
  - Picking a tour calls `_pickTour`: the chart switches to that tour and the **bus pick resets to null**, so the new tour's **first bus** shows.
  - Picking a bus calls `_pickBus`: only the chart/tally swap; the tour pick stays.
  - Each pill change fires a haptic (inside `UgamSelectorPills.onChanged`).
  - The tour-pill row only renders when `eligible.length > 1`; the bus-pill row only when `tour.buses.length > 1`.
- **Edge cases:**
  - Single eligible tour → no tour-pill row at all (chart still shows).
  - Single-bus tour → no bus-pill row; the tally gets the larger top padding instead.
- **Screens/files:** `lib/screens/charts_screen.dart` (`_pickTour`, `_pickBus`, selector pills block)

### UC-05HANDLERASSIGNCHARTS-4: Tapping a booked seat opens the READ-ONLY occupant sheet
- **Actor:** admin
- **Phase:** Phase 7 (read surface)
- **Preconditions:** Charts tab showing a bus with at least one booked seat.
- **Steps:**
  1. Tap a **booked** seat tile.
  2. Inspect the bottom sheet.
- **Expected:**
  - `OccupantActionSheet.show(..., mode: OccupantSheetMode.readOnly)` opens with the drag handle, avatar + name, and the `occupant_sheet.seat_on` subtitle ("Seat {seat} · {bus}").
  - **Only the call row** (`occupant_sheet.call`, when phone present) appears — no Move/Swap, Edit, Priority, Make-handler, Free, or Cancel-return rows (those are gated behind `mode == action`).
  - Tapping the call row dials via `PhoneDialer.call`.
- **Edge cases:**
  - Tapping a **free** / **held** seat does nothing (the tile's `onTapBooked` is null when `occupants.isEmpty`, and the sheet returns early on empty occupants).
  - Occupant with empty phone → no call row renders.
- **Screens/files:** `lib/screens/charts_screen.dart` (`_showOccupantSheet`), `lib/widgets/occupant_action_sheet.dart`

### UC-05HANDLERASSIGNCHARTS-5: Read-only sheet surfaces BOTH names on a shared / leg-shared double sofa
- **Actor:** admin
- **Phase:** Phase 7 (read surface; the shared-double bug fix)
- **Preconditions:** Charts tab showing a bus that has a Double Sofa seat held by **two distinct people** (a split share, or a GO-only + RET-only leg reuse).
- **Steps:**
  1. Tap that double-sofa seat.
  2. Use the person toggle at the top of the sheet.
- **Expected:**
  - The sheet receives the seat's **full distinct, GO-first occupant list** (`occupantListForBus`/`sheetOccupants[seatId]`), not just the first occupant.
  - A `UgamTabPills` person toggle appears (only when >1 occupant); switching it shows the other person's name, seat subtitle, and call row.
  - A whole double held **solo** collapses to a single name (no toggle).
- **Edge cases:**
  - A double shared by **3–4** riders (quad) — the tile paints a 2×2 GO/RET grid and the sheet's occupant list carries every distinct rider; the toggle pages through all of them.
  - The raw `assignments` map (berth-accurate) feeds the TILE; the de-duped `sheetOccupants` feeds the SHEET — verify the tile's half-double split still reads correctly while the sheet shows both names.
- **Screens/files:** `lib/screens/charts_screen.dart` (`_assignmentsFor`, `sheetOccupants`, `_SeatChartCard.onTapBooked`), `lib/utils/seat_occupants.dart`, `lib/widgets/occupant_action_sheet.dart`, `lib/components/seat_chart_tile.dart`

### UC-05HANDLERASSIGNCHARTS-6: Edit-seats FAB hands off to the editable assignment grid
- **Actor:** admin
- **Phase:** Phase 6/7 (read → write hand-off)
- **Preconditions:** Charts tab showing a bus whose layout has cells (`layout.totalCells > 0`).
- **Steps:**
  1. Locate the copper **Edit seats** FAB at the chart's bottom-right.
  2. Tap it.
- **Expected:**
  - `_editSeats` fires a light haptic and routes to `AppRoutes.seatAssignment` with `{tourId, busId}` for the currently-shown bus.
  - The FAB is the screen's single rationed solid-copper element, ≥48dp tap target, labeled `charts.edit_seats` (also its `Semantics` label).
  - The Charts screen itself never mutates seats — all editing happens on the pushed assignment screen.
- **Edge cases:**
  - Bus with no layout / `totalCells == 0` → the FAB (and the expand button) are not rendered; the card shows `charts.no_layout` instead.
- **Screens/files:** `lib/screens/charts_screen.dart` (`_EditSeatsFab`, `_editSeats`), `lib/screens/tour_seat_assignment_screen.dart`, `lib/routes/app_routes.dart`

### UC-05HANDLERASSIGNCHARTS-7: Expand to the app-wide fullscreen pinch-zoom chart
- **Actor:** admin
- **Phase:** Phase 7 (read surface)
- **Preconditions:** Charts tab showing a bus with a non-empty layout.
- **Steps:**
  1. Tap the **expand** button (top-left `ChartExpandButton` over the chart).
  2. Pinch-zoom and pan the chart.
  3. Tap the close control (top-right).
- **Expected:**
  - `FullscreenChartScreen.open` pushes a `fullscreenDialog` (downToUp transition) showing ONLY the chart inside an `InteractiveViewer` (minScale 0.6, maxScale 4), scaled to fit via `FittedBox`.
  - The bus name shows as a faint top-left caption (`title`); a single close control sits top-right; no roster/stats/pills.
  - `markHalfDouble: true` is passed, so a half-taken double renders split there too, identical to the inline chart.
  - Close returns to the Charts tab with the same selection intact.
- **Edge cases:**
  - Empty layout (`totalCells == 0`) → fullscreen shows `fullscreen_chart.empty` empty state instead of a grid.
  - The fullscreen tiles carry **no tap / drag / edit** (read-only by design) — verify tapping a seat there does nothing.
- **Screens/files:** `lib/screens/fullscreen_chart_screen.dart`, `lib/screens/charts_screen.dart` (`ChartExpandButton` block), `lib/widgets/chart_expand_button.dart`

### UC-05HANDLERASSIGNCHARTS-8: Half-taken double sofa renders as split (filled + empty) on the read-only chart
- **Actor:** admin
- **Phase:** Phase 7 (read surface / render correctness)
- **Preconditions:** Charts tab showing a bus with a Double Sofa holding exactly ONE berth (one person, or a single GO+RET leg-reuse on one berth).
- **Steps:**
  1. Locate that double-sofa tile on the chart.
- **Expected:**
  - The tile draws a **split**: occupant (or GO/RET stack) on one half, a dimmed empty placeholder (`event_seat_outlined`) on the other — never a fully-booked look. (Charts passes `markHalfDouble: true`.)
  - A whole double held by ONE person (two assignments, same seatId) still collapses to a single name (deduped by id), not a repeated split.
- **Edge cases:**
  - This is **render-only**: the seat is still bookable for the free berth; the engine/placement is unchanged.
  - The handler manifest chart (leg-deduped occupant list) must leave `markHalfDouble` OFF — verify Charts (berth-accurate `assignments`) is the surface that turns it ON.
- **Screens/files:** `lib/components/seat_chart_tile.dart` (`_halfDoubleTile`, `_legShareHalfTile`, `resolveSeatRender`), `lib/screens/charts_screen.dart`

### UC-05HANDLERASSIGNCHARTS-9: Appoint a passenger as bus handler from the occupant sheet (action mode)
- **Actor:** admin
- **Phase:** Phase 7 (Assign Handler)
- **Preconditions:** On an **editable** chart (assignment screen or bus-status screen, NOT the read-only Charts tab); a booked seat with a known occupant on the bus.
- **Steps:**
  1. Tap a booked seat → occupant sheet opens in **action** mode.
  2. Tap **Make handler** (`occupant.make_handler`, shield icon).
- **Expected:**
  - `_toggleHandler` calls `TourController.setBusHandler(tourId, busId, occupantId)`; the sheet stays open and the row flips to **Is handler** (`occupant.is_handler`, accent + verified-user icon).
  - `bus.handlerPassengerId` is set; `passenger.isHandler` becomes true; the legacy `tours.handler_id` points at this passenger.
  - If a DIFFERENT passenger previously handled this bus and handles no other bus, their `isHandler` is cleared.
- **Edge cases:**
  - Because the occupant is, by definition, seated on this bus, the "must be on board" rule is satisfied implicitly — no seated check fires here.
  - The handler is **per-bus**: making someone handler of bus B leaves bus A's handler untouched.
  - **i18n:** `occupant.make_handler` / `occupant.is_handler` must exist in en/gu/hi.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (`_toggleHandler`, `_isHandlerOfThisBus`), `lib/controllers/tour_controller.dart` (`setBusHandler`), `lib/screens/tour_seat_assignment_screen.dart`, `lib/screens/bus_status_screen.dart`

### UC-05HANDLERASSIGNCHARTS-10: Step a handler down from the occupant sheet
- **Actor:** admin
- **Phase:** Phase 7 (Assign Handler)
- **Preconditions:** Occupant sheet (action mode) open on a passenger who currently handles THIS bus.
- **Steps:**
  1. Tap the **Is handler** row (currently accent/verified).
- **Expected:**
  - `_toggleHandler` calls `TourController.removeBusHandler(tourId, busId)`; the row flips back to **Make handler** without closing the sheet.
  - `bus.handlerPassengerId` clears; the passenger keeps `isHandler` only if they still handle some OTHER bus; the legacy `tours.handler_id` is recomputed to another bus's handler (lowest bus id) or null.
- **Edge cases:**
  - Passenger handles two buses → stepping down from one keeps `isHandler` true (still handles the other).
  - **i18n:** `errors.set_handler` / `errors.remove_handler` failure strings must exist in en/gu/hi.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (`_toggleHandler`), `lib/controllers/tour_controller.dart` (`removeBusHandler`)

### UC-05HANDLERASSIGNCHARTS-11: Appoint / change / clear handler via the Manage Buses handler picker
- **Actor:** admin
- **Phase:** Phase 7 (Assign Handler — the dedicated home)
- **Preconditions:** Manage Buses screen open for a tour; a bus has at least one **seated** passenger.
- **Steps:**
  1. On a bus card, tap the **handler row** (`bus_handler.row_empty` "Set handler" or `bus_handler.row_current` "{name}").
  2. In the picker sheet, tap a seated passenger to set them.
  3. Reopen the picker and tap **Remove** (`bus_handler.remove`).
- **Expected:**
  - Picker title is `bus_handler.picker_title` with the bus label; subtitle `bus_handler.picker_subtitle`; it lists ONLY **seated** passengers (`_seatedPassengers` — those holding ≥1 seat on this bus), each via `_HandlerPickTile` with a current-tick on the active one.
  - Picking a non-current passenger calls `setBusHandler` and shows `bus_handler.set_done {name}`; the bus card's `_HandlerRow` updates to the accent "current handler" state.
  - The **Remove** button appears only when a handler is currently set; tapping it calls `removeBusHandler` and shows `bus_handler.remove_done`.
- **Edge cases:**
  - Bus with **no seated passengers** → the picker is never shown; a warning toast `bus_handler.none_seated` fires instead (a handler must be on board).
  - Tapping the already-current passenger is a no-op (early return after closing).
  - **i18n:** all `bus_handler.*` keys must exist in en/gu/hi.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (`_openHandlerPicker`, `_seatedPassengers`, `_HandlerRow`, `_HandlerPickTile`), `lib/controllers/tour_controller.dart`

### UC-05HANDLERASSIGNCHARTS-12: Handler reaches their OWN bus chart (separate manifest flow, not the Charts tab)
- **Actor:** handler
- **Phase:** Phase 7 / on-trip read surface
- **Preconditions:** The logged-in phone number is the designated handler (has a booking_request) for at least one tour; `handler_requests_by_phone` returns ≥1 `HandlerTourRef`.
- **Steps:**
  1. Open the handler entry flow (handler is NOT in the admin Charts shell).
  2. Select a tour the phone handles.
  3. View the bus chart for that tour.
- **Expected:**
  - Each `HandlerTourRef` carries a `requestId` so the UI hands it straight to the requestId-scoped `HandlerBusChartScreen` (handler never types a request id).
  - The chart comes from `handler_tour_manifest` (`HandlerManifest`: buses, passengers, collections, expenses, incomes, attendance) — only the authorized handler receives it.
  - The chart uses the SAME `CombinedSeatGrid`/`SeatChartTile` + `UgamSeatChartLegend`, plus a money-state dot per seat (handler-only addition).
- **Edge cases:**
  - A tour where the handler has NO booking_request does **not** appear in the refs (can't be managed via that flow).
  - The handler manifest's occupant list is **leg-deduped**, so its chart must keep `markHalfDouble` OFF (a round-trip whole double would otherwise mis-read as a half-share).
  - Non-handler phone → manifest RPC is unauthorized (no chart).
- **Screens/files:** `lib/models/handler_tour_ref.dart`, `lib/models/handler_manifest.dart`, `lib/screens/handler_bus_chart_screen.dart`

### UC-05HANDLERASSIGNCHARTS-13: Charts tab is admin-only — a handler-role user never sees it
- **Actor:** handler (role gating / negative)
- **Phase:** Phase 7 (role gating)
- **Preconditions:** A user in the handler flow (not the admin shell).
- **Steps:**
  1. Inspect the bottom dock available to a handler.
- **Expected:**
  - The five-tab admin dock (Home · Tours · **Charts** · Requests · Settings) is the **admin** shell only (`buildAdminDockItems` / `_adminPages`). The handler does not get the Charts tab; they use the manifest chart flow (UC-12).
- **Edge cases:**
  - Confirms there is no role leak: the Charts tab's write hand-off (Edit seats FAB → assignment screen) is an admin-only path and must never be reachable from a handler session.
- **Screens/files:** `lib/screens/main_shell.dart` (`buildAdminDockItems`, `_adminPages`), `lib/screens/charts_screen.dart`

### UC-05HANDLERASSIGNCHARTS-14: Shared legend reads identically (9 items, GO/RET split) under language switch
- **Actor:** admin
- **Phase:** Phase 7 (read surface / i18n)
- **Preconditions:** Charts tab (or any chart screen) visible; app language can be changed in Settings.
- **Steps:**
  1. Note the legend row below the chart.
  2. Switch language en → gu → hi in Settings, return to Charts.
- **Expected:**
  - The `UgamSeatChartLegend` always renders the same 9 swatches in order: Free (dashed) · Booked (filled) · Priority (warm ring) · Held (lock) · Go (cyan) · Return (violet) · ½ (half-fare) · Paid (green dot) · Owing (red dot).
  - Every label re-renders in the active language from `seat_legend.*`.
  - The same legend appears verbatim on `handler_bus_chart_screen`, `bus_status_screen`, and `tour_seat_assignment_screen` — no screen hand-rolls its own.
- **Edge cases:**
  - **i18n:** `seat_legend.free/booked/priority/held/go/ret/half/paid/owing` must all exist in en/gu/hi (single source of truth; missing a key shows the raw key).
  - The driver label (`charts.driver_label` on Charts, `seat_ui.driver` fallback elsewhere) must also localize.
- **Screens/files:** `lib/design/components/ugam_seat_chart_legend.dart`, `lib/components/combined_seat_grid.dart` (`_driverRow`), `lib/screens/charts_screen.dart`

### UC-05HANDLERASSIGNCHARTS-15: Chart reflects realtime changes (new booking / move / cancel) without leaving the tab
- **Actor:** admin
- **Phase:** Phase 7 (read surface / reactivity)
- **Preconditions:** Charts tab showing a specific tour+bus; the same tour is being changed elsewhere (another assignment action, a realtime DB event, or a customer cancellation).
- **Steps:**
  1. Keep the Charts tab open on a bus.
  2. Trigger a seat change for that bus (assign a pending rider, move a seat, or cancel a booking).
- **Expected:**
  - The whole screen body is inside `Obx(...)` over `TourController`, so the tally `assigned/total`, the fill bar, and the affected tiles update live without a manual refresh.
  - Selection (tour + bus) is held by id, so the same bus stays on screen across the rebuild even if the tour list reorders.
- **Edge cases:**
  - If the currently-shown tour becomes ineligible (e.g. its last bus is deleted, or it leaves active status), the screen re-resolves to the nearest upcoming eligible tour — or shows the empty state if none remain.
  - Deleting the shown bus → `_resolveBus` falls back to the tour's first remaining bus.
- **Screens/files:** `lib/screens/charts_screen.dart` (`build` Obx, `_resolveTour`, `_resolveBus`), `lib/controllers/tour_controller.dart`

### UC-05HANDLERASSIGNCHARTS-16: Bus with a layout but zero bookings shows an all-free chart, not an empty state
- **Actor:** admin
- **Phase:** Phase 7 (read surface / empty-bus path)
- **Preconditions:** An active tour has a bus with a valid layout but no passengers seated on it yet.
- **Steps:**
  1. Open Charts and select that bus.
- **Expected:**
  - The grid renders every seat in the **free** state (dashed chair silhouette + seat id); the tally shows `0/total`; the fill bar is empty.
  - The Edit-seats FAB and expand button still render (layout has cells), so the agent can jump straight to assigning.
  - Tapping any free seat does nothing on the read-only chart (no `onTapBooked`).
- **Edge cases:**
  - This bus is still **eligible** for Charts (it has a bus; emptiness of bookings is irrelevant to eligibility) — distinguish from UC-2 (no bus at all).
  - A bus whose layout has `totalCells == 0` instead shows `charts.no_layout` inside the card (no grid) — that is the layout-missing path, not this all-free path.
- **Screens/files:** `lib/screens/charts_screen.dart` (`_SeatChartCard`, `_Tally`), `lib/components/seat_chart_tile.dart` (`_freeTile`)
