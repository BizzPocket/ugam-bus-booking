# Use Cases — Money Collection, Per-Bus Settlement, Finance, P&L, Return Ticket (Money Track)

Area: Money / Settlement lifecycle track of **occubusbooking**.

These use cases are grounded in the actual current code. Money is keyed strictly per
**collection row scoped to `bus_id`** — never matched to a rider's *current* seat (a
rider who paid then changed seats keeps their collection row on the OLD seat). Bus
owner **rent (`Bus.busPrice`) is the single source of truth**: it is auto-folded into
every expense total as a synthetic `busOwner` line and is **never** a DB expense row,
yet it is **excluded from the handover expectation** (the admin pays the owner
directly, the handler hands over the full cash they hold).

Key money math (from `lib/models/money_summary.dart`, `collection.dart`, `handler_bus_money.dart`):
- `Collection.netCollected = amountReceived − amountRefunded`
- `Collection.balance = received − refunded − amountDue` → `changeToReturn` (+) / `stillToCollect` (−)
- Admin per-bus `expectedHandover = collected + income − (expensesTotal − busRent)`
- Admin per-bus `outstandingHandover = expectedHandover − handedOver`
- `netBilled = revenueBilled + income − expensesTotal` (TRUE profit; accrual)
- `netCollected = collected + income − expensesTotal` (cash profit; rent subtracted)
- Handler `inHand = collected + income − spent` (spent = ground expenses only, `busRent: 0`)

Two distinct surfaces exist:
- **ADMIN money screens** (read/write via `MoneyController` + `SyncService`): `TourMoneyBoardScreen` → `BusMoneyScreen` → `CollectionScreen`; `TripPnlScreen`; cross-tour `FinanceScreen`.
- **HANDLER money** (read/write via `CustomerRequestsStore` handler RPCs): `HandlerBusChartScreen` — collects, logs expenses & income, sees "in hand"; cannot settle the owner, cannot record handovers, never sees rent.

All user-facing strings here use `easy_localization` `tr('ns.key')`; the namespaces
`bus_money`, `collection`, `tour_money_board`, `trip_pnl`, `finance`,
`handler_chart`, `enums.expense_category`, `enums.income_category` exist in
`assets/translations/{en,gu,hi}.json` and **must keep 3-file parity** for any new string.

---

### UC-06MONEYCOLLECTIONSETTLEMENT-1: Admin records a passenger's full cash payment via the collection sheet
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** A tour exists with at least one bus and a passenger seated on it. Admin is on the per-bus `CollectionScreen` (reached via Tour Money Board → bus row "Collect", or Bus Money screen → "Collect from passengers" CTA).
- **Steps:**
  1. Observe the pinned summary header: hero "To collect" figure plus inline "Collected" and "To return" chips.
  2. Tap a passenger row whose status chip reads "Not collected" (or the accent "Due ₹X" chip).
  3. In the numpad-first `UgamAmountSheet`, the "Amount due" is prefilled as context; enter the cash received equal to the due amount.
  4. (Optional) Expand details and fill "Returned to customer", "Collected by", and "Note".
  5. Tap Save.
- **Expected:**
  - A `Collection` row is upserted (`amountReceived = due`, `amountRefunded = entered`), persisted via `MoneyController.upsertCollection` → `SyncService.smartInsert/Update`.
  - The row's chip flips to the green "Paid" state; `balance == 0` and `received > 0`.
  - The summary header recomputes live (Obx): "To collect" drops, "Collected" rises; if everything is squared the hero figure tone switches from accent to `good`.
  - Figures use INR tabular formatting (`Formatters.formatMoneyInr`).
- **Edge cases:**
  - Save with `received == null` (sheet dismissed): no write, row unchanged.
  - Overpayment (received > due): `balance > 0` → row shows warm "Return ₹X" chip and feeds "To return" total.
  - Underpayment (0 < received < due): `balance < 0` → accent "Due ₹X" chip, "Mark paid" button still shown.
  - Server write fails: controller calls `refreshForTour`, shows `errors.save_collection` toast, and rethrows (optimistic row rolled back).
  - All chip labels (`collection.chip_paid/chip_due/chip_return/chip_not_collected`) must exist in en/gu/hi.
