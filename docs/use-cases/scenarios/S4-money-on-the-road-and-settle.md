# S4 — Cash on the road (handler) & settling up (admin)

Real-world operational ("activation") scenarios for the **Money / Settlement**
lifecycle of **occubusbooking**. These are not unit checks — they are believable
trips a real Gujarati tour agent (Ramesh / Jignesh), an on-bus handler
(Mahesh / Dinesh), and DEVAM / Ugam Foj families live through, end to end, with
messy cash reality: one man paying for his whole family, half-payments,
leg-scoped shared-seat collection, extra cabin/gallery income, fuel & food
expenses, a seat change after payment, a reinstalled phone, and the settlement
night when the agent reconciles handler in-hand against the P&L and pays the bus
owner.

**Ground-truth money math these scenarios rely on** (from `money_summary.dart`,
`handler_bus_money.dart`, `collection.dart`, `bus_details.dart`):

- Cash is summed per **collection row scoped to `bus_id`**, never by a rider's
  *current* seat. A rider who paid then moved keeps their row on the bus.
- `netCollected = received − refunded`; `balance = received − refunded − due`
  → `changeToReturn` (+) / `stillToCollect` (−).
- Handler **`inHand = collected + income − spent`** (spent = ground expenses
  only; `busRent: 0` — the handler never sees rent).
- Admin per-bus **`expectedHandover = collected + income − (expensesTotal −
  busRent)`** — rent is folded INTO `expensesTotal` but pulled back OUT of the
  handover expectation, because the admin pays the owner directly.
- `netBilled = revenueBilled + income − expensesTotal` (TRUE accrual P&L);
  `netCollected = collected + income − expensesTotal` (cash P&L; rent IS
  subtracted here).
- One-way (outbound-only / return-only) seats pay **half** (`tripFactor = 0.5`);
  a **whole double sofa** held by one passenger is ONE collection row at the
  FULL sofa price (`amountDueForSeat`).
- The rent asymmetry (handler "in hand" ₹23k vs admin P&L expense view ₹30k) is
  **by design**, not a bug.

Default app language is **Gujarati**; money renders via `Formatters.formatMoneyInr`
(INR) independent of locale text.

---

### SC-S4MONEYONTHEROADANDSETTLE-1: One man pays for his whole family in cash on the bus
- **Persona & goal:** Mahesh, the handler appointed by agent Ramesh for the 41-seater on a 2-day Somnath–Dwarka trip, needs to collect every fare in cash before the bus reaches the highway dhaba, so he can tell Ramesh "this bus is fully collected."
- **Trigger (the activation):** The bus pulls out of Ahmedabad at 5:30 AM. Mahesh opens his chart and starts walking the aisle row by row.
- **Actors:** Mahesh (handler), the Patel family of 5 (Suresh Patel pays for all of them), Ramesh (agent, off-bus).
- **Phases spanned:** Trip execution → Settlement.
- **Setup / messy data:** The Patels hold 2 double sofas (whole, round-trip) at ₹6,000 each = ₹12,000, plus 1 single sofa (round-trip) at ₹2,500. Total family due ₹14,500. Suresh is the only one with cash; the four others have no separate collection. Suresh's seat is the single sofa; the kids and wife are on the two doubles.
- **The flow:**
  1. Mahesh opens **HandlerBusChartScreen** from his "My Requests" card; it loads in **List** (call-first roster) view with the "In hand" hero at ₹0.
  2. He taps Suresh's single-sofa roster row → `_CollectSheet` opens showing **Due ₹2,500** for that seat. He enters Received ₹2,500, Save. The seat's money dot goes green; "In hand" rises to ₹2,500.
  3. He taps the first Patel **double sofa** (whole, one rider entry → `sole`, no chooser) → sheet shows **Due ₹6,000** (the whole-sofa full price via `amountDueForSeat`, not the ₹3,000 half-berth). Suresh hands ₹6,000 for it. Save.
  4. Same for the second double sofa, ₹6,000. Save.
  5. "In hand" now reads ₹14,500; every Patel seat dot is green.
