# 07 — Handler On-Trip Experience (Trip Execution + Settlement)

Use cases for the **handler** (a passenger the agent appoints as the on-trip
point-of-contact / conductor). The handler is anonymous (not signed in as the
admin); they reach their bus through a **booking_request id** — either from
their own "My Requests" card or via **Find My Seat by phone**. Everything is
authorized server-side through SECURITY DEFINER RPCs that re-verify the caller
is this tour's designated handler (`is_request_handler`,
`handler_tour_manifest`, `handler_upsert_*`, `handler_delete_*`).

Key invariants grounded in the code:

- **Scope.** A handler sees the WHOLE tour manifest (every bus + every
  passenger) but the screen is read-only for seating — no drag, no
  re-assignment. Tapping an occupied seat opens a Call / Collect sheet.
- **Money is seat-agnostic.** Per-bus totals (`HandlerBusMoney.compute` built
  on `BusMoneySummary`) sum collection rows **by `bus_id`**, never by a rider's
  current seat — so a paid rider who later changed seats keeps their cash in
  `collected` (see `test/models/handler_bus_money_test.dart`).
- **In hand = collected + income − spent.** Income (cabin / gallery / other)
  ADDS to what the handler holds; ground expenses subtract. The bus-owner rent
  is excluded for the handler (the admin pays the owner directly).
- **Attendance default.** In the handler tally an UNMARKED passenger counts as
  **NOT boarded** (the tally treats "no row" as "not yet boarded"); the model
  default `present = true` only applies once a row is written.
- **Leg-aware.** Attendance and the shared-seat money chooser both have a
  GO / Return toggle; one-way fares are halved by `amountDueForSeat`.

All user-facing strings here live under the `handler_chart.*`, `collection.*`,
`bus_money.*`, `find_seat.*`, and `bus_message.*` namespaces, and MUST exist in
all three languages (`assets/translations/en.json`, `gu.json`, `hi.json`). At
the time of writing these namespaces have full 3-file key parity.

---

### UC-07HANDLERTRIPDAY-1: Handler opens their bus chart from "My Requests"
- **Actor:** handler
- **Phase:** Trip execution (post-lock)
- **Preconditions:** The phone belongs to a passenger the agent flagged as
  handler for a tour, AND that passenger has an in-app booking_request (so a
  "My Requests" card exists). Tour has at least one bus with a seat layout.
- **Steps:**
  1. Open the customer **My Requests** screen.
  2. On the request card for the tour they handle, tap the "open full chart"
     affordance (`_openFullChart` → `HandlerBusChartScreen(requestId: entry.id)`).
  3. Wait for the manifest to load.
- **Expected:**
  - A loading skeleton (`_LoadingSkeleton`: toggle + 3 stat tiles + roster rows)
    shows while `handlerTourManifest` fetches.
  - On success the chart appears titled `handler_chart.bus_chart`, defaulting to
    the **List** (call-first roster) view, with the first bus selected.
  - The "In hand" money hero, GO/RET boarded chips, and the per-seat roster all
    render for the selected bus.