- **Screens/files:** `lib/screens/collection_screen.dart`, `lib/controllers/money_controller.dart`, `lib/models/collection.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-2: Admin one-taps "Mark paid" to settle a shortfall row
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** On `CollectionScreen`, a passenger row is in shortfall (`balance < 0` — either no collection yet, or partial payment).
- **Steps:**
  1. Locate the row showing the tonal "Mark paid ₹{shortfall}" button beneath its metrics.
  2. Tap "Mark paid".
- **Expected:**
  - `_markPaid` upserts a `Collection` with `amountReceived = due`, `amountRefunded = 0`, `amountDue = due` (reuses the exact shape the detail-sheet Save builds — no separate money math).
  - Row squares to "Paid"; the button disappears (only shown while `isShortfall`).
  - Summary "To collect" decreases by the shortfall.
- **Edge cases:**
  - Button is hidden entirely when the row is already square or in "return due".
  - For a row with no existing collection, a fresh `Collection` is created (base `??` new).
  - `collection.mark_paid` (with `{amount}` arg) must be localized in all 3 files.
- **Screens/files:** `lib/screens/collection_screen.dart` (`_markPaid`, `_PassengerRow`), `lib/models/collection.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-3: Admin filters the collection roster by To return / To collect
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** On `CollectionScreen` with a mix of paid, owing, and over-paid passengers.
- **Steps:**
  1. The filter pills default to "All" (index 0).
  2. Tap "To return" (index 1).
  3. Tap "To collect" (index 2).
- **Expected:**
  - "To return" shows only rows where `col != null && col.isReturnDue` (overpaid).
  - "To collect" shows rows where `col == null || col.balance < 0` (never-collected or short).
  - When a filter has no matches the `UgamEmpty` "No match" empty state renders.
- **Edge cases:**
  - A brand-new tour with passengers but zero collections: "To collect" lists everyone; "To return" is empty.
  - Whole double-sofa stored as two assignment entries on one `seatId` must produce **one** line (iterate distinct `seatId`, not per assignment entry) — verify no duplicate/double-counted rows.
  - `collection.filter_all/filter_to_return/filter_to_collect`, `collection.empty_no_match` localized x3.
- **Screens/files:** `lib/screens/collection_screen.dart` (`_passesFilter`, `_seatLines`)

### UC-06MONEYCOLLECTIONSETTLEMENT-4: Admin views the per-bus money cockpit (outstanding handover hero)
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** Tour with a bus that has collections, optional expenses/income/handovers, and a non-zero `busPrice`.
- **Steps:**
  1. Open `BusMoneyScreen` for the bus (from the Tour Money Board row, tapping the bus body).
  2. Read the hero "Outstanding" figure and the "Expected handover" caption beneath it.
  3. Scan the demoted stat grid: Collected, Income, Expenses.
  4. Scroll to the Expenses ledger, Extra income (read-only), Handover list, and Tour rollup hero.
- **Expected:**
  - Hero = `summary.outstandingHandover`; settles to `good` tone when `|outstanding| <= 0.005`, else accent.
  - "Expenses" stat = `expensesTotal` which **includes** the auto bus-owner rent.
  - If `busPrice > 0`, a fixed non-deletable "Bus owner rent" row appears at the top of the ledger (derived from `Bus.busPrice`, no delete/edit affordance).
  - "Extra income" section is **read-only on the admin side** (handler-logged cabin/gallery/other) — no add/edit controls.
  - Tour rollup hero shows `totalNet` with breakdown lines (collected, income, expenses, outstanding, to-return).
- **Edge cases:**
  - `busPrice <= 0 && expenses.isEmpty` → expenses `UgamEmpty` state.
  - No income rows → income `UgamEmpty` state.
  - No handovers → handover `UgamEmpty` state.
  - `bus_money.*` strings (stat labels, section headers, rollup captions, `bus_owner_rent`) localized x3.