- **Complications & recovery:** Suresh only has ₹14,000 in notes and is ₹500 short on the single sofa. Mahesh enters Received ₹2,000 on that seat instead of ₹2,500 → the live balance pill flips to **`balance_still_to_collect` (danger)** showing **Due ₹500**; the seat dot stays red. Suresh promises the rest at the dhaba; Mahesh leaves the row short. Later Suresh pays the ₹500 — Mahesh re-opens the same seat, the sheet shows the running due of ₹500, he collects it, and the row squares.
- **Real-world outcome (Expected):** Mahesh can tell Ramesh "Patel family fully paid, ₹14,500." The four other Patels were **never** charged separately — billing is per distinct seat, and the whole double counts once at full price, so there is no double-count. "In hand" = collected ₹14,500 (no income, no spend yet). Each Patel seat dot is green; the seat-level dot only greened once the whole berth squared.
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-5, UC-07HANDLERTRIPDAY-11, UC-06MONEYCOLLECTIONSETTLEMENT-9; whole-double single-row billing per UC-06MONEYCOLLECTIONSETTLEMENT-3 / UC-07HANDLERTRIPDAY-14.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showOccupantSheet`, `_CollectSheet`, `_SummaryHeader`), `lib/models/handler_bus_money.dart`, `lib/models/bus_details.dart` (`amountDueForSeat`), `lib/models/collection.dart`

---

### SC-S4MONEYONTHEROADANDSETTLE-2: Half-payments and an over-payment that owes change back
- **Persona & goal:** Dinesh, handler on the second bus (30-seater) of the same trip, must collect from a crowd where nobody carries exact cash — some pay half now, one elderly man overpays with a ₹2,000 note and is owed change.
- **Trigger (the activation):** Boarding at the Maninagar pickup; people climb on, hand over what they have, and Dinesh logs it on the fly.
- **Actors:** Dinesh (handler); Kanjibhai & Jadiben (elderly couple, two single sofas, round-trip, ₹2,500 each); the Solanki two friends (one double sofa shared, round-trip).
- **Phases spanned:** Trip execution → Settlement.
- **Setup / messy data:** Kanjibhai's seat due ₹2,500; Jadiben's ₹2,500. The two Solankis SHARE one double (each a half-berth round-trip = ₹3,000 each, two separate collection rows on the same seatId). Kanjibhai pays ₹3,000 cash for "both of us" but Dinesh must split it; Jadiben has nothing yet.
- **The flow:**
  1. Dinesh taps Kanjibhai's single-sofa seat → enters Received ₹2,500 → squares; dot green.
  2. Kanjibhai hands a **₹2,000 note** that was meant for Jadiben but says "keep it on my account." Dinesh re-opens Kanjibhai's row and enters Received ₹2,000 ON TOP — now received ₹4,500 vs due ₹2,500 → **`balance_change` (warm)**, the row shows **Return ₹2,000** and feeds the bus "To return" total. Dinesh realizes he should have applied it to Jadiben.
  3. **Recovery:** Dinesh edits Kanjibhai's row back to Received ₹2,500 (Returned ₹0), squaring it, then opens **Jadiben's** row and enters Received ₹2,000 → balance **Due ₹500** (`stillToCollect`). Jadiben pays ₹500 at the next stop → row squares.
  4. The Solanki double: Dinesh taps it; it is a **shared** seat (2 round-trip occupants, no leg split) → the **chooser** lists both with no GO/Return toggle. He collects ₹3,000 from each on their own collection row.
- **Complications & recovery:** One Solanki pays ₹3,000 with a ₹500 tip "for chai" — Dinesh enters Received ₹3,500, due ₹3,000 → **Return ₹500** warm chip; he gives ₹500 back as change and corrects to Received ₹3,000. The seat-level money dot stays **red** until BOTH Solanki rows are squared (`seatMoneyStateOf` greens only when every rider on the berth is settled).
- **Real-world outcome (Expected):** Dinesh's "In hand" reflects exactly the net cash he holds (`received − refunded` per row, summed). No phantom "to return" lingers after he corrects the over-entries. He can tell Ramesh which two riders were short and when they cleared. Observable state: Kanjibhai/Jadiben/both Solanki rows all `isSquare`; bus `toReturnTotal == 0`.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-1 (overpayment/underpayment edges), UC-07HANDLERTRIPDAY-5, UC-07HANDLERTRIPDAY-6 (shared-seat chooser, no toggle), UC-06MONEYCOLLECTIONSETTLEMENT-12.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_CollectSheet`, `_showOccupantChooser`), `lib/models/collection.dart` (`changeToReturn`, `stillToCollect`), `lib/utils/seat_money_state.dart`

