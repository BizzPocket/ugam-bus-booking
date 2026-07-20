# Use Cases — Seat Assignment Grid, Groups, Exceptions, Swaps, Cross-Bus Moves, Sofa Rules (Phase 6, Admin)

Area: Phase 6 — the admin (tour agent) seat-assignment workspace. Covers the unified
Seats screen (Summary ↔ Grid), tap-to-place auto-seating, long-press drag (move /
swap / split / fill / consolidate), the floating assignment dock, the occupant action
sheet (priority / make-handler / swap-in / move-or-swap), cross-bus relocate via
SeatMoveFlow, the "needs your decision" exceptions list, the groups & priority screen,
and the double/single sofa whole/paired/shared/leg-share semantics.

All actors here are **ADMIN** unless noted. Seat counting is trip-aware: a one-leg
(GO-only or RET-only) booking weighs 0.5 of a berth and two opposite one-way riders can
reuse ONE physical berth. A Double Sofa cell is 2 berths; Single Sofa & Seater are 1.
`Tour.acceptsBookings` / status is the lock gate. All user-facing strings are localized
via `easy_localization` (`tr('ns.key')`) and must exist in **en/gu/hi** with the same
key path — every `tr(...)` call below implies a 3-file parity requirement.

Primary screens/files:
- `lib/screens/seats_screen.dart` — shell (Summary ↔ Grid switcher, head bar, clear-bus, manage-buses)
- `lib/screens/tour_overview_screen.dart` — Summary surface (auto-fill cockpit, capacity, bus rows)
- `lib/screens/tour_seat_assignment_screen.dart` — Grid workbench (tap-to-place, drag, dock, relocate)
- `lib/screens/seating_exceptions_screen.dart` — "Needs your decision" list
- `lib/screens/tour_groups_screen.dart` — Groups & priority
- `lib/components/combined_seat_grid.dart`, `lib/components/seat_chart_tile.dart` — grid render + drag wrapper
- `lib/widgets/occupant_action_sheet.dart` — occupant menu
- `lib/services/seat_move_flow.dart`, `lib/services/seat_swap_guard.dart`, `lib/utils/seat_drop_engine.dart`
- `lib/controllers/tour_controller.dart` — `assignSeats` / `moveSeat` / `swapSeats` / `moveGroupToBus` / `moveSharedPair` / `swapSeatContents` / `consolidateOntoDouble` / `unassignBus`
- `lib/models/seat_assignment.dart`, `seat_layout.dart`, `seat_type.dart`, `passenger_group.dart`

---

### UC-04SEATASSIGNMENT-1: Land on the seat Summary and drop into the Grid by hand
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** Tour exists with at least one booked bus and at least one passenger request.
- **Steps:**
  1. Open the tour and enter the Seats workspace (default `SeatsMode.summary`).
  2. Observe the Summary surface: a "seats placed / total" capacity meter (two-leg GO/RET split), the bus-requirements line (N single · N double · N seater + total to book), and a vertical list of bus rows each with a status dot + per-bus capacity meter.
  3. Tap the primary "Edit seats by hand" CTA.
  4. Observe the head bar leading control changes to a "back to Summary" affordance and the subtitle flips to the grid subtitle.
  5. Tap the head-bar back affordance to return to Summary.
- **Expected:**
  - Summary is the surface the agent lands on; "Edit seats by hand" is the prominent champagne CTA, "Fill bus / Re-generate plan" is the quiet ghost button beneath it.
  - Grid and Summary are lazy-mounted in an `IndexedStack`; switching keeps each surface's local state (selected passenger, bus, scroll).
  - The seats-placed meter shows whole seats only — never a percentage or fractional `seatLoad`.
  - Capacity figures come from one `computeTourCapacity` snapshot shared by the summary meter, each bus row, and the shortfall banner — they never disagree.
- **Edge cases:**
  - Tour with no buses → Summary shows the `_NoBuses` empty state; the Grid shows `_NoBuses` (with an add-bus path); CTAs disabled (`hasBuses == false`).
  - Tour with buses but no passengers → Grid shows `_NoPassengers` empty state.
  - Switch app language (en/gu/hi) mid-session → meter labels, "Edit seats by hand", subtitles, bus-requirement chips all re-localize.
- **Screens/files:** `lib/screens/seats_screen.dart`, `lib/screens/tour_overview_screen.dart`, `lib/screens/tour_seat_assignment_screen.dart`

---

### UC-04SEATASSIGNMENT-2: Tap-to-place a pre-selected passenger onto a fitting free seat
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid; a passenger is selected in the dock/queue (or deep-linked via "Assign Seats →" from Requests). The passenger is not fully assigned, not waitlisted, and has a pending request line matching the target cell type.
- **Steps:**
  1. Confirm the active passenger's name shows in the assignment dock with their pending lines (e.g. "1 × Single Sofa, 0/1").
  2. Tap an EMPTY seat cell of the matching type on the chart.
  3. Observe the seat fills with the passenger; a success toast appears.
  4. Continue tapping until the passenger is fully assigned.