- **Edge cases:**
  - Manifest RPC throws → full-screen `UgamEmpty` with
    `handler_chart.error_load_title` + `handler_chart.error_load` body.
  - Manifest returns null / `buses` empty → `UgamEmpty` with
    `handler_chart.no_bus_chart_title` / `..._body` (not an error).
  - A bus exists but has no layout → seat grid/roster area shows
    `handler_chart.no_seat_layout`.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`,
  `lib/screens/handler_bus_chart_screen.dart`,
  `lib/services/customer_requests_store.dart` (`handlerTourManifest`),
  `lib/models/handler_manifest.dart`

---

### UC-07HANDLERTRIPDAY-2: Handler reaches their bus via "Find My Seat by phone"
- **Actor:** handler
- **Phase:** Trip execution (post-lock)
- **Preconditions:** The handler may have NO in-app request of their own (a
  manually-added passenger). The tour's handler resolves by phone last-10-digits.
- **Steps:**
  1. From customer **More**, open **Find My Seat** (`FindMySeatScreen`).
  2. Enter the handler's mobile number; tap **Find** (`find_seat.find_btn`).
  3. App calls `seatsByPhone` and `handlerRequestsByPhone` in parallel.
  4. Tap **Manage as handler** (`find_seat.manage_as_handler`) on the matching
     ticket card or handler-only entry card.
- **Expected:**
  - If the phone holds a seat AND handles the tour → the seat ticket card shows
    "Manage as handler" inline (`_TicketCard.handlerRequestId` set).
  - If the phone handles a tour but holds NO seat in it → a separate
    `_HandlerEntryCard` is rendered with the same CTA.
  - Tapping the CTA pushes `HandlerBusChartScreen(requestId: ...)` (cupertino).
- **Edge cases:**
  - Fewer than 10 digits → inline `find_seat.error_short`, no network call.
  - Lookup throws → `find_seat.error_load` inline error.
  - No tickets AND no handler tours → `UgamEmpty` (`find_seat.empty_title` /
    `..._body`).
  - `+91` / spaces in the number must still match (server matches last 10).
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`,
  `lib/services/customer_requests_store.dart`
  (`seatsByPhone`, `handlerRequestsByPhone`), `lib/models/handler_tour_ref.dart`

---

### UC-07HANDLERTRIPDAY-3: Handler reads the call-first roster and phones a passenger
- **Actor:** handler
- **Phase:** Trip execution
- **Preconditions:** Chart open, **List** view active, at least one seated
  passenger with a phone number on the selected bus.
- **Steps:**
  1. Stay on the default **List** tab (`handler_chart.view_list`).
  2. Scroll the roster (`_SeatRoster`) — one row per distinct rider per seat.
  3. Tap the round call button on a row with a phone.
- **Expected:**
  - Each row shows seat-id chip, full name + mobile, optional group dot,
    a trip badge (round-trip / GO½ / RET½), and a money status line with dot +
    label (`handler_chart.money_paid` / `..._owing` / `..._return_due` /
    `..._not_collected`).
  - The call button triggers `PhoneDialer.call(phone)` with a Semantics label
    (`handler_chart.call_semantic`).
  - One-way riders show their leg tint (GO cyan, RET violet) on the trip badge.
- **Edge cases:**
  - Rider with no phone → `handler_chart.no_mobile` text, no call button.
  - Seat with no occupants is skipped; a bus with a layout but zero seated
    riders shows `handler_chart.no_passengers_on_bus`.
  - A Double Sofa shared by 3–4 one-way riders emits a separate row per rider.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_SeatRoster`, `_RosterRow`, `_TripBadge`), `lib/utils/phone_dialer.dart`,
  `lib/utils/seat_occupants.dart` (`occupantListForBus`)

---

### UC-07HANDLERTRIPDAY-4: Handler views the visual seat grid and expands fullscreen
- **Actor:** handler
- **Phase:** Trip execution
- **Preconditions:** Chart open, selected bus has a non-empty layout.
- **Steps:**
  1. Tap the **Grid** tab (`handler_chart.view_grid`).
  2. Observe the seat grid with price-band row washes and money dots.
  3. Tap the app-bar expand action (`Icons.open_in_full`,
     `handler_chart.expand_chart`).
- **Expected:**
  - Grid renders booked seats with occupant initials/badges, a per-seat **money
    dot** that is green only when **all** riders on the berth have squared off
    (`seatMoneyStateOf` — one unpaid rider keeps it red).
  - Price-band rows are washed in band colours; a `_PriceBandKey` legend +
    `UgamSeatChartLegend` show below.
  - The expand button opens `FullscreenChartScreen` with the same full occupant
    list per seat (`occupantListForBus`) and pinch-zoom.
- **Edge cases:**
  - Expand action is hidden unless grid view + bus + non-empty layout
    (`canExpand`).
  - Empty layout in grid view → `handler_chart.no_seat_layout` centered text.
  - Bus with no price bands → the band key is hidden (`SizedBox.shrink`).
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_SeatGrid`, `_PriceBandKey`, `_openFullscreenChart`),
  `lib/screens/fullscreen_chart_screen.dart`,
  `lib/utils/seat_money_state.dart`

---