- **Screens/files:** `lib/screens/bus_money_screen.dart`, `lib/models/money_summary.dart`, `lib/controllers/money_controller.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-5: Admin adds and edits a bus expense (busOwner category excluded)
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** On `BusMoneyScreen` for a bus.
- **Steps:**
  1. Tap "Add" on the Expenses section header.
  2. In the numpad-first sheet, pick a category from the pill rail (driver / fuel / food / toll / other).
  3. Enter the amount on the numpad; expand "Details" to set Label and Paid by.
  4. Tap "Save expense".
  5. Re-open the row by tapping it; change the amount; save again.
- **Expected:**
  - On add, `Expense` is inserted via `MoneyController.upsertExpense`; the ledger and the "Expenses" stat + tour rollup recompute live.
  - Editing reuses the same `id` (via `copyWith`), so it is an UPDATE not a new row.
  - The CTA is disabled until `amount > 0`.
  - The category rail **never offers "Bus owner"** (`busOwner` filtered out) — manual rent would double-count against `Bus.busPrice`.
- **Edge cases:**
  - Swipe-left on an expense row → confirm dialog (`delete_expense_title/body`) → `deleteExpense`; cancel leaves it.
  - Delete server failure: controller refreshes from server and shows error toast; the screen swallows the rethrow.
  - `bus_money.add_expense/edit_expense/save_expense/field_*/expense_details` + `enums.expense_category.*` localized x3.
- **Screens/files:** `lib/screens/bus_money_screen.dart` (`_openExpenseSheet`, `_ExpenseSheetBody`), `lib/models/expense.dart`, `lib/controllers/money_controller.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-6: Admin records a cash handover from the handler
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** On `BusMoneyScreen` for a bus with a non-zero expected handover.
- **Steps:**
  1. Tap "Record" on the "Handover to admin" section.
  2. The sheet shows the read-only "Expected" billboard (`expectedHandover`) and prefills the "Handed over" field with that expected value.
  3. Accept or override the handed-over amount; add an optional note.
  4. Tap "Save handover".
- **Expected:**
  - A `BusHandover` row is inserted (`expectedAmount`, `handedOverAmount`, `note`, `settledAt = now`) via `recordHandover`.
  - The hero "Outstanding" drops by the handed amount (`outstandingHandover = expected − handedOver`).
  - The handover appears in the list as "Handed ₹X of ₹Y" with a locale-aware date + AM/PM time.
  - When outstanding reaches ~0, hero + Tour Money Board status flip to settled/good.
- **Edge cases:**
  - Multiple partial handovers accumulate (`handedOver` sums all rows).
  - Editing an existing handover reuses its `id` (update); `expectedAmount` is preserved from the existing row.
  - Over-handover (handed > expected): outstanding goes negative; settled epsilon (0.005) still treats near-zero as settled.
  - Rent is NOT part of expected handover — verify a bus with large `busPrice` still expects only `collected + income − groundExpenses`.
  - Swipe-delete a handover → confirm → `deleteHandover`.
  - `bus_money.record_handover/edit_handover/field_expected/field_handed_over/save_handover/handed_of` localized x3.
