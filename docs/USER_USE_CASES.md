# occubusbooking — User Use Cases (Master Test Charter)

This is the **master index and test charter** for the occubusbooking Flutter tour-booking app.

> **What changed (read this first).** Earlier this charter led with *base-level mechanical cases* (per-screen unit checks). That altitude was too low: a tester running it never exercised how a **real Gujarati-community tour agent actually runs a trip** end to end. This charter now **LEADS with real-world operational ("activation") scenarios** — named agents, real families, messy data, ₹ amounts, decisions, recovery — under [`docs/use-cases/scenarios/`](./use-cases/scenarios/). The nine base-level area files are still here as a **reference layer beneath**: consult them only to isolate a specific mechanic when a real-world scenario surfaces a defect.

- **App:** `occubusbooking` — a tour-agent management tool (NOT a direct seat-booking system).
- **Core entity:** the **Tour**, which moves through an 8-phase lifecycle (+ a Money/Settlement track and a Return-leg phase).
- **Actors:** ADMIN (tour agent), HANDLER (on-trip conductor), CUSTOMER (passenger).
- **Status machine** (`lib/models/tour_status.dart`): `planning → collecting → busBooked → assigning → locked → completed`.

---

## How to use this for testing

Run **top-down**: real-world scenarios first, base-level mechanics only on failure.