- **Expected:**
  - On a single fit, the passenger is placed immediately with no picker (`_placeBerths`); a "seat saved" toast fires with the seat id.
  - Tapping a free Double Sofa with a pending doubleSofa line claims 2 berths; tapping with only a single/seater pending line claims 1 berth (`_berthsForFreeCell` via shared `berthsForFreeCell`).
  - When the passenger becomes fully assigned, a "fully assigned" success toast fires, haptic light-impact, and the dock auto-advances to the next un/partially-assigned passenger (excluding `journeyDone`).
  - The bus pill badge updates using leg-aware `occupiedBerthsFor` (physical seats, not raw entries) so it never reads past capacity.
- **Edge cases:**
  - Selected passenger does NOT fit the tapped cell (wrong type / no pending line) → falls through to the seat picker of other candidates.
  - Last passenger placed but no handler picked yet → a warning toast ("no handler") instead of "all done".
  - Last passenger placed AND handler already set → an "all done" success toast.
  - Waitlisted passenger cannot be auto-placed (excluded from the active fit).
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_onSeatTapped`, `_placeBerths`, `_berthsForFreeCell`), `lib/utils/seat_fit.dart`

---

### UC-04SEATASSIGNMENT-3: Seat-first assignment via the empty-seat passenger picker
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid with NO passenger selected, OR the selected passenger doesn't fit the tapped cell. At least one pending passenger can take the cell.
- **Steps:**
  1. Tap an empty seat cell.
  2. Observe a bottom sheet titled with the seat id + bus name listing pending passengers who can sit there.
  3. Pick a passenger from the list.
  4. Observe they are seated there.
- **Expected:**
  - Candidates are filtered to `!isFullyAssigned && !isWaitlisted && berthsForFreeCell > 0`; the currently-selected passenger (if any) is surfaced first and tagged with a check.
  - Each row shows name + outstanding `requestSummary`.
  - Picking calls `_placeBerths` with the computed berths for that cell.
- **Edge cases:**
  - No candidate can take the cell → a warning toast `tour_seat_assignment.picker_none` (with the seat id), no sheet.
  - Picker title/subtitle and "no candidate" warning must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_openSeatPicker`, `_SeatPassengerPicker`)

---

### UC-04SEATASSIGNMENT-4: Long-press drag to MOVE a seated passenger to a free seat (same bus)
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid (edit-seats mode OFF); a seat holds exactly one occupant (or a draggable shared-double unit).
- **Steps:**
  1. Long-press a booked seat to lift it; a chip follows the finger showing the occupant name (or "A + B" for a shared pair).
  2. While dragging, observe other cells light up: green ring = valid target, dim = bad fit, red lock = held/reserved seat.
  3. Release onto a FREE, compatible seat.
  4. Observe a "moved" success toast and the passenger now sits on the target.
- **Expected:**
  - The live highlight (`_dropHighlightFor`) mirrors the exact verdict the release will apply (`decideSeatDrop`) — what you see is what the drop does.
  - The move routes through the group-safe `TourController.moveSeat` (same-bus, `toBusId == busId`).
  - Drag is SAME-BUS only — dragging never splits a group across buses.
- **Edge cases:**
  - Release onto a class-mismatch seat (sleeper↔seater) → blocked, medium-impact haptic, a class-mismatch warning toast (seater vs sleeper variant).
  - Release onto a seat too small for a whole-double mover → `splitToSingle`: ONE berth peels onto the single (the rest stays on the source) with a "split" toast — not a "too small" rejection.
  - Release onto a held/reserved seat → red-lock highlight + `held` warning toast.
  - Reserved source seat cannot be picked up at all (`_canDragSeat` returns false).
  - Edit-seats mode ON suspends all drag.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_handleSeatDrop`, `_decideDrop`, `_dropHighlightFor`, `_canDragSeat`, `_toastBlocked`), `lib/components/combined_seat_grid.dart` (`SeatDragWrapper`), `lib/utils/seat_drop_engine.dart`

---

### UC-04SEATASSIGNMENT-5: Long-press drag to SWAP two seated passengers (same bus)
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid; two compatible seats each hold an occupant.
- **Steps:**
  1. Long-press one occupied seat, drag it over another occupied, compatible seat (green highlight).
  2. Release.
  3. Observe a "swapped" success toast naming both passengers; they exchange seats.
- **Expected:**
  - A single-occupant ↔ single-occupant exchange routes through `SeatSwapGuard.run` (leg-aware; over-book asks to bump the one-leg occupant rather than erroring).
  - Two FULL doubles dropped on each other → `swapPair` exchanges full contents via `swapSeatContents` (both cap-2, always seat-safe).
  - Dropping a mover onto a half-occupied double that can share their leg → `fill` (after a share confirm), seating them beside the occupant (1 berth) via `moveSeat`.
  - Dropping a leg-disjoint single-pair onto an occupied leg-disjoint double → `fillPairInto` (two atomic 1-berth moves; all four share across opposite legs).
- **Edge cases:**
  - Swap that would violate a leg constraint → `SeatSwapGuard` surfaces a guarded prompt / bump rather than silently overbooking (covered by the swap-leg guard).
  - Target double is shared by two distinct people and the drop is ambiguous → `sharedTargetAmbiguous` info toast (manage per-person via the occupant sheet instead).
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_handleSeatDrop` cases swap/swapPair/fill/fillPairInto), `lib/services/seat_swap_guard.dart`, `lib/controllers/tour_controller.dart` (`swapSeats`, `swapSeatContents`)

