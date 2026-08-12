# The Board — interaction design spec

**Status:** approved direction, pre-implementation
**Date:** 2026-08-12
**Supersedes:** the per-screen polish planned for `charts_screen` and `tour_seat_assignment_screen`

---

## 1. The idea in one paragraph

Eleven screens (~15,500 lines, over a third of all screen code) are the same object — **a bus, coloured by one attribute**. The Board replaces them with one canvas and a lens switcher. A lens is a colour function plus a three-item legend plus a default action; it is *not* a new screen. Tapping any berth opens one passenger sheet whose primary action changes by lens.

This document is the interaction design. The visual design is settled: one theme, one type family, one token ramp — no per-role variants.

---

## 2. Why the visual mockups are not enough

The mockups showed 4–5 berth rows. A real sleeper coach is **36–74 berths**, which is 12–18 rows. Everything hard about this design is a consequence of that number, and none of it is visible in a static panel. The sections below are the actual work.

---

## 3. Scale — fitting a coach on a 375px phone

**Two density modes, user-toggled, remembered per user.**

| Mode | Tile | Shows | Use |
|---|---|---|---|
| Compact | ~20pt | berth code + state glyph | whole bus visible, scanning |
| Comfortable | ~44pt | code + occupant name + glyph | working a section, tapping |

- Compact tiles fall below the 44pt touch minimum **by design** — in compact mode a tap targets the nearest berth with an expanded hit area, and the tile is for *reading*, not precision tapping. Comfortable mode is the working mode.
- Default to compact when berth count > 40, comfortable otherwise.
- **Reuse `lib/design/components/ugam_pinch_zoom.dart`** (41 lines, already exists) rather than writing new zoom.
- **Landscape is a first-class layout**, not an afterthought. A coach is long and narrow; rotated, the whole bus fits with names. Most operational apps ignore landscape — here it is the natural orientation for the chart.
- Vertical scroll keeps a **sticky summary strip** (counts / money total / boarded count, per lens) pinned at top. The number must never scroll away.

**Multi-bus tours:** horizontal page swipe between buses with a page indicator — a gesture, not a dropdown menu. Bus switching happens constantly and must cost nothing.

---

## 4. The single most important interaction: aisle-order advance

This is the idea that makes the Board a tool rather than a picture.

A handler collecting cash walks the aisle front to back. Today they read an alphabetical list and hunt. On the Board:

- A persistent **"આગળનું બાકી →" / "next outstanding"** control.
- Tapping it scrolls to the next berth in **aisle order** that matches the lens's "needs action" state, and opens its sheet.
- Completing the action (collect / check in) **auto-advances to the next one.**
- A running strip updates live: `₹12,400 એકઠી · ₹42,800 બાકી · 14 જણ`.

A 22-person collection round becomes 22 taps with zero navigation and nobody missed or asked twice. The same pattern serves the boarding lens ("next un-boarded") and the assignment lens ("next empty berth").

**Aisle order** = the physical walking order (row by row, left pair then right pair), *not* berth-code alphabetical. Derive it from the layout geometry.

---

## 5. Lenses

Each lens = colour function + 3-item legend + primary sheet action + summary strip metric.

| Lens | Colours by | Legend | Sheet primary | Strip |
|---|---|---|---|---|
| બેઠક Occupancy | occupied / ladies / empty | 3 | Call | `73/74 · 1 ખાલી` |
| પૈસા Money | paid / half / due | 3 | Collect | `₹55,200 બાકી · 32% એકઠી` |
| પિકઅપ Pickup | one tint per stop | ≤5 stops | Call | `18/22 અડાજણ` |
| ગ્રુપ Group | one tint per group | ≤5 groups | Move | `12 ગ્રુપ · 3 વિભાજિત` |
| બોર્ડિંગ Boarding | boarded / expected / no-show | 3 | Check in | `52/60 ચડ્યા` |

**Legend swatches are filters.** Tap "બાકી" and every other berth dims to 30%. This gives filtering for free, with no filter screen, and it is discoverable because the legend is already on screen. Tap again to clear.

**Pickup and Group lenses cap at 5 tints** and bucket the remainder as "other" — beyond five, colour stops being distinguishable. If a tour has 9 pickup stops, the lens shows the 5 largest and greys the rest, with the legend saying so.

---

## 6. Phase-driven default lens

`lib/models/handler_phase.dart` already models the trip lifecycle (`HandlerPhase`, `HandlerMilestone`). Use it — this is the payoff for work already done.

The Board opens on the lens that matters *right now*:

| Phase | Opens on | Because |
|---|---|---|
| planning / filling | Occupancy | you are placing people |
| pre-departure (T‑2d) | Money | you are chasing balances |
| departure day | Boarding | you are counting heads |
| in transit | Pickup | you are working stops |
| settling | Money | you are reconciling |