### UC-07HANDLERTRIPDAY-5: Handler collects cash from a single passenger
- **Actor:** handler
- **Phase:** Trip execution / Settlement
- **Preconditions:** Chart open; a seat with exactly one occupant (or a roster
  row, which always targets one rider).
- **Steps:**
  1. Tap an occupied single-occupant seat (grid) or a roster row.
  2. In the `_CollectSheet`, review name + handler badge + age + phone + Call,
     the read-only Seat and Amount due lines.
  3. Enter **Received**, optional **Returned**, optional **Collected by** /
     **Note**.
  4. Tap **Save**.
- **Expected:**
  - The live balance pill updates as you type: `balance_change` (warm) when over,
    `balance_still_to_collect` (danger) when under, `balance_settled` (good) at 0.
  - Save calls `handlerUpsertCollection`; the server-returned row is cached
    keyed `passengerId|busId|seatId`, the sheet pops, and the money hero +
    seat dot + roster status refresh without a reload.
  - "In hand" increases by net collected (received − returned).
- **Edge cases:**
  - Save RPC returns null / throws → `handler_chart.error_save_collection`
    toast; sheet stays open, `_saving` resets.
  - A one-way rider shows a half-fare note (`handler_chart.half_fare_note`) +
    a GO/RET ½ leg pill — the due is already halved by `amountDueForSeat`.
  - Returned > received over-refund is allowed (balance pill goes warm /
    "change to return").
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_showOccupantSheet`, `_CollectSheet`), `lib/models/collection.dart`,
  `lib/services/customer_requests_store.dart` (`handlerUpsertCollection`)

---

### UC-07HANDLERTRIPDAY-6: Handler collects on a shared seat via the leg-scoped chooser
- **Actor:** handler
- **Phase:** Trip execution / Settlement (esp. Return leg)
- **Preconditions:** A Double/Single sofa seat shared by riders across legs
  (e.g. an outbound-only + a return-only, or a round-trip + a one-way rider).
- **Steps:**
  1. Tap the shared seat in the grid → `_showOccupantChooser` opens
     (`handler_chart.seat_shared_title`).
  2. If the seat is leg-split, use the **GO / Return** toggle to switch the
     shown riders.
  3. Pick a rider (each row has phone + Call) → their `_CollectSheet` opens.
  4. Collect as in UC-5.
- **Expected:**
  - When the seat genuinely differs by leg (`seatHasLegSplit`), a GO/Return
    toggle appears and the list cross-fades; otherwise all riders are listed
    with no toggle.
  - Default leg = RETURN when the agent has finished the outbound leg
    (`outboundDone` = any passenger `journeyDone`) or no rider on the seat
    travels GO; else GO (`defaultCollectLeg`).
  - The seat-level money dot stays red until EVERY rider on the berth is squared.
- **Edge cases:**
  - A whole double held solo by one round-trip rider de-dupes to a single
    occupant → no chooser (goes straight to the collect sheet).
  - A double held by two one-way GO riders (nobody on RET) → list, no toggle.
  - This leg-scoped chooser is popup-only by design — it is NOT applied to the
    roster, grid totals, or money hero.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_showOccupantChooser`, `_OccupantChooserSheet`, `_LegSharedTile`),
  `lib/utils/seat_occupants.dart`
  (`CollectLeg`, `seatHasLegSplit`, `occupantsForCollectLeg`, `defaultCollectLeg`)

---

### UC-07HANDLERTRIPDAY-7: Handler marks attendance (boarding) per leg
- **Actor:** handler
- **Phase:** Trip execution
- **Preconditions:** Chart open; selected bus has riders expected on the chosen
  leg.
- **Steps:**
  1. Tap the **Attendance** tab (`handler_chart.view_attendance`).
  2. Use the GO / Return toggle (`att_leg_go` / `att_leg_ret`) to pick the leg.
  3. Flip the present/left-behind Switch on a passenger row.
- **Expected:**
  - Header tally shows **Present / Left behind / Total** (`att_present`,
    `att_left_behind`, `att_total`) plus an `att_tally` line; the GO/RET chips
    under the money hero (`_BoardedSummary`) reflect the same counts in every view.
  - Toggling persists via `handlerUpsertAttendance`; the server row is cached
    keyed `passengerId|busId|leg` so the tally updates without a reload.
  - The roster for the chosen leg lists only passengers whose trip uses that leg
    (`_expectedForLeg`: GO = `usesOutbound`, RET = `usesReturn`).