---

### UC-04SEATASSIGNMENT-6: Drag a paired double onto a single seat — pick which sharer peels off
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid; a Double Sofa is shared by TWO distinct passengers (a paired double). A free or single-occupant SINGLE seat is available.
- **Steps:**
  1. Long-press the shared double; release it onto a single seat (engine surfaces the target as VALID/green).
  2. Observe a picker sheet titled with the target seat id asking WHICH of the two sharers moves onto the single.
  3. Pick one passenger.
  4. Observe that passenger moves to the single; the other keeps the double.
- **Expected:**
  - `splitPairChoice` opens `_promptSplitPairOntoSingle`; the chosen sharer is moved with `moveSeat(berths: 1)` (free target) — "moved" toast.
  - If the target single is OCCUPIED, the chosen sharer SWAPS with that occupant via `SeatSwapGuard` (the displaced occupant joins the remaining sharer on the double) — "swapped" toast.
- **Edge cases:**
  - Target single is itself reused across legs (2 occupants) → too ambiguous for one tap → `sharedNeedsFreeDouble` info toast, no split.
  - Split-pair sheet title/subtitle and moved/swapped toasts must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_promptSplitPairOntoSingle`, `_seatChosenSharerOnSingle`)

---

### UC-04SEATASSIGNMENT-7: Consolidate two cross-filled singles into one Double Sofa by drag
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A passenger who requested a Double Sofa was satisfied via two cross-filled SINGLE berths on the same bus, and still has an outstanding doubleSofa request line. A FREE Double Sofa exists.
- **Steps:**
  1. Long-press one of the passenger's two single berths; drag it onto the free Double Sofa.
  2. Release.
  3. Observe BOTH singles fold into the one double (a "consolidated" success toast).
- **Expected:**
  - `_consolidationPartnerSeat` detects the second cross-filled single and routes the move through `TourController.consolidateOntoDouble` with both source seats, instead of a plain 1-berth move.
  - Only triggers when: target is a FREE double, source holds exactly 1 berth, exactly one OTHER single-sofa berth is held on this bus, and a doubleSofa request line is still outstanding.
- **Edge cases:**
  - More than one candidate "other single" → ambiguous → falls back to a plain `move`, not a consolidation.
  - Target double is occupied/half-filled → treated as fill/swap, never consolidation.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_consolidationPartnerSeat`, `_handleSeatDrop` move case), `lib/controllers/tour_controller.dart` (`consolidateOntoDouble`)

---

### UC-04SEATASSIGNMENT-8: Share a Double Sofa half / leg-reuse via tap (seat-here)
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A passenger is mid-placement (selected in the dock). A Double Sofa already holds ONE occupant, with a free half on the active passenger's leg, OR a single/double seat is occupied on the OPPOSITE leg only.
- **Steps:**
  1. With the passenger selected, tap the occupied seat.
  2. Observe the occupant action sheet opens with a "seat [name] here" action (accent-tinted).
  3. Tap it; confirm the share in the confirm sheet.
  4. Observe the active passenger now shares the seat.
- **Expected:**
  - `_seatHereBerths` computes per-leg room: a Double holds `cap` berths on GO and `cap` on RET independently; a GO-only occupant leaves the RET leg free for an opposite-leg rider on the SAME physical seat.
  - "Seat here" only appears when `berths > 0` for the active passenger; the share confirm names both occupants.
