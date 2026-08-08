# Tour Detail Cockpit Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild agent `TourDetailScreen` into the approved full-cockpit UI: collapsing tall hero, five tabs including Money, Overview vitals/tools/needs-attention, denser Travelers/Buses/Activity.

**Architecture:** Evolve `lib/screens/tour_detail_screen.dart` in place; extract focused widgets under `lib/widgets/tour_detail/` when a new section exceeds ~150 lines. Reuse `TourController`, `MoneyController`, `UgamCapacityMeter`, and existing deep-link screens. No new backend.

**Tech Stack:** Flutter, GetX, easy_localization, Ugam design system.

**Spec:** `docs/superpowers/specs/2026-08-08-tour-detail-cockpit-redesign.md`

## Global Constraints

- Agent tour detail only; do not redesign customer screens in this plan.
- Keep tall hero when `broadcastImageUrl` is set; compact path when absent.
- Hero collapses to sticky compact chrome on scroll.
- Five tabs: Overview · Travelers · Buses · Money · Activity (Activity index shifts 3→4).
- No hardcoded user-facing strings — add `en`/`gu`/`hi` keys.
- Graceful degrade if `MoneyController` is not registered.
- Prefer extracting widgets over growing the 2.5k-line screen further without structure.

---

### Task 1: i18n keys + tab bar includes Money

**Files:**
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json` (`tour_detail` section)
- Modify: `lib/screens/tour_detail_screen.dart` (`_TabBar`, `_buildTabBody`, sticky action indices)
- Test: `test/screens/tour_detail_cockpit_test.dart` (create)

**Produces:** `tab_money`, vitals/tools/needs_attention/filter keys; Money at index 3; Activity at 4.

- [ ] **Step 1:** Add translation keys for money tab, vitals labels, tools, needs attention, traveler/activity filters, seats-left chip.
- [ ] **Step 2:** Write failing test that TourDetail tab labels include Money and Activity is last.
- [ ] **Step 3:** Wire `_TabBar` to 5 items; update `_buildTabBody` / `_StickyAction` switch indices; placeholder Money tab.
- [ ] **Step 4:** Run test; commit.

### Task 2: Hero vital chip + Overview cockpit body

**Files:**
- Modify: `lib/screens/tour_detail_screen.dart` (`_HeroVitals`, `_OverviewTab`, replace `_ActionsGrid` usage)
- Create: `lib/widgets/tour_detail/tour_overview_vitals.dart`, `tour_overview_tools.dart`, `tour_needs_attention.dart` (as needed)
- Test: extend `tour_detail_cockpit_test.dart`

**Produces:** Hero chip shows seats remaining (or next vital) instead of misleading ₹0/seat; Overview = next-action → vitals → tools → needs-attention → broadcast.

- [ ] **Step 1:** Failing tests for chip label when `pendingSeatsToAssign > 0` and price is 0.
- [ ] **Step 2:** Implement vitals grid from tour + optional money.
- [ ] **Step 3:** Tools row (Money tab / Broadcast / More expander with previous secondary actions).
- [ ] **Step 4:** Needs-attention rows from unseated passengers + buses without drivers.
- [ ] **Step 5:** Remove duplicate flat Actions list from Overview default path.
- [ ] **Step 6:** Tests pass; commit.

### Task 3: Collapsing hero on scroll

**Files:**
- Modify: `lib/screens/tour_detail_screen.dart` scroll structure (`CustomScrollView` / `SliverAppBar`)
- Test: widget test that collapsed header appears after scroll (or unit test of collapse helper if widget scroll is flaky)

- [ ] **Step 1:** Implement flexible/collapsing hero preserving image + chrome + overhang summary card.
- [ ] **Step 2:** Collapsed state: title + status + photo chip + overflow.
- [ ] **Step 3:** Verify no-image compact path still works; commit.

### Task 4: Travelers search, filters, richer rows

**Files:**
- Modify: `_PassengersTab`, `_PassengerRow` in tour detail (or extract)
- Create: `lib/widgets/tour_detail/traveler_filters.dart` (pure filter helpers + UI)
- Test: unit tests for filter predicates

- [ ] **Step 1:** Pure functions: filter by query, needsSeat, moneyDue, SL/DL.
- [ ] **Step 2:** Wire search + chips UI; enrich row chips.
- [ ] **Step 3:** Tests; commit.

### Task 5: Buses occupancy + driver gaps

**Files:**
- Modify: `_BusesTab`, `_BusListItem`
- Reuse: `UgamCapacityMeter.bus` / occupancy helpers

- [ ] **Step 1:** Fleet summary strip.
- [ ] **Step 2:** Occupancy bar + driver warning + seat chart / set driver actions.
- [ ] **Step 3:** Tests or golden-free widget smoke; commit.

### Task 6: Money tab summary

**Files:**
- Create: `lib/widgets/tour_detail/tour_money_tab.dart`
- Modify: tab body case for Money
- Reuse: `MoneyController` summaries / ledger rollups patterns from `tour_money_board_screen.dart`

- [ ] **Step 1:** Summary card + per-bus rows + CTA to `TourMoneyBoardScreen`.
- [ ] **Step 2:** Empty/missing controller state.
- [ ] **Step 3:** Test navigation CTA; commit.

### Task 7: Activity filters

**Files:**
- Modify: `_ActivityTab`, `_buildEvents` tagging
- Test: filter unit tests

- [ ] **Step 1:** Tag events (seats/money/buses/system).
- [ ] **Step 2:** Filter chips UI.
- [ ] **Step 3:** Tests; commit.

### Task 8: Verification

- [ ] Run focused `flutter test` for tour detail / money / capacity related tests.
- [ ] Manual checklist against acceptance in the spec.
- [ ] Final commit if needed.

---

## File map

| Path | Role |
|---|---|
| `lib/screens/tour_detail_screen.dart` | Shell, tabs, sticky CTA, orchestration |
| `lib/widgets/tour_detail/*` | Extracted Overview/Money/filter pieces |
| `assets/translations/{en,gu,hi}.json` | Copy |
| `test/screens/tour_detail_cockpit_test.dart` | Cockpit regression tests |
| `test/widgets/tour_detail/*` | Pure filter / vitals helpers |
