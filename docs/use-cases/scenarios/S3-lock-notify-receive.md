# S3 — Committing the tour: pick a handler, lock, notify, customers receive

**Operational cluster:** The commit moment. Everything before this is provisional; locking is the agent saying out loud "this is the trip now." These scenarios walk the real life of that moment — the last pre-lock sanity checks, choosing a handler the agent actually trusts on each bus, pulling the lock, the seat-allotment WhatsApp landing in 40-odd customers' chats with a highlighted seat-chart image, the customer opening their ticket to finally see a seat NUMBER (and the deliberate fact they could not before), and the messy reality that someone always changes their mind five minutes after lock.

**Lifecycle:** Phases 7 (Assign Handler) → 8 (Lock & Notify), with the post-lock RETURN-leg tail where it bites.

**Personas used across scenarios:**
- **Ramesh** — the tour agent / admin. Runs DEVAM / Ugam Foj community bus pilgrimages off three WhatsApp groups. Reads and works the app in **Gujarati**.
- **Mahesh, Dinesh** — handler candidates (a handler is a passenger who rides the bus and runs it: collects cash, manages the manifest).
- **The Patels** (family of 5), **the Solankis** (4), **the Chauhans** (3) — families that must sit together.
- **Kanjibhai & Jadiben** — elderly couple, two single sofas near the front, Gujarati-only readers.
- **Jignesh** — a second agent / co-organiser who sometimes books from his own phone.