---

### SC-S4MONEYONTHEROADANDSETTLE-3: Leg-scoped collection — collect GO fares going out, RETURN fares on the way back
- **Persona & goal:** Mahesh runs a 2-day Diu pilgrimage where several sofas are **leg-shared**: an outbound-only rider going down for a wedding shares a double with a return-only rider coming back from his village. Mahesh must charge the right person for the right leg without double-charging the seat.
- **Trigger (the activation):** Day 1 morning Mahesh collects the GO leg; Day 2 evening, after the outbound is marked done, he collects the RETURN leg from the new occupants of the same physical berths.
- **Actors:** Mahesh (handler); Bharat Chauhan (outbound-only, GO, half fare); Vijay Rathod (return-only, RET, half fare) — both assigned to **double sofa D3** on disjoint legs; plus a round-trip rider on single sofa S2.
- **Phases spanned:** Trip execution (GO) → Return-leg phase → Settlement.
- **Setup / messy data:** D3 berth band price ₹6,000 whole / ₹3,000 half. Bharat (outbound-only) owes ₹3,000 (half). Vijay (return-only) owes ₹3,000 (half). They never meet — Bharat rides down, Vijay rides back. The chart shows D3 as leg-shared (`seatHasLegSplit == true`).
- **The flow:**
  1. **Day 1 (GO active, `outboundDone == false`):** Mahesh taps D3 → `_showOccupantChooser` opens; because the seat is leg-split a **GO / Return toggle** appears and defaults to **GO** (`defaultCollectLeg` → GO). The list shows only Bharat. He collects ₹3,000 from Bharat (RET ½ leg pill + half-fare note shown).
  2. Ramesh later completes the outbound leg from the admin side; some GO-only riders become `journeyDone` → `outboundDone` is now true for the bus.
  3. **Day 2 (RETURN):** Mahesh taps D3 again → the chooser now **defaults to Return** (`defaultCollectLeg` detects `outboundDone`); the list cross-fades to show **Vijay**. He collects ₹3,000 from Vijay.
  4. He confirms the **roster and totals are NOT leg-split** — Bharat and Vijay each still have exactly one money row in the flat roster; only the popup chooser is leg-scoped (popup-only by design).