- **Edge cases:**
  - No leg room to share BUT exactly one occupant blocks the active rider's leg → the sheet offers "swap [name] in" instead (UC-9).
  - Two occupants both overlap the active leg (ambiguous, e.g. round-trip rider onto a GO+RET leg-shared seat) → neither share nor swap-in is offered (`_conflictingOccupant` returns null — never guess/overbook).
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_seatHereBerths`, `_seatHere`, `_openOccupantSheet`), `lib/utils/seat_leg_capacity.dart`, `lib/widgets/occupant_action_sheet.dart`

---

### UC-04SEATASSIGNMENT-9: Swap a pending rider IN by bumping the leg-conflicting occupant
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A passenger is mid-placement. The tapped seat is FULL on that passenger's leg, but exactly one occupant's leg collides with theirs (no ambiguity).
- **Steps:**
  1. With the passenger selected, tap the full seat.
  2. Observe the occupant sheet offers "swap [name] in" (accent) rather than "seat here".
  3. Tap it and confirm.
  4. Observe the conflicting occupant is freed back to the pending pool and the active passenger takes the berth(s).
- **Expected:**
  - `_swapInPlacing` frees only the conflicting occupant's berth(s) on THIS seat (they keep their request → drop into pending), then `_placeBerths` seats the active passenger on the freed berth(s).
  - This fixes the old "no room on this leg" dead-end into an actionable swap (tap path only; the drag engine is untouched).
- **Edge cases:**
  - Active passenger still wouldn't fit after the bump (`berthsAfter == 0`) → swap-in is NOT offered.
  - A second leg-share occupant on the seat stays put (only the one conflicting occupant is bumped).
  - Swap-in confirm strings must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_swapInPlacing`, `_conflictingOccupant`, `_tripsOverlap`), `lib/widgets/occupant_action_sheet.dart` (`onSwapIn`)

---

### UC-04SEATASSIGNMENT-10: Cross-bus relocate — tap-to-place hand-off via SeatMoveFlow
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** Tour has 2+ buses; a passenger sits on one bus.
- **Steps:**
  1. Tap the occupant; in the sheet choose "Move or swap".
  2. In the destination-bus picker, pick a DIFFERENT bus.
  3. Observe the chart switches to that bus, an accent "relocate" banner appears naming the in-hand mover + target bus, and the mover is held "in hand".
  4. Tap a FREE seat on the new bus; confirm the move.
  5. Observe a "moved" toast; the passenger now sits on the new bus's seat.
- **Expected:**
  - `SeatMoveFlow.start` with `onRelocateToBus` hands control back to the chart (no auto swap-assistant); `_beginRelocate` switches bus + selects the mover + remembers the source seat.
  - Tapping a free seat → `_relocateOntoFree` → `moveSeat` cross-bus; tapping an occupied seat → `_relocateOntoOccupied` → occupant sheet with "seat [mover] here" → cross-bus `SeatSwapGuard` swap.
  - A whole-double mover onto a 1-capacity seat peels a single berth (cap to `targetCap`); the rest stays on the source for a second relocate.
  - Dropping one single onto a free double while the mover holds another single on this bus → asks "pair both, or just this one?".
  - Cancel via the banner's Cancel clears relocate mode (`_cancelRelocate`).