- **Screens/files:** `lib/screens/bus_money_screen.dart` (`_openHandoverSheet`, `_HandoverRow`), `lib/models/bus_handover.dart`, `lib/models/money_summary.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-7: Admin scans the Tour Money Board and reads per-bus attention states
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** Tour with multiple buses in differing money states (one settled, one with outstanding handover, one untouched).
- **Steps:**
  1. Open the Tour Money Board (Dashboard quick action, tour-detail money card, or `AppRoutes.tourMoney` deep-link).
  2. Read the P&L entry card at top (TRUE net billed preview + Profit/Loss label).
  3. Scan each per-bus row's headline action number, the collected/handover pills, the status dot, and the income "+₹X" line.
  4. Read the sticky bottom totals capsule (outstanding hero + collected + net pills).
- **Expected:**
  - Each row's state via `stateForBusSummary`: **actionNeeded** (warm ring) when `outstandingHandover > eps` OR `toCollect > eps`; **settled** (good ring) when money moved and nothing outstanding/to-collect/to-return; **neutral** when nothing happened.
  - Action headline shows outstanding handover when present, else still-to-collect.
  - "+₹X Income" line only shows when `summary.income > 0.005`.
  - Totals capsule status dot reads "All settled"/"Open"; net = `totalNet`.
- **Edge cases:**
  - Tour with zero buses → `tour_money_board.no_buses` empty state, no totals capsule.
  - Unknown/deleted tour id → `tour_money_board.tour_not_found`.
  - A bus where money is collected but a refund is still owed (`toReturn > eps`) is NOT marked settled.
  - Floating-point dust must not flip a fully-square bus to actionNeeded (epsilon 0.005).
  - `tour_money_board.*` (settled / no_activity / handover_due / to_collect_amount / all_settled / open / per_bus / collect) localized x3.
- **Screens/files:** `lib/screens/tour_money_board_screen.dart`, `lib/controllers/money_controller.dart` (`stateForBusSummary`, `summariesForBuses`)

### UC-06MONEYCOLLECTIONSETTLEMENT-8: Money is summed by bus_id, not by current seat (seat-change integrity)
- **Actor:** admin / handler
- **Phase:** Money / Settlement
- **Preconditions:** A passenger paid in full on bus A for seat S1, then was relocated to seat S2 on the same bus (collection row still names S1).
- **Steps:**
  1. Open the per-bus money summary (admin `BusMoneyScreen` and handler `HandlerBusChartScreen` for the same bus).
  2. Compare "Collected" and "To collect" on both surfaces.
- **Expected:**
  - The paid cash stays in "Collected" — `BusMoneySummary.compute` and `HandlerBusMoney.compute` fold collection rows by `c.busId`, never by the rider's current seat.
  - The rider is NOT double-counted into "To collect": `HandlerBusMoney` skips any passenger with ANY collection row on the bus (`collectedPassengerIds`, seat-agnostic).
  - Admin "Collected" and handler "Collected" agree exactly (handler is built on the same `BusMoneySummary`).
- **Edge cases:**
  - Rider moved **across buses**: their collection row stays on the OLD bus_id, so the cash counts for the old bus (rent diff between handler-23k / admin-30k scenario is by design — handler never sees rent).
  - A seated rider with no collection row at all still appears in handler "To collect" (full fare via `dueForSeat`).
  - Regression coverage: `test/models/handler_bus_money_test.dart`.
- **Screens/files:** `lib/models/handler_bus_money.dart`, `lib/models/money_summary.dart`, `lib/screens/bus_money_screen.dart`, `lib/screens/handler_bus_chart_screen.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-9: Handler collects cash from a passenger on the bus chart
- **Actor:** handler
- **Phase:** Money / Settlement
- **Preconditions:** Handler opens their bus chart via `HandlerBusChartScreen` (request-id scoped). A passenger holds a seat with an outstanding fare.
- **Steps:**
  1. In Grid or List (call-first roster) view, tap an occupied seat / roster row for a single rider.
  2. The collect sheet opens with the call header (name + phone + Call) and the money form (due shown).
  3. Enter received cash; optionally returned, collected-by, note.
  4. Save.
- **Expected:**
  - Collection upserts via `CustomerRequestsStore.handlerUpsertCollection`; the server-returned row is cached locally keyed `passengerId|busId|seatId`.
  - The seat's money dot recolors (paid/owing/return-due/uncollected) and the "In hand" hero recomputes.
  - "In hand" = `collected + income − spent` (handler never sees/subtracts rent).
- **Edge cases:**
  - Save rejected by server (`saved == null`): a `StateError` is thrown; verify error handling surfaces (handler-side caches not updated).
  - Seat with no occupant → tap is a no-op (`onTapBooked == null`).
  - A shared seat (multiple riders) routes to the chooser instead of straight to the sheet (see UC-12).
  - `handler_chart.collect_title`, money labels, `stat_in_hand/in_hand_secondary` localized x3.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showOccupantSheet`, `_CollectSheet`, `_SummaryHeader`), `lib/models/handler_bus_money.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-10: Handler logs extra Cabin/Gallery/Other income that folds into "in hand"
- **Actor:** handler
- **Phase:** Money / Settlement
- **Preconditions:** On `HandlerBusChartScreen` in Grid or List view (Income section visible).
- **Steps:**
  1. Scroll to the Income section; tap Add.
  2. Choose a category (cabin / gallery / other), enter amount, optional label + received-by.
  3. Save.
- **Expected:**
  - `IncomeEntry` upserts via `handlerUpsertIncome`; cached by id.
  - "In hand" rises by the income amount (`inHand = collected + income − spent`).
  - The same income surfaces **read-only** on the admin `BusMoneyScreen` Income section and as a "+₹X Income" line on the Tour Money Board row, and folds into `netBilled`/`netCollected` and cross-tour finance.
