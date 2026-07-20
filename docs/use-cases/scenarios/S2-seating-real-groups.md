# S2 — Seating real families & friend-groups (keep them together)

Real-world operational ("activation") scenarios for **Phase 6**, the admin seat-assignment
workspace. These are believable end-to-end trips a tour agent lives through when he has to
turn a messy pile of WhatsApp bookings into a seating chart where the Patels sit together,
Kanjibhai gets a single near the front, the GO-only and RET-only riders share berths, and a
last-minute addition doesn't blow up the plan. They exercise the **mechanics** documented in
`docs/use-cases/04-seat-assignment.md` but at the altitude of "what Ramesh actually does on a
Friday night before the bus leaves Saturday."

Personas used across this file:
- **Ramesh** — the tour agent (admin). Runs DEVAM / Ugam Foj community trips, reads the app in **Gujarati**.
- **Jignesh** — Ramesh's co-organiser who sometimes seats from his own phone.
- **The Patels** — a family of 5 (Suresh & Mina Patel + 3 kids) who must stay together.
- **The Solankis** — two brothers + wives, a friend-group of 4.
- **The Chauhans** — a family of 3 who book late.
- **Kanjibhai & Jadiben** — an elderly couple; each wants a **single sofa near the front**.
- **Bharat & Naresh** — two friends, one double sofa, full trip.

Money is in ₹. Seat counting is trip-aware: a one-leg (GO-only / RET-only) booking weighs 0.5
of a berth and two opposite one-way riders reuse ONE physical berth. A Double Sofa = 2 berths;
Single Sofa & Seater = 1. Gujarati strings are flagged where they carry the moment.

---

### SC-S2SEATINGREALGROUPS-1: Seat the Patel family of 5 as one block on one bus
- **Persona & goal:** Ramesh wants the Patels (Suresh, Mina + 3 kids) to ride together on one bus — no child stranded on bus #2 — for a 2-day Diu trip on two buses (a 41-seater "Ugam Express" and a 30-seater "Devam Travels").
- **Trigger (the activation):** Friday night seating session. The Patels' booking came in as one request from Suresh's phone: **2 Double Sofas + 1 Single Sofa**, full trip (GO+RET). Ramesh opens the Seats workspace and the Summary says 8 still need placement.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Tour has both buses booked. The Patels are NOT yet a formal group — they're one passenger request (Suresh) carrying 5 berths (2× double + 1× single). Bus #1 already has Bharat & Naresh on a double near the front; bus #2 is empty.
- **The flow:**
  1. Ramesh opens the tour → lands on the seat **Summary** (`SeatsMode.summary`); the two-leg capacity meter reads "0 / 8 placed" and the bus-requirements line shows "1 single · 2 double" outstanding for the Patel block.
  2. He taps **"Edit seats by hand"** (the champagne CTA) → drops into the **Grid**.
  3. In the assignment dock he selects **Suresh Patel**; the dock shows his pending lines "2 × Double Sofa, 1 × Single Sofa".
  4. He taps a **free Double Sofa** on Ugam Express → it claims **2 berths** (`_berthsForFreeCell` → `berthsForFreeCell` sees a doubleSofa pending line). Toast "seat saved".
  5. He taps a second free Double Sofa → 2 more berths. Then a **free Single Sofa** → 1 berth. Suresh is now **fully assigned**; a "fully assigned" success toast fires, light-impact haptic, and the dock **auto-advances** to the next pending passenger.
  6. All five Patel berths sit on **Ugam Express**, clustered.
- **Complications & recovery:** On berth #4 Ramesh accidentally taps a **Single Sofa** while a doubleSofa line is outstanding — the engine claims only **1 berth** there (a single can't hold a double pair), leaving the Patels one berth short of a whole double. He long-presses that lone single, and rather than fight it he **frees** it from the occupant sheet (request preserved, back to pending) and re-taps the correct free double. No data loss — the request line just re-entered the pending dock.
- **Real-world outcome (Expected):** Ramesh can tell Suresh "all five of you are on Ugam Express, two doubles and a single together." Observable: Suresh has 5 berths, all `busId == ugamExpress`, `isFullyAssigned == true`; bus pill badge counts physical seats via `occupiedBerthsFor` (never past capacity).
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-1, UC-04SEATASSIGNMENT-2, UC-04SEATASSIGNMENT-15.
- **Screens/files:** `lib/screens/seats_screen.dart`, `lib/screens/tour_overview_screen.dart`, `lib/screens/tour_seat_assignment_screen.dart` (`_onSeatTapped`, `_placeBerths`, `_berthsForFreeCell`), `lib/widgets/occupant_action_sheet.dart` (`_free`), `lib/utils/seat_fit.dart`.

