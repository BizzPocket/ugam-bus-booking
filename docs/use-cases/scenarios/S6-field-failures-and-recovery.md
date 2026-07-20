# S6 — Field Failures & Recovery (real-world operational scenarios)

Operational cluster: **When things go wrong in the field.** These are believable, end-to-end
stories a real Ugam Foj / DEVAM tour agent, his on-bus handler, and Gujarati-speaking customers
live through — not unit checks. Each one names people, carries messy data, walks the actual
screens, hits a realistic complication, and ends with what the user can now *do* or *tell
someone*. Money is in ₹; the default app language is **Gujarati (`gu`)**; cash is collected on
the bus.

Personas used across this file:
- **Ramesh** — the tour agent/admin who runs the trips from his three DEVAM WhatsApp groups.
- **Mahesh** — the handler (a passenger Ramesh appoints as on-bus conductor); no admin login.
- **The Patels** — a family of 5 who always travel together.
- **The Solankis / the Chauhans** — friend-groups.
- **Kanjibhai & Jadiben** — an elderly couple, Gujarati-only readers, single sofas near the front.

Grounded in: `02-request-capture.md`, `07-handler-trip-day.md`, `08-customer-experience.md`,
`09-platform-auth-settings-i18n.md`, and the code paths cited per scenario.

---

### SC-S6FIELDFAILURESANDRECOVERY-1: A 41-seater is 6 berths short the Thursday before a Diu trip
- **Persona & goal:** Ramesh wants to run a 2-day Diu pilgrimage for ~45 people and must decide
  by Thursday night whether his one 41-seater is enough or he books a second bus, so he can tell
  the owner a firm number on Friday morning.
- **Trigger (the activation):** Saturday broadcast went out to all three DEVAM groups; by
  Wednesday the requests have piled up and the families keep DMing "બીજા ૪ જણ ઉમેરો" (add 4 more).