**Grounding:** `lib/screens/notify_screen.dart` (lock gate + tracker + bus message), `lib/controllers/tour_controller.dart` (`lockTour`, `setBusHandler`, `removeBusHandler`, `completeOutboundLeg`, `addPassenger`, `_revertLockOnUnseat`), `lib/services/whatsapp_outbound.dart` (`sendSeatAllocations` → `seat_allotment` template), `lib/screens/manage_buses_screen.dart` (`_openHandlerPicker`), `lib/screens/customer_my_requests_screen.dart` + `lib/services/customer_requests_store.dart` (`seatsVisible == tourLocked && hasSeatsAssigned`), `lib/screens/find_my_seat_screen.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-1: Diu pilgrimage, the night before — final checks, pick Mahesh, lock, 38 seat-charts go out
- **Persona & goal:** Ramesh wants to commit his 2-day Diu pilgrimage and have every one of his ~38 confirmed riders wake up tomorrow with their seat in WhatsApp, without him typing 38 messages.
- **Trigger (the activation):** It is the night before departure. Cash is mostly collected, the chart is full, and Ramesh opens the tour's **Lock & notify** screen to "make it real."
- **Actors:** Ramesh (admin); 38 seated passengers as recipients; Mahesh (chosen handler).
- **Phases spanned:** 7 → 8 (handler + lock + auto-notify).
- **Setup / messy data:** One 41-seat Volvo, 38 riders seated across families and singles — the Patels (5, two double sofas + a single), the Solankis (4), Kanjibhai & Jadiben on singles S1/S2 up front, plus a dozen friend-pairs. Three seats still free (waitlist not filled). No handler has been picked yet; the bus card shows "Set handler."
- **The flow:**
  1. Ramesh opens the tour → **Lock & notify** (Notify screen). The lock-gate checklist shows three rows: at least one passenger (green), all assigned (green), **handler picked (empty circle, red)**. The sticky CTA reads the disabled label *"Finish setup to lock"* and the reason line above it names the first missing condition: *no handler*.
  2. He can't lock yet. He goes to the bus → **handler picker** (`bus_handler.row_empty` "Set handler"). The picker lists ONLY seated passengers — Mahesh (riding seat 12) is in the list; the bus owner's nephew, who is NOT on the manifest, is not. Ramesh taps **Mahesh**. Toast: *"Mahesh set as handler."*
  3. Back on Notify, the gate re-evaluates live (`Obx`): all three checks now green, the sticky CTA flips to the enabled **"Lock Tour."**
  4. Ramesh taps Lock. Confirm dialog: *"Lock this tour? 38 passengers…"* — he confirms.
  5. The tour flips to `locked`. NO green "locked" toast (by design) — the hero status dot just turns to the locked/good state and the screen switches from gate-mode to **tracker** mode (hero summary, progress card `0 / 38`, filter pills, passenger list).
  6. Immediately the **seat-allocation send dialog** appears: *"Send seats to 38 passengers?"* He confirms Send.
  7. A non-dismissible progress dialog counts *"preparing 1 of 38 … preparing 38 of 38"* (each rider's personal seat-chart image renders + uploads — the slow part) then flips to *"sending now."* Each rider gets the `seat_allotment` Cloud API template: a highlighted chart image header + body (their name, tour, bus, boarding place, departure date, departure time, handler contact = **Mahesh + his phone**).
  8. Result toast: *"Seats sent — 38 passengers."* Every row's status dot flips to **Sent**; the progress card reads `38 / 38` green / "All notified"; the "Send to all pending" sticky CTA disappears (pending hit 0).
- **Complications & recovery:** Ramesh genuinely forgot to pick a handler — the gate caught it *before* lock instead of letting him lock a trip nobody runs. The reason line told him exactly what was missing (handler), not a generic "can't lock." Because the handler picker only lists seated people, he physically cannot pick someone who isn't on the bus.
- **Real-world outcome (Expected):** Ramesh can close the app and tell the bus owner "we're locked, 38 on the Volvo, Mahesh is running it." Bookings are now closed everywhere (the tour stops accepting new requests). Every rider has, in their own WhatsApp, a picture of the bus with THEIR seat lit and Mahesh's number to call on the day. Observable state: `tour.status == locked`, `bus.handlerPassengerId == Mahesh`, `tours.handler_id == Mahesh`, `Mahesh.isHandler == true`, tracker `38/38` sent (session-only markers).
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-7, UC-01TOURLIFECYCLEADMIN-8, UC-05HANDLERASSIGNCHARTS-11.
- **Screens/files:** `lib/screens/notify_screen.dart`, `lib/screens/manage_buses_screen.dart`, `lib/controllers/tour_controller.dart` (`lockTour`, `setBusHandler`), `lib/services/whatsapp_outbound.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-2: Two buses, two handlers — Mahesh runs the Volvo, Dinesh runs the 30-seater, each rider gets the RIGHT contact
- **Persona & goal:** Ramesh's Dwarka trip outgrew one bus — 41-seat Volvo + a 30-seat second bus. He wants each rider's seat message to carry the contact of the handler on *their* bus, not a single shared number.
- **Trigger (the activation):** Bus #2 was booked yesterday; seats spilled onto it; now Ramesh is at the lock step and must appoint a handler per bus.
- **Actors:** Ramesh (admin); Mahesh (rides the Volvo, seat 5); Dinesh (rides bus #2, seat 3); ~60 passengers split across both buses.
- **Phases spanned:** 7 → 8 (per-bus handler + lock + per-bus contact in the message).
- **Setup / messy data:** Volvo holds ~40, bus #2 holds ~22, both full enough to run. The Patels are entirely on the Volvo; the Chauhans (3) are on bus #2. Kanjibhai & Jadiben are on the Volvo front singles. No handler set on either bus.
- **The flow:**
  1. On Notify the gate is blocked: "handler picked" is red because NEITHER bus has a handler (a tour needs a handler to lock, and per-bus handlers feed it).
  2. Ramesh opens **Manage buses**. On the Volvo card he taps the handler row → picker lists only Volvo-seated riders → taps **Mahesh**. Toast "Mahesh set as handler." The Volvo card's handler row goes to the accent "current handler" state.
  3. On bus #2's card he taps the handler row → picker lists only bus-#2 riders → taps **Dinesh**. "Dinesh set as handler." Setting Dinesh on bus #2 leaves Mahesh on the Volvo untouched (handler is per-bus).
  4. Back on Notify the gate is green (a handler exists). Lock → confirm 60 → locked.
  5. Seat-allocation send fires. For each rider, the message picks the handler of THAT rider's bus: every Volvo rider's message shows **Mahesh + phone**; every bus-#2 rider's shows **Dinesh + phone**. The Chauhans get Dinesh; the Patels get Mahesh.
  6. Result toast "Seats sent — 60." Tracker `60/60`.
- **Complications & recovery:** Ramesh first tapped the bus-#2 handler row before anyone was seated on it earlier in the day and got the warning *"No seated passengers — a handler must be on board"*; once seats spilled over, the picker populated. He never risked appointing a handler who wasn't actually riding that bus.
- **Real-world outcome (Expected):** A Chauhan on bus #2 who needs the boarding point on the morning calls **Dinesh**, not Mahesh on the other bus. Ramesh can tell each driver "your handler is X." Observable state: `Volvo.handlerPassengerId == Mahesh`, `bus2.handlerPassengerId == Dinesh`, both `isHandler == true`, `tours.handler_id` points at one of them (legacy pointer), seat messages carry per-bus handler contact.
- **Base-level UCs exercised:** UC-05HANDLERASSIGNCHARTS-11, UC-05HANDLERASSIGNCHARTS-9, UC-01TOURLIFECYCLEADMIN-8.
- **Screens/files:** `lib/screens/manage_buses_screen.dart` (`_openHandlerPicker`, `_seatedPassengers`), `lib/services/whatsapp_outbound.dart` (per-bus handler contact: `bus?.handlerPassengerId ?? tour.handlerId`), `lib/screens/notify_screen.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-3: The customer side — the Patels couldn't see seat numbers before lock, and the whole family's seats appear the moment Ramesh locks
- **Persona & goal:** Mrs. Patel (booked from her phone) wants to know which seats her family of 5 got. She keeps opening "My Requests" the day before and seeing "being finalized."
- **Trigger (the activation):** Ramesh locks the Diu tour (SC-1). The seat reveal gate flips for the Patels' device-local ticket.
- **Actors:** Mrs. Patel (customer, no account, device-local ticket); Ramesh (admin) as the off-screen trigger.
- **Phases spanned:** 6 (assigned, pre-lock) → 8 (locked, revealed).
- **Setup / messy data:** The Patels' single request covers 2 double sofas + 1 single, full trip — Ramesh seated them on D3, D4, S6 a day earlier but had NOT locked yet. Mrs. Patel's ticket server-side already has `hasSeatsAssigned == true` but `tourLocked == false`.
- **The flow (customer):**
  1. **Before lock:** Mrs. Patel opens My Requests. Her row shows the warm **"Seats finalizing"** chip — NOT numbers. She taps the row: instead of a layout sheet she gets the info toast *"Seats are still being finalized."* The footer shows a neutral "finalizing" chip, never a seat id. (Privacy/no-lie gate: `seatsVisible == tourLocked && hasSeatsAssigned` is false.)
  2. She closes the app frustrated, reopens an hour later — still finalizing (Ramesh hasn't locked).
  3. **Ramesh locks** (SC-1) and the seat-allotment message lands in her chat: the bus picture with the family's seats lit, plus boarding/departure/Mahesh's number.
  4. She opens My Requests again and pulls to refresh: per-row `booking_request_tour_locked` now returns true → her row chip flips to the good **"Seats assigned."** She taps it → the customer seat-layout sheet opens (loaded via `bus_layouts_for_request`): for the bus, a header "Your seats: D3, D4, S6", the real grid with HER seats in accent and everyone else neutral/anonymous, and a 2-item Mine/Others legend. Footer also shows a green "Seats: D3, D4, S6" chip.
- **Complications & recovery:** Mrs. Patel's anxiety the day before is by design, not a bug — the app refuses to leak provisional numbers that Ramesh might still reshuffle. The instant lock happens, both the push message and the in-app reveal turn on together, so she never sees a number she'd then have to un-learn.
- **Real-world outcome (Expected):** The Patel family knows they're on D3/D4/S6 and can plan who sits where, and they have a chart they can show the handler at the door. No other family's names are visible to them. Observable state: ticket `seatsVisible == true`, layout sheet renders the family's seats highlighted, all others anonymous.
- **Base-level UCs exercised:** UC-08CUSTOMEREXPERIENCE-12, UC-08CUSTOMEREXPERIENCE-11.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`, `lib/services/customer_requests_store.dart` (`seatsVisible`), `lib/widgets/customer_seat_layout_sheet.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-4: Reinstalled phone, no ticket — Kanjibhai finds his seat by phone after lock
- **Persona & goal:** Kanjibhai (elderly, Gujarati-only) changed phones last week; the new phone has no "My Requests" history. The morning of the trip he wants to confirm where he and Jadiben are sitting.
- **Trigger (the activation):** Tour is locked; Kanjibhai opens the app fresh and his ticket list is empty even though his seat is held server-side under his number.
- **Actors:** Kanjibhai (customer, fresh install / no device-local ticket); seats held under his phone.
- **Phases spanned:** 8 (post-lock, phone-keyed recovery).
- **Setup / messy data:** Kanjibhai & Jadiben were booked as one request (2 single sofas, S1/S2, full trip) from Kanjibhai's number. The new phone's `CustomerRequestsStore` is empty. The tour is locked.
- **The flow:**
  1. Kanjibhai opens the app → lands on the customer Explore screen. My Requests is **empty** (device-local; a reinstall shows nothing even though bookings are live).
  2. He opens menu → **Find my seat**. He types his 10-digit number and taps Find. (Phone is matched on the last 10 digits server-side, so a stray +91 or spaces wouldn't matter.)
  3. `seat_lookup_by_phone` resolves his ticket: a card with the tour title, route, his name, an accent **"Your seats: S1, S2"** chip, and the bus diagram with S1/S2 highlighted (everyone else anonymous).
  4. He shows the screen to Jadiben; both confirm they're up front as requested.
- **Complications & recovery:** Because seats only resolve for LOCKED/completed tours, if Kanjibhai had checked before Ramesh locked, the lookup would have returned nothing — correct, since seats were still provisional. After lock, the phone path recovers everything the lost device-local ticket would have shown. If he'd typed only 8 digits he'd get the inline "number too short" error with no network call.
- **Real-world outcome (Expected):** Kanjibhai recovers his and Jadiben's seats with zero in-app history, purely from his phone number, in Gujarati. Observable state: Find-my-seat card renders S1/S2 highlighted; no dependence on `CustomerRequestsStore`.
- **Base-level UCs exercised:** UC-08CUSTOMEREXPERIENCE-14, UC-08CUSTOMEREXPERIENCE-12 (the "only locked tours return seats" rule).
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`, `lib/services/customer_requests_store.dart`, `lib/models/seat_ticket.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-5: Five minutes after lock, the Solankis drop one rider — Ramesh re-seats, the lock auto-reverts, he re-locks and re-notifies only the affected
- **Persona & goal:** Ramesh locked and notified, then Mr. Solanki calls: their grandmother can't travel, free her seat and give it to a waitlisted friend. Ramesh needs to fix the chart and make sure messages stay truthful.
- **Trigger (the activation):** A phone call right after lock — a real last-minute change on a committed tour.
- **Actors:** Ramesh (admin); the Solankis (was 4, now 3); a waitlisted friend, Jignesh's cousin, who takes the freed seat.
- **Phases spanned:** 8 (post-lock edit → re-lock → targeted re-notify).
- **Setup / messy data:** Tour is `locked`, tracker shows everyone Sent. Grandmother sits on D7 (one half of a double the Solankis share). The waitlisted friend has a pending request on the same tour.
- **The flow:**
  1. Ramesh opens the tour's seat editor (the only write path — Notify and Charts are read-only for seats). He frees the grandmother's berth on D7.
  2. **Side effect:** clearing a seat on a LOCKED tour un-finalizes the allocation — `_revertLockOnUnseat` drops the tour from `locked` back to `assigning`. The "Lock & notify" action reappears; the Notify screen swaps back to gate-mode.
  3. Ramesh places the waitlisted friend onto the freed D7 half. The chart is full and correct again.
  4. He returns to Notify. The gate is green again (all assigned, handler still Mahesh, passengers present). He re-locks → confirm.
  5. Seat-allocation send dialog appears again. He could blast all, but instead uses the per-rider **chat** button on just the two changed riders (the new friend, and the remaining Solankis whose shared-double half changed) to re-fire the `seat_allotment` template to only them — the same picture-and-details message, scoped to those ids. Their rows flip to Sent.
- **Complications & recovery:** The dangerous failure mode — a locked tour silently out of sync with reality — is structurally prevented: you literally cannot edit a seat on a locked tour without it dropping to `assigning` and forcing a fresh lock, so a stale "locked" snapshot can't persist. The grandmother's now-removed seat won't keep showing as visible on her side because the seat data is gone.
- **Real-world outcome (Expected):** The chart matches who's actually travelling; the new friend has a seat message with his correct seat; the Solankis' updated half is reflected; nobody got a redundant duplicate blast. Observable state: tour `locked` again after re-lock, grandmother freed, friend on D7, two targeted re-sends marked Sent.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-9, UC-01TOURLIFECYCLEADMIN-10, UC-01TOURLIFECYCLEADMIN-8.
- **Screens/files:** `lib/controllers/tour_controller.dart` (`_revertLockOnUnseat`, `addPassenger`), `lib/screens/notify_screen.dart` (`_dispatchSeatAllocations` scoped to one id), `lib/screens/tour_seat_assignment_screen.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-6: Meta sandbox bites — three numbers aren't on the allowed list; Ramesh sends, sees the partial failure, retries only the failures
- **Persona & goal:** On the first locked tour after WhatsApp Cloud API setup, Ramesh wants every rider notified, but the account is still in Meta's test phase where only allow-listed numbers can receive.
- **Trigger (the activation):** Ramesh locks and the auto-send runs; some recipients silently fail at Meta's side.
- **Actors:** Ramesh (admin); ~20 seated riders, three of whom (the Chauhans, just added) aren't on Meta's allowed test list yet.
- **Phases spanned:** 8 (lock → send → partial failure → retry).
- **Setup / messy data:** 20 riders seated; three Chauhan numbers were added to the manifest but never added to Meta's sandbox allow-list. Handler Mahesh set, tour about to lock.
- **The flow:**
  1. Lock → confirm 20 → locked. Send dialog "Send seats to 20?" → confirm.
  2. Progress dialog counts "preparing 1 of 20 … 20 of 20" then "sending now."
  3. Result is NOT all-sent. A summary dialog appears: *"Sent 17, 3 failed,"* with the first Meta error reason appended (e.g. `(#131030) Recipient phone number not in allowed list`). It offers a one-tap **Retry (3)** that will re-send ONLY the 3 failures.
  4. Ramesh adds the three Chauhan numbers to the Meta sandbox in another window, comes back, and taps **Retry (3)**. The progress dialog runs for just those 3; this time they succeed.
  5. Tracker now `20/20`; the Chauhan rows flip from pending to Sent. The 17 already-sent were NOT re-messaged (only failed ids retried).
- **Complications & recovery:** The partial-failure summary surfaces the exact Meta reason instead of a generic "failed," so Ramesh immediately understands it's the allow-list, not a bad number. Retry is scoped to failures, so the 17 successful riders don't get a duplicate seat message. The successfully-sent markers are session-only, so a restart resets the tracker but never re-sends without him asking.
- **Real-world outcome (Expected):** All 20 riders end up notified with no duplicates; Ramesh learns the operational gotcha (sandbox allow-list) and can graduate the WhatsApp number to production. Observable state: tracker `20/20` Sent after retry; `_sentIds` holds all 20 for this session.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-8 (partial/total failure + retry), UC-01TOURLIFECYCLEADMIN-10.
- **Screens/files:** `lib/screens/notify_screen.dart` (`_dispatchSeatAllocations`, `_firstError`, `_SendProgressDialog`), `lib/services/whatsapp_outbound.dart`.

---

### SC-S3LOCKNOTIFYRECEIVE-7: "Boarding moved to Gate 3" — one bus, one announcement, the morning of departure
- **Persona & goal:** Departure morning, the Volvo's boarding point shifts from the temple gate to Gate 3. Ramesh wants ONLY the Volvo riders told, not the whole two-bus tour.
- **Trigger (the activation):** A last-minute logistics change after the tour is locked and everyone already has their seat message.
- **Actors:** Ramesh (admin); Volvo riders (~40); bus-#2 riders who must NOT be confused by a wrong gate.
- **Phases spanned:** 8 (post-lock free-text per-bus broadcast).
- **Setup / messy data:** Locked two-bus Dwarka tour from SC-2. Volvo boards at Gate 3 now; bus #2 still boards at its own point. Ramesh is on the Notify tracker.
- **The flow:**
  1. On the tracker, Ramesh taps the **"Message this bus"** card.
  2. The composer opens. Because there are two buses, the bus selector shows; he picks **Volvo**. The recipient chip reads "40 recipients" (riders seated on the Volvo).
  3. He types, in Gujarati, "બોર્ડિંગ હવે ગેટ 3 પર — સવારે 6 વાગ્યે" ("Boarding now at Gate 3 — 6 AM"). The Gujarati string flows straight through as free text to the Cloud API.
  4. Tap Send. Success toast *"Message sent — 40."* Only Volvo riders receive it; bus-#2 riders are untouched.
- **Complications & recovery:** If Ramesh had picked bus #2 by mistake, the recipient chip would have shown bus #2's count, giving him a chance to notice before sending. An empty message is blocked with "Message can't be empty." A bus with zero seated riders disables Send / warns "no recipients" — so he can't fire into the void.
- **Real-world outcome (Expected):** Every Volvo rider knows the new gate; nobody on bus #2 is misdirected. Ramesh did it with one message, not 40, and in Gujarati. Observable state: send routed to Volvo's seated passengers only; bus-#2 recipients excluded.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-11.
- **Screens/files:** `lib/screens/notify_screen.dart` (`_BusMessageCard`, `_BusMessageComposer`, `_openBusMessageComposer`), `lib/services/whatsapp_outbound.dart` (`sendBusMessage`).

---

### SC-S3LOCKNOTIFYRECEIVE-8: Return-leg sell-off after a one-way crowd — GO done, freed seats become return tickets, and only return riders are re-notified
- **Persona & goal:** Ramesh ran a Somnath trip where half the riders booked GO-only (locals heading home a different way). After the GO leg lands, he wants to resell those freed seats as return-only tickets and notify only the new return riders — without unlocking the whole tour.
- **Trigger (the activation):** The bus reaches Somnath; the GO leg is finished; Ramesh marks GO complete and the return chart opens up.
- **Actors:** Ramesh (admin); GO-only riders (now `journeyDone`); two new return-only riders who DM after the GO leg; Mahesh (handler).
- **Phases spanned:** 8 post-lock RETURN-leg track.
- **Setup / messy data:** Locked tour, 40 seated, ~18 were outbound-only. After GO they vacate. Two community members (a Solanki cousin + a friend) message Ramesh wanting only the return leg into the now-empty seats.
- **The flow:**
  1. On the tour Overview the Next-Action card showed **"Complete GO leg."** Ramesh tapped it and confirmed — `completeOutboundLeg` froze the GO chart, freed the 18 outbound-only seats, and flagged those riders `journeyDone`. Crucially they're excluded from "pending to assign," so the app does NOT falsely shout "allocate 18."
  2. Overview now shows **"Add return ticket"** with the free return-seat count. Ramesh adds the two return-only riders into freed seats. This booking uses the sanctioned `overrideLock` bypass — the only place a NEW booking is allowed on a locked tour — so the lock gate doesn't reject them.
  3. Ramesh goes to Notify. The tracker lists the currently-seated (return + round-trip) riders. The 18 `journeyDone` GO-only riders are off the active roster, so they don't clutter the list and won't be re-messaged.
  4. He uses the per-rider chat button to send the two new return riders their seat-allotment message (seat picture + boarding + departure + Mahesh's contact), without re-blasting the 22 round-trippers who already have theirs.
- **Complications & recovery:** Completing the GO leg could have looked like "18 unassigned seats" and panicked Ramesh into re-seating ghosts — instead `journeyDone` keeps them out of the pending count and the GO chart is frozen for history. The two return bookings would normally be blocked by the lock gate; the return-phase override is precisely the exception that lets him resell without un-finalizing the whole trip.
- **Real-world outcome (Expected):** Ramesh resold the empty return seats, the new riders have correct return-leg seat messages, the original riders weren't spammed, and the GO chart is preserved for the record. Observable state: 18 riders `journeyDone` (seats freed, records kept), 2 return-only riders seated via `overrideLock`, only those 2 freshly notified, tour still `locked`.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-15, UC-01TOURLIFECYCLEADMIN-9 (override exception), UC-01TOURLIFECYCLEADMIN-10.
- **Screens/files:** `lib/screens/tour_detail_screen.dart` (`_nextActionFor`, `completeGoLeg`, `addReturnTicket`), `lib/controllers/tour_controller.dart` (`completeOutboundLeg`, `addPassenger(overrideLock: true)`), `lib/screens/notify_screen.dart`.

---

## Notes for the assembler
- **The commit moment has three gates in a row that must all be green to lock:** ≥1 passenger, all active assigned, a handler picked — and the disabled CTA names the *first* missing one. SC-1 and SC-2 turn that abstract checklist into "you forgot the handler" and "no handler on either bus."
- **Per-bus handler contact is load-bearing in the message,** not cosmetic: SC-2 shows a Chauhan on bus #2 calling Dinesh, not Mahesh. The fallback chain is `bus.handlerPassengerId ?? tour.handlerId`.
- **The customer reveal is gated on LOCK, not assignment** (SC-3, SC-4) — the single biggest "is this a bug?" trap. Provisional numbers never leak; the reveal and the WhatsApp message turn on together at lock.
- **You cannot keep a locked tour out of sync with the chart** (SC-5): editing a seat on a locked tour auto-reverts it to `assigning` and forces a re-lock, so a stale "locked" state can't ship.
- **Re-notify is always scoped** (SC-5, SC-6, SC-8): per-rider or per-failure or per-bus — the app never forces a full re-blast, which keeps customers from getting duplicate seat messages.
- **`journeyDone` + `overrideLock` are the two return-phase escape hatches** (SC-8) that let a locked tour resell freed seats without un-finalizing; sent markers are session-only so a restart never silently re-sends.
- **Gujarati matters at send time** (SC-7): free-text bus messages flow Gujarati straight to the Cloud API; the seat-allotment template body is localized per the recipient/app locale.
