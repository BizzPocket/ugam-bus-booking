# S5 — The Round-Trip Reality (Return-Leg Phase)

Real-world operational ("activation") scenarios for the moment a tour's GO leg
finishes and the return leg becomes its own little trip: some riders went one-way
and are done, some join for the return only (booked past the lock), the bus money
gets a second collection pass on the way home, and a return rider drops out at the
last minute. The thread running through all of these: once the GO leg is completed,
the GO-only riders are `journeyDone` and must NOT keep showing up as "allocate N"
pending seats, as "to collect" on the return roster, or as occupied berths the
agent can't resell.

These stories are grounded in the real code paths:
- `TourController.completeOutboundLeg` — frees every active `outboundOnly` rider's
  seats and flags them `journeyDone`; freezes the GO chart snapshot first.
- `Tour.pendingSeatsToAssign` / `Tour.allSeatsAssigned` — both filter out
  `journeyDone`, so a finished GO rider never resurfaces as pending or blocks lock.
- `Tour.isReturnPhase = locked && goLegCompleted` — drives the "Add return ticket"
  next-action and the `{free}` return-seats count (`computeTourCapacity().returnSeatsFree`).
- `AddReturnTicketSheet` → `addPassenger(..., overrideLock: true)` with the form
  `forcedLeg: TripType.returnOnly` — the only sanctioned bypass of the lock gate.
- `cancelReturnSeatTransform` — a return-only rider who never rode is removed
  outright; a round-trip rider is demoted to `outboundOnly` + `journeyDone`
  (record kept, berth freed).
- Handler chooser `defaultCollectLeg(occupants, outboundDone)` — once any rider is
  `journeyDone`, the shared-seat money chooser opens on the **Return** leg.
- Money is seat-agnostic (`BusMoneySummary`/`HandlerBusMoney` sum by `bus_id`), so a
  freed-and-resold berth keeps the GO rider's cash where it was paid.

Gujarati strings matter throughout (default app language): the agent reads
`tour_detail.action_complete_go_*`, `action_return_leg_*`, `cancel_return_*`, and
the handler reads `handler_chart.att_leg_go/att_leg_ret`. Concrete gu values cited
inline where they drive a decision.

---

### SC-S5RETURNLEGREALITY-1: Ramesh closes the Diu GO leg and the "allocate 6" ghost does not come back
- **Persona & goal:** Ramesh, the tour agent, ran a 2-day Diu pilgrimage on one 41-seater. The group has just reached Diu. He wants to "close out" the outward journey so his board stops nagging him about the eight one-way pilgrims who got off at Diu and aren't coming back with the bus.
- **Trigger (the activation):** The bus has arrived at Diu; eight local pilgrims (the Ahmedabad→Diu one-way crowd) collect their luggage and leave. Ramesh opens the tour to mark the GO leg done before he starts planning the return.
- **Actors:** Ramesh (admin).
- **Phases spanned:** Lock → Return-leg phase (the GO→return boundary).
- **Setup / messy data:** Tour is `locked`, 41-seater fully assigned. Roster: 8 `outboundOnly` pilgrims (got off at Diu for good), 30 `roundTrip` riders staying for the return, 3 seats empty. Before completion, `pendingSeatsToAssign == 0` (all assigned), so the next-action already reads neither "assign" nor "lock".
- **The flow:**
  1. Ramesh opens `TourDetailScreen` Overview. Because the tour is `locked` and at least one `outboundOnly` rider is still active (`!journeyDone`), the Next-Action card reads "GO લેગ પૂર્ણ કરો" / "જતી મુસાફરી પૂરી કરો — ફક્ત-જતા મુસાફરોની સીટ વળતી મુસાફરી માટે ખાલી થઈ જશે." (`action_complete_go_title/subtitle`).
  2. He taps it. The confirm sheet says "આનાથી {count} ફક્ત-જતા મુસાફરોની સીટ વળતી લેગ માટે ખાલી થશે" with `count = 8` (`complete_go_confirm_body`).
  3. He confirms. `completeOutboundLeg` first freezes the GO chart (`_captureSeatSnapshot(outbound, overwriteIfExists: true)`), then clears the 8 one-way riders' seats and flags each `journeyDone: true`. Toast: "GO લેગ પૂર્ણ થઈ — 8 વન-વે મુસાફરો દૂર થયા" (`complete_go_done`, count 8).
  4. He re-reads Overview. The Next-Action card has flipped to "વળતી મુસાફરી" with "{free} સીટ ખાલી" (`action_return_leg_*`), `free` from `returnSeatsFree = capacity − retOccupied = 41 − 30 = 11`.