- **Edge cases:**
  - Single-bus tour → SeatMoveFlow skips the picker (no relocate, only the in-bus swap-assist path).
  - Tapping the mover's OWN seat during relocate is a no-op.
  - Relocate banner + confirm + moved/swapped toasts must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_beginRelocate`, `_onRelocateSeatTapped`, `_relocateOntoFree`, `_relocateOntoOccupied`, `_relocateSwap`, `_RelocateBanner`), `lib/services/seat_move_flow.dart`, `lib/widgets/occupant_action_sheet.dart`

---

### UC-04SEATASSIGNMENT-11: Move or swap via the auto swap-assistant (in-bus / no relocate callback)
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** Occupant sheet "Move or swap" reaches `SeatMoveFlow` WITHOUT a relocate callback (legacy / detail-screen path), or destination == source bus.
- **Steps:**
  1. From the occupant sheet choose "Move or swap" → pick a destination bus.
  2. Observe the Swap Assistant sheet: a "free seats" section (accent chips), a "can swap" section (ranked candidates with seat + reason), and a dimmed "cannot move" section.
  3. Tap a free seat chip → the mover takes it; OR tap a swap candidate → they exchange.
- **Expected:**
  - `SwapCandidateFinder.find` resolves the mover's seat class/berths on the source bus so a cross-bus swap surfaces candidates even when their request is already satisfied.
  - "Take free" → `moveTo` (caps berths for a too-small target); "swap" → `swapMover` → `SeatSwapGuard`.
  - Empty result → a "no room on [destination]" message.
- **Edge cases:**
  - Candidate reason strings (e.g. swap-candidate reasons) must exist in en/gu/hi.
  - Sheet anchored to the root navigator so it paints above the bottom dock and survives the source sheet being popped.
- **Screens/files:** `lib/services/seat_move_flow.dart` (`_openSwapAssist`, `_SwapAssistSheet`), `lib/services/swap_candidate_finder.dart`, `lib/services/seat_swap_guard.dart`

---

### UC-04SEATASSIGNMENT-12: Group cohesion — moving a grouped passenger cascades the whole group across buses
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A passenger belongs to a cross-booking group (2+ members) whose siblings are NOT all on the destination bus.
- **Steps:**
  1. Relocate or drag the grouped passenger toward another bus (or use Move-or-swap → destination bus).
  2. Observe a "Move whole group (N people)?" confirm.
  3. Confirm.
  4. Observe every group member is re-seated together on the destination bus.
- **Expected:**
  - A cross-bus `moveSeat` of a grouped member whose group isn't already wholly on the destination reroutes to `moveGroupToBus` (`_groupNotAllOnBus`); the specific target seat is intentionally NOT preserved (within-bus arrangement is free).
  - `moveGroupToBus` REPLACES each member's entire `assignedSeats` with engine-proposed berths on the destination — nobody is left behind on the old bus.
  - `SeatMoveFlow._moveGroup` shows the group-move confirm and a blocked dialog when the group doesn't fully fit.
- **Edge cases:**
  - Manual `assignSeats` that would put a grouped passenger on a different bus from a seated sibling → blocked with `seat.group_locked_msg` warning (no write).
  - Group can't fit the destination bus → `seat.group_move_no_fit` warning; the move is refused.
  - Same-bus move of a grouped member is allowed (group stays whole on this bus).
  - The first member seated (no sibling seated yet) is allowed.
- **Screens/files:** `lib/controllers/tour_controller.dart` (`assignSeats`, `moveSeat`, `moveGroupToBus`, `_wouldSplitGroup`, `_groupNotAllOnBus`), `lib/services/seat_move_flow.dart` (`_moveGroup`), `lib/services/group_cascade.dart`

---

### UC-04SEATASSIGNMENT-13: Create, fill, and manage cross-booking groups + the one-bus capacity gate
- **Actor:** admin
- **Phase:** 6 (and earlier; groups feed seating)
- **Preconditions:** Tour with 2+ passengers and at least one bus.
- **Steps:**
  1. Open the Groups & priority screen.
  2. Tap "New group" → rows grow checkboxes; tick 2+ passengers.
  3. Observe the sticky CTA shows the running seat count "Create group (N) — S seats".
  4. Tap it, accept/rename the pre-filled "Group N" label, confirm.
  5. Observe a new group section with a numbered colour badge, member chips, and a capacity readout.
  6. Add a member via the inline "+ Add" chip; remove a member via the chip's ×; delete the whole group (confirm).
- **Expected:**
  - Group berths are summed via `seatBerths`; a selection whose berths exceed `biggestBusSeats` is BLOCKED (the "41 in a 36-seat bus" rule) — CTA disabled + relabelled, and `_createGroup` re-checks and errors with `tour_groups.create_too_big`.
  - New group gets a distinct golden-angle colour (`colorIndex = existing group count`).
  - Group capacity badge tone: green = room, warm = exactly full, red = over (`GroupFit`); an over-capacity inline "won't fit" note shows.
  - Deleting a group only UNgroups members (they stay on the tour); copy says so.
  - "+ Add" chip is disabled + relabelled "full for bus" when the group already fills the biggest bus.
- **Edge cases:**
  - Fewer than 2 selected → CTA reads "pick two or more", disabled.
  - Empty roster / no search hits → `_NoPassengers` / `_NoSearchResults` empty states.
  - Remembered-companions suggestion cards (returning customers who travelled together) offer one-tap re-grouping via `recreateCompanionGroup`.
  - Search by name/phone filters the roster; all group/label/capacity strings must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_groups_screen.dart`, `lib/models/passenger_group.dart`, `lib/widgets/group_picker.dart` (`AddMemberToGroupSheet`), `lib/controllers/tour_controller.dart` (`createGroup`, `setPassengerGroup`, `deleteGroup`)

---

### UC-04SEATASSIGNMENT-14: Toggle priority (star) and make-handler from the occupant sheet / groups screen
- **Actor:** admin
- **Phase:** 6 / 7
- **Preconditions:** A passenger sits on a bus (occupant sheet) or appears in the groups roster.
- **Steps:**
  1. Open the occupant action sheet by tapping a booked seat (or use the star on a groups-screen row).
  2. Tap "Make priority" → confirm the priority alert ("reserve a lower berth where possible").
  3. Observe the star fills warm and the sheet stays open re-rendered.
  4. Tap "Make handler" to make this occupant the handler of THIS bus.
  5. Observe the action flips to "Is handler"; tapping again steps them down.
- **Expected:**
  - Turning priority ON confirms first (`priority.alert_*`); turning it OFF is a direct toggle (`setPassengerPriority`).
  - Make-handler is PER-BUS (`setBusHandler` / `removeBusHandler` on `widget.busId`); the sheet reflects `handlerPassengerId == occ.id` live.
  - The sheet re-reads the live occupant so the toggle reflects immediately without closing.
- **Edge cases:**
  - A shared-sofa seat shows a person toggle at the top — priority/handler/free act on the SELECTED occupant only.
  - Priority promise is honoured by the engine seating approved-priority riders onto LOWER berths first; a miss surfaces as a Priority exception (UC-16).
  - Priority alert + make/remove handler + make/remove priority labels must exist in en/gu/hi.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (`_togglePriority`, `_toggleHandler`), `lib/screens/tour_groups_screen.dart` (`_togglePriority`), `lib/controllers/tour_controller.dart`