- **Edge cases:**
  - Edit an income entry → reuses id (update); delete → confirm dialog (`delete_income_title/msg_*`) then `handlerDeleteIncome`.
  - Unknown stored category string falls back to `IncomeCategory.other`.
  - Admin cannot add/edit income (no controls on `BusMoneyScreen`) — consolidation note: handler is the single home, admin reflects it.
  - `handler_chart.add_income/edit_income/delete_income_*` and `enums.income_category.*` localized x3.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showIncomeSheet`, `_deleteIncome`, `_IncomeSection`), `lib/models/income_entry.dart`, `lib/screens/bus_money_screen.dart` (`_IncomeRow`)

### UC-06MONEYCOLLECTIONSETTLEMENT-11: Handler logs and deletes a ground expense (no rent, no handover)
- **Actor:** handler
- **Phase:** Money / Settlement
- **Preconditions:** On `HandlerBusChartScreen`, Expenses section visible.
- **Steps:**
  1. Tap Add on the Expenses section; pick category, enter amount, optional label/paid-by; save.
  2. Tap an existing expense to edit; or use delete → confirm.
- **Expected:**
  - Expense upserts via `handlerUpsertExpense`; "Spent" rises and "In hand" drops (`inHand = collected + income − spent`).
  - `HandlerBusMoney` is computed with `busRent: 0`, so "Spent" is the handler's own ground costs only — the owner's rent is never shown to the handler.
  - There is no handover-record affordance on the handler screen (the handler hands physical cash; only the admin records the `BusHandover`).
- **Edge cases:**
  - Delete confirm dialog message branches on whether the expense has a label vs category.
  - Server delete returns false → `error_delete_expense` toast, row stays.
  - `handler_chart.add_expense/edit_expense/delete_expense_*` localized x3.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showExpenseSheet`, `_deleteExpense`, `_ExpensesSection`), `lib/models/handler_bus_money.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-12: Handler collects from a shared seat via the leg-scoped GO/Return chooser
- **Actor:** handler
- **Phase:** Money / Settlement (incl. Return-leg)
- **Preconditions:** A Double Sofa (or shared seat) carries riders on different legs — e.g. an outbound-only rider and a return-only rider, or a round-trip rider sharing with a one-way rider. On `HandlerBusChartScreen`.
- **Steps:**
  1. Tap the shared seat (2+ occupants).
  2. The chooser sheet opens. If the seat is leg-divided, a GO / Return toggle appears.
  3. Read the default-selected leg, switch legs if needed, pick a rider, then collect in the opened sheet.
- **Expected:**
  - The toggle only appears when `seatHasLegSplit(occupants)` is true; a non-divided shared seat lists everyone with no toggle.
  - Default leg = `defaultCollectLeg(occupants, outboundDone)`: once the GO leg is complete (`outboundDone` = any passenger `journeyDone`), the chooser opens on **Return**.
  - Switching the toggle cross-fades the shown occupant list (`occupantsForCollectLeg`).
  - This leg-scoped chooser is **popup-only** — the roster, grid, and totals are NOT leg-split (each rider still gets one row / one money state).
- **Edge cases:**
  - A Double Sofa booked by 3-4 one-way passengers lists all of them (was previously leg-shared-only, now full roster).
  - Each chooser tile carries phone + Call; tapping Call dials without opening the collect sheet.
  - A roster-row tap (single rider) skips the chooser (`onTapSeat(seatId, [p])`).
  - `handler_chart.seat_shared_title/leg_shared_intro/att_leg_go/att_leg_ret` localized x3.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showOccupantChooser`, `_OccupantChooserSheet`), `lib/utils/seat_occupants.dart` (`defaultCollectLeg`, `seatHasLegSplit`, `occupantsForCollectLeg`)

### UC-06MONEYCOLLECTIONSETTLEMENT-13: Admin reads the per-trip P&L (TRUE billed net vs cash net, per handler & per bus)
- **Actor:** admin
- **Phase:** Money / Settlement
- **Preconditions:** Tour with buses, seated passengers (so billed revenue is non-zero), expenses, rent, and some collections. Reached via the Tour Money Board P&L entry card.
- **Steps:**
  1. Open `TripPnlScreen`.
  2. Read the trip total hero: big "Net profit/loss" = `totalNetBilled`, with "Cash collected" net beneath, plus a revenue/costs/collected stat triple.
  3. Scroll to "By handler" cards, then "By bus" cards; each shows billed net (headline) + revenue/costs/cash-net.