- **Complications & recovery:** On Day 2 Mahesh taps the toggle back to **GO** by habit and sees Bharat already squared (history) — no double charge, because GO is collected once. A return-only rider boards late at the temple; Mahesh, while still in the chooser, taps **Call** on Vijay's tile to confirm he's coming before collecting — Call dials without opening the collect sheet.
- **Real-world outcome (Expected):** Each physical berth earned its two half-fares (₹3,000 + ₹3,000 = ₹6,000, the whole-sofa value) across two legs without ever charging one person for the other's leg. Mahesh can tell Ramesh "D3 fully paid both legs." Observable: two distinct collection rows on the same `seatId`, both `isSquare`; chooser default flips GO→RET exactly when `journeyDone` appears.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-12, UC-07HANDLERTRIPDAY-6, UC-07HANDLERTRIPDAY-18 (return-leg default), UC-07HANDLERTRIPDAY-5 (half-fare note).
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showOccupantChooser`, `_OccupantChooserSheet`, `_LegSharedTile`), `lib/utils/seat_occupants.dart` (`seatHasLegSplit`, `occupantsForCollectLeg`, `defaultCollectLeg`), `lib/models/bus_details.dart` (`tripFactor`)

---

### SC-S4MONEYONTHEROADANDSETTLE-4: Cabin & gallery income plus fuel/food spend folds into "in hand"
- **Persona & goal:** Dinesh wants his "In hand" hero to match the actual wad of cash in his bag at the end of Day 2 — including the extra ₹400 he charged a family to use the bus's sleeping cabin and the ₹250 for gallery (luggage roof) space, minus what he paid for diesel and the group's dhaba dinner.
- **Trigger (the activation):** Mid-trip a family asks for the rear cabin; Dinesh charges them and logs it. At the dhaba he pays for fuel and food out of the collected cash.
- **Actors:** Dinesh (handler); a family renting the cabin; the diesel pump and dhaba (expenses).
- **Phases spanned:** Trip execution → Settlement.
- **Setup / messy data:** Collected fares so far ₹46,000. Extra income: **Cabin ₹400** (income category `cabin`), **Gallery ₹250** (`gallery`), and a ₹150 "other" tip pooled (`other`). Ground expenses: **Fuel ₹3,000** (`fuel`), **Food ₹1,800** (`food`), **Toll ₹450** (`toll`). The bus owner's rent (₹30,000) is NOT his concern.
- **The flow:**
  1. Dinesh scrolls to **Bus income**, taps Add, picks **Cabin**, amount ₹400, Save → "In hand" rises by ₹400 (income adds; rendered in green/good tone).
  2. Adds **Gallery ₹250** and **Other ₹150** the same way.
  3. At the pump he scrolls to **Bus expenses**, Add → category **Fuel**, "What for" = diesel, amount ₹3,000, Save → "In hand" DROPS by ₹3,000.
  4. Adds **Food ₹1,800** and **Toll ₹450**.
  5. He opens the money breakdown (chevron): Collected ₹46,000, Income ₹800, Spent ₹5,250 → **In hand = 46,000 + 800 − 5,250 = ₹41,550**.
- **Complications & recovery:** Dinesh fat-fingers the food amount as ₹18,000. The "In hand" hero plunges to ₹24,550 — obviously wrong. He taps the food expense row, edits the amount back to ₹1,800 (same id via `copyWith`, an UPDATE not a new row), Save → "In hand" corrects to ₹41,550. He never sees a "Bus owner" category in the expense rail (it is filtered out so rent can't be double-counted).
- **Real-world outcome (Expected):** Dinesh's "In hand" ₹41,550 equals the cash in his bag; he can hand exactly that to Ramesh and they will reconcile. The owner's ₹30,000 rent is invisible to him — by design. Observable: `inHand = collected + income − spent`; income entries in green; no `busOwner` chip in the handler expense sheet.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-10, UC-06MONEYCOLLECTIONSETTLEMENT-11, UC-07HANDLERTRIPDAY-8, UC-07HANDLERTRIPDAY-9, UC-07HANDLERTRIPDAY-10, UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_IncomeSection`, `_ExpensesSection`, `_showIncomeSheet`, `_showExpenseSheet`, `_SummaryHeader`), `lib/models/income_entry.dart`, `lib/models/expense.dart`, `lib/models/handler_bus_money.dart`

---