---

### UC-04SEATASSIGNMENT-15: Free an occupant's berth / edit their request / call them from the occupant sheet
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A booked seat with one or two occupants.
- **Steps:**
  1. Tap a booked seat → occupant action sheet.
  2. Tap "Call" (if a phone exists) → the dialer opens.
  3. Tap "Edit request" → the edit-request sheet opens for that occupant (name / quantities / trip type).
  4. Tap "Free" → that occupant's berth(s) on THIS seat are released; they keep their request and drop back to pending.
- **Expected:**
  - "Free" removes only the assignments on `(busId, seatId)` for the selected occupant via `assignSeats`; the request is preserved so they re-enter the pending dock.
  - For a shared sofa, the person toggle selects which occupant "Free" acts on.
  - The read-only Charts variant of this sheet exposes only Call (no mutating actions) — admin action mode exposes the full set.
- **Edge cases:**
  - No phone → the Call row is hidden.
  - Editing the request can change quantities/trip → may free up or create new pending lines and shift capacity.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (`_free`, `_editRequest`, Call row), `lib/widgets/edit_request_sheet.dart`, `lib/utils/phone_dialer.dart`

---

### UC-04SEATASSIGNMENT-16: Review and resolve "Needs your decision" seating exceptions
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** The tour has live seating exceptions (priority-no-lower-berth, group-won't-fit, broken pair, seat-type-unavailable, overflow/waitlist).
- **Steps:**
  1. From the Summary "N need your decision" chip (or capacity banner "review waitlist"), open the exceptions screen.
  2. Observe exceptions grouped into Priority (pinned, danger-toned alert), Groups, Seat type, Waitlist sections with tabular counts.
  3. Tap an exception card → the grid opens pre-selected to the affected passenger (and their bus if seated).
  4. For an overflow/waitlist card, tap "Hold" (waitlists them) or "Edit" (shrink/retype the request), then re-generate.
- **Expected:**
  - The list reads LIVE via `seatingDecisionExceptions(tour)` (a pure, non-mutating helper) — never `fillTour` (which would assign + persist seats just to view). It is the SINGLE source shared with the Dashboard/Requests badge.
  - An overflow rider already HELD drops off the list instantly (no re-generate).
  - Priority-no-lower-berth gets explicit alert copy (title + message) and danger tones, pinned first.
  - Tapping a card with NO placed passenger still routes into the grid pre-selected to the affected passenger (not a dead end); only a fully unresolvable id shows the "nothing placed" hint.
- **Edge cases:**
  - No exceptions → calm "All clear" `UgamEmpty` (never an attention tone).
  - The Summary decision chip and the capacity banner are mutually exclusive (never both warm blocks at once).
  - All category labels, priority alert copy, hold/edit actions, all-clear, group-label, "nothing placed" must exist in en/gu/hi.
- **Screens/files:** `lib/screens/seating_exceptions_screen.dart`, `lib/screens/tour_overview_screen.dart` (`_DecisionChip`, `_CapacityBanner`), `lib/services/seating_engine.dart`

---

### UC-04SEATASSIGNMENT-17: Auto-fill / re-generate the plan and read the capacity / overflow banner
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** Tour with buses + passenger requests; on the Summary surface.
- **Steps:**
  1. With nothing placed, tap "Fill bus".
  2. Observe seats fill; the seats-placed meter and bus rows update; any unseatable riders surface as exceptions / overflow.
  3. With seats already placed, tap the now-labelled "Re-generate plan" → confirm the destructive re-run.
  4. If demand exceeds capacity, observe the warm capacity banner with "Add a bus" + ("Review waitlist" after an overflow OR "Edit requests" before a fill).
- **Expected:**
  - First fill runs immediately; every re-generate (placed > 0) confirms first (`regenerate_confirm_*`) since it discards the arrangement and re-assigns everyone.
  - `fillTour` persists only changed passengers via the offline-first `assignSeats` path; a no-op re-run writes nothing.
  - Pre-fill shortfall is ENGINE truth (`cap.needsDecision`) — leg-aware, not the naive `demandBerths − total`, so it never claims a phantom "6 short" when leg-sharing seats most riders.
  - Locked assignments are never moved by a re-generate (`SeatAssignment.locked`).
- **Edge cases:**
  - No buses → Fill/Edit CTAs disabled.
  - Overflow after a fill → authoritative `overflowWaitlist` count drives the banner title; "Review waitlist" jumps to the exceptions list.
  - Banner title/message/actions + berth/berths singular-plural must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_overview_screen.dart` (`_fill`, `_CapacityBanner`), `lib/controllers/tour_controller.dart` (`fillTour`), `lib/utils/tour_capacity.dart`, `lib/services/seating_engine.dart`

---

### UC-04SEATASSIGNMENT-18: Edit-seats mode — set Forward/Reserved flags (no placement)
- **Actor:** admin
- **Phase:** 6 / 5
- **Preconditions:** In the Grid.
- **Steps:**
  1. Tap the "Edit seats" pill at the end of the bus-pills row (it switches ON, accent-tinted, label → "Done").
  2. Tap any seat → a flags sheet opens with two switches: "Forward / premium seat" and "Hold / reserved".
  3. Toggle a flag; observe the chart repaints reactively.
  4. Tap "Done" to leave edit mode.
- **Expected:**
  - In edit mode a seat tap routes to `_showSeatFlagsSheet` (Forward via `setSeatForward`, Reserved via `setSeatReserved`) and drag-to-move is suspended — the two modes never compete for the long-press.
  - Reserved seats are protected: the seating engine never auto-fills them, and they can't be drag-targeted (red-lock highlight) or picked up.
  - Forward drives PRICING only (premium price) — it no longer affects auto assignment.
- **Edge cases:**
  - Reserving an already-occupied seat does not auto-free the occupant (flags are independent of occupancy).
  - Flags survive seat-id re-numbering (`copyWith` threads reserved+forward through `_regenerateIds`).
  - Edit-seats label / flag labels must exist in en/gu/hi.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_EditSeatsToggle`, `_showSeatFlagsSheet`, `_SeatFlagsSheet`), `lib/models/seat_layout.dart`

