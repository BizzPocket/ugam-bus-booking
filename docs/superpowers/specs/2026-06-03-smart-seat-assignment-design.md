# Smart Seat Assignment — Design Spec

**Date:** 2026-06-03
**Status:** Approved (brainstorm complete) — ready for implementation planning
**Supersedes the seat-assignment portions of:** `2026-05-06-agent-workflow-realignment-design.md`

---

## 1. Problem

The agent runs community yatra tours with **20–25 buses per tour**, ~1 tour/month, ~1000 berths. Today seat assignment is:

- **100% manual** — every berth placed by hand across two screens with *contradictory* gestures (`tour_seat_assignment_screen.dart` = tap-to-assign; `seat_assignment_screen.dart` = long-press-drag-to-rearrange). This is the "too many gestures / too complex" pain.
- **Blind to groups.** Two people who booked separately but must ride the same bus (A & C) have **zero** linkage in the data — it lives only in the agent's memory. Moving one cascades to nothing.
- **Blind to priority.** Elderly/unwell passengers who genuinely need front/sofa seats are not modeled (only an unused `AgeGroup`). If customers self-select "front seat," everyone claims it.
- **Built for 1–2 buses.** Bus picker is a horizontal pill strip; the pending list caps at 8; no overview; no auto-assign.

## 2. Goals / Non-goals

**Goals**
- The app **generates a full seating plan**; the agent reviews and fixes a **short exception list** instead of placing 1000 berths.
- Groups are first-class: **same-bus guaranteed**, moves **cascade** with one confirm.
- Priority is **request → agent-approved** (un-gameable); approved priority is seated front/sofa first, **spread across all buses**.
- **One calm, tap-first screen** per job; the seat grid gets *bigger*, not smaller.
- Scales to 25 buses without horizontal-pill hunting.

**Non-goals (deferred)**
- Ladies / gender-based seating (out of scope now; existing "ladies" marker untouched).
- Per-traveller / gender capture (bookings stay lean: contact + seat-type counts).
- A full mathematical optimizer — a **deterministic, explainable greedy engine + exception surfacing** is the target. "Better than the agent could do by hand, and never a confident bad guess."
- Premium/per-row pricing tie-in — pending the pricing brief (`2026-06-03-bus-pricing-brief.md`).

## 3. Decisions (locked in brainstorm)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Auto-generate plan; agent fixes exceptions | Removes the manual grind; concentrates judgment where it adds value |
| 2 | Buses interchangeable (single pickup point) | Any passenger, any bus → solver has freedom; elder-overflow avoidable |
| 3 | Lean bookings; **no gender**, no per-traveller form | One person books many seats; per-person data entry for 1000 is pointless |
| 4 | Groups = **agent-tagged**, hard rule = same bus, cascade on move | Customers can't game it; matches family/village reality |
| 5 | Priority = customer **requests**, agent **approves**; age is a hint only | Asking is free, but only approved priority is honored → un-gameable |
| 6 | One screen, **tap-first**; drag optional | Fewest gestures; works for both new placement and rearrange |
| 7 | Hard rules vs ordered goals; conflicts → exception card | The anti-"first-come-first-serve" guarantee; never a confident bad guess |
| 8 | Swap-assistant finds **who/where** for the agent | The "with whom do I swap" problem is solved by the app, not the human |

Additional confirmed hard rules: **reserved/blocked seats** (per-seat flag), **handler gets a front/door seat** (handler picked late).

## 4. Data model changes

All additive; offline-first (whole-row writes) preserved.

### 4.1 Groups
- New table **`passenger_groups`**: `id uuid pk`, `tour_id uuid fk`, `label text`, `color_index int` (for the tile ring), `created_at`.
- **`passengers.group_id uuid null`** (fk → passenger_groups, `on delete set null`) + index `(tour_id, group_id)`.
- Same-booking seats are already one unit (one passenger row). Cross-booking grouping = setting the same `group_id` on multiple passenger rows.

### 4.2 Priority
- **`passengers.priority_status text`** default `'none'` ∈ `{none, requested, approved, declined}`.
- **`passengers.priority_reason text null`** (short note; from customer or agent).
- Solver honors **only `approved`**.

### 4.3 Reserved seats & locked assignments
- **`SeatCell.reserved bool`** (in `buses.layout` jsonb) — agent marks driver/held-back seats; solver never fills them.
- **`SeatAssignment.locked bool`** (in `passengers.assigned_seats` jsonb) — a seat the agent placed/confirmed by hand; a re-generate must never move it. Default `false`; auto-set `true` on any manual move/swap/approve-fix.

### 4.4 Migration
- New file `supabase/migrations/005_seat_groups_priority.sql` (table + columns + indexes) and a matching update to `database.sql`.
- Dart models updated: `Passenger` (+groupId, priorityStatus, priorityReason), new `PassengerGroup`, `SeatCell` (+reserved), `SeatAssignment` (+locked).

## 5. The seating engine (the brain)

A **pure Dart module** — no UI, no I/O — so it is unit-testable and deterministic.