---

### SC-S2SEATINGREALGROUPS-2: Lock the Solanki four-some so a re-generate can never split them
- **Persona & goal:** Ramesh learns from the Solanki brothers' WhatsApp thread that the two couples MUST share a bus (they're carrying the prasad and one brother is the informal handler). He wants the app to **enforce** that, not rely on his memory, so a later auto-fill can't scatter them.
- **Trigger (the activation):** Before he runs the big auto-fill, Ramesh formalises the Solankis as a **cross-booking group**.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6 (groups feed seating).
- **Setup / messy data:** Four separate requests (each brother + each wife booked individually on different days): Dinesh Solanki (1 double), Mahesh Solanki (1 double), and the two wives (1 double shared, or 2 singles). Total Solanki demand ≈ 4 berths. The 30-seater bus exists alongside the 41-seater.
- **The flow:**
  1. Ramesh opens **Groups & priority** (`tour_groups_screen`).
  2. Taps **"New group"** → rows grow checkboxes. He ticks the four Solanki rows.
  3. The sticky CTA shows the running count: **"Create group (4) — 4 seats"** (berths summed via `seatBerths`).
  4. He taps it, accepts the pre-filled **"Group 1"** label but renames it "Solanki" in the prompt, confirms.
  5. A new section appears with a golden-angle colour badge (`colorIndex = existing group count`), the four member chips, and a **green** capacity readout ("room") because 4 ≤ 41.
  6. Later he runs the auto-fill (SC-4); the engine seats all four Solankis on the SAME bus, and any manual `assignSeats` that would put a Solanki on a different bus from a seated sibling is **blocked** with the warning **`seat.group_locked_msg`** (Gujarati: "ગ્રુપના સભ્યો એક જ બસમાં રહેવા જોઈએ. તેના બદલે આખું ગ્રુપ ખસેડો." — *group members must stay on one bus; move the whole group instead*).
- **Complications & recovery:** Months from now the wives travel again with the brothers; on the NEXT tour Ramesh sees a **"remembered companions"** suggestion card (`suggestedCompanionGroups` / `recreateCompanionGroup`) offering one-tap re-grouping of the four — he doesn't have to re-tick them.
- **Real-world outcome (Expected):** Ramesh has a hard guarantee: the four Solankis are now an atomic unit. He can re-generate the whole plan at will without ever splitting them. Observable: all four share one `groupId`; group badge tone = green; a split write is refused with no DB mutation.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-13, UC-04SEATASSIGNMENT-12.
- **Screens/files:** `lib/screens/tour_groups_screen.dart`, `lib/models/passenger_group.dart`, `lib/controllers/tour_controller.dart` (`createGroup`, `setPassengerGroup`, `_wouldSplitGroup`, `recreateCompanionGroup`), `lib/widgets/group_picker.dart`.

---

### SC-S2SEATINGREALGROUPS-3: Sofa preferences — a double for the friends, singles up front for the elders
- **Persona & goal:** Ramesh must honour two specific sofa wishes that came over WhatsApp: **Bharat & Naresh** (two friends) want **one Double Sofa together**, and **Kanjibhai & Jadiben** (elderly couple) each want a **Single Sofa near the front** because Jadiben gets travel-sick at the back.
- **Trigger (the activation):** Ramesh is hand-seating the "special requests" before he bulk-fills the rest, so the engine doesn't bury the elders at the rear.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Bharat requested 1 Double Sofa (full trip). Kanjibhai and Jadiben are two SEPARATE single-sofa requests (each 1 berth, full trip). Ramesh marks the elders **priority** so the engine prefers lower/front berths for them.
- **The flow:**
  1. In the Grid, Ramesh selects **Bharat** → his pending line "1 × Double Sofa". He taps a free Double Sofa near the front → 2 berths claimed for the pair (Bharat carries his friend on the second berth of the same double); toast "seat saved".
  2. He taps Bharat's seat → occupant sheet → confirms Bharat & Naresh now share that double.
  3. He selects **Kanjibhai**, taps a **front Single Sofa** → 1 berth. Then **Jadiben**, taps the adjacent front single → 1 berth.
  4. He taps Kanjibhai's seat → occupant sheet → **"Make priority"** → confirms the priority alert (`priority.alert_*`, "reserve a lower berth where possible"); the star fills warm and the sheet stays open. Repeats for Jadiben.