---

### UC-04SEATASSIGNMENT-19: Clear a whole bus's assignments from the head bar
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** In the Grid; the selected bus has at least one assigned seat.
- **Steps:**
  1. Observe the head bar shows a danger "layers clear" icon for the selected bus.
  2. Tap it → a destructive confirm sheet ("clear N seats on [bus]").
  3. Confirm.
  4. Observe every seat on that bus empties and a "cleared" success toast; passengers keep their requests and drop back into the pending dock.
- **Expected:**
  - The embedded grid pushes the clear callback up to the `SeatsScreen` head bar via `clearActionSink`; the icon only shows when the bus actually has seats (clearable↔empty flip).
  - `unassignBus` empties only the selected bus; other buses are untouched.
- **Edge cases:**
  - Bus with no assigned seats → no clear icon (`clearAction == null`).
  - Cancelling the confirm leaves everything assigned.
  - Clear-bus title/body/confirm/done strings must exist in en/gu/hi.
- **Screens/files:** `lib/screens/seats_screen.dart` (`_header`), `lib/screens/tour_seat_assignment_screen.dart` (`_confirmClearBus`, `_clearCachedBus`), `lib/controllers/tour_controller.dart` (`unassignBus`)

---

### UC-04SEATASSIGNMENT-20: Assignment dock — collapse/expand, queue navigation, and the Lock / Download gate
- **Actor:** admin
- **Phase:** 6 → 8
- **Preconditions:** In the Grid with pending passengers and/or all seats assigned.
- **Steps:**
  1. Observe the floating dock pinned at the bottom (collapsed by default) showing a one-line active-passenger summary, a horizontal pending queue strip, and a primary action.
  2. Drag the dock handle up (or tap it) → it OVERLAYS the chart with the active passenger's full pending breakdown (the chart is never squeezed).
  3. Tap a name in the queue → the chart jumps to that passenger (and their bus if seated).
  4. When every seat is assigned AND a handler is picked, tap the "Lock & notify" pill.
  5. After the tour is locked, tap "Download chart" to generate the A4 PDF.
- **Expected:**
  - The dock is collapsed by default so the whole chart stays visible; expanding overlays upward.
  - The Lock CTA appears only when `status != locked/completed`, passengers exist, `allSeatsAssigned`, and `handlerId != null` (content gate, not the stalled status label). It routes to `NotifyScreen` (the single lock+notify home) — this workbench no longer locks inline.
  - "Download chart" is enabled only when the tour is `locked`; it loads/edits the saved footer, persists it, then shares an all-buses A4 PDF.
  - When every seat is full, `passenger` is null and the dock shows only the done-state (no duplicate "all seats assigned" card).
