# Seats page — visual polish (no functional change)

**Date:** 2026-07-20
**Branch:** feat/money-collection-settlement
**Screen:** `TourSeatAssignmentScreen` (embedded in `SeatsScreen`) — the manual seat-assignment grid.

## Goal

Make the seat-assignment page look clean and premium **without changing how it
works or what the seat tiles show**. Approved against a mockup
(`.superpowers/brainstorm/.../polish-v1.html`).

Hard constraints from the user:
- Keep seat-tile content exactly: **name + mobile number + the existing
  Go/Return/Priority background colors**.
- Keep the dark Charcoal-Copper theme.
- **Do not change functionality** — tap-to-seat, drag-to-move/swap, sofa
  sharing, relocate, lock/download, manage buses, the pending queue: all
  behave identically.

## Changes (visual + one approved relocation)

### 1. Remove the `સીટ બદલો` (edit-seats) chip
- Delete `_EditSeatsToggle` and the `_editMode` state/branches from
  `tour_seat_assignment_screen.dart`.
- This frees the horizontal space that was clipping the second bus pill's
  capacity badge (the cut-off "32").

### 2. Relocate Premium/Held marking into the seat tap menu (approved)
The chip was the only entry to `_showSeatFlagsSheet` (Forward/premium +
Hold/reserved). Preserve the capability, move the entry:
- **Occupied seat** → tap opens `OccupantActionSheet`; add a "Seat: Hold /
  Premium" action row (action mode only) that opens the existing flags sheet.
- **Empty seat** → **long-press** opens the flags sheet. The grid already has an
  unused `onSeatLongPressForFlags` hook; extend `CombinedSeatGrid._wrapTile` so a
  **non-draggable (free)** seat can carry the long-press even while drag is
  enabled for booked seats. Booked-seat long-press stays = drag (unchanged).

### 3. Bottom dock — de-cramp (`_AssignmentDock`)
The current collapsed dock reserves a fixed **360px** and stacks the active
summary directly above near-identical queue rows ("two Zeel rows").
- Split into two clearly-labelled zones: **Now seating** (one highlighted
  copper-tinted card: avatar + name + request + progress) and **Up next**
  (compact horizontal passenger chips + "See all ›" + "+N").
- Reduce reserved height (`_kCollapsedDockHeight`) to match the shorter dock so
  more chart shows. Grab handle still expands to the full `_PassengerCard`.
- Every action/behavior preserved: tap a chip = select that passenger; "See
  all" = full pending sheet; lock / download / pick-handler buttons unchanged.

### 4. Bus pills + header tidy
- Bus row: drop the trailing chip; clean pill styling; full `assigned/total`
  badges visible.
- Header (`SeatsScreen._header`): consistent spacing for the circular controls.

### 5. Chart
- Seat-tile **content untouched**. Benefits from the shorter dock (more room),
  even gaps, and the existing copper selection ring.

## Out of scope
No layout re-architecture (no slide-up sheet / guided flow), no seat-tile
content or color changes, no behavioral changes.

## Verification
- `flutter analyze` clean.
- Existing widget tests green (`seats_screen_test.dart`,
  `tour_controller_test.dart`, seat-assignment tests).
- Drive the real app: chip gone, badges intact, long-press empty seat →
  flags sheet, tap occupied → sheet has Hold/Premium, dock reads Now/Up-next.