- **Complications & recovery:** Ramesh's worry from a previous trip was that "completing GO" would dump the 8 departed pilgrims back into an "allocate 8 seats" pending pile on the return chart (they now hold no seat). It does not: `pendingSeatsToAssign` and the "Assign seats" next-action both filter `!p.journeyDone`, so the 8 finished riders are invisible to the engine and to the pending count. He sees 30 round-trip riders still seated for the return and 11 free berths — exactly the true return picture.
- **Real-world outcome (Expected):** Ramesh can confidently say "the outward leg is closed; I have 30 confirmed for the ride home and 11 empty seats I can still sell as return tickets." Observable state: 8 passengers `journeyDone: true` with empty `assignedSeats`; `goLegCompleted == true`; `isReturnPhase == true`; Next-Action = Add return ticket; no false "allocate 8".
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-15, UC-01TOURLIFECYCLEADMIN-7 (lock-gate ignores journeyDone), UC-06MONEYCOLLECTIONSETTLEMENT-15.
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `_runKind::completeGoLeg`), `lib/controllers/tour_controller.dart` (`completeOutboundLeg`, `outboundOnlyActiveCount`), `lib/models/tour.dart` (`pendingSeatsToAssign`, `goLegCompleted`, `isReturnPhase`), `lib/utils/tour_capacity.dart` (`returnSeatsFree`).

---

### SC-S5RETURNLEGREALITY-2: Selling the 11 empty homeward seats to walk-ups at Diu (return-only, past the lock)
- **Persona & goal:** Ramesh wants to fill the homeward bus. Three Diu families who travelled down by train want to ride back to Ahmedabad with his group. The tour is locked — bookings are closed everywhere — but these are legitimate return-only fares into seats he just freed.
- **Trigger (the activation):** Standing at the Diu bus stand, three groups DM Ramesh on WhatsApp asking for the return: the Solanki family of 4 (wants seats together), two college friends (one double), and Kanjibhai (one single, near the front, for his knees).
- **Actors:** Ramesh (admin); the Solankis, the two friends, Kanjibhai (return-only riders).
- **Phases spanned:** Return-leg phase.
- **Setup / messy data:** Tour `locked`, `isReturnPhase == true`, 11 return seats free. New demand: 4 + 2 + 1 = 7 return-only berths. None of these people exist in the tour yet; they have no prior request.
- **The flow:**
  1. Ramesh taps the "વળતી ટિકિટ ઉમેરો" Next-Action (`add_return_ticket`). `AddReturnTicketSheet` opens (`add_return_ticket_title`), hint: "આ મુસાફરો ફક્ત વળતી બસમાં ચડે છે" (`add_return_ticket_hint`).
  2. He fills the `BookingCaptureForm` for the Solankis: name "Solanki", phone, 2 double sofas. The form is `forcedLeg: TripType.returnOnly`, so every line is return-only — there is no GO/round-trip option to mis-pick. Tap "વળતી ટિકિટ ઉમેરો". `addPassenger(..., overrideLock: true)` writes the passenger with `tripType = returnOnly` **even though the tour is locked**. Toast "Solanki માટે વળતી ટિકિટ ઉમેરાઈ" (`return_ticket_added`). Contact remembered (`UserController.rememberContact`).
  3. He repeats for the two friends (1 double) and Kanjibhai (1 single).
  4. Back on the seat-assignment chart, the three new return-only riders show as **pending** seats to assign (they hold no berth yet). Ramesh seats the Solankis in two adjacent doubles, the friends in a double, and Kanjibhai in a front single.