- **Edge cases:**
  - **Unmarked = not boarded** in the handler tally — `_isPresent` defaults to
    `false` (no row), so a fresh leg shows Present = 0 even though the model's
    raw default is `present = true`.
  - No expected passengers on the leg → `handler_chart.att_none` empty text.
  - Save fails → `handler_chart.error_save_attendance` toast; the Switch reverts
    on next rebuild (cache not updated).
  - A rider holding multiple seats on the bus shows all seat ids joined; counts
    them once (deduped by passenger id).
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_AttendanceView`, `_AttendanceRow`, `_togglePresent`, `_BoardedSummary`),
  `lib/models/attendance.dart`,
  `lib/services/customer_requests_store.dart` (`handlerUpsertAttendance`)

---

### UC-07HANDLERTRIPDAY-8: Handler logs a ground expense (fuel/toll/food)
- **Actor:** handler
- **Phase:** Trip execution / Settlement
- **Preconditions:** Chart open (Grid or List view shows the Expenses section).
- **Steps:**
  1. Scroll to **Bus expenses** (`handler_chart.bus_expenses`); tap **Add**.
  2. In `_ExpenseSheet`, pick a category chip (busOwner is excluded), enter
     "What for", **Amount**, optional "Paid by".
  3. Tap **Save expense**.
- **Expected:**
  - Save calls `handlerUpsertExpense`; the row is cached, the ledger row appears,
    the section total updates, and the **In hand** hero drops by the amount
    (spent subtracts).
  - Each ledger row shows category chip, label (or category fallback), optional
    "paid by", amount, and a delete glyph.
- **Edge cases:**
  - Amount ≤ 0 → `handler_chart.error_amount_zero` toast, no save.
  - Save fails → `handler_chart.error_save_expense` toast, sheet stays open.
  - The bus-owner rent is NEVER selectable here (single source of truth =
    `Bus.busPrice`, settled by the admin), so it cannot be double-counted.
  - Empty ledger shows `handler_chart.no_expenses`.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_ExpensesSection`, `_HandlerExpenseRow`, `_ExpenseSheet`, `_showExpenseSheet`),
  `lib/models/expense.dart`,
  `lib/services/customer_requests_store.dart` (`handlerUpsertExpense`)

---

### UC-07HANDLERTRIPDAY-9: Handler edits or deletes a logged expense
- **Actor:** handler
- **Phase:** Trip execution / Settlement
- **Preconditions:** At least one handler-logged expense exists on the bus.
- **Steps:**
  1. Tap an expense row → edit sheet opens pre-filled.
  2. Change the amount/category and **Save** (reuses same id via `copyWith`).
  3. Or tap the trash glyph on a row to delete.
- **Expected:**
  - Edit updates the same row (id preserved); totals + hero refresh.
  - Delete shows a confirm dialog (`delete_expense_title` +
    `delete_expense_msg_label` / `..._msg_category`) gated by
    `app.action.delete`; on confirm `handlerDeleteExpense` removes it locally and
    server-side.
- **Edge cases:**
  - Delete returns false / throws → `handler_chart.error_delete_expense` toast,
    row stays.
  - Cancelling the confirm leaves the row untouched.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_deleteExpense`, `_showExpenseSheet`),
  `lib/services/customer_requests_store.dart` (`handlerDeleteExpense`)

---

### UC-07HANDLERTRIPDAY-10: Handler logs extra income (cabin / gallery / other)
- **Actor:** handler
- **Phase:** Trip execution / Settlement
- **Preconditions:** Chart open; Income section visible.
- **Steps:**
  1. Scroll to **Bus income** (`handler_chart.bus_income`); tap **Add**.
  2. In `_IncomeSheet`, pick a category (cabin / gallery / other), enter label,
     **Amount**, optional "Received by".
  3. Tap **Save income**.
- **Expected:**
  - Save calls `handlerUpsertIncome`; the row caches, the ledger + total update,
    and **In hand** INCREASES by the amount (income adds, unlike an expense).
  - Income amounts render in the "good" (green) tone.
- **Edge cases:**
  - Amount ≤ 0 → `handler_chart.error_amount_zero` toast.
  - Save fails → `handler_chart.error_save_income`; delete fail →
    `handler_chart.error_delete_income`.
  - Empty ledger shows `handler_chart.no_income`.
  - This income is read-only on the ADMIN money screen (handler logs it on the
    ground; admin only views it — see UC-15).
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_IncomeSection`, `_HandlerIncomeRow`, `_IncomeSheet`, `_showIncomeSheet`,
  `_deleteIncome`), `lib/models/income_entry.dart`,
  `lib/services/customer_requests_store.dart`
  (`handlerUpsertIncome`, `handlerDeleteIncome`)