- **Edge cases:**
  - Locked tour: the grid is effectively a read/settlement view; new bookings are blocked elsewhere by `acceptsBookings` (the single lock gate) — placement here should not re-open bookings.
  - Tapping a fully-assigned passenger jumps to the bus they actually sit on.
  - PDF generation failure → an error toast (`chart.error`); re-entry is blocked while generating.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_AssignmentDock`, `_openLockAndNotify`, `_downloadChart`), `lib/screens/notify_screen.dart`, `lib/services/seat_chart_pdf.dart`

---

### UC-04SEATASSIGNMENT-21: Return-leg phase — cancel a return seat and rebook in place
- **Actor:** admin
- **Phase:** 6 (return-leg track)
- **Preconditions:** The tour is in its return phase (`isReturnPhase`); an occupant rides the return leg (`retBerths > 0`).
- **Steps:**
  1. Tap the occupant → the sheet now shows "Cancel return seat" (return-phase only).
  2. Tap it → confirm the destructive cancel.
  3. Observe the return seat is freed; a success toast fires.
  4. Accept the follow-up "rebook?" prompt → the Add-return-ticket sheet opens to rebook the just-freed seat.
- **Expected:**
  - `onCancelReturn` is offered only when set AND `retBerths > 0` AND `isReturnPhase`; it routes through `_cancelReturnSeatFlow` → `cancelReturnSeat` then offers guided rebook.
  - `journeyDone` (GO-leg-complete) passengers are excluded from the engine and `pendingSeatsToAssign`, so the dock never shows a false "allocate N" for them.
- **Edge cases:**
  - A round-trip occupant before the return phase → "Cancel return seat" is hidden.
  - Declining the rebook prompt leaves the seat free (re-assignable normally).
  - Cancel-return + rebook strings must exist in en/gu/hi.
- **Screens/files:** `lib/widgets/occupant_action_sheet.dart` (`onCancelReturn` gate), `lib/screens/tour_seat_assignment_screen.dart` (`_cancelReturnSeatFlow`), `lib/screens/add_return_ticket_sheet.dart`, `lib/controllers/tour_controller.dart` (`cancelReturnSeat`)

---

### UC-04SEATASSIGNMENT-22: Single-sofa share semantics and double half-empty render are correct (not bugs)
- **Actor:** admin
- **Phase:** 6
- **Preconditions:** A bus with single and double sofas; a mix of round-trip and one-way (GO-only / RET-only) riders.
- **Steps:**
  1. Seat a GO-only rider on a Single Sofa, then a RET-only rider onto the SAME single.
  2. Observe both occupy the one single berth (leg reuse) — this is intended, not an overbook.
  3. Place a single GO+RET leg-share on a Double Sofa.
  4. Observe the double still renders ONE free empty half.
  5. Tap a double shared by 3-4 leg-disjoint riders on a read-only chart.
- **Expected:**
  - A Single Sofa = 1 berth: one person OR a GO+RET leg-reuse pair on disjoint legs (kept by design); side-by-side split tiles are double-only.
  - A double that isn't physically full (incl. a GO+RET leg-share) renders a free empty half via `_freeDoubleBerths = 2 − max(GO,RET)` — a render-only correctness, placement was already right.
  - Leg is shown by a background tint (cyan = GO, violet = RET) alone — NO GO/RET text chip on seat tiles.
  - Read-only charts resolve occupants via full-roster `occupantListForBus` so a double sofa's 3-4 riders aren't dropped (a +N badge shows on the tile).
- **Edge cases:**
  - A "shared single" rendered as two distinct people was a render mis-classification (now fixed) — verify it renders as ONE berth, not a split tile.
  - The shared seat legend is one shared `UgamSeatChartLegend` (9 items, split go/return) across every occupancy screen for all roles — never hand-rolled.
- **Screens/files:** `lib/components/seat_chart_tile.dart`, `lib/components/combined_seat_grid.dart`, `lib/design/components/ugam_seat_grid.dart` (legend), `lib/utils/passenger_display.dart` (`occupantListForBus`)

---

### UC-04SEATASSIGNMENT-23: Empty states, offline, and role gating in the seat workspace
- **Actor:** admin (negative/edge focus)
- **Phase:** 6
- **Preconditions:** Various degraded conditions.
- **Steps:**
  1. Open the Grid for a tour with no buses → `_NoBuses`; with buses but no passengers → `_NoPassengers`; a bus with no layout → `_NoLayout`.
  2. Go offline, place a seat → the optimistic local update lands; the change queues for sync.
  3. Trigger a save failure (e.g. RPC unavailable on a group move) → observe the fallback and any snap-back to server truth.
- **Expected:**
  - Placement is offline-first via `_write` (optimistic local mutation, then persist); a hard write failure on a group move refreshes from server and surfaces an error toast.
  - `moveGroupToBus` falls back to per-passenger writes when the atomic `applySeatAssignments` RPC is unavailable (migration not deployed).
  - Empty-state copy (`tour_not_found`, `no_buses`, `no_passengers`, `no_layout`) must exist in en/gu/hi.
- **Edge cases:**
  - The seat workspace is an ADMIN surface — handlers/customers do not reach the assignment grid (handlers act on the bus money/chart screens; customers only fill the request form). The occupant sheet's read-only variant is what non-admin roles see in Charts.
  - Realtime tour updates repaint the chart via the `Obx` without rebuilding the static header.
- **Screens/files:** `lib/screens/tour_seat_assignment_screen.dart` (`_NoBuses`, `_NoPassengers`, `_NoLayout`), `lib/controllers/tour_controller.dart` (`_write`, `moveGroupToBus` fallback)