- **Complications & recovery:** When Ramesh later re-generates the plan, Kanjibhai's priority can't always be honoured if the front singles are taken — that miss surfaces as a **priority-no-lower-berth** exception (pinned, danger-toned) in "Needs your decision," not a silent rear placement (SC-6). For now both elders sit up front exactly as promised.
- **Real-world outcome (Expected):** Ramesh can reassure Jadiben "you and Kanjibhai are right at the front, two singles side by side; Bharat and Naresh have their double." Observable: Bharat seat holds 2 occupants (paired double, renders as two people side-by-side — the double-only split tile); each elder holds a 1-berth single; both elders have `isPriorityApproved == true`.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-2, UC-04SEATASSIGNMENT-14, UC-04SEATASSIGNMENT-22.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_onSeatTapped`, `_placeBerths`), `lib/widgets/occupant_action_sheet.dart` (`_togglePriority`), `lib/components/seat_chart_tile.dart` (paired-double split tile).

---

### SC-S2SEATINGREALGROUPS-4: Auto-fill the bulk, then read "Needs your decision" honestly
- **Persona & goal:** With the special cases hand-placed (Patels, Solankis, elders, Bharat), Ramesh wants the app to seat the remaining ~25 ordinary riders in one shot and tell him the TRUTH about who didn't fit — without lying "6 short" when leg-sharing actually seats most of them.
- **Trigger (the activation):** Ramesh taps **"Fill bus"** on the Summary.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Mixed demand including several **GO-only** day-trippers and a few **RET-only** riders who joined the group at Diu and only need the way back. Locked hand-placements from SC-1/2/3 must survive.
- **The flow:**
  1. On the Summary, with the special cases already placed, Ramesh taps **"Fill bus"** (first fill runs immediately — no confirm).
  2. Seats fill; the seats-placed meter and per-bus rows update. The hand-placed Patels/Solankis/elders are **not disturbed** (their `SeatAssignment.locked` survives the engine pass).
  3. The pre-fill shortfall shown is **engine truth** (`cap.needsDecision`, leg-aware) — because two opposite one-way riders reuse one berth, the banner does NOT claim a phantom "6 short."
  4. A few riders genuinely overflow → a warm **capacity banner** appears with **"Add a bus"** + **"Review waitlist"**.
  5. Ramesh taps the Summary **"N need your decision"** chip → the **Seating Exceptions** screen, grouped into Priority / Groups / Seat type / Waitlist sections (live via `seatingDecisionExceptions`, NOT `fillTour`).
- **Complications & recovery:** One overflow rider (a late single-sofa request) has no compatible berth left. Ramesh taps **"Hold"** on that card → `setWaitlisted(true)`; the card drops off the list **instantly** (no re-generate), and the engine skips them on the next fill so no phantom overflow re-appears.
- **Real-world outcome (Expected):** Ramesh trusts the number: "everyone's seated except one held single — I'll squeeze them in if a no-show opens up." Observable: locked seats unchanged; banner count = authoritative `overflowWaitlist`; held rider gone from exceptions; the decision chip and capacity banner are never both warm at once.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-17, UC-04SEATASSIGNMENT-16.
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_fill`, `_CapacityBanner`, `_DecisionChip`), `lib/screens/seating_exceptions_screen.dart` (`_onHold`), `lib/controllers/tour_controller.dart` (`fillTour`), `lib/utils/tour_capacity.dart`, `lib/services/seating_engine.dart`.

---