### SC-S4MONEYONTHEROADANDSETTLE-5: A rider pays, then gets moved seats — cash must not vanish
- **Persona & goal:** Ramesh (agent) gets a panicked WhatsApp: "Mahesh says my husband paid but the app shows him owing again!" Ramesh must confirm the cash is safe and that the figures the handler and he both see agree.
- **Trigger (the activation):** Mid-trip seat shuffle — a rider who already paid on seat **A11** is relocated to **A14** (same bus) because a window seat opened up his elderly mother wanted.
- **Actors:** Ramesh (agent); Mahesh (handler); Jayesh Makwana (round-trip rider who paid ₹2,500 on A11, then moved to A14).
- **Phases spanned:** Trip execution → Settlement (seat-change integrity).
- **Setup / messy data:** Jayesh's collection row was written for seat **A11** (received ₹2,500, squared). Ramesh then drags Jayesh from A11 to A14 on the seating chart. The collection row STILL names A11; A14 has no collection row.
- **The flow:**
  1. Ramesh opens the admin **BusMoneyScreen** for the bus: "Collected" still includes Jayesh's ₹2,500; the per-bus summary sums collection rows **by `bus_id`**, not by current seat (`BusMoneySummary.compute`).
  2. Mahesh opens his **HandlerBusChartScreen**: "In hand" still includes Jayesh's ₹2,500, and Jayesh is **not** re-listed in "To collect" — `HandlerBusMoney` skips any passenger who has ANY collection row on the bus (`collectedPassengerIds`, seat-agnostic).
  3. Ramesh and Mahesh compare "Collected" on both screens — they agree exactly (handler is built on the same `BusMoneySummary`).
  4. Ramesh reassures the wife: the cash is logged and safe.
- **Complications & recovery:** Mahesh, confused, taps the NEW seat **A14** to "collect again." The collect sheet shows Jayesh's due — but Mahesh notices the roster money line for Jayesh already reads **Paid**. He closes the sheet without collecting; no double row is created. Had he saved, it would have created a second row and shown an over-collection — but the roster status (seat-agnostic) warned him first.
- **Real-world outcome (Expected):** Ramesh can confidently tell the family "fully paid, nothing owed." Cash never moved off the bus's total just because the seat changed. Observable: collection row keyed to old seat A11; "Collected" identical on admin and handler; Jayesh absent from "To collect." (Regression: `test/models/handler_bus_money_test.dart`.)
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-8, UC-07HANDLERTRIPDAY-11 (seat-agnostic correctness), UC-06MONEYCOLLECTIONSETTLEMENT-9.
- **Screens/files:** `lib/models/handler_bus_money.dart`, `lib/models/money_summary.dart`, `lib/screens/bus_money_screen.dart`, `lib/screens/handler_bus_chart_screen.dart`

---

### SC-S4MONEYONTHEROADANDSETTLE-6: Settlement night — handler hands over the bag, admin records it and reconciles outstanding to ₹0
- **Persona & goal:** It's 11 PM, the bus is back in Ahmedabad. Ramesh meets Mahesh to take the cash, record the handover, and close the bus to "settled" so nothing nags him on the Tour Money Board tomorrow.
- **Trigger (the activation):** Mahesh hands Ramesh a bag of cash and a scribbled note of what he spent.
- **Actors:** Ramesh (agent); Mahesh (handler).
- **Phases spanned:** Settlement.
- **Setup / messy data:** Mahesh's bus: collected ₹46,000, income ₹800, ground expenses (fuel/food/toll) ₹5,250. His **In hand = ₹41,550**. The bus owner's **rent ₹30,000** is in the admin P&L but NOT in the handover expectation. Mahesh hands ₹41,550 in cash.
- **The flow:**
  1. Ramesh opens **BusMoneyScreen**; the **Outstanding handover** hero reads the full **expected ₹41,550** (`collected + income − (expensesTotal − busRent)` = 46,000 + 800 − (35,250 − 30,000) = 46,000 + 800 − 5,250). The expense ledger shows a fixed, non-deletable **"Bus owner rent ₹30,000"** top row plus Mahesh's ground expenses; the handler-logged income is read-only here.
  2. Ramesh taps **Record** on Handover; the sheet pre-fills **Expected ₹41,550** in the "Handed over" field. Mahesh handed exactly that — Ramesh accepts, adds note "cash bag #2," Save.
  3. The **Outstanding** hero drops to **₹0** and turns to the calm "good" tone; the handover lists "Handed ₹41,550 of ₹41,550" with date + AM/PM time.
  4. Ramesh pays the bus owner ₹30,000 separately (offline) — that is NOT recorded as a handover; rent was never in the handover math.