- **Complications & recovery:** Halfway through, a fourth group of 6 DMs wanting the return — but `returnSeatsFree` is now down to 11 − 7 = 4. The "{free} સીટ ખાલી" subtitle and the two-leg capacity meter both show only 4 homeward seats. Ramesh tells the group of 6 "only 4 seats left on the way back" and waitlists the other 2 rather than overbooking the bus.
- **Real-world outcome (Expected):** Ramesh sold the empty homeward berths to legitimate return-only riders without re-opening the whole tour. Observable state: 3 new passengers, `tripType == returnOnly`, all lines return-only; they flow into the return chart as pending then seated; they appear in the money/collection track for their return fare; the GO `journeyDone` riders are untouched. Lock gate stayed closed for normal "Add request" surfaces — only this sanctioned `overrideLock` path admitted them.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-15, UC-01TOURLIFECYCLEADMIN-9 (overrideLock escape hatch), UC-01TOURLIFECYCLEADMIN-15.
- **Screens/files:** `lib/screens/add_return_ticket_sheet.dart`, `lib/widgets/booking_capture_form.dart` (`forcedLeg`), `lib/controllers/tour_controller.dart` (`addPassenger` overrideLock), `lib/screens/tour_seat_assignment_screen.dart`, `lib/utils/tour_capacity.dart` (`returnSeatsFree`).

---

### SC-S5RETURNLEGREALITY-3: Handler Mahesh collects the homeward cash and the chooser opens on Return by itself
- **Persona & goal:** Mahesh is the handler/conductor on the Diu bus. On the GO leg he collected from the one-way pilgrims and some round-trippers who paid early. Now the bus is rolling home; he needs to collect the return fares from the new return-only riders and the round-trippers who deferred — without re-charging anyone who already paid.
- **Trigger (the activation):** The return bus departs Diu. Mahesh opens his bus chart on his own phone to work the aisle and collect.
- **Actors:** Mahesh (handler).
- **Phases spanned:** Return-leg phase / Settlement.
- **Setup / messy data:** Same 41-seater. The Solanki double (seat D3) is now a **leg-split** berth: on the GO leg it carried a Diu pilgrim (now `journeyDone`); on the return it carries the new Solanki return-only riders. The bus has at least one `journeyDone` rider, so `outboundDone == true`. Kanjibhai's front single is return-only, ₹600 due (one-way fare). The two friends owe ₹1,200 for their return double.
- **The flow:**
  1. Mahesh opens `HandlerBusChartScreen` (from "My Requests" or Find My Seat by phone). The "In hand" hero already shows the GO-leg cash he holds.
  2. He taps the shared D3 berth. `_showOccupantChooser` runs; because `outboundDone == true` (a `journeyDone` rider exists), `defaultCollectLeg` seeds the chooser to **Return** — the toggle reads "વળતી" (`att_leg_ret`) selected by default, not "જતી" (`att_leg_go`). He sees the Solanki return riders, not the departed Diu pilgrim.
  3. He picks a Solanki rider; the `_CollectSheet` opens with the due. He enters the cash received; "In hand" rises by net collected (`inHand = collected + income − spent`).
  4. He works down the aisle: Kanjibhai's single (₹600), the friends' double (₹1,200), and the round-trippers who deferred. Round-trippers who already paid in full on the GO leg show a green money dot and a "ચૂકવાયું" (`money_paid`) status — he skips them.