### SC-S2SEATINGREALGROUPS-5: A late Chauhan addition forces a re-seat — keep them with their cousins
- **Persona & goal:** Two days before departure the Chauhans (family of 3) finally confirm. Their cousins (the Solankis) are already seated on Ugam Express. Ramesh wants the Chauhans seated **next to the Solankis**, but Ugam Express is nearly full.
- **Trigger (the activation):** A new request lands in the inbox at 11pm Thursday: Chauhan family, 1 Double Sofa + 1 Single, full trip.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Ugam Express has 2 free single berths left but NO free double. Devam Travels (30-seater) has plenty of room but no Solankis. Ramesh would rather keep the cousins together than perfectly honour the double.
- **The flow:**
  1. Ramesh approves the Chauhan request (it appears in the pending dock).
  2. He selects **Chauhan** and taps the two free **single** berths on Ugam Express → the engine cross-fills the double request as **two singles** (1 berth each) so the family still rides with their cousins.
  3. He taps one of the Chauhan singles → occupant sheet → confirms the family is on Ugam Express beside the Solankis.
  4. Later a **free Double Sofa** opens on Ugam Express (a no-show). Ramesh long-presses one Chauhan single and drags it onto that free double → the engine **consolidates** both cross-filled singles into the one double (`_consolidationPartnerSeat` → `consolidateOntoDouble`); toast "consolidated".
