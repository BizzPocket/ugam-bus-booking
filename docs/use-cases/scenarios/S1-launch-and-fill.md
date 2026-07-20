# Scenarios — S1: Launching a tour & filling the bus (real demand over days)

**Cluster:** Launch a trip → broadcast → requests trickle in over days → tally true
demand → decide bus count (one vs a second bus vs waitlist).
**Lifecycle:** Phases 1–5 (Create → Broadcast → Collect Requests → Tally → Add Bus).
**Personas:** Ramesh & Jignesh (tour agents), the Patel / Solanki / Chauhan families,
two friends Bhavesh & Hardik, the elderly couple Kanjibhai & Jadiben. Money in ₹.
Default app language is **Gujarati** — notes flag where a `gu` string is load-bearing.

These are end-to-end OPERATIONAL stories, not unit checks. Each scenario cites the
base-level UC ids it exercises from `01-tour-lifecycle-admin.md`,
`02-request-capture.md`, `03-bus-management.md`. The mechanics are grounded in
`lib/utils/tour_capacity.dart` (`computeTourCapacity`, leg demand = `max(GO,RET)`,
`needsDecision`), `lib/screens/tour_overview_screen.dart` (`_SummaryCard`,
`_CapacityBanner`), `lib/screens/requests_screen.dart` (`_CapacityBanner` no-bus
"Need {go} going · {ret} returning"), `lib/screens/add_bus_screen.dart` (3-step
wizard, uniform vs price-bands), `lib/controllers/tour_controller.dart`
(`createTour`, `addPassenger`, `addBus`, `setWaitlisted`, `setConfirmed`).

---

### SC-S1LAUNCHANDFILL-1: Ramesh launches the Diu pilgrimage and broadcasts to three WhatsApp groups
- **Persona & goal:** Ramesh, the tour agent, wants to open a 2-day Diu pilgrimage
  for the DEVAM / Ugam Foj community and start collecting interest the same evening.
  His goal is a live, shareable tour the families can request against — even before
  a single bus is booked.
- **Trigger (the activation):** It's Saturday night; Ramesh decides the trip is on and
  taps "+" on the Tours tab to create it and fire the broadcast immediately.
- **Actors:** Ramesh (admin). Downstream: ~45 community members on three WhatsApp groups.
- **Phases spanned:** 1 (Create) → 2 (Broadcast).
- **Setup / messy data:** Ramesh has the date firm (departs Sat, returns Sun) but
  has NOT priced anything and has NO bus owner confirmed yet. He types the name in
  Gujarati ("દીવ યાત્રા"), From = Ahmedabad, To = Diu. He has a poster image saved
  from last year's trip.
- **The flow:**
  1. Tours tab → circular "+" (`tours.create`) → Create Tour screen.
  2. Types the Gujarati tour name; From "Ahmedabad", To "Diu"; watches the live
     preview card and the route monogram update (~90ms debounce).
  3. Picks the departure date (Saturday) and a 6:00 AM departure time; picks the
     return date (Sunday). Leaves price empty — pricing is per-bus later.
  4. Attaches last year's poster as the broadcast image, edits the broadcast
     message to mention "બે દિવસ" (two days) and the boarding point.
  5. Taps "Create & Broadcast" (`create_tour.action.create_broadcast`).
- **Complications & recovery:**
  - The poster upload fails (weak signal). The tour is STILL created (image silently
    dropped) and a warning toast `create_tour.broadcast_image_upload_failed` shows —
    Ramesh doesn't lose the tour over a flaky image (UC-01...-1 edge).
  - WhatsApp's group picker opens with the announcement pre-filled and the text also
    copied to clipboard; Ramesh shares it to all three DEVAM groups in turn (the
    same `broadcastTour` deep-link, fire-and-forget).
- **Real-world outcome (Expected):** A live "દીવ યાત્રા" tour exists in status
  `planning` (no passenger yet), `pricePerSeat == 0`, sitting at the top of "This
  week" in the Tours list. The announcement is out to all three groups. Ramesh can
  now tell the bus owner "interest is collecting, I'll confirm seat counts by
  Friday." The tour is a route-and-date shell that families can request against
  before any bus is booked.
- **Base-level UCs exercised:** UC-01TOURLIFECYCLEADMIN-1, UC-01TOURLIFECYCLEADMIN-6,
  UC-01TOURLIFECYCLEADMIN-14 (it appears under "This week"), UC-01TOURLIFECYCLEADMIN-17 (Gujarati name renders).
