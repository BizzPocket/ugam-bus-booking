# Requests screen — density redesign

**Date:** 2026-07-20
**Branch:** feat/money-collection-settlement
**Screen:** `lib/screens/requests_screen.dart` (`RequestsScreen`)

## Problem

The admin Requests list (`_RequestCard`) renders each request as a tall card:
name + a 40px-tall tap-to-call phone row + a wrapping chip block (often 2 rows)
+ a full note quote box + a 44px action row. Each card is ~200–240px, so only
**2–3 requests fit on a 6-inch phone**. This is the agent's primary triage
workspace, and the low density makes scanning and acting on a queue slow.

## Goal

Roughly **triple the rows per screen** (target 8–9 collapsed rows vs ~3 today)
without losing any information or action. Keep the change surgical: only the
list row and its interaction change.

## Non-goals (YAGNI)

- No new swipe/gesture package (reuse the existing `UgamSwipeAction`).
- No detail screen or new route.
- No changes to the top bar, search, tour pills, capacity banner, status tabs,
  sticky "Seats" CTA, or bulk-selection mode.
- No multi-action swipe menus; no left-swipe on the Assigned tab.

## Chosen model

**Compact rows + swipe for the top 2 actions + tap-to-expand (inline accordion)
for everything else.** Swipe is a pure accelerator — every action also remains
reachable through the expanded row, so nothing depends on discovering the
gesture.

---

## A. Collapsed row (default)

Two tight lines, ~64px tall. No avatar, no standalone phone row, no note box,
no button row when collapsed — those are today's height hogs.

```
│▎ Test Mahesh (QA)                     1d │  line 1: name (bold, ellipsis) + time-ago (right)
│   1/2 · Double Sofa   [star][grp][pin]   │  line 2: seats·types text + Material-icon indicator strip
```
(the `[star][grp][pin][note][go]` are Material icon glyphs, listed in the table
below — not emoji.)

**Line 1:** `passenger.displayName` (bold, single line, ellipsis) with the
time-ago pushed to the right.

**Line 2 (left):** `"{totalSeatsAssigned}/{seatBerths} · {types}"` when partially
assigned, else `"{seatBerths} · {types}"`, where `{types}` is the
`requestLines` labels joined with `+`. The seat-count text is **accent**
normally, **warm** when partially assigned. Single line, ellipsis.

**Line 2 (right): a compact indicator strip of Material icons (≈14px).**
STRICTLY Material `Icons.*` glyphs tinted with design tokens — **no emoji
characters anywhere**. Each icon appears only when the condition holds:

| Condition | Icon | Tint |
|---|---|---|
| `isPriorityApproved` | `Icons.star_rounded` | `c.warm` |
| `groupId != null` | `GroupDot(colorIndex, size: 8)` (shared seat-chart dot) | group color |
| `pickupLocationName` present | `Icons.place_outlined` | `c.ink3` |
| `note` present | `Icons.chat_bubble_outline_rounded` | `c.ink3` |
| `tripType.isOneWay` | `Icons.arrow_forward_rounded` (outbound) / `Icons.arrow_back_rounded` (return) | `c.warm` |

The full labelled chips (seats, types, one-way with city names, partial, pickup
`CODE · NAME`, group label, cancel-requested, assigned-seat chips) are NOT shown
collapsed — they render on expand.

