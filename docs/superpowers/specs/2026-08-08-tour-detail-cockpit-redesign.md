# Tour Detail Full Cockpit Redesign

**Date:** 2026-08-08  
**Status:** Approved (visual mockups v1–v2 + user confirmation)  
**Scope:** Agent `TourDetailScreen` only. Customer tour detail is a later phase.

## Problem

The agent tour detail screen wastes the first viewport on a marketing-style layout while operational work (seats, money, drivers, requests) is buried or duplicated. Overview repeats navigation already available as tabs. The hero price badge often shows `₹0 / seat`, which reads as broken data. Buses and Activity tabs are thin; Travelers lack search/filters and payment context.

## Goals

1. Keep the **tall hero + tour image** (immersive identity).
2. Rebuild everything under it as an **ops cockpit**: denser data + richer controls.
3. Make Overview a command center (next step → vitals → tools → blockers), not a second menu.
4. Add **Money** as a first-class tab.
5. Upgrade Travelers / Buses / Activity with filters, meters, and clearer status.
6. Reuse existing controllers and screens; no new backend APIs in this phase.

## Non-goals

- Customer `customer_tour_detail_screen` redesign (follow-up).
- New money ledger RPCs or schema changes.
- Replacing `TourMoneyBoardScreen` — Money tab is a summary that deep-links to the full board.
- Changing bottom app dock / global nav.

## Decisions locked

| Decision | Choice |
|---|---|
| Hero | Tall image hero kept |
| Scroll | Hero collapses to sticky compact bar (title + status + photo chip) |
| Depth | Full cockpit (data + interactions) |
| Overview IA | Hybrid: vitals + Tools row (Money / Broadcast / More) |
| Tabs | Overview · Travelers · Buses · Money · Activity |
| Scope | Agent only now |
| Hero card chip | Replace `₹0 / seat` with stage vital (e.g. seats remaining) |

## Design

### Shell

- `CustomScrollView` (or equivalent) with:
  - Collapsing hero (`SliverAppBar` / flexible space pattern) showing broadcast image when present; existing compact header when no image.
  - Sticky collapsed chrome: back, truncated title, status dot+label, photo chip, overflow menu.
  - Sticky tab pills under collapsed header.
- Sticky bottom stage CTA (existing `_StickyAction`) updated for 5-tab indices; Money tab may omit CTA or link “Open money board”.

### Overview

1. **Next-action card** (keep) — progress bar when seating; same `_runAction` as sticky CTA.
2. **Vitals grid** (2×2): seats remaining, money due, requests/seated, bus fill (capacity). Tap may switch tab or open deep link.
3. **Tools row** (3 tiles): Money (opens Money tab or board), Broadcast (existing WhatsApp flow), More (expandable: Groups, Lock/Notify, Edit tools currently under Actions).
4. **Needs attention** list — derived blockers (unseated travelers, buses without drivers, unpaid if available). Each row jumps to the fix surface.
5. Remove the flat duplicate Actions list (Requests/Seat/Money/More as equal rows). Requests/Seats remain reachable via tabs + next-action + More.

### Travelers

- Search field (name / phone).
- Filter chips: All · Needs seat · Money due · SL · DL (filters that can be computed locally).
- Rows: avatar, name, seat type + bus/seat when assigned, status chips (seated / needs seat, payment hint when MoneyController data exists).
- Sticky “Assign seats · N left” when `pendingSeatsToAssign > 0`.
- Keep Add traveler CTA.

### Buses

- Fleet summary strip: % filled, drivers set, AC/type summary.
- Per-bus card: name, AC badge, occupancy bar + `filled/capacity`, driver warning, actions (Seat chart, Set driver / open manage).
- Sticky or bottom primary: Add bus.

### Money (new tab)

- Tour-level summary: expected / collected / due / claims (from `MoneyController` / ledger rollups already used by money board).
- Per-bus rows with due + status.
- CTA: “Open full Money Board” → existing `TourMoneyBoardScreen`.
- If money data not hydrated, show skeleton / empty with refresh — no invented numbers.

### Activity

- Filter chips: All · Seats · Money · Buses (client-side filter on existing timeline events; extend event tags as needed).
- Keep vertical timeline; richer icons/colors by category.

## Data sources (existing)

- `TourController.getTour` / passengers / buses / `pendingSeatsToAssign` / capacity helpers.
- `MoneyController` for due/collected when registered; degrade gracefully if missing.
- `TourCapacity` / bus occupancy already used on bus list.
- WhatsApp broadcast helpers already on Overview.

## i18n

Add keys under `tour_detail.*` in `en.json` / `gu.json` / `hi.json` for new labels (vitals, tools, needs attention, money tab, filters). No hardcoded user-facing English in widgets.

## Testing

- Widget/unit tests for: tab count includes Money; vitals values from tour fixtures; traveler filter logic; hero chip shows seats remaining not zero price when price is 0 and seats pending; money tab navigates to board.
- Preserve existing tour detail / next-action tests; update indices where Activity moved from 3 → 4.

## Risks

- `tour_detail_screen.dart` is already ~2.5k lines — prefer extracting private widgets into `lib/widgets/tour_detail/` if the file grows further during this work.
- Collapsing hero must not break the no-image compact path.
- Money tab must not block Overview if `MoneyController` is unavailable.

## Acceptance

- [ ] Tall hero with image when URL present; collapses to compact sticky on scroll.
- [ ] Five tabs including Money.
- [ ] Overview shows next-action, vitals, tools, needs-attention (no duplicate Actions list).
- [ ] Hero chip is a real vital, not misleading ₹0/seat.
- [ ] Travelers searchable/filterable with richer status.
- [ ] Buses show occupancy meters and driver gaps.
- [ ] Money tab summarizes and opens full board.
- [ ] Activity filterable.
- [ ] Gujarati/Hindi/English strings present.
- [ ] Relevant tests pass.