- **Complications & recovery:** One round-trip rider, Dineshbhai, paid his full round-trip fare on the GO leg but then swapped seats at a rest stop (Mahesh moved his sticker). Mahesh worries the bus total now under-counts Dineshbhai's old seat. It doesn't: money is summed by `bus_id`, not by current seat — Dineshbhai's collection row stays put and he is NOT re-listed in "to collect" (he has a collection row on the bus, so `collectedPassengerIds` skips him). The "In hand" hero stays correct.
- **Real-world outcome (Expected):** Mahesh collected every outstanding return fare in one aisle pass, never re-charging a paid rider, and the chooser pointed him at the right (homeward) people on every shared seat without him fiddling the GO/Return toggle. Observable state: new collection rows on the bus for the return riders; "In hand" reflects collected + income − spent; paid GO riders unchanged; leg-split seats default to Return.
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-18, UC-07HANDLERTRIPDAY-6, UC-06MONEYCOLLECTIONSETTLEMENT-12, UC-06MONEYCOLLECTIONSETTLEMENT-8.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_showOccupantChooser`, `_CollectSheet`, `outboundDone`), `lib/utils/seat_occupants.dart` (`defaultCollectLeg`, `seatHasLegSplit`, `occupantsForCollectLeg`), `lib/models/handler_bus_money.dart`, `lib/models/passenger.dart` (`journeyDone`).

---

### SC-S5RETURNLEGREALITY-4: A return rider cancels at Diu — cancel-in-place, then rebook the same berth
- **Persona & goal:** Ramesh has a return-only rider who just dropped out, and a different walk-up who wants exactly that seat. He wants to cancel the return seat and immediately resell it without leaving the seat chart.
- **Trigger (the activation):** At the Diu bus stand, one of the two college friends (return-only, seat D7-right) calls: his plans changed, he's staying back. A minute later a solo traveller, Jadiben, asks for one homeward seat.
- **Actors:** Ramesh (admin); the cancelling friend (return-only), Jadiben (new return-only rider).
- **Phases spanned:** Return-leg phase.
- **Setup / messy data:** Tour `locked`, `isReturnPhase`. The cancelling rider is `returnOnly` (every request line is return-only) — he never rode the GO leg. His berth D7-right is one half of a double the two friends share.
- **The flow:**
  1. Ramesh opens the seat-assignment chart, taps the cancelling friend's occupant, and chooses "વળતી રદ કરો" (`cancel_return_seat` / `cancel_return_cta`) — the entry only appears because the tour is in its return phase.
  2. Confirm sheet: "{name}ની વળતી સીટ ખાલી થશે જેથી તમે ફરી બુક કરી શકો" (`cancel_return_confirm_body`). He confirms.
  3. `cancelReturnSeat` runs `cancelReturnSeatTransform`: because the rider is return-only (`lines.every(leg == returnOnly)`), the transform returns `null` → the passenger is **removed outright** (`removePassenger`). The berth frees. Toast "{name}ની વળતી સીટ ખાલી છે" (`cancel_return_done`).
  4. The app offers "બદલીમાં બુક કરવી છે?" (`cancel_return_rebook_title/body`). Ramesh taps "વળતી ટિકિટ ઉમેરો"; `AddReturnTicketSheet` opens in place. He books Jadiben (1 return-only seat) and seats her on the just-freed D7-right.
- **Complications & recovery:** Ramesh first feared cancelling would also wipe the *other* friend who shares the double — it doesn't; only the tapped occupant's return is cancelled, the partner keeps his seat. Contrast with a *round-trip* rider cancelling their return (next scenario): that record is kept, not deleted, because they already rode GO.
- **Real-world outcome (Expected):** The friend's homeward seat is freed and immediately filled by Jadiben, all from the seat chart in one flow. Observable state: cancelling return-only rider removed entirely (no orphan record, since they never travelled); Jadiben added as a fresh return-only passenger seated on the freed berth; `returnSeatsFree` net unchanged; the partner's seat intact.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-15 (cancelReturnSeat), UC-06MONEYCOLLECTIONSETTLEMENT-15 (rebook past lock).
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_cancelReturnSeatFlow`), `lib/controllers/tour_controller.dart` (`cancelReturnSeat`, `cancelReturnSeatTransform`, `removePassenger`), `lib/screens/add_return_ticket_sheet.dart`.