**Attention edge:** a `cancel-requested` (`isCancelRequested`) row gets a 3px
**warm left edge** (`▎`) so a pending cancellation pops during a scan. (Other
rows have a transparent edge; the selection border reuses today's accent edge.)

## B. Tap → inline expand (single-open accordion)

Tapping a collapsed row expands it in place via `AnimatedSize`
(`UgamMotion.tab` / `easeOut`). `_expandedId` (`String?`) is tracked on the
parent `_RequestsScreenState` — so **only one row is open at a time**, it
survives the `Obx` list rebuilds, and opening another row collapses the previous
one. Tapping the open row collapses it.

The expanded region reveals, in order (this is today's card content):

1. tap-to-call phone (`PhoneDialer.call`) + full time — today's phone/time row.
2. the note quote box (full note text, capped `maxLines`) when a note exists.
3. the full chip `Wrap` — the exact chip set built today (seats, types, one-way
   with cities, partial, priority, group, pickup, cancel-requested, assigned
   seats).
4. the existing **`_CardActions`** row — primary CTA + secondary circle +
   overflow menu — **reused verbatim**, so every per-state action (confirm,
   confirm & seat, assign, waitlist, promote, back-to-new, group, priority,
   edit, notify, unassign, decline, approve/dismiss cancellation) stays exactly
   as it is today.

## C. Swipe actions (accelerator for the top 2 moves)

Reuse `UgamSwipeAction` (Dismissible-based, already in the codebase): right
swipe = one non-destructive action that snaps back; left swipe = destructive,
removes the row. Each row is wrapped with a `ValueKey(passenger.id)`.

| State | → Right (snaps back) | ← Left (removes row) |
|---|---|---|
| New / Waitlist | **Confirm & seat** (`_confirmAndSeat`) | **Decline** (`_confirmDecline` gates via `confirmDelete`) |
| Confirmed | **Assign seats** (`_openAssignment`) | **Decline** |
| Assigned | **Notify / WhatsApp** (`_sendAck`) | — (none) |
| any `isCancelRequested` | **Approve cancellation** (`_approveCancellation`) | — (none) |

Notes:
- Right-swipe fires the state's primary and snaps back. When that action moves
  the request to another tab (e.g. Confirm & seat), the reactive `Obx` rebuild
  simply drops it from the current filtered list — no `Dismissible` dismissal is
  claimed, so there's no "dismissed widget still in tree" risk.
- Left-swipe = Decline reuses the existing destructive confirm dialog as the
  `confirmDelete` gate; on confirm the row dismisses and `removePassenger` +
  WhatsApp cancellation fire (today's `_confirmDecline` behavior). The declined
  row legitimately leaves the filtered list, satisfying `Dismissible`.
- **Assigned** has no left swipe (decline isn't offered on assigned today — you
  unassign first). Unassign stays in the expanded overflow menu. This avoids
  mislabeling unassign as a red "delete" (the component's left pane is hardcoded
  danger-red).
- **Selection mode:** swipe and tap-to-expand are disabled while
  `_selectionMode` is active; long-press still enters selection and tap toggles
  the checkbox (today's behavior). The `UgamSwipeAction` wrapper is bypassed
  (plain child) in selection mode.

## D. Structure / code changes

- `requests_screen.dart` only. No new files (the file is already ~2400 lines and
  under active review; extraction is out of scope).
- Add `String? _expandedId` to `_RequestsScreenState`; pass `expanded` +
  `onToggleExpand` into the row; clear it on tour switch / filter change /
  entering selection.
- Rework `_RequestCard` into: collapsed two-line row → wrapped in
  `UgamSwipeAction` (only when not in selection mode) → with an `AnimatedSize`
  expanded region below. `_CardActions` and the chip-building logic are reused;
  the note box and phone row move into the expanded region.
- Indicator strip is a small private helper building the Material-icon row from
  the passenger flags above.

## E. Testing

Widget tests (`test/screens/seats_screen_test.dart` is the pattern reference;
add to a requests-screen test):

1. Collapsed row shows name and the `seats · types` summary; the note box and
   action buttons are NOT in the tree while collapsed.
2. Tapping a row expands it: the note text and `_CardActions` primary label
   become visible.
3. Only one row is expanded at a time (tapping a second collapses the first).
4. Indicator icons appear for the matching flags (e.g. priority → star icon).
5. In selection mode, the swipe wrapper is absent and tap toggles selection
   instead of expanding.

## Risks

- **Swipe discoverability:** mitigated because tap-expand exposes the identical
  full action set; swipe is only an accelerator.
- **Dismissible + reactive list:** decline path removes the row from the list so
  `Dismissible` is satisfied; right-swipe never claims a dismissal.
- **Localization / long text:** seats·types line and name both ellipsize; the
  Gujarati/Hindi labels already flow through `tr()` unchanged.