---

### UC-07HANDLERTRIPDAY-11: Handler reads the "In hand" money summary and breakdown
- **Actor:** handler
- **Phase:** Settlement
- **Preconditions:** Chart open; some collections / income / expenses exist.
- **Steps:**
  1. Read the money hero (`_SummaryHeader` → `UgamHeroStat`,
     label `handler_chart.stat_in_hand`).
  2. Tap the chevron to reveal the breakdown.
- **Expected:**
  - Headline value = `inHand` = **collected + income − spent** (rent excluded).
  - Secondary line restates collected (`in_hand_secondary`).
  - Breakdown lines: Collected (good), To collect (accent), To return (warm),
    Income (good), Spent (warm).
  - Totals come from `HandlerBusMoney.compute` on `BusMoneySummary` so they MATCH
    the admin's board.
- **Edge cases:**
  - **Seat-agnostic correctness:** a rider who paid then moved seats keeps their
    cash in `collected` and is NOT re-added to `toCollect` (rows summed by
    `bus_id`, passenger ids deduped against open collections).
  - Riders with no collection row yet still add their full (leg-adjusted) fare to
    `toCollect`.
  - Multi-bus tour: only the selected bus's figures show; switching the bus pill
    recomputes for that bus.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_SummaryHeader`, `_summaryForBus`), `lib/models/handler_bus_money.dart`,
  `lib/models/money_summary.dart`, `test/models/handler_bus_money_test.dart`

---

### UC-07HANDLERTRIPDAY-12: Handler broadcasts a free-text message to their bus
- **Actor:** handler
- **Phase:** Trip execution
- **Preconditions:** Chart loaded with a bus selected (any view mode).
- **Steps:**
  1. Tap the app-bar campaign icon (`bus_message.message_bus`).
  2. In `_HandlerBusMessageSheet`, type a message (no bus picker — scoped to the
     handler's own bus).
  3. Tap **Send**.
- **Expected:**
  - Send calls `WhatsAppCloudService.sendBusMessageAsHandler` (Edge Function
    re-verifies the caller is this bus's handler) to every seated passenger.
  - All sent → success toast (`bus_message.sent_title` / `..._sent_body` with
    count). Partial → warning (`partial_title` / `partial_body` with sent/failed).
    None → error (`bus_message.failed_body`). Sheet pops on success.
- **Edge cases:**
  - Empty text → `bus_message.empty_text` toast, no send.
  - The campaign action is hidden until a bus is loaded (`canMessage`).
  - A handler can only ever message their own bus(es) — no cross-bus reach.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_openBusMessageComposer`, `_HandlerBusMessageSheet`),
  `lib/services/whatsapp_cloud_service.dart`,
  `lib/components/bus_message_composer_field.dart`

---

### UC-07HANDLERTRIPDAY-13: Handler reads bus departure + contacts the driver
- **Actor:** handler
- **Phase:** Trip execution
- **Preconditions:** Chart open; bus has a boarding point / time and/or a driver.
- **Steps:**
  1. Read the `_BusDeparture` header (`<boardingPoint> · <HH:MM>`).
  2. In `_DriverContact`, tap **Call** or **WhatsApp** on the driver.
- **Expected:**
  - Departure line shows place + time; either half omitted when empty, hidden
    entirely when both empty.
  - Driver call → `PhoneDialer.call`; WhatsApp → `WhatsAppService.openChat`.