- **Complications & recovery:** During the drag in step 4, Ramesh first releases onto a Single Sofa that's too small for a whole-double mover → the engine does **`splitToSingle`** (peels one berth, rest stays, "split" toast) instead of rejecting — no dead end. He then finds the actual free double and the consolidation lands.
- **Real-world outcome (Expected):** The Chauhans ride beside their Solanki cousins, and once room opened they got their proper double. Ramesh can tell them "you're with your cousins; you've now got your double too." Observable: Chauhan held 2 cross-filled singles → folded into 1 double via `consolidateOntoDouble`; both families share Ugam Express.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-3, UC-04SEATASSIGNMENT-7, UC-04SEATASSIGNMENT-4.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_openSeatPicker`, `_consolidationPartnerSeat`, `_handleSeatDrop` move case), `lib/controllers/tour_controller.dart` (`consolidateOntoDouble`), `lib/utils/seat_drop_engine.dart`.

---

### SC-S2SEATINGREALGROUPS-6: Resolve a "broken pair" and a priority miss the engine flagged
- **Persona & goal:** After the big fill, "Needs your decision" shows two real problems: a **broken pair** (Bharat & Naresh ended up on separate seats) and a **priority-no-lower-berth** for Jadiben (front singles filled before her). Ramesh wants both fixed by hand.
- **Trigger (the activation):** Ramesh opens the **Seating Exceptions** screen from the Summary decision chip.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Exceptions present: `brokenPair` (Bharat/Naresh), `priorityNoLowerBerth` (Jadiben, pinned + danger-toned), and one `seatTypeUnavailable`. The list reads LIVE via `seatingDecisionExceptions(tour)` — a pure helper, never `fillTour` (which would re-assign just to view).
- **The flow:**
  1. The exceptions screen groups cards into **Priority** (pinned first, danger tone) → **Groups** → **Seat type** → **Waitlist**.
  2. Ramesh taps the **Jadiben priority** card → the Grid opens **pre-selected to Jadiben** and jumps to her bus (`_onExceptionTap` prefers a passenger who already holds a seat).
  3. He long-presses a front-row occupant who doesn't need the front and drags Jadiben's seat to swap → `SeatSwapGuard.run` (leg-aware) exchanges them; toast "swapped". Jadiben is now up front; her priority exception clears on the next read.
  4. He taps the **broken-pair** card → Grid pre-selected to Bharat. He drags Bharat's single onto Naresh's half-occupied double that can share their leg → engine offers `fill` (after a share confirm, Gujarati `tour_seat_assignment.share_confirm_*`: "આ ડબલ સોફા શેર કરવો?"), seating Bharat beside Naresh.
- **Complications & recovery:** The `seatTypeUnavailable` card is for a rider who wants a double but only seaters remain. Ramesh taps it → it routes into the grid pre-selected (not a dead end) and he taps **"Edit"** to shrink the request to a seater, then accepts. The exception disappears after the edit; no full re-generate needed for the held/edited ones.
- **Real-world outcome (Expected):** The decision list empties to a calm **"All clear"** (`UgamEmpty`, never an attention tone). Ramesh can say "every flagged problem is handled — Jadiben's up front, Bharat & Naresh are together." Observable: zero live exceptions; Jadiben on a front lower berth; Bharat/Naresh share one double.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-16, UC-04SEATASSIGNMENT-5, UC-04SEATASSIGNMENT-14.
- **Screens/files:** `lib/screens/seating_exceptions_screen.dart` (`_onExceptionTap`, `_onEdit`), `lib/screens/tour_seat_assignment_screen.dart` (`_handleSeatDrop` swap/fill), `lib/services/seat_swap_guard.dart`, `lib/services/seating_engine.dart`.

---

### SC-S2SEATINGREALGROUPS-7: Cross-bus move to keep a family whole — cascade the group
- **Persona & goal:** Ugam Express turns out to be over-subscribed and the bus owner asks Ramesh to move one whole family to Devam Travels to balance the load. Ramesh must move the **entire Patel family** (now a formal group) — never leave a Patel child behind.
- **Trigger (the activation):** The bus owner phones: "Ugam Express is too heavy, shift one family to the 30-seater."
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** The Patels are now a **group** of 5 berths sitting on Ugam Express. Devam Travels has room for all 5. Two buses exist, so the destination picker will appear.
- **The flow:**
  1. Ramesh taps any seated Patel → occupant sheet → **"Move or swap"** (`occupant_sheet.move_or_swap`).
  2. The **destination-bus picker** opens (`_DestinationPickerSheet`, Gujarati title "{name} ને {destination} પર ખસેડો"). He picks **Devam Travels** (a DIFFERENT bus).
  3. Because the mover is grouped and crossing buses, a **"Move whole group (5 people)?"** confirm appears (`seat_detail.group_move.*`). He confirms.
  4. `moveGroupToBus` REPLACES every Patel's `assignedSeats` with engine-proposed berths on Devam Travels — all 5 land together; nobody is stranded on Ugam Express. The chart switches and a "moved" outcome lands.
- **Complications & recovery:** Had Devam Travels lacked room for all 5, the cascade would have shown a **blocked dialog** (`seat.group_move_no_fit`, Gujarati "આખું ગ્રુપ આ બસમાં સમાતું નથી.") and refused the move — better a clear refusal than a half-moved family. The atomic RPC also has a **per-passenger fallback** if migration 011 isn't deployed, so the move still completes offline-first.
- **Real-world outcome (Expected):** Ramesh tells the owner "the Patel family — all five — are on Devam Travels now; Ugam Express is balanced." Observable: every Patel `busId == devamTravels`; no Patel berth remains on the old bus; tour status advances `busBooked → assigning` if it hadn't already.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-10, UC-04SEATASSIGNMENT-12.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (move-or-swap), `lib/services/seat_move_flow.dart` (`start`, `_moveGroup`, `_confirmGroupMove`, `_showBlockedDialog`), `lib/controllers/tour_controller.dart` (`moveGroupToBus`), `lib/services/group_cascade.dart`.

---

### SC-S2SEATINGREALGROUPS-8: Mixed GO/RET legs — share one physical berth between two one-way riders
- **Persona & goal:** Ramesh has two riders who together need only one physical seat: **Ramila** travels **GO-only** (returns by train), and **Hasmukh** joined at Diu and is **RET-only**. Ramesh wants the app to seat both on the **same single sofa** so he isn't paying the bus owner for a phantom extra seat.
- **Trigger (the activation):** Ramesh notices the capacity meter still shows a free berth even though "every rider" seems placed — he leans into the leg-reuse the engine allows.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Ramila = 1× Single Sofa, GO-only. Hasmukh = 1× Single Sofa, RET-only. The bus is otherwise full on the GO leg but has RET-leg room on Ramila's seat.
- **The flow:**
  1. Ramesh selects **Ramila** and taps a free single → she takes the berth (GO leg; tile tints **cyan** for GO — no GO/RET text chip, tint alone).
  2. He selects **Hasmukh** and taps **Ramila's occupied single** → because the seat is free on the RET leg, the occupant sheet offers **"seat Hasmukh here"** (`occupant_sheet.seat_here`, accent-tinted; `_seatHereBerths` computes per-leg room).
  3. He taps it, confirms the share → Hasmukh reuses the SAME physical single on the RET leg. The tile now carries both, tinted by leg (cyan GO / violet RET).
- **Complications & recovery:** Next Ramesh tries to seat a **round-trip** rider onto a single already holding a GO+RET leg-shared pair — both legs are taken, so the sheet offers **neither share nor swap-in** (`_conflictingOccupant` returns null — the app refuses to guess/overbook). He places that round-trip rider on a genuinely free seat instead. (Where exactly one occupant's leg DID collide, the sheet would instead offer **"swap [name] in"**, `occupant_sheet.swap_in`, bumping that one occupant back to pending.)
- **Real-world outcome (Expected):** Ramesh confirms to the bus owner "I need one fewer physical seat than headcount — two one-way riders share a single." Observable: one single sofa holds Ramila (GO) and Hasmukh (RET) as a leg-reuse, rendered as ONE berth (not a split tile, single-only rule); capacity meter counts it once.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-8, UC-04SEATASSIGNMENT-9, UC-04SEATASSIGNMENT-22.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_seatHereBerths`, `_seatHere`, `_conflictingOccupant`, `_swapInPlacing`), `lib/utils/seat_leg_capacity.dart`, `lib/components/seat_chart_tile.dart`, `lib/widgets/occupant_action_sheet.dart`.