- **Actors:** Ramesh (admin), several customers.
- **Phases spanned:** 3 Collect Requests → 4 Tally (capacity read).
- **Setup / messy data:** 41-seater booked. Incoming demand is mixed-leg and group-bound:
  - Patel family — 2 Double Sofas + 1 Single, **full trip** (5 berths).
  - Solanki friends — 1 Double Sofa, **full trip** (2 berths).
  - Kanjibhai & Jadiben — 1 Single Sofa each, **full trip**, front (2 berths).
  - A college group — 3 Double Sofas **GO-only** (they'll find their own way back) → 6 berths of
    GO demand but **0.5 leg-weight each** in seat-load accounting.
  - Several round-trip seaters. Total physical demand lands near 47 going.
- **The flow:**
  1. Ramesh opens **Requests**, picks the Diu tour from the selector pills (UC-02…-9).
  2. He triages: waitlists the college GO-only group for now, confirms the Patels and the elderly
     couple (auto-sends the Cloud confirmation template — UC-02…-10).
  3. He watches the **collapsed capacity banner** glance line, then taps to expand it
     (UC-02…-16). With a bus present it shows the two-leg `UgamCapacityMeter` — placed/cap/**free
     as whole seats per leg**, driven by `computeTourCapacity` (engine-truth free, not naive
     capacity − demand).
  4. The banner reads going-leg **free = 0** and a **"needs your decision"** count for the riders
     the engine can't auto-seat. The shared sofas are counted ONCE (max(GO,RET)); the GO-only
     college group inflates the GO leg but not the return.
- **Complications & recovery:** The banner does NOT lie "FULL" while a single is empty
  (project_capacity_single_source); the over-demand for Double Sofas surfaces as `needsDecision`,
  never a phantom **negative** free count. Ramesh taps the needs-your-decision line, sees he is
  **6 berths short going**, and decides: book a second 30-seater rather than waitlist the Patels
  (a family that always travels whole).
- **Real-world outcome (Expected):** Ramesh can phone the bus owner Friday morning and say with
  confidence **"બે બસ — ૪૧ + ૩૦"** (two buses, 41 + 30). Observable state: capacity banner shows
  whole-seat free per leg (never a fractional `1.5` or a `%`), needs-decision count routes to the
  seating-exceptions screen, GO-only riders weigh 0.5 in seat-load but stay physically counted.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-9, UC-02REQUESTCAPTURE-10,
  UC-02REQUESTCAPTURE-16.
- **Screens/files:** `lib/screens/requests_screen.dart` (`_CapacityBanner`, `_TypeFreePill`),
  `lib/utils/tour_capacity.dart` (`computeTourCapacity`),
  `lib/design/components/ugam_capacity_meter.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-2: The Patels DM "add 4 more" twice in five minutes — one phone, two real requests
- **Persona & goal:** Jignesh Patel books for his whole joint family. He sends the form once for
  the 5 core members, then realizes his brother-in-law's family of 4 also wants in and submits
  again from the same phone — both are genuine, neither should overwrite the other.
- **Trigger (the activation):** Jignesh taps **Book** on the Somnath tour list row, fills the
  form, submits — then immediately opens **My Requests → Add another request** to add the second
  family.
- **Actors:** Jignesh Patel (customer).
- **Phases spanned:** 3 Collect Requests.
- **Setup / messy data:** Same phone `+91 98XXXXXXXX`. Request A: traveller "Patel — Jignesh
  (5)", 2 Double Sofa + 1 Single, full trip. Request B (added next): traveller "Patel — Mehul
  (4)", 2 Double Sofa, full trip. Different name, different seat mix.
- **The flow:**
  1. Jignesh submits Request A from the booking form; the screen replaces itself with **My
     Requests** (`Get.offNamed`) and a `customer_booking.success_sent_wa` toast fires; WhatsApp
     opens to Ramesh (UC-08…-6).
  2. On the Request A row he taps **Add another request** — a BLANK create form opens for the same
     tour (`existing == null`) (UC-02…-3, UC-08…-10).
  3. He types Mehul's family, 2 Double Sofa, submits.
  4. Migration-030 path inserts a fresh passenger + `booking_requests` audit row with a new UUID;
     Request A is NOT collapsed. Both now appear as separate rows in My Requests and as **two
     separate cards** on Ramesh's Requests screen.
- **Complications & recovery:**
  - **Excited double-tap on Submit within 15s** → the second tap is hard-blocked by the cooldown
    with `customer_booking.err_too_fast` (`_cooldownMs = 15000`), no duplicate network write.
  - **He re-opens Add-another and re-types the SAME family + same seat counts** by mistake → the
    exact-duplicate preflight soft-warns (`warn_duplicate_*`) with **submit-anyway**; because
    Mehul's request differs in name/seat mix from Jignesh's, it is correctly NOT flagged.
- **Real-world outcome (Expected):** Both families ride on Ramesh's roster as distinct requests;
  Ramesh sees two cards he can triage independently. Jignesh tracks both tickets on his one phone.
  Observable state: two passenger rows, two audit rows, no overwrite; cooldown blocks the panic
  double-submit but never blocks the genuine second family.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-1, UC-02REQUESTCAPTURE-3,
  UC-08CUSTOMEREXPERIENCE-6, UC-08CUSTOMEREXPERIENCE-10.
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart` (`_openAddAnother`),
  `lib/screens/customer_booking_request_screen.dart` (`_preflightCreate`, `_cooldownMs`),
  `lib/services/customer_requests_store.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-3: Kanjibhai & Jadiben never switch off Gujarati — the whole loop must read in their script
- **Persona & goal:** Kanjibhai (68) and Jadiben (64) read only Gujarati. They want two single
  sofas near the front for the full Ambaji trip and must be able to do the entire loop — find the
  tour, request, track, see seats after lock — without ever touching English.
- **Trigger (the activation):** A grandchild installs the app on Kanjibhai's phone and hands it
  over; the app's first launch is already in **Gujarati** (default/fallback/start locale = `gu`),
  so nothing needs to be switched.
- **Actors:** Kanjibhai & Jadiben (customers).
- **Phases spanned:** 3 Collect Requests → 8 Lock & Notify (seat reveal).
- **Setup / messy data:** Fresh install, no language ever changed. Request: 2 Single Sofa, full
  trip, note typed in Gujarati ("આગળની સીટ જોઈએ" — want a front seat). Phone `+91 99XXXXXXXX`.
- **The flow:**
  1. App cold-starts → splash → `/customer-home` in Gujarati without any login (UC-09…-2).
  2. Kanjibhai reads the **Explore** header (`customer_tour_list.header_explore`), the date pill
     localized via `app.month.short.*`, taps the Ambaji row's **Book** pill.
  3. Booking form: every label, the leg tabs (Full trip / Go only / Return only), the sticky CTA
     seat-count and estimated-total all render via `tr(...)` in Gujarati. He sets 2 Single Sofa,
     types the Gujarati note, submits.
  4. After Ramesh locks the tour and assigns seats, Kanjibhai opens **My Requests**, sees the
     green "બેઠક ફાળવાઈ" (Seats assigned) chip, taps the row → the seat-layout sheet opens with
     **his two seats highlighted**, all others anonymous (UC-08…-11).
- **Complications & recovery:**
  - Before lock the row shows the warm **"finalizing"** state (`chip_seats_finalizing`); tapping
    it shows `seats_pending_toast` — in Gujarati — and **no provisional seat numbers leak**
    (UC-08…-12). Kanjibhai isn't confused by a half-finished assignment.
  - String-parity is load-bearing here: any new string on these screens missing from
    `gu.json` would render the raw key and break his loop. All six customer namespaces are at
    en/gu/hi parity (UC-08…-15).
- **Real-world outcome (Expected):** Kanjibhai completes browse → request → track → seat-view
  entirely in Gujarati and can tell Jadiben "આપણી સીટ ફાળવાઈ ગઈ, આગળ છે" (our seats are
  allotted, up front). Observable state: locale persists as `gu`; no English fragment on any
  customer surface he touched; seat numbers appear only post-lock.
- **Base-level UCs exercised:** UC-09PLATFORMAUTHSETTINGSI18N-2, UC-09PLATFORMAUTHSETTINGSI18N-11,
  UC-08CUSTOMEREXPERIENCE-6, UC-08CUSTOMEREXPERIENCE-11, UC-08CUSTOMEREXPERIENCE-12,
  UC-08CUSTOMEREXPERIENCE-15.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart`,
  `lib/screens/customer_booking_request_screen.dart`,
  `lib/screens/customer_my_requests_screen.dart`, `lib/config/i18n_config.dart`,
  `assets/translations/{en,gu,hi}.json`

---

### SC-S6FIELDFAILURESANDRECOVERY-4: The Chauhans cancel two of five seats the night before, on a locked tour
- **Persona & goal:** Ramesh needs to drop 2 of the Chauhan family's 5 seats at 10pm the night
  before departure (two cousins backed out) WITHOUT cancelling the whole booking and without
  re-opening the locked tour to everyone.
- **Trigger (the activation):** Mr. Chauhan phones Ramesh: "પાંચમાંથી બે જણ નથી આવતા" (two of our
  five aren't coming). The Saurashtra tour is already **locked** (`acceptsBookings == false`),
  seats assigned and visible.
- **Actors:** Ramesh (admin), Mr. Chauhan (phone-in customer).
- **Phases spanned:** 8 Lock & Notify (post-lock edit).
- **Setup / messy data:** Chauhan request = 2 Double Sofa + 1 Single, full trip (5 berths), all
  seats assigned on Bus #1. Ramesh must drop exactly one Double-Sofa berth and one... no — Mr.
  Chauhan specifies the two cousins shared one double, so Ramesh drops **one whole Double Sofa
  seat** (2 berths) → request goes from 5 to 3.
- **The flow:**
  1. Ramesh opens the tour's seat workspace, finds the Chauhan double on Bus #1.
  2. He uses the **cancel-one-seat** flow (the phone-in "I booked N but need fewer now" path):
     pick the seat to drop → `cancelOneSeat` does BOTH the unassignment AND the request-line
     decrement, so the Chauhans don't keep showing as "outstanding" in Requests.
  3. The method looks up the seat's type+position from the bus layout to decrement the right
     `RequestLine` (exact type+position first, seatType-only fallback); the freed double becomes
     an empty berth on the chart.
- **Complications & recovery:**
  - Because the tour is locked, a *new* booking would be blocked — but **cancelling** an existing
    seat is allowed; the locked gate guards new writes (`addPassenger`), not a seat release.
  - `_revertLockOnUnseat` runs after the unassign so the tour's lock/fullness state is reconciled
    (an empty seat no longer falsely reads FULL).
  - If no matching request line exists, only the seat is freed and the request is left untouched
    (defensive) — Ramesh doesn't accidentally zero out the family.
- **Real-world outcome (Expected):** Ramesh tells Mr. Chauhan "થઈ ગયું, ત્રણ સીટ રહી" (done, three
  seats remain). The freed Double Sofa shows as an empty berth the handler can re-seat a waitlist
  rider into. Observable state: Chauhan `assignedSeats` down by the released seat, request-line
  qty decremented, capacity meter reflects the now-free berth.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-4 (lock gate boundary),
  UC-02REQUESTCAPTURE-13 (edit auto-release), UC-08CUSTOMEREXPERIENCE-7.
- **Screens/files:** `lib/controllers/tour_controller.dart` (`cancelOneSeat`,
  `_revertLockOnUnseat`), `lib/models/request_line.dart`, `lib/models/seat_layout.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-5: A no-show at the boarding point — Mahesh marks "left behind", money stays straight
- **Persona & goal:** Mahesh, the handler, is at the Maninagar boarding point at 5:45am. One
  rider on his manifest, "Rohit Solanki", never shows. Mahesh needs the boarded count to be honest
  so the bus leaves with the right tally and the money board doesn't pretend Rohit paid.
- **Trigger (the activation):** Departure time; Mahesh is calling the roster down the list, but
  Rohit doesn't answer his phone after three rings.
- **Actors:** Mahesh (handler), Rohit Solanki (no-show passenger).
- **Phases spanned:** 7 Assign Handler / Trip execution.
- **Setup / messy data:** Bus #1, 41 seats, ~38 boarded. Rohit holds 1 Single Sofa, full trip,
  fare ₹1,400, **not yet collected**. Mahesh reached the chart via **My Requests → open full
  chart** (he has his own ticket) (UC-07…-1).
- **The flow:**
  1. Mahesh opens the **Attendance** tab, GO leg selected (`att_leg_go`) (UC-07…-7).
  2. Header tally shows **Present / Left behind / Total**; because **unmarked = NOT boarded** in
     the handler tally (`_isPresent` defaults to `false` with no row), the count is honest from
     the start — he doesn't have to "un-board" anyone.
  3. He marks the 38 who showed as present; Rohit stays unmarked → counts as left-behind.
     (Optionally he flips Rohit's switch explicitly so the row reads intentional, not forgotten.)
  4. The GO/RET boarded chips under the money hero (`_BoardedSummary`) update in **every** view
     without a reload (cache keyed `passengerId|busId|leg`).
- **Complications & recovery:**
  - Rohit's ₹1,400 was never collected → it stays in **"To collect"**, NOT silently zeroed; the
    seat-level money dot stays red. Mahesh doesn't accidentally show the bus as fully paid.
  - The bus leaves; Mahesh phones Rohit one more time from the roster's round call button
    (`PhoneDialer.call`) — still no answer. The left-behind tally is the record Ramesh sees later.
- **Real-world outcome (Expected):** Mahesh can tell Ramesh "Rohit ચડ્યો નહીં, ₹૧,૪૦૦ બાકી, સીટ
  ખાલી" (Rohit didn't board, ₹1,400 outstanding, seat empty). Observable state: GO boarded = 38,
  left-behind ≥ 1, Rohit's fare in `toCollect`, his seat dot red, no false "paid".
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-3, UC-07HANDLERTRIPDAY-7,
  UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_AttendanceView`,
  `_togglePresent`, `_isPresent`, `_BoardedSummary`, `_SeatRoster`),
  `lib/models/attendance.dart`, `lib/utils/phone_dialer.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-6: Mahesh collects cash on the highway with no signal — and a save fails
- **Persona & goal:** Mahesh is collecting cash seat-by-seat as the bus runs between Rajkot and
  Somnath, where the mobile data drops in and out. He needs every collection to actually land,
  and to know immediately when one didn't.
- **Trigger (the activation):** Mid-journey cash collection; the bus enters a dead zone right as
  he saves the Solanki double's payment.
- **Actors:** Mahesh (handler), the Solanki friends (paying riders).
- **Phases spanned:** Trip execution / Settlement.
- **Setup / messy data:** Bus #1. Solanki double = ₹2,800 due (whole sofa). Mahesh collects
  ₹3,000, returns ₹200 change. Several other riders queued behind. One rider, Dinesh, hands ₹500
  short ("બાકીના સાંજે આપીશ" — I'll give the rest by evening).
- **The flow:**
  1. Mahesh taps the Solanki seat → `_CollectSheet` opens with read-only Seat + Amount due lines
     (UC-07…-5).
  2. He enters **Received ₹3,000**, **Returned ₹200**; the live balance pill turns **good**
     (`balance_settled`) at net ₹2,800. He taps **Save**.
  3. Save calls `handlerUpsertCollection` over the network; on the dead-zone attempt the RPC
     **throws** → `handler_chart.error_save_collection` toast, the sheet **stays open**, `_saving`
     resets. Nothing is silently lost.
  4. A minute later signal returns; Mahesh taps **Save** again → the server row comes back and is
     cached keyed `passengerId|busId|seatId`; the money hero, seat dot, and roster status all
     refresh without a reload. **In hand** rises by ₹2,800.
  5. For Dinesh's partial: Received ₹900 against ₹1,400 → balance pill goes **danger**
     (`balance_still_to_collect`); saved as a real partial, leaving ₹500 in `toCollect`.
- **Complications & recovery:** The offline failure is recoverable because the sheet doesn't close
  on error and the optimistic UI never claims success the network didn't confirm — the handler
  retries rather than re-counting cash. Partial payments are first-class (the shortfall stays
  visible), so Dinesh's ₹500 doesn't vanish.
- **Real-world outcome (Expected):** By Somnath the money board is true: collected reflects real
  cash, Dinesh shows ₹500 owing, nothing was double-saved. Observable state: Solanki seat dot
  green only after the retry succeeds; **In hand = collected + income − spent**; failed save left
  no orphan row.
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-5, UC-07HANDLERTRIPDAY-11.
- **Screens/files:** `lib/screens/handler_bus_chart_screen.dart` (`_CollectSheet`,
  `_showOccupantSheet`), `lib/services/customer_requests_store.dart`
  (`handlerUpsertCollection`), `lib/models/collection.dart`, `lib/models/handler_bus_money.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-7: Reinstalled phone, empty "My Requests" — recover the seat by phone
- **Persona & goal:** Bhavna Patel dropped her phone, reinstalled the app the morning of the
  Dwarka trip, and her **My Requests** is empty — even though her seat is live server-side. She
  needs to find her allotted seat before boarding without re-booking.
- **Trigger (the activation):** Fresh install on the trip morning; the tour is already **locked**
  and her seat is held under her phone.
- **Actors:** Bhavna Patel (customer with a live seat but no device-local ticket).
- **Phases spanned:** 8 Lock & Notify (post-lock recovery).
- **Setup / messy data:** Reinstalled app → `CustomerRequestsStore` (SharedPreferences,
  `customer_requests_v1`) is empty; the device-local journal is gone. Her real seat: 1 Single
  Sofa, Bus #1, full trip, under `+91 97XXXXXXXX`.
- **The flow:**
  1. App opens to `/customer-home`; **My Requests** shows the `inbox` empty state — the #1
     device-locality surprise (UC-08…-8, cross-cutting note).
  2. Bhavna opens **menu → Find my seat** (`FindMySeatScreen`), enters her mobile, taps **Find**
     (UC-08…-14).
  3. App runs `seat_lookup_by_phone` + `handler_requests_by_phone` in parallel (matched on
     **last 10 digits**, so the +91 prefix doesn't matter).
  4. A ticket card renders: tour title, route, her name, an accent **"Your seats: …"** chip, and
     the bus diagram with HER seat highlighted, everyone else anonymous.
- **Complications & recovery:**
  - She first mistypes 9 digits → inline `find_seat.error_short`, no network call; she corrects it.
  - Because only **LOCKED/completed** tours return seats, this works precisely because the agent
    has locked the tour — an unlocked tour would return nothing (seats still provisional). Here
    that's the right behavior.
  - She was originally **manually added** by Ramesh (no in-app request of her own), and find-my-seat
    still resolves her by phone — the path exists exactly to cover the no-ticket gap.
- **Real-world outcome (Expected):** Bhavna walks to her single sofa without calling Ramesh.
  Observable state: My Requests stays empty (device-local), but find-my-seat returns her live
  ticket with only her seat highlighted; identities of co-passengers never shown.
- **Base-level UCs exercised:** UC-08CUSTOMEREXPERIENCE-8, UC-08CUSTOMEREXPERIENCE-14,
  UC-07HANDLERTRIPDAY-2 (phone-resolution mechanics).
- **Screens/files:** `lib/screens/find_my_seat_screen.dart`,
  `lib/services/customer_requests_store.dart` (`seatsByPhone`), `lib/models/seat_ticket.dart`

---

### SC-S6FIELDFAILURESANDRECOVERY-8: Same phone is also the handler — recover the WHOLE bus, not just one seat
- **Persona & goal:** Mahesh reinstalled his phone too (it's his and his family's only handset).
  He's the appointed handler on the Dwarka return leg and needs to get back into the **full bus
  chart** to keep collecting return fares — not just see his own seat.
- **Trigger (the activation):** Outbound is done (several riders `journeyDone`); the bus is about
  to turn around for the return and Mahesh's app has no local ticket after reinstall.
- **Actors:** Mahesh (handler, also a seated passenger).
- **Phases spanned:** Return-leg phase / Trip execution.
- **Setup / messy data:** Mahesh's phone holds a seat AND is the tour's designated handler. After
  reinstall, both My Requests and any cached manifest are gone. Return-only riders on shared sofas
  owe halved fares.
- **The flow:**
  1. Mahesh opens **Find my seat**, enters his number (UC-07…-2).
  2. The lookup returns his ticket card — and because his phone also handles the tour, a
     **"Manage as handler"** CTA appears inline (`_TicketCard.handlerRequestId` set).
  3. Tapping it pushes `HandlerBusChartScreen(requestId: …)`; the server RPC `is_request_handler`
     re-verifies him before the manifest loads (fail-closed if he weren't the handler).
  4. He opens a shared return sofa → the leg-scoped chooser opens **defaulting to RETURN** because
     `outboundDone` is true (any passenger `journeyDone`) → `defaultCollectLeg` (UC-07…-18). He
     collects the halved return fare.
- **Complications & recovery:**
  - Had he NOT been the handler, no "Manage as handler" CTA would appear and the manifest RPC
    would refuse (null → `no_bus_chart` empty state) — the full manifest is never exposed to a
    plain passenger (UC-07…-16). Fail-closed is the safety net.
  - A reinstall doesn't strip his handler authority because authority is **server-side per-tour by
    phone**, not a local token.
- **Real-world outcome (Expected):** Mahesh resumes return-leg collection on the full chart minutes
  after reinstalling, with the chooser already on the Return leg. Observable state: handler chart
  loads via re-verified requestId; return chooser default = RETURN; one-way return riders show the
  RET ½ leg pill + half-fare note.
- **Base-level UCs exercised:** UC-07HANDLERTRIPDAY-2, UC-07HANDLERTRIPDAY-16,
  UC-07HANDLERTRIPDAY-18, UC-08CUSTOMEREXPERIENCE-14.
- **Screens/files:** `lib/screens/find_my_seat_screen.dart` (`_TicketCard`,
  `_HandlerEntryCard`), `lib/screens/handler_bus_chart_screen.dart`,
  `lib/services/customer_requests_store.dart` (`handlerRequestsByPhone`, `isRequestHandler`),
  `lib/utils/seat_occupants.dart` (`defaultCollectLeg`)

---

### SC-S6FIELDFAILURESANDRECOVERY-9: A request slips in just as Ramesh locks the tour — the mid-flow lock race
- **Persona & goal:** Ramesh is locking the Palitana tour Friday night to freeze the manifest. At
  the same moment a late customer, Hardik, who opened the booking form 10 minutes ago, hits
  Submit. Ramesh needs the lock to hold — no rider should slip in after freeze — while Hardik gets
  an honest message, not a silent failure.
- **Trigger (the activation):** Ramesh taps **Lock** on the tour; Hardik taps **Submit** on a form
  he opened while the tour was still open.
- **Actors:** Ramesh (admin), Hardik (late customer).
- **Phases spanned:** 8 Lock & Notify ↔ 3 Collect Requests boundary (race).
- **Setup / messy data:** Tour flips `status → locked` (`acceptsBookings` becomes false). Hardik's
  form is stale: his `widget.tour` still says open. He's requesting 1 Double Sofa, full trip.
- **The flow:**
  1. Ramesh locks the tour. On the customer **list**, the Palitana row's Book pill switches to a
     non-actionable **lock** chip; the detail CTA reads `customer_tour_detail.cta_bookings_closed`
     with `onTap == null` (UC-02…-4, UC-08…-7).
  2. Hardik (who never saw the lock because his form was already open) taps **Submit**.
  3. `_submit` re-checks the **LIVE** tour via `TourController.getTour` — NOT the stale
     `widget.tour` — and aborts with `customer_booking.err_bookings_closed`. No passenger row is
     written.
- **Complications & recovery:**
  - The double-guard is the point: the UI affordance hides the entry AND the submit path
    re-verifies against the live tour, so a form opened pre-lock can't slip a rider through after
    freeze. Hardik sees a clear "bookings closed" message in his language, not a crash.
  - If Ramesh genuinely wants to add Hardik anyway (e.g. a return-leg seat), the admin
    **overrideLock** escape hatch on `addPassenger` is the deliberate, agent-controlled path —
    customers never get it.
- **Real-world outcome (Expected):** The locked manifest holds; Ramesh can broadcast the final
  seat allocation knowing no late row crept in. Hardik gets an honest closed-bookings toast and
  can WhatsApp Ramesh to ask for a manual add. Observable state: tour `locked`, Hardik has no
  passenger/request row, his customer-side affordances all show the locked state.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-4, UC-08CUSTOMEREXPERIENCE-6,
  UC-08CUSTOMEREXPERIENCE-7, UC-02REQUESTCAPTURE-12 (overrideLock escape hatch).
- **Screens/files:** `lib/screens/customer_booking_request_screen.dart` (`_submit` live re-check),
  `lib/screens/customer_tour_list_screen.dart` (`_BookPill`),
  `lib/screens/customer_tour_detail_screen.dart` (`_StickyBookCta`),
  `lib/models/tour_status.dart` (`acceptsBookings`),
  `lib/controllers/tour_controller.dart` (`addPassenger` `overrideLock`)

---

## Cross-scenario field notes for testers
- **Device-locality is the #1 field surprise** (SC-7, SC-8): a reinstall empties My Requests but
  never touches the live seat — always recover via **Find my seat by phone** (last-10-digit match).
- **Failures must be honest, never silent** (SC-5, SC-6): an unmarked passenger reads as
  not-boarded, an uncollected fare stays in `toCollect`, and a failed collection save keeps the
  sheet open for retry — the app never fakes a success the network didn't confirm.
- **The lock gate is double-checked** (SC-4, SC-9): UI hides the affordance AND `_submit`
  re-verifies the live tour, while cancellations and the admin `overrideLock` remain available.
- **Gujarati is the default, not an option** (SC-3): the whole customer loop must read in `gu`
  with full 3-file string parity, or a `tr()` key renders raw for a Gujarati-only reader.
- **Multiple genuine requests per phone are first-class** (SC-2): the 15s cooldown blocks a panic
  double-tap, the exact-duplicate soft-warn catches an accidental repeat, but a genuinely
  different second family always passes.