- **Screens/files:** `lib/screens/create_tour_screen.dart`,
  `lib/controllers/tour_controller.dart::createTour`,
  `lib/services/whatsapp_service.dart::broadcastTour`, `lib/screens/tours_screen.dart`.

---

### SC-S1LAUNCHANDFILL-2: Requests trickle in over two days — families that must sit together, mixed legs, one payer
- **Persona & goal:** Over Sunday and Monday the requests pile into Ramesh's inbox.
  His goal across two days is simply to CAPTURE each family's real, messy ask
  faithfully — who sits with whom, which legs, who's paying — without losing or
  flattening anyone.
- **Trigger (the activation):** Notifications fire as twelve families DM and submit
  the in-app form; Ramesh also keys in two phone-only requests himself.
- **Actors:** Ramesh (admin); the Patels, Solankis, Chauhans, the friends Bhavesh &
  Hardik, the elderly couple Kanjibhai & Jadiben (customers).
- **Phases spanned:** 2 → 3 (Collect Requests).
- **Setup / messy data (the real asks):**
  - **Patel family of 5** — wants 2 Double Sofas + 1 Single Sofa, **RETURN-ONLY**
    (they'll reach Diu by their own car and only need the bus back). Devang Patel
    pays for the whole family.
  - **Bhavesh & Hardik** — 1 Double Sofa, **full trip** (they'll share the sofa).
  - **Solanki family of 4** — 2 Double Sofas, full trip; mum is anxious, asks to be
    "near the front" (a priority request, agent-approved later).
  - **Chauhan family of 3** — 1 Double Sofa + 1 Single Sofa, but MIXED: the double is
    **GO-only**, the single is **full trip** (grandfather returns by train).
  - **Kanjibhai & Jadiben** — the elderly couple wants **a Single Sofa each near the
    front**, full trip.
  - Plus four more small requests Ramesh keys in from WhatsApp DMs by hand.
- **The flow:**
  1. Customers fill the in-app booking form; each submit writes one passenger + one
     `booking_requests` audit row via `submit_booking_request`, and WhatsApp hands
     them off to Ramesh.
  2. The Chauhan request is a true mixed-leg: on the form they set Double Sofa = 1 on
     the **Go only** tab and Single Sofa = 1 on the **Full trip** tab — producing one
     GO-only `RequestLine` and one round-trip `RequestLine` (per-line leg is the
     source of truth; derived `tripType` summarises as round-trip).
  3. Ramesh opens the **Requests** tab, selects "દીવ યાત્રા", and watches the **New**
     list grow newest-first. He taps phones to confirm a couple of asks on WhatsApp.
  4. For the two phone-only DMs he uses the **person-add** action and keys name +
     phone + seat counts; they're remembered in his contact directory.
  5. He toggles **priority ON** for Solanki-mum and approves the alert (priority is
     requested-by-customer, approved-by-agent — never auto-derived from age).
- **Complications & recovery:**
  - **Devang Patel submits twice** — once for himself, once "for my brother's family"
     under the same phone. The second submission does NOT overwrite the first
     (migration 030): both appear as separate New cards. Because the second had a
     different name/seat-mix it is NOT flagged a duplicate.
  - **An impatient re-tap within 15s** is hard-blocked client-side
    (`customer_booking.err_too_fast`) — no double row.
  - One DM-keyed request had a 9-digit phone; the form blocks it inline
    (`booking_form.err_phone_invalid`) before any write.
- **Real-world outcome (Expected):** Every family's true ask is captured with the
  RIGHT legs and groupings — Patel return-only, Chauhan mixed-leg, the elderly couple
  as two single-sofa full-trip riders, Solanki-mum flagged PRIORITY. The New tab seat
  chips count BERTHS (a Double Sofa line = 2). Ramesh can now read aggregate demand,
  not a pile of chats.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-1, UC-02REQUESTCAPTURE-2
  (mixed-leg), UC-02REQUESTCAPTURE-3 (second request same phone),
  UC-02REQUESTCAPTURE-6 (phone validation), UC-02REQUESTCAPTURE-9 (New tab triage),
  UC-02REQUESTCAPTURE-12 (manual add), UC-02REQUESTCAPTURE-15 (priority).
- **Screens/files:** `lib/screens/customer_booking_request_screen.dart`,
  `lib/widgets/booking_capture_form.dart`, `lib/screens/requests_screen.dart`,
  `lib/models/request_line.dart`, `lib/controllers/tour_controller.dart::addPassenger`.

---

### SC-S1LAUNCHANDFILL-3: Friday tally — Ramesh reads TRUE demand and the no-bus banner tells him what to book
- **Persona & goal:** It's Friday morning. Ramesh must tell the bus owner an exact
  seat count TODAY. His goal is to convert twelve messy requests into one honest
  number per leg and per seat type — without double-counting the leg-sharers.
- **Trigger (the activation):** Ramesh opens the tour's Overview / Requests to do the
  "what to book" tally before he calls the owner.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 3 → 4 (Tally & Book Bus).
- **Setup / messy data:** No bus is booked yet (`totalBusSeats == 0`). The captured
  roster sums to roughly: doubles from Bhavesh/Hardik (1), Solanki (2), Patel (2),
  Chauhan GO-only (1) = 6 Double Sofas; singles from Patel (1), Chauhan full (1),
  Kanjibhai (1), Jadiben (1) = 4 Single Sofas; plus the four hand-keyed small asks.
  Critically, the Patel block is RETURN-ONLY and the Chauhan double is GO-ONLY.
- **The flow:**
  1. **Tour Overview** `_SummaryCard`: the "Bus requirements / what to book" line
     shows per-type UNIT counts — a Double Sofa is ONE unit (one tile), not its two
     berths — and `total_to_book` = singles + doubles + seaters. This is the number
     Ramesh reads aloud to the owner ("6 double, 4 single …").
  2. **Requests capacity banner** (no bus yet): because there's no bus, the banner
     tints warm and shows per-leg DEMAND as whole seats — `Need {go} going · {ret}
     returning`. The GO and RET numbers DIFFER because Patel is return-only and the
     Chauhan double is go-only — Ramesh sees the two legs aren't symmetric.
  3. He notes the asymmetry: the return leg is heavier (Patel's 5) than he'd assumed
     from a naive "headcount".
- **Complications & recovery:**
  - Ramesh almost reads "12 families ≈ 24 berths" off the top of his head. The app
    corrects him: the requirement chips count requested berths per type (waitlisted
    included in the CHIPS), while the no-bus banner shows the per-leg whole-seat
    demand so he doesn't conflate GO and RET into one inflated total. The two legs
    are shown separately — never merged, never fractional.
  - A waitlisted hold would still show in the requirement CHIPS but is excluded from
    the banner's `demandBerths` — so holding someone doesn't make the "what to book"
    number lie.
- **Real-world outcome (Expected):** Ramesh has an exact, leg-split shopping list:
  the unit counts to book AND the per-leg seat demand (GO vs RET) with the
  return-leg-heavy reality visible. He can now reason about ONE bus vs TWO, knowing a
  return-only block and a go-only block can partly share berths once seated.
- **Base-level UCs exercised:** UC-03BUSMANAGEMENT-1 (requirements / what to book),
  UC-02REQUESTCAPTURE-16 (no-bus per-leg demand banner), UC-03BUSMANAGEMENT-15
  (per-type breakdown never negative).
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_SummaryCard`),
  `lib/screens/requests_screen.dart` (`_CapacityBanner`),
  `lib/utils/tour_capacity.dart::computeTourCapacity`.

---

### SC-S1LAUNCHANDFILL-4: One 41-seater isn't enough — the banner says 6 short, Ramesh books bus #2
- **Persona & goal:** Ramesh's instinct is "one big sleeper will do." His goal is to
  TEST that instinct against engine truth and, if it fails, decide between a second
  bus and a waitlist — then give the owner a firm "2 buses, 41+30."
- **Trigger (the activation):** Ramesh adds a single 41-berth sleeper, runs the
  tally, and the capacity banner turns warm: he's short.
- **Actors:** Ramesh (admin), the bus owner (off-app).
- **Phases spanned:** 4 (Tally) → 5 (Add Bus).
- **Setup / messy data:** The full Friday roster needs more berths on the busier leg
  than one 41-seater offers (the engine's load is `max(GO, RET)` per bus). Several
  doubles want to sit as whole sofas; the elderly couple need two fronts.
- **The flow:**
  1. **Manage Buses → Add bus.** Step 1 identity: Ramesh names it "Bus 1", AC ON,
     boarding "Naroda", departure 6:00 AM. No field is hard-required (he leaves the
     registration blank to fill later).
  2. Step 2 capacity: stepper to 41 total seats; sets the single-sofa count so the
     elderly couple and the singles fit; reads the live "X single sofas + Y double
     sofas" summary. The engine (`BusLayout.generate`) keeps lane pairs even.
  3. Step 3 price (uniform "Same for all"): enters the whole bus rent; the per-seat
     field auto-fills as `busPrice ÷ 41` with the "÷ 41 seats" note; single = base,
     double = 2 × base pre-seed. Saves.
  4. Adding the first bus advances the tour `collecting → busBooked`.
  5. Back on **Tour Overview**, the warm `_CapacityBanner` appears: it reads the
     ENGINE shortfall, not a naive `demand − capacity`. The headline is the
     "short" message with `demand`/`capacity`/`shortfall` — about **6 berths short**.
  6. Ramesh taps **"Add a bus"** straight from the banner and adds **Bus 2** as a
     30-berth sleeper, same uniform pricing.
- **Complications & recovery:**
  - Ramesh worries the "6 short" is the old lie where a return-only and a go-only
    rider were counted as two seats. It is NOT: `shortfall` is
    `computeTourCapacity(tour).needsDecision` (engine truth) — leg-sharing is already
    honored, so the banner doesn't overstate the gap. The number he sees is the real
    number of riders the engine genuinely can't seat.
  - After Bus 2 is added the banner clears (demand now fits with seatable riders), and
    the per-bus meters and the banner agree because they read the SAME plan.
- **Real-world outcome (Expected):** Two buses on the tour (41 + 30 = 71 berths), tour
  in `busBooked`. The capacity banner is gone. Ramesh phones the owner with a firm
  order: **"2 buses, 41 and 30."** The per-bus two-leg meters show honest GO/RET loads.
- **Base-level UCs exercised:** UC-03BUSMANAGEMENT-2 (engine-truth shortfall banner),
  UC-03BUSMANAGEMENT-3 / -4 / -5 (add-bus steps 1–3 uniform), UC-03BUSMANAGEMENT-7
  (save advances status), UC-03BUSMANAGEMENT-11 (leg-aware meters).
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_CapacityBanner`),
  `lib/screens/add_bus_screen.dart`, `lib/screens/manage_buses_screen.dart`,
  `lib/controllers/tour_controller.dart::addBus`, `lib/utils/tour_capacity.dart`.

---

### SC-S1LAUNCHANDFILL-5: Leg-sharing rescue — the "6 short" shrinks to "3 short" instead of buying a whole second bus
- **Persona & goal:** Jignesh (a second agent covering for Ramesh on a different
  Somnath trip) sees a "short" banner and his goal is to AVOID over-booking a second
  bus when the gap is really a few one-way riders who can share berths.
- **Trigger (the activation):** Jignesh adds one 40-seater for a trip where many
  riders are single-leg, and the banner shows a smaller shortfall than the raw
  headcount implied.
- **Actors:** Jignesh (admin).
- **Phases spanned:** 4 → 5.
- **Setup / messy data:** On the Somnath trip a big share of requests are one-way:
  a clutch of GO-only pilgrims (arriving home by relatives' cars) and a separate
  clutch of RETURN-only pilgrims (who got there independently). By raw headcount it
  looks like ~46 berths of demand on a 40-seat bus → "6 short". But each GO-only
  berth and an opposite RETURN-only berth can REUSE the same physical seat.
- **The flow:**
  1. Manage Buses → Add a single 40-berth sleeper, uniform price, save.
  2. Tour Overview `_CapacityBanner`: instead of the raw "6 short", it reads
     `needsDecision` from the engine — only the riders the engine genuinely cannot
     seat after honoring leg-sharing. The banner says roughly **"3 short"**, not 6.
  3. Jignesh expands the Requests capacity banner: the per-leg meter shows GO and RET
     loads separately and an opposite-leg reclaim hint (`reclaim_go` / `reclaim_ret`)
     telling him empty GO slots a return-only rider can't use but a GO-only rider can.
- **Complications & recovery:**
  - Jignesh was about to call the owner for a second 30-seater. The leg-aware number
    stops him: 3 short is solvable with a small second bus OR by waitlisting 3 — far
    cheaper than a whole coach. The old patchwork math (`demand − capacity`) would
    have lied "6 short" and triggered an unnecessary bus.
  - He confirms per-type free never goes negative: an over-demanded single-sofa shows
    `0` free (clamped), and the excess surfaces as `needsDecision`, not "Single −2".
- **Real-world outcome (Expected):** Jignesh decides on ONE 40-seater + waitlist 3,
  not two buses. He can defend the call: the engine, not a guess, says 3. The banner
  and per-bus meters agree because they share one `computeTourCapacity` plan.
- **Base-level UCs exercised:** UC-03BUSMANAGEMENT-2 (engine-truth, leg-sharing
  honored), UC-02REQUESTCAPTURE-16 (reclaim hint, per-leg meter),
  UC-03BUSMANAGEMENT-15 (free-by-type never negative).
- **Screens/files:** `lib/utils/tour_capacity.dart` (`needsDecision`, `goOnlyFree`,
  `retOnlyFree`, `freeByType`), `lib/screens/tour_overview_screen.dart`,
  `lib/screens/requests_screen.dart` (`_CapacityBanner`, `_TypeFreePill`).

---

### SC-S1LAUNCHANDFILL-6: Late additions on Friday afternoon — three more families DM after the tally
- **Persona & goal:** After Ramesh has told the owner "41+30", three more families DM
  Friday afternoon. His goal is to absorb the late demand WITHOUT re-doing the whole
  plan or panicking the owner — decide which fit and who goes on the waitlist.
- **Trigger (the activation):** Three new requests land while Ramesh already has both
  buses booked and a near-full plan.
- **Actors:** Ramesh (admin); three late families (customers).
- **Phases spanned:** 3 → 4 (re-tally on a booked tour).
- **Setup / messy data:** Both buses (71 berths) are nearly committed by the existing
  roster. The late asks: a family of 4 (2 doubles, full trip), a lone rider (1 single,
  GO-only), and a couple (1 double, return-only).
- **The flow:**
  1. The three late requests arrive as New cards (the tour still `acceptsBookings` —
     it's not locked).
  2. Ramesh re-reads the Tour Overview meters. The lone GO-only rider and the
     return-only couple can slot into leg-free seats the engine already left
     (`goOnlyFree` / `retOnlyFree`), so they DON'T cost full berths.
  3. The family of 4 (2 whole doubles, full trip) genuinely overflows. Rather than
     book a THIRD bus for one family, Ramesh long-presses their card and **Waitlists**
     them (`setWaitlisted(true)`), toast `requests.snack.moved_to_waitlist`.
  4. Waitlisting them removes their berths from `demandBerths` (held riders excluded),
     so the capacity banner stops screaming "short" while keeping the family on record.
- **Complications & recovery:**
  - Ramesh confirms a waitlisted rider still shows in the requirement CHIPS (so he
    remembers they exist) but NOT in the banner's active demand — the "what to book"
    number stays honest and he isn't pushed to buy a third bus.
  - When a small no-show frees two berths next week, the held family can be promoted
    off the waitlist (`setWaitlisted(false)`) without a re-broadcast.
- **Real-world outcome (Expected):** Both small one-way late riders absorbed into
  leg-free seats; the family of 4 safely held on the waitlist (visible, not lost).
  Ramesh does NOT call the owner back for a third bus. Observable state: two waitlisted
  passengers under the Waitlist tab, banner no longer warns "short".
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-9 / -11 (triage, bulk waitlist),
  UC-03BUSMANAGEMENT-2 (banner recomputes), UC-02REQUESTCAPTURE-16 (waitlisted
  excluded from demand).
- **Screens/files:** `lib/screens/requests_screen.dart` (`_BulkActionBar`,
  `_bulkWaitlist`, `_CapacityBanner`),
  `lib/controllers/tour_controller.dart::setWaitlisted`, `lib/utils/tour_capacity.dart`.

---

### SC-S1LAUNCHANDFILL-7: Price-bands instead of one flat fare — front rows cost more on the Diu sleeper
- **Persona & goal:** Ramesh's bus owner charges more for the front (smoother) rows
  and the elderly couple specifically asked for the front. Ramesh's goal is to price
  the bus so the per-passenger amount due is RIGHT before any cash is collected —
  using row bands, not one flat fare.
- **Trigger (the activation):** On Step 3 of the add-bus wizard Ramesh switches the
  price mode from "Same for all" to "Price bands".
- **Actors:** Ramesh (admin).
- **Phases spanned:** 5 (Add Bus Details, pricing) feeding the money track.
- **Setup / messy data:** Front two rows = premium (₹1,400/person), middle = standard
  (₹1,100/person), rear = budget (₹900/person). Kanjibhai & Jadiben sit front
  (premium singles); Bhavesh & Hardik share a whole double in the middle band.
- **The flow:**
  1. Step 3 → tap the **"Price bands"** pill; the bands editor body appears.
  2. **Add band** "Front" From row 1 (blank To = single… he sets To row 2),
     ₹1,400/person; **Add band** "Middle" rows 3–6, ₹1,100; **Add band** "Rear"
     rows 7–end, ₹900. Rows are entered 1-based, stored 0-based.
  3. Each band's price is PER PERSON/per berth — so Bhavesh+Hardik's whole double in
     the middle band costs 2 × ₹1,100. Bands win over per-type overrides for the rows
     they cover; on overlap the FIRST band wins.
  4. Save the wizard. Because this is add mode (layout not yet built), the
     `rows_clamped_note` shows and bands are clamped to the bus's real row count at save.
- **Complications & recovery:**
  - Ramesh accidentally enters a band backwards (To row < From row); it's normalised
    on save. A zero-price band he half-typed is dropped on save (price ≤ 0).
  - Switching back to "Same for all" mid-edit stashes the bands (he can restore them);
    persisting in uniform mode writes `priceBands = []` so the two modes stay either/or.
- **Real-world outcome (Expected):** The bus prices correctly per row: Kanjibhai &
  Jadiben each owe ₹1,400 (front singles), the Bhavesh/Hardik shared double owes
  ₹2,200 (2 × ₹1,100 middle), rear riders owe ₹900/berth. A one-leg rider pays HALF
  via `tripFactor`. Ramesh has accurate per-passenger amounts due BEFORE the handler
  collects a rupee of cash on the bus.
- **Base-level UCs exercised:** UC-03BUSMANAGEMENT-6 (price-bands mode),
  UC-03BUSMANAGEMENT-16 (band vs override vs base, single vs double, leg factor),
  UC-03BUSMANAGEMENT-5 (uniform mode it switches away from).
- **Screens/files:** `lib/screens/add_bus_screen.dart` (`_buildBandsBody`,
  `_openBandSheet`, `_sanitizedBands`, `_onModeChanged`),
  `lib/models/bus_details.dart` (`PriceBand`, `effectiveBands`, `bandForRow`,
  `berthPriceFor`, `tripFactor`).

---

### SC-S1LAUNCHANDFILL-8: A "lakh-sized" tour the agent can't fill alone — collecting demand before a bus exists
- **Persona & goal:** Ramesh floats an ambitious 3-bus Dwarka–Somnath circuit to
  gauge whether the community wants it at all. His goal is to COLLECT real demand
  first and only commit buses if the numbers justify it — the app must let demand
  accrue against a bus-less tour.
- **Trigger (the activation):** Ramesh broadcasts an open tour with NO bus and lets
  requests run for a week before deciding.
- **Actors:** Ramesh (admin); a wide slice of the community (customers).
- **Phases spanned:** 2 → 3 → 4 (collect-before-book).
- **Setup / messy data:** Zero buses on the tour for the first several days. Dozens of
  requests of every shape land — full trip, go-only, return-only, sofas and seaters.
- **The flow:**
  1. On the customer list the tour shows the neutral **"Open"** chip (`chip_open`,
     `capacity == 0`) with a tappable Book pill — demand can be collected before a bus
     exists. Customers book freely; none are blocked for "full" because there's no
     capacity yet.
  2. Ramesh watches the Tour Overview requirement chips climb day by day and the
     no-bus capacity banner show the per-leg `Need {go} going · {ret} returning`
     demand growing.
  3. After a week he reads the tally: the demand is real and asymmetric. He books the
     buses to match the busier leg, sized from the engine demand — not a guess.
- **Complications & recovery:**
  - A few customers see the bus is "Open" and assume seats are guaranteed; the seat
    numbers stay HIDDEN until the tour is locked (`seatsVisible = tourLocked &&
    hasSeatsAssigned`), so nobody is shown a phantom seat. Their My-Requests row shows
    a "Finalizing" state, not a fake seat ID.
  - If Ramesh decides the demand is too thin to run, the families simply stay as
    pending requests; nothing was over-committed because no bus (and no cash) ever
    entered the picture.
- **Real-world outcome (Expected):** Ramesh has a defensible, data-backed go/no-go: a
  bus-less tour that accrued honest per-leg demand he can act on. When he books, the
  bus count matches engine demand. Observable state: an "Open"-chip tour with a
  growing roster, no phantom seats shown to customers, requirements chips reflecting
  the full ask.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-5 (no-bus "Open" chip, book before
  bus), UC-02REQUESTCAPTURE-8 (seat reveal gated until lock),
  UC-03BUSMANAGEMENT-1 / -2 (requirements + banner before booking),
  UC-02REQUESTCAPTURE-16 (no-bus per-leg demand).
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart` (`_BookPill`,
  `chip_open`), `lib/screens/tour_overview_screen.dart`,
  `lib/services/customer_requests_store.dart` (`seatsVisible`),
  `lib/utils/tour_capacity.dart`.

---

### SC-S1LAUNCHANDFILL-9: Reinstalled phone & a Gujarati-only customer — capture survives the mess
- **Persona & goal:** Mansukhbhai, a Gujarati-only reader, reinstalled WhatsApp/phone
  and lost his local "My Requests" journal, but he DID submit a request earlier. His
  goal is to re-find his request and not double-book; Ramesh's goal is that the lost
  device doesn't corrupt his roster on Friday.
- **Trigger (the activation):** Mansukhbhai opens the app on a fresh install, sees an
  empty My-Requests, and re-submits — while Ramesh is mid-tally.
- **Actors:** Mansukhbhai (Gujarati-only customer), Ramesh (admin).
- **Phases spanned:** 2 → 3.
- **Setup / messy data:** The server already holds Mansukhbhai's first request (1
  Double Sofa, full trip). His new install has an EMPTY device-local journal
  (`CustomerRequestsStore` is SharedPreferences — there's no customer auth session).
  App language is Gujarati throughout.
- **The flow:**
  1. Fresh install → My Requests is empty (`empty_title` / `empty_body` in Gujarati).
     Mansukhbhai assumes nothing went through and opens the tour to book again.
  2. He submits the SAME ask (same phone, same name, same seat counts). The form's
     soft duplicate check warns `warn_duplicate_*` (submit-anyway) because an
     identical pending request exists for that phone+tour — but it's a soft warn, not
     a hard block, since it can't see his old device journal, only the server dupe.
  3. Ramesh, on the Requests screen, sees the would-be duplicate and uses **Edit
     request** to reconcile rather than letting two identical rows ride — phone is
     locked (identity guard) but seat counts/leg are editable.
- **Complications & recovery:**
  - Every label, chip, empty state, and the duplicate-warning toast render in Gujarati
    via `tr(...)` with no missing-key fallback — the `warn_duplicate_*`,
    `success_sent_wa`, and `empty_*` keys must exist in `gu.json` or Mansukhbhai sees
    raw keys. (String-parity rule.)
  - If Ramesh had already deleted one of the rows, Mansukhbhai's My-Requests entry
    would flip to **Cancelled** on next refresh (server lookup returns empty →
    `markCancelled`) — so the customer sees the truth, not a ghost allocation.
- **Real-world outcome (Expected):** Mansukhbhai ends up with exactly ONE live
  request, fully in Gujarati, despite the reinstall; Ramesh's Friday roster is clean
  (no phantom duplicate inflating demand). The capture flow survived a lost device and
  a language-locked user.
- **Base-level UCs exercised:** UC-02REQUESTCAPTURE-3 (soft duplicate warn),
  UC-02REQUESTCAPTURE-8 (My-Requests journal, markCancelled on delete),
  UC-02REQUESTCAPTURE-13 (admin edit reconciles, phone locked),
  UC-02REQUESTCAPTURE-17 / UC-01TOURLIFECYCLEADMIN-17 (full Gujarati render).
- **Screens/files:** `lib/screens/customer_my_requests_screen.dart`,
  `lib/screens/customer_booking_request_screen.dart` (`_preflightCreate`),
  `lib/services/customer_requests_store.dart` (`refreshAll`, `markCancelled`),
  `lib/widgets/edit_request_sheet.dart`, `assets/translations/gu.json`.