---

### SC-S2SEATINGREALGROUPS-9: Split a paired double to free a seat for a late single — pick who peels off
- **Persona & goal:** A single-sofa late addition (Govind) has no free seat, but Bharat & Naresh's **paired double** has a sharer who could move to an open single, freeing room. Ramesh wants to move just **one** of the pair, not break them needlessly.
- **Trigger (the activation):** Govind DMs Friday afternoon; the grid looks full but Ramesh knows a paired double can be split.
- **Actors:** Ramesh (admin).
- **Phases spanned:** 6.
- **Setup / messy data:** Bharat (double, with Naresh) on Ugam Express; one **free Single Sofa** elsewhere on the same bus; Govind pending (1× Single Sofa, full trip).
- **The flow:**
  1. Ramesh long-presses Bharat & Naresh's **shared double** (the lifted chip reads "Bharat + Naresh") and drags it onto the **free single** (engine surfaces it green/VALID).
  2. On release a **split-pair picker** opens (`_promptSplitPairOntoSingle`) asking WHICH of the two sharers moves onto the single.
  3. He picks **Naresh** (Bharat keeps the front double) → Naresh moves with `moveSeat(berths: 1)`; toast "moved". The double now shows ONE free empty half.
  4. He selects **Govind** and taps that freed half of Bharat's double (or the now-open arrangement) → Govind is seated; the chart re-renders the double's free half correctly via `_freeDoubleBerths = 2 − max(GO,RET)`.
- **Complications & recovery:** Ramesh first tried dropping the paired double onto a single that is itself **reused across legs** (2 occupants) → too ambiguous for one tap → `sharedNeedsFreeDouble` info toast, no split. He retried onto the genuinely free single and the picker appeared. Had the target single been **occupied** by one person, the chosen sharer would have **swapped** with that occupant via `SeatSwapGuard` (the displaced person joining the remaining sharer) — "swapped" toast.
- **Real-world outcome (Expected):** Govind gets a seat without exiling either friend; Bharat & Naresh stay on the same bus (just not the same cell). Ramesh can tell Govind "you're in — I moved one person over to make room." Observable: Naresh on the single, Bharat on the double with one free half rendered, Govind seated; no leg overbook.
- **Base-level UCs exercised:** UC-04SEATASSIGNMENT-6, UC-04SEATASSIGNMENT-22, UC-04SEATASSIGNMENT-4.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_promptSplitPairOntoSingle`, `_seatChosenSharerOnSingle`, `_handleSeatDrop`), `lib/components/seat_chart_tile.dart` (`_freeDoubleBerths`), `lib/services/seat_swap_guard.dart`.