- **Expected:**
  - Headline net = `totalNetBilled = totalRevenueBilled + totalIncome − totalExpenses` (accrual; tone good/danger).
  - "Cash collected" line = `totalNet = totalCollected + totalIncome − totalExpenses`.
  - `totalExpenses` already **includes bus rents** (folded as `busRent`); the per-bus subtitle shows "Rent ₹X" but rent is never added again.
  - Per-handler card = sum of that handler's buses' summaries; buses with no handler fall into the "No handler" bucket kept LAST (never dropped).
- **Edge cases:**
  - Tour with buses but no seated passengers → revenueBilled 0; net = −costs (loss), hero danger tone.
  - Income == 0 → income line hidden.
  - Tour not found / no buses → `tour_money_board.tour_not_found` / `no_buses` empty states.
  - A handler running a bus whose passenger paid then moved off it: P&L for that handler/bus uses bus-scoped rows (see UC-8).
  - `trip_pnl.*` (net_profit/net_loss/true_billed/cash_collected/by_handler/by_bus/revenue/costs/collected/rent/profit/loss) localized x3.
- **Screens/files:** `lib/screens/trip_pnl_screen.dart`, `lib/controllers/money_controller.dart` (`handlerSummaries`, `tourSummary`, `_billedRevenues`, `_busRents`), `lib/models/money_summary.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-14: Admin views the cross-tour Finance (P&L) report and switches period
- **Actor:** admin
- **Phase:** Money / Settlement (post-trip reporting)
- **Preconditions:** Admin has at least one COMPLETED tour with money rows. Finance screen reached from Settings.
- **Steps:**
  1. Open `FinanceScreen`; it defaults to the "This month" period.
  2. Read the hero net card (signed net, margin bar, revenue / income / expenses metrics) and the stat triple (tours, avg, best).
  3. Switch the period pills to "This year" then "All time".
  4. Pull-to-refresh; tap a per-tour row.
- **Expected:**
  - `FinanceController.financesFor(period, completedOnly: true)` aggregates `collections` (received − refunded), `expenses`, AND `buses.bus_price` rents and `incomes`, paging past the 500-row sync cap (page size 1000).
  - Net = `revenue + income − expenses`; expenses include every bus rent (or cross-tour P&L would overstate profit).
  - Period filter uses `TourFinance.date = returnDate ?? departureDate` (trip-end), so multi-day trips land in the period they ended.
  - Tapping a row opens that tour's money board (`AppRoutes.tourMoney`).
  - Margin% per row uses gross-in (`revenue + income`) so cabin/gallery cash isn't ignored.
- **Edge cases:**
  - First load shows skeleton (`_Loading`); load failure (and not loaded once) shows `_ErrorState` with a TONAL retry.
  - No completed tours in period → `finance.empty_title/empty_body` empty state.
  - In-progress tours are excluded by default (`completedOnly`); `lifetimeNet` getter feeds the Settings card.
  - Income metric column only renders when `totals.income != 0`.
  - `finance.*` (net_profit/net_loss/revenue/expenses/period_*/per_tour/stat_*/from_tours_one|other/bus_one|other/margin_pct/error_*/empty_*) localized x3.
- **Screens/files:** `lib/screens/finance_screen.dart`, `lib/controllers/finance_controller.dart`, `lib/models/tour_finance.dart`

### UC-06MONEYCOLLECTIONSETTLEMENT-15: Admin adds a return-only ticket during the Return-leg phase (past the lock gate)
- **Actor:** admin
- **Phase:** Return-leg
- **Preconditions:** Tour is locked AND its GO leg is complete (`isReturnPhase == status == locked && goLegCompleted`, i.e. some passenger is `journeyDone`). Outbound-only riders' seats are now free to resell.
- **Steps:**
  1. From the tour-detail Next-action ("Add return ticket") or the return-phase CTA, open `AddReturnTicketSheet`.
  2. Fill the `BookingCaptureForm` (name, phone, seat counts) — every line is forced to `TripType.returnOnly` (`forcedLeg`).
  3. Tap "Add return ticket".
- **Expected:**
  - `TourController.addPassenger(..., overrideLock: true)` books the new return rider **even though the tour is locked** (return phase intentionally locked).
  - New passenger `tripType = returnOnly`; their lines are return-only via `forcedLeg`.
  - Success toast `tour_detail.return_ticket_added` with the name; contact remembered via `UserController.rememberContact`.
  - The new rider is now a pending seat to assign on the return chart; GO-done (`journeyDone`) riders are excluded from pending/engine so no false "allocate N" appears.
  - The new return rider then flows into the money track (handler can collect their return fare; it counts toward the bus's collected).
- **Edge cases:**
  - Invalid form (no seats / bad phone): `collect()` returns null, inline errors shown, no write.
  - Save throws → `requests.snack.add_error` toast; `_saving` resets.
  - Not in return phase: the "Add return ticket" action should not be offered (tour-detail gates on `isReturnPhase`).
  - `maxPerType` capped at 10 per type.
  - `tour_detail.add_return_ticket_title/hint/add_return_ticket/return_ticket_added` localized x3.
- **Screens/files:** `lib/screens/add_return_ticket_sheet.dart`, `lib/screens/tour_detail_screen.dart` (Next-action dispatch ~L2025), `lib/controllers/tour_controller.dart` (`addPassenger`, `completeOutboundLeg`), `lib/models/tour.dart` (`isReturnPhase`)

### UC-06MONEYCOLLECTIONSETTLEMENT-16: Money figures stay correct and localized under language switch and offline conditions
- **Actor:** admin / handler
- **Phase:** Money / Settlement
- **Preconditions:** Any money screen open with real figures.
- **Steps:**
  1. On `CollectionScreen` / `BusMoneyScreen` / `TourMoneyBoardScreen` / `TripPnlScreen` / `FinanceScreen`, switch the app language en → gu → hi (via Settings).
  2. With the device offline, open a money screen that was previously loaded.
  3. Attempt to save a collection/expense/handover while offline.
- **Expected:**
  - All labels (stat captions, section headers, chips, period pills, P&L labels) re-render in the active language; figures remain INR tabular numerals (number formatting is locale-aware where used, dates follow `context.locale.languageCode`).
  - Offline read: `MoneyController.loadForTour` uses `SyncService.smartFetch` (cache); a transient fetch failure leaves previously held rows in place (the money screen does not blank).
  - Offline write: optimistic local mutation shows instantly; if the server write ultimately fails, the controller `refreshForTour`s and shows the matching error toast (`errors.save_collection/save_expense/record_handover` etc.).
- **Edge cases:**
  - Every category enum (`ExpenseCategory`, `IncomeCategory`) and `PaymentStatus` resolves its `displayName` from `tr(...)`; all must exist in en/gu/hi.
  - Handler chart manifest fetch failure → `handler_chart.error_load` / `error_load_title` empty state.
  - A locale with a longer money string must not overflow tabular figures (rows ellipsize, `maxLines: 1`).
- **Screens/files:** `lib/controllers/money_controller.dart`, `lib/screens/*` (all money screens), `lib/utils/formatters.dart`, `lib/models/{expense,income_entry,payment_status}.dart`, `assets/translations/{en,gu,hi}.json`

---

## Notes for the assembler

- **`chart_footer.dart` is NOT a money model.** Despite being in the focus list, `ChartFooter` (boarding place / departure time / handler note) belongs to the **seating-chart footer**, persisted per-tour via `ChartFooterStore`. It carries no money fields and is intentionally not covered by a money use case here — route it to the seat-chart / PDF area.
- **Two write paths, deliberately separate.** Admin money writes go through `MoneyController` + `SyncService` (RLS via tour-owner join). Handler money writes go through `CustomerRequestsStore` handler RPCs scoped by `requestId`. They share the SAME aggregation value objects (`BusMoneySummary`) so admin and handler can never disagree on collected cash.
- **Rent asymmetry is by design** (potential tester confusion): rent is IN the P&L expense total but OUT of the handover expectation; the handler never sees rent at all. A handler "in hand" of ₹23k vs an admin P&L expense view of ₹30k is the documented expected behavior, not a bug.
- **`payment_status.dart`** (`PaymentStatus.paid/notPaid`) is a thin enum with localized `displayName`; the live collection screens derive status from `Collection.balance` rather than this enum, so it is referenced only at the localization-parity level (UC-16).
- **Return phase + money interplay:** `journeyDone` riders are excluded from the engine and pending-seat counts, which keeps the money/collection roster from showing departed GO-only riders as "to collect" on the return leg.