1. **Run the REAL-WORLD SCENARIOS first.** Start with the [Golden tour](#golden-tour--one-real-trip-start-to-finish) — one believable trip threaded through S1→S5 in a single pass. Then run each of the six [scenario files](#primary--real-world-operational-scenarios). Each scenario is an end-to-end field story (persona, trigger, messy setup, the flow, complications **with app-supported recovery**, the concrete observable outcome) — this is genuine field usage, not a unit check.
2. **Drop into the BASE-LEVEL section files only to isolate a mechanic.** When a real-world scenario fails, open the matching [base-level area file](#reference--base-level-mechanics-index) and run the single granular UC it cites (each scenario lists the `UC-…` ids it exercises). The base-level files carry **Actor / Phase / Preconditions / Steps / Expected / Edge cases / Screens-files** for surgical reproduction.
3. **Check coverage** with the [Coverage Matrix](#coverage-matrix-phase--actor) and the [Gaps](#coverage-gaps-explicit) list (thin/empty-by-design cells you must confirm are intentional).
4. **Mind the cross-cutting truths** (these trip up testers and are real, not bugs unless flagged) — see [the 7 truths](#the-7-cross-cutting-truths) below.

> **Localization rule for every test:** the codebase uses **nested** JSON keys (e.g. `charts.empty.title`). A flat `grep -c 'charts.empty.title'` returns 0 (false negative). Verify parity with a JSON-path check across `assets/translations/{en,gu,hi}.json`, not grep. Several scenarios are **load-bearing on Gujarati string parity** (a missing key shows the raw dotted key to a Gujarati-only elder).

> **Known issues** are tracked separately in [`docs/BUGS.md`](./BUGS.md). Two intersect end-to-end flows (push deep-link tab mismatch; auth debug-PII snackbar) and reproduce in the base-level cross-cutting journeys.

---

## Actor glossary

| Actor | Who they are | How they enter the app | What they can do | What they CANNOT do |
|---|---|---|---|---|
| **ADMIN** (tour agent / owner) | The person running tours. The only authenticated identity. | Hidden long-press on the customer "Explore" header → `/login` (phone → password two-step). Cold start restores the session. | Everything: create/edit/broadcast/lock tours, review/approve requests, add buses & pricing, assign seats, appoint handlers, run all money screens (collection, per-bus settlement, P&L, finance), notify. | n/a (full access). |
| **HANDLER** (on-trip conductor) | A passenger appointed per-bus as the trip point-of-contact. **Not an auth identity** — a per-bus appointment (`bus.handlerPassengerId`). | Reaches their OWN bus chart from **My Requests** ("View full chart") or **Find My Seat by phone**, via the `handler_tour_manifest` RPC flow — NOT the admin Charts tab. | Read their bus manifest/roster, mark attendance per leg, collect cash (incl. leg-scoped shared-seat chooser), log ground expenses + extra income, see "in hand", broadcast to their bus, call driver/passengers. | Create/edit/lock tours, reach the seat-assignment grid, settle the owner, record handovers, see rent. |
| **CUSTOMER** (passenger) | Anyone browsing tours and requesting seats. No auth session. | Default app entry (`/customer-home`); no login required. Server access is via `SECURITY DEFINER` RPCs that **fail closed**. | Browse/search tours, read detail, submit (and edit) seat requests, hold multiple distinct requests per tour, track status in device-local My Requests, view their own seat **after lock**, find-my-seat by phone, switch language, read legal docs. | See other passengers' seats, reach any admin surface, see provisional seat numbers pre-lock. |

> **Role note:** `UserRole` enum is `{admin, handler, passenger}`, but the auth layer only ever assigns `admin` or `passenger`. There is **no handler login** — "handler" is a per-tour appointment.

---

## The 8-phase tour lifecycle (overview)

The app is a tour-agent management tool: every screen revolves around a **Tour** moving through these phases. The Money/Settlement track and the Return-leg phase run alongside Phases 6–8.

| # | Phase | Primary actor | What happens | Status transition |
|---|---|---|---|---|
| **1** | **Create Tour** | Admin | Agent sets route (from→to), departure/return dates, optional broadcast message/image. Price is per-bus, set later. | starts `planning` |
| **2** | **Broadcast / Notify** | Admin → Customer | Tour announcement is pushed to WhatsApp (Cloud API / deep-link); customers see it in the public tour list. | (no status change) |
| **3** | **Collect Requests** | Customer → Admin | Customers submit in-app seat requests (per-leg lines); admin reviews/confirms/declines in the Requests inbox. | first passenger → AUTO `collecting` |
| **4** | **Tally & Book Bus** | Admin | Admin reads aggregate seat demand + capacity banner to decide how many buses to book. | — |
| **5** | **Add Bus Details** | Admin | Add bus identity, capacity/layout (seat engine), pricing (uniform vs price-bands). | first bus → AUTO `busBooked` |
| **6** | **Assign Seats** | Admin | Tap-to-place / drag seat assignment, groups, swaps, cross-bus moves, sofa rules, exception resolution. | first real placement → AUTO `assigning` |
| **7** | **Assign Handler** | Admin | Appoint one seated passenger per bus as the trip handler (occupant sheet or Manage Buses picker). | — |
| **8** | **Lock & Notify** | Admin → all | Lock gate (all-assigned + handler + ≥1 passenger) → lock → auto-send seat allocations; post-lock tracker, per-bus announcements, mark completed. | MANUAL `locked`; then `completed` |
| **+M** | **Money / Settlement** | Admin + Handler | Per-passenger collection, per-bus settlement/handover, ground expenses, extra income, per-trip P&L, cross-tour finance. | (parallel track) |
| **+R** | **Return-leg phase** | Admin + Handler | After GO leg completes (`journeyDone`), return-only ticket add (past lock gate), return collection, cancel-in-place. | post-lock sub-phase |

---

## The 7 cross-cutting truths

These hold across every scenario. Most look like bugs but are by design — verify, don't file.

1. **Single lock gate** = `Tour.acceptsBookings` (false once `locked` OR `completed`). Enforced at the `addPassenger` chokepoint; the only sanctioned bypass is `addPassenger(overrideLock:true)` for **return-only** tickets during the return-leg phase.
2. **Seat numbers are gated on LOCK, not assignment**: `seatsVisible = tourLocked && hasSeatsAssigned`. Pre-lock shows a "Finalizing" chip, never provisional numbers. Provisional seats must never leak to a customer.
3. **Money is summed by `bus_id`, never by current seat.** A paid rider who changes seats keeps their collection row on the old bus (the documented handler-23k vs admin-30k case is *this* plus rent, not a miscount).
4. **Bus rent (`Bus.busPrice`)** is folded into P&L expenses as a synthetic `busOwner` line but **excluded from the handover expectation**; the handler never sees rent. `expectedHandover = collected + income − (expensesTotal − busRent)`.
5. **Default locale is Gujarati (gu)**, default theme is Dark. Every user-facing string must have **en/gu/hi parity** or `tr()` renders the raw key — and a Gujarati-only elder will see that raw key.
6. **My Requests is device-local** (`SharedPreferences`), so it is empty after reinstall even with live server bookings — Find-my-seat-by-phone (last-10-digit match, locked/completed tours only) covers that gap, for handlers too.
7. **Auto-archive:** on app load, any non-completed admin-owned tour whose `(returnDate ?? departureDate)+1 day` is past is silently flipped to `completed`. Old tours leaving the active list is expected.

---

# PRIMARY — Real-world operational scenarios

**Run these first.** Six persona-driven files under [`docs/use-cases/scenarios/`](./use-cases/scenarios/), 52 scenarios total. Each is a full field story with recovery and a concrete observable outcome, citing the base-level `UC-…` ids it exercises.

### [S1 — Launching a tour & filling the bus (real demand over days)](./use-cases/scenarios/S1-launch-and-fill.md) · Phases 1–5 · 9 scenarios
| id | persona | title |
|---|---|---|
| SC-S1…-1 | Ramesh (agent) | Ramesh launches the Diu pilgrimage and broadcasts to three WhatsApp groups |
| SC-S1…-2 | Ramesh + Patels/Solankis/Chauhans (+more) | Requests trickle in over two days — families that must sit together, mixed legs, one payer |
| SC-S1…-3 | Ramesh (admin) | Friday tally — reads TRUE demand and the no-bus banner tells him what to book |
| SC-S1…-4 | Ramesh + bus owner | One 41-seater isn't enough — the banner says 6 short, books bus #2 |
| SC-S1…-5 | Jignesh (second agent) | Leg-sharing rescue — "6 short" shrinks to "3 short" instead of a whole second bus |
| SC-S1…-6 | Ramesh + 3 late families | Late additions Friday afternoon — three more families DM after the tally |
| SC-S1…-7 | Ramesh (admin) | Price-bands instead of one flat fare — front rows cost more on the Diu sleeper |
| SC-S1…-8 | Ramesh + wide community | A "lakh-sized" tour the agent can't fill alone — collecting demand before a bus exists |
| SC-S1…-9 | Mansukhbhai (Gujarati-only) + Ramesh | Reinstalled phone & a Gujarati-only customer — capture survives the mess |

### [S2 — Seating real families & friend-groups (keep them together)](./use-cases/scenarios/S2-seating-real-groups.md) · Phase 6 · 9 scenarios
| id | persona | title |
|---|---|---|
| SC-S2…-1 | Ramesh (agent) | Seat the Patel family of 5 as one block on one bus |
| SC-S2…-2 | Ramesh (agent) | Lock the Solanki four-some so a re-generate can never split them |
| SC-S2…-3 | Ramesh; Bharat & Naresh; Kanjibhai & Jadiben | Sofa preferences — a double for the friends, singles up front for the elders |
| SC-S2…-4 | Ramesh (agent) | Auto-fill the bulk, then read "Needs your decision" honestly |
| SC-S2…-5 | Ramesh; the Chauhans | A late Chauhan addition forces a re-seat — keep them with their cousins |
| SC-S2…-6 | Ramesh (agent) | Resolve a "broken pair" and a priority miss the engine flagged |
| SC-S2…-7 | Ramesh; the Patel group | Cross-bus move to keep a family whole — cascade the group |
| SC-S2…-8 | Ramesh; Ramila (GO-only); Hasmukh (RET-only) | Mixed GO/RET legs — share one physical berth between two one-way riders |
| SC-S2…-9 | Ramesh; Govind; Bharat & Naresh | Split a paired double to free a seat for a late single — pick who peels off |

### [S3 — Committing the tour: pick a handler, lock, notify, customers receive](./use-cases/scenarios/S3-lock-notify-receive.md) · Phases 7–8 · 8 scenarios
| id | persona | title |
|---|---|---|
| SC-S3…-1 | Ramesh (admin) | Diu pilgrimage, the night before — final checks, pick Mahesh, lock, 38 seat-charts go out |
| SC-S3…-2 | Ramesh; Mahesh + Dinesh | Two buses, two handlers — each rider gets the RIGHT contact |
| SC-S3…-3 | Mrs. Patel (customer) | The customer side — the whole family's seats appear the moment Ramesh locks |
| SC-S3…-4 | Kanjibhai (elderly, fresh install, Gujarati-only) | Reinstalled phone, no ticket — finds his seat by phone after lock |
| SC-S3…-5 | Ramesh; the Solankis | Five minutes after lock the Solankis drop one — re-seat auto-reverts lock, re-lock, re-notify only affected |
| SC-S3…-6 | Ramesh (admin) | Meta sandbox bites — three numbers off the allow-list; send, see partial failure, retry only failures |
| SC-S3…-7 | Ramesh (admin) | "Boarding moved to Gate 3" — one bus, one announcement, the morning of departure |
| SC-S3…-8 | Ramesh; GO-only + 2 new return-only | Return-leg sell-off after a one-way crowd — freed seats become return tickets, only return riders re-notified |

### [S4 — Cash on the road (handler) & settling up (admin)](./use-cases/scenarios/S4-money-on-the-road-and-settle.md) · Money / Settlement · 9 scenarios
| id | persona | title |
|---|---|---|
| SC-S4…-1 | Mahesh (handler); Suresh Patel pays for all | One man pays for his whole family in cash on the bus |
| SC-S4…-2 | Dinesh (handler); Kanjibhai & Jadiben; two Solankis | Half-payments and an over-payment that owes change back |
| SC-S4…-3 | Mahesh; Bharat (GO-only) + Vijay (RET-only) on D3 | Leg-scoped collection — GO fares going out, RETURN fares coming back |
| SC-S4…-4 | Dinesh (handler) | Cabin & gallery income plus fuel/food spend folds into "in hand" |
| SC-S4…-5 | Ramesh + Mahesh; Jayesh moved A11→A14 | A rider pays, then gets moved seats — cash must not vanish |
| SC-S4…-6 | Ramesh records Mahesh's ₹41,550 handover | Settlement night — handler hands over the bag, outstanding → ₹0 |
| SC-S4…-7 | Ramesh reads TripPnl across two buses | Two-bus trip P&L — rent asymmetry ("in hand ₹23k vs admin ₹30k") and the real profit |
| SC-S4…-8 | Ramesh resells to Hasmukh; Mahesh collects | Return-leg ticket sold mid-trip — extra cash flows into settlement |
| SC-S4…-9 | Mahesh (Gujarati-only handler) | Reinstalls his phone mid-trip and refinds his bus by phone |

### [S5 — The round-trip reality (return-leg phase)](./use-cases/scenarios/S5-return-leg-reality.md) · Lock → Return-leg · 8 scenarios
| id | persona | title |
|---|---|---|
| SC-S5…-1 | Ramesh (admin) | Closes the Diu GO leg and the "allocate 6" ghost does not come back |
| SC-S5…-2 | Ramesh; Solankis, two friends, Kanjibhai (RET-only) | Selling the 11 empty homeward seats to walk-ups at Diu (past the lock) |
| SC-S5…-3 | Mahesh (handler) | Collects the homeward cash and the chooser opens on Return by itself |
| SC-S5…-4 | Ramesh; cancelling return-only friend, Jadiben | A return rider cancels at Diu — cancel-in-place, then rebook the same berth |
| SC-S5…-5 | Ramesh; Jignesh (round-trip abandoning return) | A round-trip rider skips the bus home — demoted, not deleted, GO cash stays |
| SC-S5…-6 | Ramesh; Mahesh hands cash | Settlement night — admin records the homeward handover, P&L counts both passes |
| SC-S5…-7 | Ramesh (admin) | A pure one-way (no-return) tour skips the return phase entirely |
| SC-S5…-8 | Ramesh, Mahesh | Return roster shows only homeward riders — departed GO pilgrims are not "to collect" |

### [S6 — Field failures & recovery (cross-cutting failure paths)](./use-cases/scenarios/S6-field-failures-and-recovery.md) · Cross-cutting · 9 scenarios
| id | persona | title |
|---|---|---|
| SC-S6…-1 | Ramesh (agent/admin) | A 41-seater is 6 berths short the Thursday before a Diu trip |
| SC-S6…-2 | Jignesh Patel (customer) | The Patels DM "add 4 more" twice in five minutes — one phone, two real requests |
| SC-S6…-3 | Kanjibhai & Jadiben (Gujarati-only) | Never switch off Gujarati — the whole loop must read in their script |
| SC-S6…-4 | Ramesh + Mr. Chauhan (phone-in) | The Chauhans cancel two of five seats the night before, on a locked tour |
| SC-S6…-5 | Mahesh (handler) | A no-show at the boarding point — marks "left behind", money stays straight |
| SC-S6…-6 | Mahesh (handler) | Collects cash on the highway with no signal — and a save fails |
| SC-S6…-7 | Bhavna Patel (customer, no device ticket) | Reinstalled phone, empty "My Requests" — recover the seat by phone |
| SC-S6…-8 | Mahesh (handler, also seated) | Same phone is also the handler — recover the WHOLE bus, not just one seat |
| SC-S6…-9 | Ramesh + Hardik (late customer) | A request slips in just as Ramesh locks the tour — the mid-flow lock race |

---

## Golden tour — one real trip, start to finish

> **Run this in one pass to live the whole life of a real tour.** It threads **S1 → S2 → S3 → S4 → S5** as a single believable Diu pilgrimage with continuous personas and ₹ amounts. Each step links the scenario id that owns the detail — open that scenario for the full flow + recovery. This is the fastest way to confirm the app holds together for an actual agent; if a step breaks, drop into the cited base-level UC to isolate the mechanic.

**Cast (carried throughout):** **Ramesh** — the tour agent (reads the app in Gujarati). **Mahesh** & **Dinesh** — two passengers appointed as per-bus handlers. **Families:** the **Patels** (5: Suresh pays for all), the **Solankis** (a four-some + a couple sharing a double), the **Chauhans** (late add), elderly **Kanjibhai & Jadiben** (Gujarati-only, two front singles), friends **Bharat & Naresh**, and one-way riders **Ramila** (GO-only) / **Hasmukh** & **Vijay** (return-only). **Buses:** a **41-berth Volvo sleeper** (Mahesh) and a **30-seater** (Dinesh). Route: **Ahmedabad → Diu**, round trip.

### Act 1 — Launch & fill (S1)
1. **(Sat night)** Ramesh taps **+**, creates "Diu pilgrimage" with route + departure/return dates, and fires **Create & Broadcast** to three WhatsApp groups. The Gujarati tour name renders cleanly in the public list. → **SC-S1…-1**
2. **(Sun–Mon)** Twelve families DM and submit the in-app form — Patels as one request (2 doubles + 1 single, round-trip, *one payer*), mixed-leg riders, a couple. Ramesh keys two phone-only requests himself. → **SC-S1…-2**
3. **(Fri AM)** Ramesh opens Overview/Requests and reads **TRUE demand**: the no-bus banner says **"Need {go} going · {ret} returning"** in *units*, not a phantom headcount. → **SC-S1…-3**
4. He books a **41-seater Volvo** — the capacity banner turns warm: **6 short** (engine-truth `needsDecision`, leg-sharing already honored). → **SC-S1…-4**, contrast **SC-S1…-5** (a one-way-heavy bus shrinks "6 short" to "3 short" — no phantom over-count).
5. He books **bus #2 (a 30-seater)** to absorb the overflow; on **add-bus Step 3** he switches the Volvo from "Same for all" to **Price bands** so front rows cost more. → **SC-S1…-7**
6. **(Fri PM)** Three more families DM after the tally; he re-tallies on the now-booked tour without breaking capacity. → **SC-S1…-6**. A Gujarati-only customer (**Mansukhbhai**) re-submits after a reinstall mid-tally — capture survives. → **SC-S1…-9**

### Act 2 — Seat the real groups (S2)
7. **(Fri night)** Ramesh seats the **Patel family of 5 as one block** on the Volvo (2 doubles + 1 single together). → **SC-S2…-1**
8. He formalizes the four separate **Solanki** requests into one cross-booking **group and locks it** so an auto-fill can never split them. → **SC-S2…-2**. He hand-seats special requests: a **double for Bharat & Naresh**, **front singles for Kanjibhai & Jadiben**. → **SC-S2…-3**
9. He taps **Fill bus** for the bulk, then reads **"Needs your decision"** honestly (read LIVE, never `fillTour`), resolving a **broken pair** and a **priority miss**. → **SC-S2…-4**, **SC-S2…-6**
10. **(Thu 11pm)** A late **Chauhan** request lands — he re-seats to keep them with their cousins. → **SC-S2…-5**. The bus owner phones to shift one whole family to the 30-seater: a **cross-bus move cascades the group**. → **SC-S2…-7**
11. He leans into **leg-reuse**: **Ramila** (GO-only) and **Hasmukh** (RET-only) **share one physical berth**. → **SC-S2…-8**. A late single (**Govind**) DMs — he **splits a paired double**, picking who peels off. → **SC-S2…-9**

### Act 3 — Commit: handler, lock, notify, receive (S3)
12. **(Night before)** Ramesh appoints **Mahesh** on the Volvo and **Dinesh** on the 30-seater (handler picker lists only *seated* passengers). The lock gate clears (all-assigned + handler + ≥1 passenger); he **locks** and **38 seat-charts auto-send** — each rider gets the **right per-bus handler contact**. → **SC-S3…-1**, **SC-S3…-2**
13. **(Customer side)** **Mrs. Patel** could not see seat numbers before lock; the moment Ramesh locks, the whole family's seats appear. → **SC-S3…-3**. **Kanjibhai** (reinstalled, no device ticket) recovers via **Find my seat by phone** — returns only the locked tour. → **SC-S3…-4**
14. **(Recovery)** Five minutes after lock the **Solankis drop one rider**; clearing the seat **auto-reverts** the lock to `assigning`; Ramesh re-seats, **re-locks, and re-notifies only the affected**. → **SC-S3…-5**. Three numbers fail Meta's allow-list — he **retries only the failures**. → **SC-S3…-6**. Departure morning he sends **"Boarding moved to Gate 3"** to one bus. → **SC-S3…-7**

### Act 4 — Cash on the road & settle up (S4)
15. **(5:30 AM, on the Volvo)** **Mahesh** walks the aisle. **Suresh Patel pays ₹14,500 for the whole family** in cash — 2 doubles at **₹6,000** (whole-sofa price, not the half-berth) + 1 single at **₹2,500**; the four other Patels are never charged separately. → **SC-S4…-1**
16. **(30-seater)** **Dinesh** handles **half-payments and an over-payment** owing change back (Kanjibhai's ₹2,000 note, a ₹500 "for chai" tip returned). → **SC-S4…-2**. On leg-shared **D3**, the **GO/Return chooser** opens on GO and collects **₹3,000 from Bharat** outbound. → **SC-S4…-3**
17. Dinesh logs **Cabin ₹400 + Gallery ₹250 + Other ₹150** income and **Fuel ₹3,000 / Food ₹1,800 / Toll ₹450** spend; **In hand = collected + income − spent**. → **SC-S4…-4**. A rider (**Jayesh**) is moved A11→A14 *after paying* — his cash stays on the bus by `bus_id`, doesn't vanish. → **SC-S4…-5**

### Act 5 — The return-leg reality (S5)
18. **(At Diu)** Ramesh marks the **GO leg complete**: 8 one-way pilgrims are freed and flagged `journeyDone`; **no "allocate 6" ghost** returns (excluded from `pendingSeatsToAssign`). → **SC-S5…-1**
19. He **sells the 11 empty homeward seats to Diu walk-ups** as **return-only tickets** — the only sanctioned bypass of the lock gate (`addPassenger(overrideLock:true)`, `forcedLeg: returnOnly`); only return riders are re-notified. → **SC-S5…-2** / **SC-S3…-8**
20. **(Return bus departs)** **Mahesh** collects the homeward cash; the shared-seat **chooser now defaults to Return by itself** (it detects `outboundDone`) — **Vijay** pays **₹3,000** on D3's return half. → **SC-S5…-3**, **SC-S4…-3** (Day 2). A return-only friend cancels → **cancel-in-place, rebook the same berth**. → **SC-S5…-4**. **Jignesh** (round-trip, paid ₹1,200) takes the train home — **demoted, not deleted; his GO cash stays**. → **SC-S5…-5**. The return roster shows **only homeward riders**, not departed GO pilgrims. → **SC-S5…-8**

### Act 6 — Settlement night (S4 / S5)
21. **(11 PM, back in Ahmedabad)** **Mahesh** hands over the bag. On **Mahesh's Volvo**: collected ₹46,000 + income ₹800 − spend ₹5,250 = **In hand ₹41,550**. Ramesh **records the handover**; **Outstanding → ₹0**, the bus reads **settled**. The owner's **₹30,000 rent** is paid separately, never in the handover math. → **SC-S4…-6**, return-leg variant **SC-S5…-6**
22. **(Next morning)** Ramesh reads **two-bus trip P&L**: rent is in P&L expenses but out of the handover, so Mahesh's "in hand" looks **lower** than the admin's expense view — the **documented rent asymmetry**, not a bug. → **SC-S4…-7**

**Golden-tour expected outcome.** Status moved `planning → collecting → busBooked → assigning → locked → completed`; every group stayed whole; no customer saw a seat number before lock; the return phase produced no phantom "allocate N"; handler "in hand" and admin handover reconcile (rent excluded from handover, folded once into P&L); every screen rendered in Gujarati with no raw `tr()` key. If any link in the chain fails, jump to the cited scenario, then to its base-level UC.

---

# REFERENCE — Base-level mechanics index

> **Low-level checks. Consult only when a real-world scenario fails** and you need to isolate the exact mechanic. Each area file lists granular use cases with **Actor / Phase / Preconditions / Steps / Expected / Edge cases / Screens-files**. The real-world scenarios above cite these `UC-…` ids inline.

### [01 — Tour lifecycle (admin)](./use-cases/01-tour-lifecycle-admin.md) — 17 UCs · Phases 1, 2, 8
Create / edit / delete / broadcast / lock / notify / complete; status-driven next-action card; tours-list states; return-leg phase; WhatsApp handoff settings; language switch.
UC-01…-1 create+broadcast · -2 create-blocks-on-missing-date · -3 create-needs-session · -4 edit · -5 delete · -6 broadcast · -7 lock-gate-checklist · -8 lock+auto-send · -9 locked-closes-bookings · -10 post-lock tracker · -11 per-bus announcement · -12 mark completed · -13 next-action card · -14 list states · -15 return-leg phase · -16 handoff settings · -17 language switch.

### [02 — Request capture (customer submit + admin review)](./use-cases/02-request-capture.md) — 18 UCs · Phase 3
Round-trip / mixed-leg / second request; lock + full blocks; validation; edit; My-Requests; admin review/confirm/bulk/manual-add/edit/decline/priority/group; capacity banner; language; list states.
UC-02…-1 round-trip · -2 mixed-leg · -3 second request · -4 locked block · -5 full-bus block · -6 form validation · -7 edit pending · -8 My-Requests tracking/gating · -9 review New tab · -10 confirm · -11 bulk-triage · -12 manual add · -13 edit auto-release · -14 decline · -15 priority/group · -16 capacity banner · -17 language · -18 search/empty/error.

### [03 — Bus management (tally, add bus, pricing, capacity)](./use-cases/03-bus-management.md) — 16 UCs · Phases 4–5
Read demand; shortfall banner; add-bus Step 1/2/3 (uniform vs price-bands); save advances status; edit/resize/regenerate; leg-aware meters; per-bus actions; assign handler; per-type free; pricing correctness.
UC-03…-1 read demand · -2 shortfall banner · -3 Step1 identity · -4 Step2 layout · -5 Step3 uniform · -6 Step3 price-bands · -7 save+advance · -8 edit no-resize · -9 resize-unassign · -10 regenerate · -11 leg-aware meters · -12 empty state · -13 per-bus actions · -14 per-bus handler · -15 per-type free · -16 pricing correctness.

### [04 — Seat assignment (grid, groups, swaps, cross-bus, sofa rules)](./use-cases/04-seat-assignment.md) — 23 UCs · Phase 6
Summary→Grid; tap-to-place; seat-first; drag move/swap; paired-double peel; consolidate; share double/leg-reuse; swap-in; cross-bus relocate; swap-assistant; group cascade; groups+one-bus gate; priority/make-handler; occupant sheet; "Needs your decision"; auto-fill/overflow; edit-flags; clear bus; dock; return-leg cancel+rebook; sofa-render correctness; empty/offline/role.
UC-04…-1…23 (see file).

### [05 — Handler appointment + read-only charts](./use-cases/05-handler-assign-charts.md) — 16 UCs · Phase 7 + read surfaces
Charts tab auto-opens; empty state; tour/bus pills; read-only sheet; both names on shared double; edit-seats hand-off; fullscreen pinch-zoom; half-double split; appoint/step-down handler; Manage Buses picker; handler reaches own chart; Charts admin-only; shared legend; realtime; all-free chart.
UC-05…-1…16 (see file).

### [06 — Money collection, settlement, finance, P&L, return ticket](./use-cases/06-money-collection-settlement.md) — 16 UCs · Money track
Admin payment/mark-paid/filter; per-bus cockpit; bus expense (busOwner excluded); handover; money board; sum-by-bus_id; handler collect/income/expense/leg-scoped chooser; per-trip P&L; cross-tour finance; return-only past lock; localized+offline.
UC-06…-1…16 (see file).

### [07 — Handler trip-day (chart, attendance, manifest, collect, handover)](./use-cases/07-handler-trip-day.md) — 18 UCs · Trip execution + settlement
Open chart from My Requests / Find My Seat; call-first roster; grid+fullscreen; collect single/shared; attendance per leg; expense add/edit/delete; extra income; in-hand; broadcast; driver contact; admin collection+handover; customer own-seats; language mid-trip; return-leg collection.
UC-07…-1…18 (see file).

### [08 — Customer experience (browse, track, find seat, detail, notify)](./use-cases/08-customer-experience.md) — 18 UCs · Phases 2–3 + post-lock
Browse/search; detail; share; contact organiser; submit; full/locked block; My Requests+filter; edit pending; add another; seat post-lock; provisional pre-lock; one-way chips; find-my-seat; language; More/legal/version; hidden admin entry; handler-customer "View full chart".
UC-08…-1…18 (see file).

### [09 — Platform: auth, settings, i18n, notifications, roles](./use-cases/09-platform-auth-settings-i18n.md) — 16 UCs · Cross-cutting
Cold-start restore; hidden login; two-step login; non-admin reject; wrong password; admin-setup explainer; account edit; notification prefs+master gate; theme; live language switch; legal docs; logout; admin-only hiding; push deep-link; back/exit PopScope.
UC-09…-1…16 (see file).

**Total base layer: 9 sections · 158 area use cases.** (Plus 10 base-level cross-phase journeys preserved inside the section files as `UC-E2E-*` for low-level reproduction of the lock gate, overbook, rent asymmetry, multi-request, cross-bus, cancellation, language, and auth-lifecycle mechanics.)

---

## Coverage Matrix (phase × actor)

Cells show **count + representative UC ids** of base-level use cases per phase/actor combination. The real-world scenarios above *reinforce* these cells (they exercise the same UCs end-to-end) but are not counted in them. A UC may appear in more than one cell when it spans actors/phases.

| Phase ↓ / Actor → | ADMIN | HANDLER | CUSTOMER |
|---|---|---|---|
| **1 Create Tour** | **4** · UC-01…-1,2,3,4 | 0 | 0 |
| **2 Broadcast / Notify** | **3** · UC-01…-1,6,16 | 0 | **4** · UC-08…-1,4,5; UC-02…-18 |
| **3 Collect Requests** | **9** · UC-02…-9,10,11,12,13,14,15,16; UC-01…-(via list) | 0 | **12** · UC-02…-1,2,3,4,5,6,7,8,18; UC-08…-6,7,9 |
| **4 Tally & Book Bus** | **5** · UC-03…-1,2,11,12,15 | 0 | 0 |
| **5 Add Bus Details** | **10** · UC-03…-3,4,5,6,7,8,9,10,13,16 | 0 | 0 |
| **6 Assign Seats** | **23** · UC-04…-1…23 | 0 | **2** · UC-08…-12,13 |
| **7 Assign Handler** | **8** · UC-05…-9,10,11; UC-03…-14; UC-04…-14 | **3** · UC-05…-12,13; UC-08…-18 | 0 |
| **8 Lock & Notify** | **10** · UC-01…-7,8,9,10,11,12,13,15; UC-04…-20 | 0 | **3** · UC-08…-11,14; UC-02…-4 |
| **+M Money / Settlement** | **11** · UC-06…-1…8,13,14; UC-07…-14,15 | **9** · UC-06…-9,10,11,12; UC-07…-5,6,8,9,10,11 | 0 |
| **+R Return-leg** | **4** · UC-01…-15; UC-04…-21; UC-06…-15 | **2** · UC-06…-12; UC-07…-18 | 0 |
| **Cross-cutting (auth/i18n/roles/nav)** | **12** · UC-09…-1,3,4,6,8,9,10,11,13,15,16; UC-08…-17 | **2** · UC-05…-13; UC-07…-17 | **8** · UC-09…-2,5,7,12,14; UC-08…-15,16; UC-02…-17 |

**Scenario coverage of the matrix:** S1 covers Admin/Customer P1–5; S2 covers Admin P6 (incl. cross-bus + leg-reuse + group cascade); S3 covers Admin P7–8 + Customer post-lock receive; S4/S5 cover Admin+Handler Money/Settlement and the Return-leg; S6 spans the cross-cutting failure/recovery cells (one-phone-many-requests, gu-only, offline save, reinstall recovery, no-show, lock race). The empty cells below remain empty in the scenarios too — by design.

---

## Coverage gaps (explicit)

These phase/actor cells are **thin or empty by design** — confirm each is intentional (not a missed surface) before signing off.

1. **HANDLER in Phases 1–6 = 0 (by design).** Handlers never create tours, book buses, or reach the seat-assignment grid. They appear only at Phase 7, Money, Return-leg, and trip-day. *Test = confirm those surfaces are unreachable for a handler.* (No scenario gives a handler an in-grid action.)
2. **CUSTOMER in Phases 1, 4, 5 = 0 (by design).** Customers can't create tours, tally demand, or add buses. Their touchpoints are Broadcast (P2), Requests (P3), seat reveal (post-P6/P8). *Verify no admin bus/tally surface is reachable from customer home (role gating UC-09…-14).*
3. **CUSTOMER × Money = 0.** Customers have **no** money screen — payment is collected in person by handler/admin (S4 entirely). Flag if any payment UI ever surfaces to the customer.
4. **CUSTOMER × Return-leg = 0.** No customer-facing return-leg flow (return-only tickets are admin-added, S5…-2). Confirm a return-only passenger can still find their seat via Find-my-seat (UC-08…-14 / SC-S3…-4) — the only customer-visible return surface.
5. **HANDLER × Phase 8 (Lock & Notify) = 0.** Locking/notification are admin-only (S3 is Ramesh-only). The handler only *consumes* the post-lock state (their bus chart). Confirm the handler has no lock/notify affordance.
6. **Phase 4 (Tally & Book Bus) is ADMIN-only and thin (5 UCs).** "Book the bus" is an off-app phone call; the app models the *decision* (demand + capacity banner). The two coexisting capacity counters (leg-aware `UgamCapacityMeter` vs raw `_Tally`) legitimately differ — SC-S1…-3/-4/-5 dramatize the engine-truth read so a tester doesn't file the difference as a bug.
7. **Return-leg coverage spans three section files** (01 lifecycle, 04 seats, 06/07 money) — there is no single base-level "return-leg" section. **S5 is the consolidated walk-through**; rely on it to avoid a fragmented test.
8. **Two open bugs intersect cross-cutting flows** (`docs/BUGS.md`): push deep-link lands on Charts (index 2) not Requests (index 3); wrong-password snackbar leaks debug PII. Both reproduce in the base-level cross-cutting journey (UC-E2E-10 in section 09) — keep them failing-expected until fixed.

---

*Master charter over `docs/use-cases/scenarios/` (6 real-world scenario files · 52 activation scenarios incl. the Golden tour) leading `docs/use-cases/` (9 base-level sections · 158 area use cases) + a phase×actor coverage matrix. Keep the layers in lock-step: when a scenario or base-level UC is added/renumbered, update the [PRIMARY](#primary--real-world-operational-scenarios) index, the [Golden tour](#golden-tour--one-real-trip-start-to-finish) links, and the [Base-level index](#reference--base-level-mechanics-index).*