- **Edge cases:**
  - Driver with no name → `handler_chart.driver_unnamed`; with no phone → only
    the name shows (no call/WA buttons).
  - No driver name AND no phone → the whole driver card is hidden.
  - WhatsApp open fails → `handler_chart.wa_open_failed`; throws →
    `handler_chart.wa_open_error`.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_BusDeparture`, `_DriverContact`), `lib/services/whatsapp_service.dart`,
  `lib/utils/phone_dialer.dart`, `lib/utils/time_format.dart`

---

### UC-07HANDLERTRIPDAY-14: Admin collects per-passenger cash on the Collection screen
- **Actor:** admin
- **Phase:** Settlement (admin-side mirror of the handler collect flow)
- **Preconditions:** Admin in a tour's money flow; a bus has seated passengers.
  `MoneyController` is registered.
- **Steps:**
  1. From `BusMoneyScreen`, tap the sticky **Collect from passengers** CTA
     (`bus_money.collect_from_passengers`).
  2. On `CollectionScreen`, filter via **All / To return / To collect** pills.
  3. Tap a row → numbered settle sheet (`UgamAmountSheet`): enter Received,
     optional Returned / Collected by / Note; **Save**.
  4. Or tap **Mark paid** on a shortfall row for one-tap full settlement.
- **Expected:**
  - One line per **distinct seat** a passenger holds on the bus (a whole double
    sofa stored as two entries on one seatId collapses to ONE line — no double
    count); `amountDueForSeat` already charges the full sofa.
  - Status chip resolves: return-due (warm) → due/shortfall (accent) →
    paid (good) → not collected (neutral).
  - Save / Mark-paid call `controller.upsertCollection`; the pinned summary
    (`To collect`, `Collected`, `To return`) and rows refresh live via `Obx`.
- **Edge cases:**
  - Filter "To collect" with everything settled → `collection.empty_no_match`.
  - One-way passenger shows a trip label (`trip_outbound_only` /
    `trip_return_only`) and a halved due.
  - Mark-paid records the full due as received with no refund (squares the line).
- **Screens/files:** `lib/screens/collection_screen.dart`,
  `lib/screens/bus_money_screen.dart`, `lib/controllers/money_controller.dart`,
  `lib/models/collection.dart`

---

### UC-07HANDLERTRIPDAY-15: Admin records the bus cash handover from the handler
- **Actor:** admin
- **Phase:** Settlement
- **Preconditions:** Admin on `BusMoneyScreen` for a bus; the handler has
  collected cash / logged income/expenses (so `expectedHandover` is non-zero).
- **Steps:**
  1. Read the **Outstanding handover** hero (`_OutstandingHero`) — the one action
     number — over the demoted Collected / Income / Expenses tiles.
  2. Tap **Record** on the Handover section (`bus_money.action_record`).
  3. In the sheet, the **Expected** billboard pre-fills; adjust **Handed over**
     and optional **Note**; **Save**.
  4. Review the rollup card (`_TourRollupCard`).
- **Expected:**
  - Expected handover = `collected + income − (expenses − busRent)` (rent
    excluded; admin pays the owner). Outstanding = expected − handed over.
  - Save calls `controller.recordHandover`; the handover row lists
    `handed_of` amount + locale-aware date; the hero settles toward 0 and turns
    to the calm "good" tone when fully square.
  - The bus-owner rent shows as a fixed, non-deletable top row in the expense
    ledger (`_BusOwnerRentRow`); handler-logged income is read-only here.
- **Edge cases:**
  - Handover can be EDITED later (`recordHandover` upserts by id) or swiped to
    delete (confirm: `delete_handover_title` / `..._body`).
  - Empty handover list → `bus_money.handover_empty`; empty expenses with
    `busPrice ≤ 0` → `bus_money.expenses_empty`.
  - Deleting an expense/handover is gated by a destructive confirm; the
    controller rolls back + toasts on failure.
- **Screens/files:** `lib/screens/bus_money_screen.dart`
  (`_OutstandingHero`, `_HandoverRow`, `_openHandoverSheet`, `_TourRollupCard`),
  `lib/models/bus_handover.dart`, `lib/models/money_summary.dart`,
  `lib/controllers/money_controller.dart`

---

### UC-07HANDLERTRIPDAY-16: Customer-with-a-seat sees only their own seats (not the handler chart)
- **Actor:** customer
- **Phase:** Trip execution (negative / permission-gating)
- **Preconditions:** A plain passenger (not the tour's handler) uses Find My Seat
  or My Requests.
- **Steps:**
  1. In Find My Seat, enter a non-handler phone and search.
  2. Open the resulting ticket card.
- **Expected:**
  - The ticket card shows the tour header, passenger name, "your seats" chip, and
    a bus diagram where ONLY the rider's own seats are highlighted; every other
    seat is rendered anonymous (`anonymous: true`, `mine` only on own seats).
  - **No** "Manage as handler" CTA appears (`handlerRequestId` is null) — the
    full manifest is never exposed.
- **Edge cases:**
  - Even if a customer somehow opens `HandlerBusChartScreen` with a non-handler
    requestId, the server RPCs (`handler_tour_manifest`, `handler_upsert_*`)
    refuse: manifest returns null → `no_bus_chart` empty state; upserts return
    null → save-error toasts.
  - Layout missing on a bus → `find_seat.layout_unavailable`.
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`
  (`_TicketCard`, `_BusDiagram`), `lib/services/customer_requests_store.dart`
  (`isRequestHandler`, SECURITY DEFINER RPCs)