- **Complications & recovery:** Mahesh actually hands ₹41,050 — ₹500 short because he forgot one fuel top-up he didn't log. Ramesh overrides "Handed over" to **₹41,050** → Outstanding shows **₹500** open, ring stays warm. Mahesh then logs the missing ₹500 fuel on his chart; expected recomputes to ₹41,050, Outstanding squares to ₹0 (within the 0.005 epsilon, the bus reads settled). Alternatively, partial handovers accumulate — a second ₹500 handover row would also clear it.
- **Real-world outcome (Expected):** Ramesh has the cash, the bus reads **settled** on the Tour Money Board (good ring), and he knows the owner is owed ₹30,000 which he pays directly. Observable: `outstandingHandover ≈ 0`; bus state via `stateForBusSummary` = `settled`; rent NOT in `expectedHandover` but IS in `expensesTotal`.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-6, UC-06MONEYCOLLECTIONSETTLEMENT-4, UC-07HANDLERTRIPDAY-15, UC-06MONEYCOLLECTIONSETTLEMENT-7 (settled state).
- **Screens/files:** `lib/screens/bus_money_screen.dart` (`_OutstandingHero`, `_openHandoverSheet`, `_HandoverRow`, `_BusOwnerRentRow`), `lib/models/bus_handover.dart`, `lib/models/money_summary.dart` (`expectedHandover`), `lib/controllers/money_controller.dart` (`recordHandover`, `stateForBusSummary`)

---