```
SeatingEngine.propose(Tour tour, {Set<lockedSeats>}) -> SeatingPlan
SeatingPlan { List<SeatAssignment> assignments, List<Exception> exceptions, Map<seat,Reason> rationale }
```

### 5.1 Hard rules (never violated)
1. Seat **type/position** matches the request (or valid cross-fill: 2 single berths ⇒ 1 doubleSofa line).
2. A **group** is entirely on **one bus**.
3. A **coupled** double-sofa's two berths stay together.
4. **Capacity** respected (no overbooking).
5. **Reserved** seats stay empty.
6. **Locked** assignments are kept exactly as-is.

### 5.2 Goals (optimized, in strict priority order)
1. **Approved-priority → front/sofa**, distributed across buses so no bus exceeds its front-seat budget.
2. Keep a **group's seats adjacent** within its bus (best effort).
3. **Balance** fill across buses.
4. Minimize **stranded** single berths.

### 5.3 Algorithm (greedy, deterministic)
1. Seed locked + reserved.
2. Pin coupled doubles.
3. **Bin-pack groups** (largest first) into buses that can hold the whole group; if the group has approved-priority members, prefer a bus with enough front seats.
4. Place **approved-priority individuals** into front/sofa seats globally.
5. Fill remaining individuals by best-fit type matching.
6. Anything unplaceable under hard rules ⇒ **Exception** (never a bad guess).

**Determinism:** stable sort keys (no randomness). Same input ⇒ same plan. **Explainability:** every placement carries a one-line reason ("group Patel", "approved priority — front", "type match"). **Missing data:** unknown ⇒ normal adult.

### 5.4 Exception types
`PriorityNoFrontSeat`, `GroupWontFit`, `SeatTypeUnavailable`, `PendingPriorityApproval`, `Overflow/Waitlist`, `BrokenPairAfterCancel`. Each carries a **suggested one-tap fix** + alternatives.

## 6. Screens

Three focused screens; **one job each**; existing `CombinedSeatGrid` reused. Replaces the two contradictory screens with **one** seat-detail surface.

### 6.1 Tour overview
- Vertical scroll of all buses (no pill strip): name · type · fill ratio · status dot (✓ / issues).
- Header: `placed / total`; a **warm "N need your decision →"** chip → exception list.
- Sticky primary: **Generate / Re-generate plan**.
- Tap a bus → seat detail.

### 6.2 Exception list
- The ~12 real decisions, grouped (Approvals / Groups / Seat type / Priority / Waitlist).
- Each card: plain-language problem + **one-tap suggested fix** + "Other".
- Empty list + handler set ⇒ **Lock tour** enabled.

### 6.3 Per-bus seat detail (tap-first)
- Full-bleed grid; **real names** (initials on tile, full info in sheet); **group ring** (color), **priority ring** (warm), dashed = free, reserved = struck.
- **Tap a seat → bottom sheet**: name/phone, requested lines, **Move / Swap / Free / Call**. No permanent panels.
- **Move/Swap → swap-assistant:** app lists only **movable** candidates (not in a group, not protected priority, compatible type), ranked by fit; one tap to swap. If none movable → states it + 3 explicit options (pick another bus / move whole group / override-split-with-confirm).
- **Group cascade:** moving a grouped passenger prompts "move the whole group?".
- Drag-to-move remains as an *optional* power gesture, never the only way.

## 7. Persistence & scale
- **Batch apply** a generated plan in one operation (RPC `apply_seating_plan` or batched upsert), not ~1000 sequential row writes; queued offline.
- Index `group_id`; consider a cached occupancy map to avoid the `seatOccupant` O(passengers×seats) scan.
- Re-generate respects **locked** assignments and **reserved** seats.

## 8. Edge cases (all surface to the exception list — never silent)
- **Cancellation** → frees seats; breaking a group/pair raises a card.
- **Late booking** after a plan exists → placed into free seats, or a card if none fit; locked seats untouched.
- **More requests than seats** → explicit **waitlist** card with who's over.
- **Handler front seat** → handler picked late; plan keeps a front/door seat easy to free; on appointment, offer to move them there via swap-assistant.

## 9. Implementation phasing (basis for the plan)
1. **Data & capture** — migration + models (`group_id`, `priority_status/reason`, `reserved`, `locked`); agent UI to tag groups, approve priority, mark reserved seats.
2. **Seating engine** — pure Dart, TDD; `propose()` + exceptions + rationale; full unit coverage of hard rules, ordered goals, cross-fill, determinism.
3. **Tour overview + exception list** screens wired to the engine.
4. **Per-bus seat detail** — one tap-first screen + swap-assistant + group cascade; **retire** the two old screens.
5. **Batch persistence + re-run/lock + edge cases** (cancellation/late/waitlist/handler).

## 10. Open / deferred
- Ladies rule & gender capture (out of scope).
- Premium/per-row pricing as an anti-gaming lever — pending `2026-06-03-bus-pricing-brief.md`.
- Money/handler-chart integration of group/priority rings — pending those briefs.