---

### UC-07HANDLERTRIPDAY-17: Handler switches app language mid-trip
- **Actor:** handler
- **Phase:** Trip execution (localization)
- **Preconditions:** Chart open in any view; language switch available
  (en / gu / hi).
- **Steps:**
  1. Change the app language.
  2. Return to the handler chart.
- **Expected:**
  - All chrome re-localizes: tab labels, money hero + breakdown, attendance
    tally, expense/income categories, band key, collect sheet, driver/departure,
    and snackbars — every string under `handler_chart.*`, `collection.*`,
    `bus_money.*`, `find_seat.*`, `bus_message.*`.
  - The synthesized rear band's English sentinel `'Rear'` re-localizes to
    `handler_chart.band_rear` at render; empty band labels →
    `handler_chart.band_unnamed`.
- **Edge cases (string-parity notes):**
  - Any NEW string added to these flows MUST be added to all three JSON files —
    a missing key renders the raw key and fails 3-file parity.
  - Money amounts use `Formatters.formatMoneyInr` (INR formatting), independent
    of locale text.
- **Screens/files:** `assets/translations/en.json`, `gu.json`, `hi.json`;
  `lib/screens/handler_bus_chart_screen.dart`,
  `lib/screens/collection_screen.dart`, `lib/screens/bus_money_screen.dart`,
  `lib/screens/find_my_seat_screen.dart`

---

### UC-07HANDLERTRIPDAY-18: Return-leg collection after the outbound is done
- **Actor:** handler
- **Phase:** Return-leg phase / Settlement
- **Preconditions:** The agent has completed the outbound (GO) leg — some
  passengers are `journeyDone`. A return-only or shared-leg seat exists.
- **Steps:**
  1. Open the chart; tap a shared seat that has return riders.
  2. The chooser opens defaulting to the **Return** leg.
  3. Collect from a return rider.
- **Expected:**
  - `_showOccupantChooser` detects `outboundDone` (any `journeyDone`) and seeds
    the chooser's default leg to RETURN (`defaultCollectLeg`).
  - GO-only riders who are journeyDone are no longer the focus; the handler
    collects from riders still aboard for the return.
  - The attendance tab likewise lets the handler mark the RET leg independently
    of GO.
- **Edge cases:**
  - A seat with only GO riders (no return riders) and `outboundDone` → chooser
    opens on RETURN but lists no one for that leg (handler toggles back to GO to
    see history).
  - Return-only riders pay a halved fare (one-way) — the collect sheet shows the
    RET ½ leg pill + half-fare note.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart`
  (`_showOccupantChooser`, `_OccupantChooserSheet`),
  `lib/utils/seat_occupants.dart` (`defaultCollectLeg`), `lib/models/passenger.dart`
  (`journeyDone`, `tripType`)