---

### SC-S5RETURNLEGREALITY-5: A round-trip rider skips the bus home — demoted, not deleted, and his GO cash stays
- **Persona & goal:** Ramesh has a round-trip family member whose plan changed: he rode down to Diu with the group but will go home by train. Ramesh must free his homeward seat for resale WITHOUT losing the record that the man rode the GO leg and already paid.
- **Trigger (the activation):** Jignesh (round-trip, paid ₹1,200 for the full trip on the GO leg) tells Ramesh at Diu he'll catch the train home. Ramesh needs that return berth back.
- **Actors:** Ramesh (admin); Jignesh (round-trip rider abandoning the return).
- **Phases spanned:** Return-leg phase / Settlement.
- **Setup / messy data:** Tour `locked`, `isReturnPhase`. Jignesh is `roundTrip`, holds seat C4 on both legs, has a full collection row of ₹1,200 on the bus from the GO leg. He is NOT `journeyDone` yet (round-trippers aren't cleared by `completeOutboundLeg`).
- **The flow:**
  1. Ramesh opens the seat chart, taps Jignesh's occupant on C4, chooses "વળતી રદ કરો".
  2. Confirm body explicitly reassures: "રાઉન્ડ-ટ્રિપ મુસાફરની પૂર્ણ થયેલી GO ટ્રિપ જળવાઈ રહેશે" (`cancel_return_confirm_body`). He confirms.
  3. `cancelReturnSeatTransform` runs: Jignesh has a non-return-only line, so he is NOT removed. Instead every `roundTrip` line becomes `outboundOnly`, his `assignedSeats` clear (C4 frees), `journeyDone: true`, `tripType = outboundOnly`. He drops off the active roster exactly like a one-way rider who finished.
  4. C4 is now free; Ramesh resells it as a return ticket to a walk-up.
- **Complications & recovery:** Ramesh checks the bus money afterward, worried Jignesh's ₹1,200 vanished or that freeing C4 created a "to collect" hole. Neither: money is seat-agnostic — Jignesh's ₹1,200 collection row stays on the bus by `bus_id`, still counted in "Collected". And because he's now `journeyDone`, he is excluded from `pendingSeatsToAssign` and from the active "to collect" roster — no phantom "allocate 1" and no double-charge. The new walk-up seated on C4 gets their own fresh return collection row.
- **Real-world outcome (Expected):** Ramesh freed and resold Jignesh's homeward seat while preserving the fact (and the cash) that Jignesh rode and paid for GO. Observable state: Jignesh `tripType == outboundOnly`, `journeyDone == true`, no seats, record intact; his GO collection row unchanged and still in "Collected"; C4 resold; capacity/return-free counts correct.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-15 (round-trip demote branch), UC-06MONEYCOLLECTIONSETTLEMENT-8 (seat-agnostic money), UC-06MONEYCOLLECTIONSETTLEMENT-15.
- **Screens/files:** `lib/controllers/tour_controller.dart` (`cancelReturnSeat`, `cancelReturnSeatTransform`), `lib/screens/tour_seat_assignment_screen.dart` (`_cancelReturnSeatFlow`), `lib/models/handler_bus_money.dart`, `lib/models/money_summary.dart`.

---

### SC-S5RETURNLEGREALITY-6: Settlement night — admin records the homeward handover and the P&L counts both passes
- **Persona & goal:** The trip is over. Mahesh hands Ramesh the cash he collected on BOTH legs (GO one-way fares + return fares + any cabin income, minus ground spends). Ramesh must record the handover and confirm the bus's true profit/loss reflects both collection passes and the return-only walk-up fares.
- **Trigger (the activation):** Back in Ahmedabad, settlement night. Mahesh meets Ramesh and hands over the cash bag.
- **Actors:** Ramesh (admin); Mahesh (handler, hands physical cash).
- **Phases spanned:** Return-leg phase → Settlement.
- **Setup / messy data:** One bus, `busPrice` (owner rent) ₹30,000. GO-leg collections + return-leg collections together = ₹52,000 collected. Mahesh logged ₹2,000 cabin income and ₹3,500 ground spends (fuel/toll/food). The three return-only walk-up groups' fares are part of the ₹52,000.
- **The flow:**
  1. Ramesh opens `BusMoneyScreen` for the bus. The "Outstanding handover" hero shows `expectedHandover = collected + income − (expenses − busRent) = 52,000 + 2,000 − (3,500 + 30,000 − 30,000) = 50,500` (rent excluded from the handover; Ramesh pays the owner directly).
  2. He taps "Record"; the Expected billboard pre-fills ₹50,500. Mahesh hands over exactly that. Ramesh saves the `BusHandover`; the hero settles to the calm "good" tone (outstanding ≈ 0).
  3. He opens the trip P&L (`TripPnlScreen`). The headline `totalNetBilled` reflects revenue billed across both legs (including the return-only walk-ups' fares) plus ₹2,000 income minus expenses (which already fold in the ₹30,000 rent). The "Cash collected" line shows the cash net.
- **Complications & recovery:** Ramesh is briefly confused that the handler's "In hand" was ₹50,500 while the P&L expense view shows ₹33,500 of costs including ₹30,000 rent — a ₹17k gap. This is the documented rent asymmetry: rent is IN the P&L expense total but OUT of the handover expectation, and the handler never sees rent at all. Not a bug.
- **Real-world outcome (Expected):** Ramesh recorded the full homeward handover, knows the bus is settled (outstanding 0), and can read the bus's true profit with both collection passes and the return-only fares included. Observable state: `BusHandover` row "Handed ₹50,500 of ₹50,500"; outstanding ≈ 0, good tone; P&L net includes return revenue; rent folded once into expenses, never into handover.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-6, UC-06MONEYCOLLECTIONSETTLEMENT-13, UC-07HANDLERTRIPDAY-15, UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/bus_money_screen.dart` (`_OutstandingHero`, `_openHandoverSheet`, `_TourRollupCard`), `lib/screens/trip_pnl_screen.dart`, `lib/models/money_summary.dart`, `lib/models/handler_bus_money.dart`, `lib/controllers/money_controller.dart`.

---

### SC-S5RETURNLEGREALITY-7: A pure one-way (no-return) tour skips the return phase entirely
- **Persona & goal:** Ramesh ran a one-way drop — a Saturday-only Ahmedabad→Ambaji darshan where everyone makes their own way back. He must NOT be pestered by a return phase that doesn't exist, and the trip should close cleanly.
- **Trigger (the activation):** The bus reaches Ambaji; everyone disembarks. There is no homeward leg for this tour.
- **Actors:** Ramesh (admin).
- **Phases spanned:** Lock → terminal (no return-leg).
- **Setup / messy data:** Tour `locked`, every passenger `outboundOnly` (one-way), `returnDate == null`. No round-trip or return-only riders anywhere.
- **The flow:**
  1. Ramesh opens Overview. While GO-only riders are still active, the Next-Action reads "GO લેગ પૂર્ણ કરો". He completes the GO leg.
  2. `completeOutboundLeg` flags every one-way rider `journeyDone` and frees seats. Now `isReturnPhase = locked && goLegCompleted` is technically true, BUT `returnSeatsFree` and the return chart have no return riders to seat.
  3. Because there are no round-trip/return-only riders, the natural close-out is "Mark completed". Ramesh taps it; `completeTour` freezes both snapshots (return snapshot is skipped — `buildSeatSnapshot` returns null with no return occupants) and flips status to `completed`.
- **Complications & recovery:** On a previous one-way trip Ramesh saw a confusing "Add return ticket — N free" prompt on a tour that had no return. The guard here is that a one-way tour has `returnDate == null` and no return riders, so the agent's real next step is simply "Mark completed" — adding a return ticket would be pointless (and the trip-completion gate, UC-12, lets him close it). The scenario documents that the return phase must not block close-out for a no-return tour.
- **Real-world outcome (Expected):** Ramesh closes a one-way tour without wrestling a phantom return leg. Observable state: all riders `journeyDone`; tour `completed`; only the GO snapshot frozen (no return snapshot written); tour drops out of active lists and Dashboard attention.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-15 (one-way skips return), UC-01TOURLIFECYCLEADMIN-12 (mark completed).
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `_runKind::completeGoLeg` / `markCompleted`), `lib/controllers/tour_controller.dart` (`completeOutboundLeg`, `completeTour`, `_captureSeatSnapshot`), `lib/models/tour.dart` (`isReturnPhase`).

---

### SC-S5RETURNLEGREALITY-8: Return roster shows only homeward riders — departed GO pilgrims are not "to collect"
- **Persona & goal:** On the homeward run, Ramesh (checking remotely) and Mahesh (on the bus) both want their money roster to show ONLY the people actually riding home, with the right return fares — not the eight Diu pilgrims who got off and owe nothing more.
- **Trigger (the activation):** Mid-return, Ramesh opens the collection screen to check who still owes; Mahesh works the same money from his chart.
- **Actors:** Ramesh (admin), Mahesh (handler).
- **Phases spanned:** Return-leg phase / Settlement.
- **Setup / messy data:** 8 `journeyDone` GO-only pilgrims (got off at Diu), 30 round-trippers (some paid GO, some deferred), 3 return-only walk-ups added past the lock. The 8 departed pilgrims must not appear as owing.
- **The flow:**
  1. Admin: Ramesh opens `CollectionScreen` for the bus, filters "To collect". The roster lists round-trippers with an outstanding balance plus the return-only walk-ups — NOT the 8 departed pilgrims (they hold no seat on the bus; `_seatLines` iterates distinct seatIds the rider currently holds, and `journeyDone` riders have no `assignedSeats`).
  2. Handler: Mahesh's "To collect" likewise excludes anyone with a collection row (`collectedPassengerIds`) and anyone seatless. He sees the same homeward owing list.
  3. Each return-only walk-up shows a halved one-way due (`amountDueForSeat` charges the RET ½ fare) with a return trip label; the collect sheet shows the RET ½ leg pill + half-fare note.
- **Complications & recovery:** One round-tripper, Kanjibhai's wife Jadiben, paid only half on the GO leg (partial). She still appears in "To collect" with her remaining balance — correctly, because her collection row's `balance < 0`. The 8 departed pilgrims, by contrast, had paid in full on GO and are `journeyDone`, so they're absent from both surfaces. Ramesh doesn't waste a call chasing a pilgrim who's already home.
- **Real-world outcome (Expected):** Both the admin collection screen and the handler chart show a clean homeward "to collect" list — round-trippers who still owe plus return-only fares — with departed GO pilgrims correctly absent and half-fares correct. Observable state: `journeyDone` seatless riders excluded from `_seatLines`/handler `toCollect`; return-only riders charged the ½ fare; partial round-trippers still listed by their negative balance.
- **Base-level UCs exercised:** UC-06MONEYCOLLECTIONSETTLEMENT-3, UC-07HANDLERTRIPDAY-14, UC-07HANDLERTRIPDAY-11, UC-06MONEYCOLLECTIONSETTLEMENT-8.
- **Screens/files:** `lib/screens/collection_screen.dart` (`_seatLines`, `_passesFilter`), `lib/screens/handler_bus_chart_screen.dart`, `lib/models/handler_bus_money.dart` (`collectedPassengerIds`), `lib/models/bus.dart` (`amountDueForSeat`), `lib/models/passenger.dart` (`journeyDone`).