The user can always switch; this only sets the default. **Never override an explicit manual choice within the same session.**

---

## 7. Direct manipulation

- **Tap** berth → passenger sheet (or, if empty in assign mode, the assign picker).
- **Long-press** → multi-select mode. Tap N berths → bulk action bar. This is how a family of four gets assigned or moved together, and it is what `tour_groups_screen.dart` (1,014 lines) exists to do today.
- **Drag** an unassigned name from the bottom rail onto a berth to assign. Drag berth→berth to swap.
- **Drag threshold** before a drag starts, so scrolling the chart never accidentally moves a passenger. This is critical: the canvas both scrolls and drags.
- **Invalid drop** (occupied, blocked, wrong seat type, gender rule) → the berth flashes danger, a haptic warning fires, and the drag returns to origin with a reason in a snackbar. Never a silent failure.

---

## 8. Undo is mandatory

Assign, move, collect and check-in all mutate real operational state, often at speed, often by a tired person at 5am.

**Every Board mutation raises a snackbar with Undo.** `lib/design/components/ugam_snackbar.dart` currently has **no undo affordance** — it needs one before the Board ships. This is a blocking dependency, not a nice-to-have.

Money actions additionally require a confirm step, because they cannot be silently reversed downstream.

---

## 9. Offline

A handler on a highway between Surat and Dwarka has no signal, and boarding and collection are exactly when they need the app most.

- Board mutations **queue locally and sync when connectivity returns**. Build on `lib/services/sync_service.dart`.
- The summary strip shows a plain offline indicator with the pending-action count: `3 ક્રિયા બાકી · સિંક થશે`.
- **Never block a Board action on the network.** Optimistic local write, reconcile later.
- Conflict rule: server wins for money amounts, last-write-wins for seat assignment, and the handler is told when their change was overridden.

> **Open question for the team:** how complete is offline write support in `sync_service` today? If it is read-only caching, the offline story is a larger piece of work than the Board itself and should be scoped separately.

---

## 10. Search

Search **highlights, it does not navigate.** Type `રમેશ`, the matching berth pulses and scrolls into view, everything else dims. Clearing search restores. Searching a 74-berth chart by leaving it for a list screen is the exact pattern the Board exists to eliminate.

---

## 11. Accessibility

- **Colour is never the only signal.** Every tile carries a glyph as well as a fill: `✓` paid, `₹550` due, `½` half, `—` empty, `●` boarded.
- Every berth gets a full semantic label: *"DL3, Priti Patel, paid, double sofa, boarding at Adajan"* — not "DL3".
- The lens switcher uses proper tab semantics with selected state announced.
- Multi-select state is announced (`3 berths selected`).
- Respect `prefers-reduced-motion`: the pulse-on-search and auto-advance scroll become instant jumps.
- Dim-to-30% filtering must not be the only indication of filtering — the legend swatch also shows an active state.

---

## 12. Haptics as a feedback language

The app already has ~100 haptic call sites; formalise them for the Board so touch feedback is consistent:

| Event | Haptic |
|---|---|
| berth tap | `selectionClick` |
| drag pick-up | `mediumImpact` |
| valid drop / collect / check-in | `lightImpact` on success |
| invalid drop | double `heavyImpact` (the "no" pattern) |
| auto-advance to next | `selectionClick` |

---

## 13. Per-lens empty and zero states

Each lens needs its own honest state — the audit found empty states across this app that name a problem and offer no way out.

- **No layout at all** → "this bus has no seat plan yet" + a primary action that creates one.
- **Money lens, no pricing set** → "set fares to track collection" + action. Do not show ₹0 everywhere.
- **Boarding lens before departure day** → "boarding opens on 14 Aug" + a preview of expected headcount.
- **Pickup lens, no stops configured** → "add pickup points" + action.

Never render a legend for berths that do not exist.

---

## 14. What the Board does *not* absorb

Out of scope for the collapse; these get the unified theme only:

`requests`, `notify`, `finance` / `trip_pnl`, `tour_money_board`, all settings screens, and the entire customer booking funnel. They are not "the bus coloured by X".

---

## 15. Build order

1. **Board shell + occupancy lens**, routed in place of the current chart. Nothing deleted. ~6 new files.
2. **Stop-and-review gate** — used on a live tour before anything else proceeds.
3. Money lens + aisle-order advance + undo in `UgamSnackbar`.
4. Pickup, group, boarding lenses.
5. Retire the eleven screens, migrating remaining logic and redirecting routes.

The gate at step 2 is the point of the whole sequence: if the Board does not feel better in the hand, it has cost one screen instead of eleven.