### SC-S4MONEYONTHEROADANDSETTLE-7: Two-bus trip P&L — rent asymmetry, "in hand ₹23k vs admin ₹30k", and the real profit
- **Persona & goal:** After settling both buses Ramesh wants to know whether the trip actually made money, and he must NOT be confused that handler Dinesh's "In hand" (₹23k-ish) is smaller than the rent line he sees in the P&L (₹30k) — he needs to understand the true vs cash net.
- **Trigger (the activation):** Both handlers have handed over; Ramesh opens the trip P&L the morning after.
- **Actors:** Ramesh (agent); Mahesh (41-seater handler); Dinesh (30-seater handler).
- **Phases spanned:** Settlement → post-trip reporting.
- **Setup / messy data:** **Bus A (41-seater, Mahesh):** revenue billed ₹98,000, collected ₹96,000 (₹2,000 still to collect from a no-show's friend), income ₹800, ground expenses ₹5,250, **rent ₹30,000**. **Bus B (30-seater, Dinesh):** revenue billed ₹52,000, collected ₹52,000, income ₹0, ground expenses ₹4,000, **rent ₹25,000**. Dinesh's handler "In hand" after handover = collected − spent = ₹48,000 → but the admin P&L for his bus subtracts ₹25,000 rent on top.
- **The flow:**
  1. Ramesh opens the **Tour Money Board**; each per-bus row shows its action state. Bus A reads **action-needed** (₹2,000 still to collect); Bus B reads **settled**. Bus A also shows "+₹800 Income."
  2. He taps the **P&L entry card** → **TripPnlScreen**. The hero shows **Net profit = `totalNetBilled` = (98,000 + 52,000) + 800 − totalExpenses**, where `totalExpenses` ALREADY folds both rents (₹30,000 + ₹25,000) plus ground (₹5,250 + ₹4,000) = ₹64,250. Net billed = 150,800 − 64,250 = **₹86,550 profit** (good tone).
  3. Beneath, **"Cash collected"** net = `totalNet` = (96,000 + 52,000) + 800 − 64,250 = **₹84,550** (lower, because ₹2,000 isn't collected yet).
  4. He scrolls to **By handler** cards: Mahesh's card and Dinesh's card each show billed net + revenue/costs/cash-net. Each per-bus subtitle shows "Rent ₹X" but rent is never added twice.
- **Complications & recovery:** Ramesh sees Dinesh's chart said "In hand ₹48,000" but the P&L "By bus" cash-net for Bus B is ₹23,000 (52,000 + 0 − (4,000 + 25,000)). He almost messages Dinesh "where's ₹25k?" — then remembers the **rent asymmetry**: the handler never sees rent; the ₹25,000 is the owner's cut Ramesh pays directly. No money is missing; it's the same cash viewed with vs without rent.
- **Real-world outcome (Expected):** Ramesh can tell his partner "the trip cleared ₹86,550 true profit, ₹84,550 in cash so far, ₹2,000 still to collect." He understands the handler/admin ₹23k-vs-₹48k gap is rent, by design. Observable: `totalNetBilled` > `totalNet` by the uncollected ₹2,000; both rents inside `totalExpenses`; "No handler" bucket (if any bus unassigned) kept last.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-13, UC-06MONEYCOLLECTIONSETTLEMENT-7, UC-06MONEYCOLLECTIONSETTLEMENT-8 (rent-diff by design), UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/trip_pnl_screen.dart`, `lib/screens/tour_money_board_screen.dart`, `lib/controllers/money_controller.dart` (`handlerSummaries`, `tourSummary`, `_busRents`, `_billedRevenues`), `lib/models/money_summary.dart` (`netBilled` vs `netCollected`)

---

### SC-S4MONEYONTHEROADANDSETTLE-8: Return-leg ticket sold mid-trip — extra cash that must flow into settlement
- **Persona & goal:** During the return phase Ramesh resells freed-up seats: an outbound-only family went home by train, so their berths are empty for the ride back. A villager wants a return-only seat. Ramesh adds it and Mahesh must collect the half-fare so it lands in the bus's collected total.
- **Trigger (the activation):** The GO leg is done (`isReturnPhase`); Ramesh gets a WhatsApp asking for one seat back to Ahmedabad.
- **Actors:** Ramesh (agent); Mahesh (handler); Hasmukh Vasava (return-only walk-up).
- **Phases spanned:** Return-leg → Settlement.
- **Setup / messy data:** Tour is **locked** and GO is complete (some riders `journeyDone`). A single sofa freed by a departed outbound-only rider is open for the return. Return-only single-sofa half-fare = ₹1,250.
- **The flow:**
  1. From the tour-detail Next-action **"Add return ticket"**, Ramesh opens `AddReturnTicketSheet`, fills name "Hasmukh Vasava," phone, 1 single sofa. Every line is forced to `returnOnly` (`forcedLeg`).
  2. Tap **Add return ticket** → `addPassenger(..., overrideLock: true)` books him even though the tour is locked (return phase is intentionally locked). Success toast `tour_detail.return_ticket_added` with his name.
  3. Hasmukh is now a pending seat on the **return** chart; GO-done riders are excluded from pending/engine, so no false "allocate N."
  4. On the bus, Mahesh taps Hasmukh's seat → collect sheet shows **Due ₹1,250** (return-only half fare, RET ½ leg pill + half-fare note). He collects ₹1,250.
  5. That ₹1,250 now counts toward the bus's **collected** and flows into "In hand" and the eventual handover.
- **Complications & recovery:** Hasmukh only has ₹1,000. Mahesh collects ₹1,000 → row shows **Due ₹250**; at drop-off Hasmukh pays the rest and the row squares. If Ramesh had tried to add the ticket while NOT in return phase, the "Add return ticket" action wouldn't be offered (gated on `isReturnPhase`).
- **Real-world outcome (Expected):** The freed seat earned an extra ₹1,250 that correctly raises the bus's collected and the trip's cash net, with no impact on the GO-leg riders who already left. Ramesh can tell the owner the return leg was resold. Observable: new passenger `tripType = returnOnly`; their fare in `collected`; GO-done riders not in pending count.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-15, UC-07HANDLERTRIPDAY-18, UC-07HANDLERTRIPDAY-5 (half-fare), UC-06MONEYCOLLECTIONSETTLEMENT-9.
- **Screens/files:** `lib/screens/add_return_ticket_sheet.dart`, `lib/screens/tour_detail_screen.dart` (Next-action dispatch), `lib/controllers/tour_controller.dart` (`addPassenger`, `completeOutboundLeg`), `lib/screens/handler_bus_chart_screen.dart` (`_CollectSheet`), `lib/models/bus_details.dart` (`tripFactor`)

---

### SC-S4MONEYONTHEROADANDSETTLE-9: Gujarati-only handler reinstalls his phone mid-trip and refinds his bus by phone
- **Persona & goal:** Mahesh's phone storage filled up; he uninstalled and reinstalled the app at the dhaba to free space. He reads only Gujarati, has no admin login, and must get back to his collecting screen without losing the cash he already logged — and confirm the figures still match the server.
- **Trigger (the activation):** Reinstall on the road; the app opens fresh with no "My Requests" card.
- **Actors:** Mahesh (handler, Gujarati-only); Ramesh (agent, reachable by phone).
- **Phases spanned:** Trip execution → Settlement (recovery + localization).
- **Setup / messy data:** Before reinstalling, Mahesh had collected ₹46,000 and logged ₹800 income + ₹5,250 expenses (server-side via handler RPCs). After reinstall the local cache is gone; the app UI is in **Gujarati** by default. His own booking request still exists server-side; he is the tour's designated handler (matched by phone last-10-digits).
- **The flow:**
  1. Mahesh opens the reinstalled app; there is no card yet. From customer **More** he opens **Find My Seat** (`શોધો` / Find), enters his mobile number, taps **Find**.
  2. The app calls `seatsByPhone` + `handlerRequestsByPhone`; his ticket card shows **"Manage as handler"** (`find_seat.manage_as_handler`, Gujarati label) because the phone holds a seat AND handles the tour.
  3. He taps it → `HandlerBusChartScreen(requestId: ...)`; the manifest fetches from the server. His collected ₹46,000, income ₹800, and expenses ₹5,250 are ALL back — they were persisted server-side, not just locally.
  4. He opens the breakdown: **In hand = ₹41,550** exactly as before the reinstall.
  5. Every label — money hero, GO/RET boarded chips, expense/income categories, collect sheet — renders in Gujarati (`handler_chart.*`, `collection.*` keys, 3-file parity); amounts stay INR via `Formatters.formatMoneyInr`.
- **Complications & recovery:** The dhaba Wi-Fi is flaky and the manifest fetch first throws → the chart shows the Gujarati `handler_chart.error_load` empty state, not a blank. Mahesh pulls to retry; on success the full chart loads. He then collects the last two pending fares; the new rows persist server-side so even another reinstall would recover them.
- **Real-world outcome (Expected):** Mahesh is back on his exact bus with no data loss, reading everything in Gujarati, and his "In hand" matches what Ramesh sees on the admin board to the rupee. He can finish collecting and hand over the correct cash. Observable: server-sourced figures identical pre/post reinstall; all chrome localized; INR formatting locale-independent.
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-2 (Find My Seat by phone), UC-07HANDLERTRIPDAY-1, UC-07HANDLERTRIPDAY-17 (mid-trip language), UC-06MONEYCOLLECTIONSETTLEMENT-16 (localization + offline resilience), UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`, `lib/screens/handler_bus_chart_screen.dart`, `lib/services/customer_requests_store.dart` (`seatsByPhone`, `handlerRequestsByPhone`, `handlerTourManifest`), `assets/translations/{en,gu,hi}.json`, `lib/utils/formatters.dart`
