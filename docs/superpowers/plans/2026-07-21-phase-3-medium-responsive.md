# Phase 3 — Medium correctness + responsiveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Resolve the §6 cross-cutting themes from the 2026-07-21 audit — leg-share seat overcounts, money loading/refresh/staleness, one crash-state, tile text-scaling, attendance UX, per-seat leg partitioning, sync-layer hardening, and a handful of misc correctness/i18n/iOS items — so the app is theme-clean ahead of the dual-store release.

**Architecture:** Point fixes across existing GetX screens/controllers plus two small new shared units (a money loading skeleton widget and an attendance-tally value type). The leg-aware seat count reuses the already-shipped `Tour.occupiedBerthsFor`; money screens adopt the `isLoading && !loadedOnce → skeleton` + `RefreshIndicator(refreshForTour)` pattern that `finance_screen` already uses; sync hardening extracts two pure helpers (`syncIsRetryable`, `paginateRows`) so the classification and pagination loops become unit-testable without a live Supabase client.

**Tech Stack:** Flutter, GetX, Supabase, easy_localization, flutter_test.

## Global Constraints
- Money formatting always `formatMoneyInr` (₹, en_IN).
- Every user-facing string via `tr()`; keys in en/gu/hi in sync.
- Leg-aware seat counts via `tour.occupiedBerthsFor(busId)`.
- `isLoading && !loadedOnce` → skeleton; errors via `UgamEmpty.error`.
- Widget tests calling `plural()` must `Localization.load` a locale in `setUpAll`.

**Cross-phase notes (do NOT redo):**
- Phase 2 added handler pull-to-refresh/retry/offline/resume (H-2) but **no realtime**. In this plan a `MoneyController` realtime subscription is **OPTIONAL** (Task 5); the handler manifest realtime stays optional and is out of scope here — do not re-add handler pull-to-refresh.
- Phase 2 folded **AL-4** (create-tour return-before-departure) into its AL-1 date guard — **SKIP AL-4**; it is intentionally absent from this plan.
- Phase 2 converted `UgamInput` to a `TextFormField`. No task here touches inputs; be aware if you stray.
- Phase 1 introduced `HandlerManifest.handovers`, `HandlerBusMoney.outstandingHandover`, and the `passengers.billed_amount` snapshot. **None of Phase 3's tasks depend on them** — every fix below stands alone.

**Repo facts used throughout:**
- Package name (test imports): `occubusbooking` (e.g. `package:occubusbooking/models/tour.dart`).
- `UgamColors.of(context)` only reads `Theme.of(context).brightness`, so a bare `MaterialApp(theme: ThemeData(brightness: Brightness.dark))` is enough context for design-system widgets in tests.
- `MoneyController` (`lib/controllers/money_controller.dart`) exposes `isLoading`, `loadedOnce`, `loadFailed` (all `.obs`), `loadForTour(tourId)`, `refreshForTour(tourId)`, `summaryForBus(busId)`, `summariesForBuses(ids)`, `tourSummary()`, `loadedTourId`.
- Existing test harness patterns: `test/components/seat_chart_tile_phone_test.dart` (SeatChartTile pump), `test/models/tour_leg_occupancy_test.dart` (leg-shared tour construction).

---

## Theme A — Leg-shared seat overcounting (audit §6.3)

`charts_screen` (AS-1) and `bus_status_screen` (AS-2) fold raw `assignments.values` instead of the leg-aware `Tour.occupiedBerthsFor`, so a berth shared by an outbound-only + a return-only rider is counted twice and the fill can read past capacity ("40/37", "100%"). Migrate both call sites to the count the assignment screen already uses.

### Task 1: charts_screen fill count → `occupiedBerthsFor`

**Files:**
- Modify: `lib/screens/charts_screen.dart:191-196` (the `assignedCount` fold that feeds `_FillIndicator(assigned: assignedCount)` at `:220`).
- Test: `test/screens/charts_leg_count_test.dart` (new).

**Interfaces:**
- Consumes: `Tour.occupiedBerthsFor(String busId) → int` (already shipped, `lib/models/tour.dart:163`).
- Produces: nothing new; the on-screen `'$assigned/$total'` now shows the leg-aware berth count.

- [ ] **Step 1: Write the failing test** — lock the value the screen must display for a leg-shared bus.

Create `test/screens/charts_leg_count_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';

Passenger _p(String id, TripType trip, List<String> seats) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      tripType: trip,
      requestLines: [RequestLine(seatType: SeatType.seater, qty: seats.length, leg: trip)],
      assignedSeats: [for (final s in seats) SeatAssignment(busId: 'b1', seatId: s)],
    );

void main() {
  test('charts fill uses the leg-aware count, never the raw entry fold', () {
    final bus = Bus(
      id: 'b1',
      name: 'Shivay',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 4),
    );
    final tour = Tour(
      id: 't1', title: 't', fromCity: 'A', toCity: 'B',
      departureDate: DateTime(2026, 7, 1), pricePerSeat: 1,
      buses: [bus],
      passengers: [
        _p('p1', TripType.roundTrip, ['S1']),
        _p('p2', TripType.roundTrip, ['S2']),
        _p('p3', TripType.outboundOnly, ['S3']),
        _p('p4', TripType.returnOnly, ['S3']), // shares S3 on the opposite leg
      ],
    );

    // OLD (buggy) fold the screen used: raw assignment entries per bus = 4.
    final rawFold = tour.passengers
        .expand((p) => p.assignedSeats)
        .where((a) => a.busId == 'b1')
        .length;
    expect(rawFold, 4);

    // NEW: the leg-aware berth count is 3 (busier leg), <= capacity.
    expect(tour.occupiedBerthsFor('b1'), 3);
    expect(tour.occupiedBerthsFor('b1'), lessThan(rawFold));
    expect(tour.occupiedBerthsFor('b1'), lessThanOrEqualTo(bus.totalSeats));
  });
}
```

- [ ] **Step 2: Run test to verify it passes for the model but documents the fold gap**

Run: `flutter test test/screens/charts_leg_count_test.dart -v`
Expected: PASS (this test pins the invariant; the screen swap below wires the display to it).

- [ ] **Step 3: Swap the call site** — in `lib/screens/charts_screen.dart`, replace the fold at `:192-196`:

```dart
          final totalSeats = layout?.totalSeats ?? 0;
          final assignedCount = tour.occupiedBerthsFor(bus.id);
```

(Delete the old `final assignedCount = assignments.values.fold<int>(0, (sum, list) => sum + list.length);`. `assignments` is still used to feed the tiles, so keep it; only the count derivation changes.)

- [ ] **Step 4: Run the analyzer + the file's tests**

Run: `flutter analyze lib/screens/charts_screen.dart` then `flutter test test/screens/charts_leg_count_test.dart`
Expected: no new analyzer issues; test PASS.

- [ ] **Step 5: Manual verification** — build a tour with one outbound-only + one return-only rider sharing a berth; open Charts. The bus fill reads the leg-aware value (e.g. `3/4`, never `4/4` while a berth is empty).

- [ ] **Step 6: Commit**

```bash
git add lib/screens/charts_screen.dart test/screens/charts_leg_count_test.dart
git commit -m "fix(charts): AS-1 leg-aware fill count via occupiedBerthsFor"
```

### Task 2: bus_status_screen tally + ratio → `occupiedBerthsFor`

**Files:**
- Modify: `lib/screens/bus_status_screen.dart:98-101` (the `assignedCount` fold feeding `_Tally(assigned: assignedCount)` at `:126`, which computes `ratio` at `:392` and `'${(ratio*100).round()}%'` at `:425`).
- Test: `test/screens/bus_status_leg_count_test.dart` (new).

**Interfaces:**
- Consumes: `Tour.occupiedBerthsFor(String busId) → int`.

- [ ] **Step 1: Write the failing test**

Create `test/screens/bus_status_leg_count_test.dart` — identical scaffold to Task 1's test (copy the `_p` builder and tour construction verbatim), with the assertions:

```dart
  test('bus-status tally uses the leg-aware count so the ratio never exceeds 100%', () {
    // ...build the same 4-berth leg-shared tour as charts_leg_count_test...
    final assigned = tour.occupiedBerthsFor('b1');
    final total = bus.totalSeats;
    expect(assigned, 3);
    expect(assigned / total, lessThanOrEqualTo(1.0)); // was 4/4 = 100% before
  });
```

- [ ] **Step 2: Run test**

Run: `flutter test test/screens/bus_status_leg_count_test.dart -v`
Expected: PASS.

- [ ] **Step 3: Swap the call site** — in `lib/screens/bus_status_screen.dart`, replace `:97-101`:

```dart
          final totalSeats = layout.totalSeats;
          final assignedCount = tour.occupiedBerthsFor(bus.id);
```

(Keep the `assignments` map above it — it still feeds the grid; only the count derivation changes.)

- [ ] **Step 4: Run analyzer + test**

Run: `flutter analyze lib/screens/bus_status_screen.dart` then `flutter test test/screens/bus_status_leg_count_test.dart`
Expected: clean; PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/bus_status_screen.dart test/screens/bus_status_leg_count_test.dart
git commit -m "fix(bus-status): AS-2 leg-aware tally + ratio via occupiedBerthsFor"
```

---

## Theme B — Money display correctness

### Task 3: CALC-2 — `formatMoneyInr` sign after rounding

**Files:**
- Modify: `lib/utils/formatters.dart:22-26`.
- Test: `test/utils/formatters_money_sign_test.dart` (new).

**Problem:** the sign is taken from `amount < 0` but the magnitude is `amount.round().abs()`; tiny negative dust (e.g. `-0.004`) renders `-₹0`. Derive the sign from the rounded value.

**Interfaces:**
- Produces: `Formatters.formatMoneyInr(num) → String` (same signature; `-₹0` no longer possible).

- [ ] **Step 1: Write the failing test**

Create `test/utils/formatters_money_sign_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/formatters.dart';

void main() {
  test('negative dust that rounds to zero shows ₹0, not -₹0', () {
    expect(Formatters.formatMoneyInr(-0.004), '₹0');
    expect(Formatters.formatMoneyInr(-0.49), '₹0');
    expect(Formatters.formatMoneyInr(0), '₹0');
  });

  test('real negatives keep the minus after rounding', () {
    expect(Formatters.formatMoneyInr(-1), '-₹1');
    expect(Formatters.formatMoneyInr(-0.5), '-₹1'); // rounds to -1
    expect(Formatters.formatMoneyInr(-123456), '-₹1,23,456');
  });

  test('positives unchanged', () {
    expect(Formatters.formatMoneyInr(123456), '₹1,23,456');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/utils/formatters_money_sign_test.dart -v`
Expected: FAIL — `formatMoneyInr(-0.004)` returns `-₹0`.

- [ ] **Step 3: Fix the formatter** — in `lib/utils/formatters.dart`, replace `:22-26`:

```dart
  static String formatMoneyInr(num amount) {
    final rounded = amount.round();
    final n = NumberFormat.decimalPattern('en_IN').format(rounded.abs());
    final sign = rounded < 0 ? '-' : '';
    return '$sign₹$n';
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/utils/formatters_money_sign_test.dart -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/utils/formatters.dart test/utils/formatters_money_sign_test.dart
git commit -m "fix(money): CALC-2 derive formatMoneyInr sign after rounding"
```

---

## Theme C — Loading state, refresh, and snapshot-vs-live on money screens (audit §6.1, §6.2, §6.6)

The four money screens (`bus_money`, `collection`, `tour_money_board`, `trip_pnl`) render before the first fetch resolves (all-₹0 "settled" flash), have no pull-to-refresh, and two of them read a stale constructor `Tour`/`Bus` snapshot. `finance_screen` already does all three correctly — mirror it.

### Task 4: AM-2 — shared money loading skeleton + first-load gate on all four screens

**Files:**
- Create: `lib/widgets/money_loading_skeleton.dart`.
- Modify: `lib/screens/bus_money_screen.dart` (Obx at `:69`), `lib/screens/collection_screen.dart` (Obx at `:125`), `lib/screens/tour_money_board_screen.dart` (Obx at `:102`), `lib/screens/trip_pnl_screen.dart` (Obx at `:84`).
- Test: `test/widgets/money_loading_skeleton_test.dart` (new).

**Interfaces:**
- Produces: `class MoneyLoadingSkeleton extends StatelessWidget` with a `const MoneyLoadingSkeleton({super.key})` constructor — a `ListView` of `UgamSkeleton` blocks. Consumed by Tasks 4 (gate) on all four screens.

- [ ] **Step 1: Write the failing test**

Create `test/widgets/money_loading_skeleton_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/widgets/money_loading_skeleton.dart';
import 'package:occubusbooking/design/components/ugam_skeleton.dart';

void main() {
  testWidgets('renders shimmer blocks with no overflow', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MoneyLoadingSkeleton()),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(UgamSkeleton), findsWidgets);
  });
}
```

(If `ugam_skeleton.dart` is not the correct import path for `UgamSkeleton`, resolve it with `grep -rn "class UgamSkeleton" lib/` before writing — it is exported from the design barrel `lib/design/ugam.dart` used by the money screens.)

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/money_loading_skeleton_test.dart -v`
Expected: FAIL — `MoneyLoadingSkeleton` does not exist.

- [ ] **Step 3: Create the widget** — `lib/widgets/money_loading_skeleton.dart`:

```dart
import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// Shared first-load placeholder for the money screens (bus money, collection,
/// tour money board, trip P&L). Shown while `isLoading && !loadedOnce` so the
/// board never flashes an all-₹0 "settled" state before the first fetch lands.
/// Mirrors `finance_screen`'s `_Loading` shape (hero + stat row + rows).
class MoneyLoadingSkeleton extends StatelessWidget {
  const MoneyLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      children: const [
        UgamSkeleton(height: 184, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
            SizedBox(width: UgamSpacing.md),
            Expanded(child: UgamSkeleton(height: 84, radius: UgamRadius.stat)),
          ],
        ),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/widgets/money_loading_skeleton_test.dart -v`
Expected: PASS.

- [ ] **Step 5: Gate `bus_money_screen`** — in `lib/screens/bus_money_screen.dart`, add `import '../widgets/money_loading_skeleton.dart';`, then as the FIRST line inside the Obx at `:69` (before the `_showLoadError` check):

```dart
              child: Obx(() {
                if (controller.isLoading.value && !controller.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
                // A failed load leaves the money lists empty; show the shared
                // retry rather than a ₹0 cockpit that reads as a settled bus.
                if (_showLoadError) {
```

- [ ] **Step 6: Gate `collection_screen`** — same import; first line inside the Obx at `:125` (before `_showLoadError`):

```dart
              child: Obx(() {
                if (controller.isLoading.value && !controller.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
```

- [ ] **Step 7: Gate `tour_money_board_screen`** — same import; inside the Obx at `:102`, right after the `tour == null` guard and before `_showLoadError`:

```dart
                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
```

- [ ] **Step 8: Gate `trip_pnl_screen`** — same import; inside the Obx at `:84`, right after the `tour == null` guard (before the `buses.isEmpty` / `_showLoadError` checks):

```dart
                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
```

- [ ] **Step 9: Analyze the four screens**

Run: `flutter analyze lib/screens/bus_money_screen.dart lib/screens/collection_screen.dart lib/screens/tour_money_board_screen.dart lib/screens/trip_pnl_screen.dart`
Expected: no new issues.

- [ ] **Step 10: Commit**

```bash
git add lib/widgets/money_loading_skeleton.dart lib/screens/bus_money_screen.dart lib/screens/collection_screen.dart lib/screens/tour_money_board_screen.dart lib/screens/trip_pnl_screen.dart test/widgets/money_loading_skeleton_test.dart
git commit -m "feat(money): AM-2 first-load skeleton on the four money screens"
```

### Task 5: AM-3 — pull-to-refresh (`refreshForTour`) on all four money screens

**Files:**
- Modify: `lib/screens/bus_money_screen.dart` (the `ListView` at `:92`), `lib/screens/collection_screen.dart` (the roster `ListView.separated` at `:182`), `lib/screens/tour_money_board_screen.dart` (`ListView` at `:135`), `lib/screens/trip_pnl_screen.dart` (`ListView` at `:116`).

**Interfaces:**
- Consumes: `MoneyController.refreshForTour(String tourId)` (invalidates cache keys then reloads).

**Note (optional realtime):** the audit lists realtime *or* pull-to-refresh; Phase 2 shipped no realtime. Pull-to-refresh is the required deliverable. A `MoneyController` realtime subscription is an OPTIONAL follow-up — if added later, subscribe to the four money tables filtered by `tour_id` and call `refreshForTour` on change; it is NOT part of this task's exit criteria.

- [ ] **Step 1: `bus_money_screen`** — wrap the `ListView` inside the `Stack` at `:92` with a `RefreshIndicator`:

```dart
                return Stack(
                  children: [
                    RefreshIndicator(
                      onRefresh: () => controller.refreshForTour(widget.tour.id),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.lg,
                          UgamSpacing.gutter,
                          UgamSpacing.dockClearance,
                        ),
                        children: [
                          // ...existing children unchanged...
                        ],
                      ),
                    ),
                    // ...rest of the Stack unchanged...
                  ],
                );
```

(Add `physics: const AlwaysScrollableScrollPhysics()` so the pull works even when the list is short.)

- [ ] **Step 2: `collection_screen`** — the roster is the `Expanded → ListView.separated` at `:182`. Wrap that `ListView.separated` with `RefreshIndicator(onRefresh: () => controller.refreshForTour(widget.tour.id), child: ...)` and add `physics: const AlwaysScrollableScrollPhysics()` to it. (Leave the empty-state `UgamEmpty` branch as-is; the pinned summary/pills above stay outside the indicator.)

- [ ] **Step 3: `tour_money_board_screen`** — wrap the `ListView` at `:135`:

```dart
                return RefreshIndicator(
                  onRefresh: () => _money.refreshForTour(widget.tourId),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    // ...existing padding + children unchanged...
                  ),
                );
```

- [ ] **Step 4: `trip_pnl_screen`** — wrap the `ListView` at `:116` identically, `onRefresh: () => _money.refreshForTour(widget.tourId)`, `physics: const AlwaysScrollableScrollPhysics()`.

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/screens/bus_money_screen.dart lib/screens/collection_screen.dart lib/screens/tour_money_board_screen.dart lib/screens/trip_pnl_screen.dart`
Expected: no new issues.

- [ ] **Step 6: Manual verification** — open each money screen, pull down: the indicator spins and the rows re-fetch. Record a collection on a second device; pull-to-refresh on the first surfaces it.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/bus_money_screen.dart lib/screens/collection_screen.dart lib/screens/tour_money_board_screen.dart lib/screens/trip_pnl_screen.dart
git commit -m "feat(money): AM-3 pull-to-refresh (refreshForTour) on money screens"
```

### Task 6: AM-4 — resolve tour/bus from `TourController.getTour` inside the Obx

**Files:**
- Modify: `lib/screens/collection_screen.dart` (the `_seatLines` getter at `:72-97` and the build at `:112+`), `lib/screens/bus_money_screen.dart` (the Obx at `:69`).

**Problem:** both screens hold a constructor `widget.tour` / `widget.bus` snapshot. After a mid-session roster change the header total (computed by `MoneyController` from the live tour) disagrees with the rows built from the stale snapshot. Resolve the live tour/bus inside the Obx.

**Interfaces:**
- Consumes: `TourController.getTour(String id) → Tour?` (`lib/controllers/tour_controller.dart:635`).

- [ ] **Step 1: `collection_screen` — add a TourController accessor.** Near the other `Get.find` usages at the top of the State class, add:

```dart
  TourController get _tours => Get.find<TourController>();
```

(Ensure `import '../controllers/tour_controller.dart';` and `import '../models/bus_details.dart';` / `import '../models/tour.dart';` are present.)

- [ ] **Step 2: Convert `_seatLines` from a getter to a method** taking the live tour/bus — replace `:72-97`:

```dart
  List<_SeatCollectionLine> _seatLinesFor(Tour tour, Bus bus) {
    final lines = <_SeatCollectionLine>[];
    for (final p in tour.passengers) {
      final seatIds = p.assignedSeats
          .where((a) => a.busId == bus.id)
          .map((a) => a.seatId)
          .toSet();
      for (final seatId in seatIds) {
        final due = bus.amountDueForSeat(p, seatId);
        lines.add(
          _SeatCollectionLine(
            passenger: p,
            seatId: seatId,
            due: due,
            col: controller.collectionFor(p.id, bus.id, seatId),
          ),
        );
      }
    }
    lines.sort((a, b) => a.seatId.compareTo(b.seatId));
    return lines;
  }
```

- [ ] **Step 3: Resolve live tour/bus in build** — inside the Obx at `:125`, after the skeleton (Task 4) and `_showLoadError` guards, before `final s = ...`:

```dart
                final tour = _tours.getTour(widget.tour.id) ?? widget.tour;
                Bus liveBus = widget.bus;
                for (final b in tour.buses) {
                  if (b.id == widget.bus.id) { liveBus = b; break; }
                }
                final s = controller.summaryForBus(liveBus.id);
                final lines = _seatLinesFor(tour, liveBus).where(_passesFilter).toList();
```

(Replace the old `final s = controller.summaryForBus(widget.bus.id);` and `final lines = _seatLines.where(...)`.)

- [ ] **Step 4: `bus_money_screen` — add the accessor and resolve.** Add `TourController get _tours => Get.find<TourController>();` (with the same imports), then inside the Obx at `:69`, after the skeleton/error guards and before `final s = controller.summaryForBus(widget.bus.id);`:

```dart
                final tour = _tours.getTour(widget.tour.id) ?? widget.tour;
                Bus liveBus = widget.bus;
                for (final b in tour.buses) {
                  if (b.id == widget.bus.id) { liveBus = b; break; }
                }
                final s = controller.summaryForBus(liveBus.id);
                final expenses = controller.expenses.where((e) => e.busId == liveBus.id).toList();
                final handovers = controller.handovers.where((h) => h.busId == liveBus.id).toList();
                final incomes = controller.incomes.where((i) => i.busId == liveBus.id).toList();
```

(Replace the four `widget.bus.id` references at `:78-87`. The app-bar title's `widget.bus.name` can stay — the bus name rarely changes and the app bar is outside the Obx.)

- [ ] **Step 5: Analyze**

Run: `flutter analyze lib/screens/collection_screen.dart lib/screens/bus_money_screen.dart`
Expected: no new issues.

- [ ] **Step 6: Manual verification** — open Collection for a bus, reassign a passenger onto that bus from another screen, return: the header total and the visible row sum agree (no snapshot drift).

- [ ] **Step 7: Commit**

```bash
git add lib/screens/collection_screen.dart lib/screens/bus_money_screen.dart
git commit -m "fix(money): AM-4 resolve live tour/bus from getTour inside Obx"
```

---

## Theme D — Crash / stuck-state

### Task 7: AS-3 — past-tour seat history never gets stuck on the skeleton

**Files:**
- Modify: `lib/screens/past_tour_seat_history_screen.dart:61-68` (the `_load` method) and the `_body` at `:99-114`.
- Test: `test/screens/past_tour_seat_history_load_test.dart` (new).

**Problem:** `_load` has no try/catch; `_loading` is only cleared on success, so a thrown snapshot load leaves the screen shimmering forever. Add try/catch/finally; on failure fall back to the existing live-chart/empty path (already handled by `_body` when `_snapshots` is empty).

**Interfaces:**
- The state already flows to a graceful fallback: with `_loading == false` and `_snapshots == []`, `_body` renders `_fallbackLiveChart` (tour present) or `_empty` (tour null). So the only fix is to guarantee `_loading` is cleared.

- [ ] **Step 1: Write the failing test** — a `TourController` test double whose `loadSeatSnapshots` throws; assert the screen leaves the loading state and shows the fallback rather than shimmering.

Create `test/screens/past_tour_seat_history_load_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/components/ugam_skeleton.dart';
import 'package:occubusbooking/models/tour_seat_snapshot.dart';
import 'package:occubusbooking/screens/past_tour_seat_history_screen.dart';

class _ThrowingTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async {
    throw StateError('snapshot load boom');
  }
}

void main() {
  testWidgets('a thrown snapshot load clears the skeleton (no infinite shimmer)', (tester) async {
    Get.put<TourController>(_ThrowingTourController());
    addTearDown(Get.reset);

    await tester.pumpWidget(const GetMaterialApp(
      home: PastTourSeatHistoryScreen(tourId: 'unknown'),
    ));
    await tester.pumpAndSettle();

    // Before the fix: _loading stays true forever → skeletons remain on screen.
    expect(find.byType(UgamSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
```

(Confirm the snapshot model import path with `grep -rn "class TourSeatSnapshot" lib/` and the loading-skeleton widget name used by `_loadingSkeleton()` — adjust the `findsNothing` target to whatever `_loadingSkeleton` renders, e.g. `UgamSkeleton`, if different.)

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/past_tour_seat_history_load_test.dart -v`
Expected: FAIL — skeleton still present / uncaught exception.

- [ ] **Step 3: Harden `_load`** — replace `:61-68`:

```dart
  Future<void> _load() async {
    try {
      final snaps = await _ctrl.loadSeatSnapshots(widget.tourId);
      if (!mounted) return;
      setState(() => _snapshots = snaps);
    } catch (e, st) {
      dev.log('past-tour snapshot load failed: $e\n$st', name: 'PastTourSeatHistory');
      // Fall through to the live/empty fallback in _body with an empty list.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
```

(Add `import 'dart:developer' as dev;` at the top if not already present.)

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/screens/past_tour_seat_history_load_test.dart -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/past_tour_seat_history_screen.dart test/screens/past_tour_seat_history_load_test.dart
git commit -m "fix(seat-history): AS-3 try/catch/finally so a failed load falls back"
```

---

## Theme E — Fixed-size chrome vs OS text scaling (audit §6.5)

### Task 8: AS-4 — clamp effective text scale inside the seat tile

**Files:**
- Modify: `lib/widgets/seat_occupant_label.dart` (add the shared clamp constant near `:21-37`), `lib/components/seat_chart_tile.dart` (`build` at `:238`).
- Test: `test/components/seat_chart_tile_textscale_test.dart` (new).

**Problem:** the tile is a fixed 68×74 box; at large OS accessibility text scale the name/phone (fixed 13 / 9.5 px) clip/overflow. Clamp the effective `textScaler` for everything inside the tile so large-text users get a bounded, readable tile instead of an overflow.

**Interfaces:**
- Produces: `const double kSeatTileMaxTextScale = 1.15;` in `lib/widgets/seat_occupant_label.dart` (defined there to avoid a circular import — `seat_chart_tile.dart` already imports `seat_occupant_label.dart`). Consumed by `seat_chart_tile.dart`.

- [ ] **Step 1: Write the failing test** — a booked tile with a long name at OS scale 3.0 must not overflow.

Create `test/components/seat_chart_tile_textscale_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

Passenger _p() => Passenger(
      id: 'a', tourId: 't1',
      name: 'Venkataraman Subramaniam',
      phone: '+919876543210',
      tripType: TripType.roundTrip,
    );

SeatCell _seat() => const SeatCell(
      row: 0, col: 0, seatType: SeatType.seater, position: null, seatId: 'A1',
    );

void main() {
  testWidgets('seat tile does not overflow at OS text scale 3.0', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3.0)),
          child: Scaffold(
            body: Center(
              child: SeatChartTile(
                cell: _seat(),
                occupants: [_p()],
                groupColors: const GroupColorResolver(<String, int>{}),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull); // overflow throws in tests
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/components/seat_chart_tile_textscale_test.dart -v`
Expected: FAIL — a RenderFlex/overflow exception at ×3 text.

- [ ] **Step 3: Add the clamp constant** — in `lib/widgets/seat_occupant_label.dart`, above the class (near `:14`):

```dart
/// The seat tile is a FIXED 68×74 box (see [kSeatTileW]/[kSeatTileH]); OS
/// accessibility text scaling above this factor clips the name/phone. Every
/// seat chart clamps its effective text scale to this ceiling. Scales BELOW
/// 1.0 are untouched — the grid's scale-down handles small phones.
const double kSeatTileMaxTextScale = 1.15;
```

- [ ] **Step 4: Clamp the tile** — in `lib/components/seat_chart_tile.dart`, rename the current `build` body and wrap it. Change the method at `:238`:

```dart
  @override
  Widget build(BuildContext context) {
    // Bound the effective text scale so a fixed-size tile never clips its
    // name/phone under large OS accessibility settings (AS-4).
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kSeatTileMaxTextScale,
      child: Builder(builder: _buildTile),
    );
  }

  Widget _buildTile(BuildContext context) {
    final c = UgamColors.of(context);
    // ...the ENTIRE existing build body (the `if (anonymous) {...}` block through
    // the final return) moves here verbatim, unchanged...
```

(`kSeatTileMaxTextScale` is visible because `seat_chart_tile.dart` already imports `../widgets/seat_occupant_label.dart` at `:11`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/components/seat_chart_tile_textscale_test.dart -v`
Expected: PASS.

- [ ] **Step 6: Regression — the existing tile tests still pass**

Run: `flutter test test/components/seat_chart_tile_phone_test.dart test/components/seat_chart_tile_test.dart`
Expected: PASS (clamp is a no-op at the default scale 1.0 those tests use).

- [ ] **Step 7: Commit**

```bash
git add lib/widgets/seat_occupant_label.dart lib/components/seat_chart_tile.dart test/components/seat_chart_tile_textscale_test.dart
git commit -m "fix(seat-tile): AS-4 clamp effective text scale to keep fixed tiles legible"
```

### Task 9: H-4 — cap the grid down-scale and scroll horizontally beyond the floor

**Files:**
- Modify: `lib/components/combined_seat_grid.dart:165-176` (the bare `FittedBox`) plus a small natural-width helper.
- Test: `test/components/combined_seat_grid_scroll_test.dart` (new).

**Problem:** the whole grid is `FittedBox(scaleDown)`, so a wide coach on a narrow phone shrinks seat text below its "fixed" size with no floor and no scroll fallback. Cap the down-scale at a floor; beyond that, scroll horizontally.

**Interfaces:**
- Consumes: `layout.cellAt(row, col)`, `layout.balconyPair(row)`, `SeatGridCols`, and the instance fields `cellWidth`, `colGap`.

- [ ] **Step 1: Write the failing test** — a wide layout in a narrow viewport must not overflow and must expose a horizontal `Scrollable`.

Create `test/components/combined_seat_grid_scroll_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/combined_seat_grid.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/bus_type.dart';

void main() {
  testWidgets('wide grid in a narrow viewport scrolls horizontally without overflow', (tester) async {
    final layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 40);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 180, // deliberately narrower than the grid's floor width
            child: CombinedSeatGrid(
              layout: layout,
              showDriver: false,
              tileBuilder: (context, cell) => const SizedBox(
                width: kSeatTileW, height: kSeatTileH,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final horizontal = find.byWidgetPredicate((w) =>
        w is Scrollable && w.axisDirection == AxisDirection.right);
    expect(horizontal, findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/components/combined_seat_grid_scroll_test.dart -v`
Expected: FAIL — no horizontal `Scrollable` (the current code is a plain `FittedBox`).

- [ ] **Step 3: Add a natural-width helper** — in `lib/components/combined_seat_grid.dart`, near `_usedLaneCols`:

```dart
  /// The widest row's natural width at scale 1.0 — max slot count across rows ×
  /// [cellWidth] plus the inter-slot [colGap]s. Drives the down-scale floor.
  double _naturalWidth(Set<int> usedCols, bool showAisle, List<int> rows) {
    var maxSlots = 0;
    for (final row in rows) {
      final pair = layout.balconyPair(row);
      int n;
      if (pair.upper.hasSeat || pair.lower.hasSeat) {
        n = 0;
        if (layout.cellAt(row, SeatGridCols.singleUpper).hasSeat) n++;
        if (layout.cellAt(row, SeatGridCols.singleLower).hasSeat) n++;
        if (pair.upper.hasSeat) n++;
        if (pair.lower.hasSeat) n++;
        if (layout.cellAt(row, SeatGridCols.doubleLower).hasSeat) n++;
        if (layout.cellAt(row, SeatGridCols.doubleUpper).hasSeat) n++;
      } else {
        n = 0;
        if (usedCols.contains(SeatGridCols.singleUpper)) n++;
        if (usedCols.contains(SeatGridCols.singleLower)) n++;
        if (showAisle) n++;
        if (usedCols.contains(SeatGridCols.doubleLower)) n++;
        if (usedCols.contains(SeatGridCols.doubleUpper)) n++;
      }
      if (n > maxSlots) maxSlots = n;
    }
    if (maxSlots == 0) return 0;
    return maxSlots * cellWidth + (maxSlots - 1) * colGap;
  }
```

- [ ] **Step 4: Replace the `FittedBox`** at `:165-176` with a `LayoutBuilder` that scales to a floor, then scrolls:

```dart
        LayoutBuilder(
          builder: (context, constraints) {
            final grid = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < rowsWithSeats.length; i++) ...[
                  _row(context, rowsWithSeats[i], usedCols, hasLeft, hasRight),
                  if (i < rowsWithSeats.length - 1) SizedBox(height: rowGap),
                ],
              ],
            );
            final showAisle = hasLeft && hasRight;
            final natural = _naturalWidth(usedCols, showAisle, rowsWithSeats);
            final avail = constraints.maxWidth;
            const minScale = 0.72; // don't shrink seat text below this
            if (natural <= 0 || avail.isInfinite || natural * minScale <= avail) {
              // Fits at natural size or within the shrink floor → scale to fit.
              return FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: grid,
              );
            }
            // Wider than the floor even shrunk → scale to the floor, then scroll.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SizedBox(
                width: natural * minScale,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: grid,
                ),
              ),
            );
          },
        ),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/components/combined_seat_grid_scroll_test.dart -v`
Expected: PASS.

- [ ] **Step 6: Regression + manual**

Run: `flutter test test/components/combined_seat_grid_test.dart`
Expected: PASS. Manual: open a 40+ seat sleeper on a small phone (360dp) at 1.0 and at 2.0 text scale — seats shrink to the floor then scroll horizontally; nothing overflows.

- [ ] **Step 7: Commit**

```bash
git add lib/components/combined_seat_grid.dart test/components/combined_seat_grid_scroll_test.dart
git commit -m "fix(seat-grid): H-4 cap down-scale + horizontal-scroll fallback"
```

---

## Theme F — Attendance UX (audit §6.7)

The attendance board opens showing every not-yet-marked rider as "left behind" (H-5), the toggle waits on the server round-trip (H-6), and the seat-id chip can overflow the row (H-7).

### Task 10: H-5 — an explicit "unmarked" state so the board doesn't read "40 left behind"

**Files:**
- Create: `lib/utils/attendance_tally.dart`.
- Modify: `lib/screens/handler_bus_chart_screen.dart` — the `_AttendanceEntry` at `:1606-1613`, its construction at `:833-839`, and the `_AttendanceView.build` tally at `:2949-3007`; add three localization keys.
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json`.
- Test: `test/utils/attendance_tally_test.dart` (new).

**Interfaces:**
- Produces: `enum AttendanceMark { unmarked, present, left }` and `class AttendanceTally { final int present, left, unmarked; int get total; factory AttendanceTally.from(Iterable<AttendanceMark>); }` in `lib/utils/attendance_tally.dart`.

- [ ] **Step 1: Write the failing test**

Create `test/utils/attendance_tally_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/attendance_tally.dart';

void main() {
  test('unmarked riders are NOT counted as left-behind', () {
    final t = AttendanceTally.from([
      AttendanceMark.present,
      AttendanceMark.present,
      AttendanceMark.left,
      AttendanceMark.unmarked,
      AttendanceMark.unmarked,
    ]);
    expect(t.present, 2);
    expect(t.left, 1);        // only the explicit left-behind
    expect(t.unmarked, 2);
    expect(t.total, 5);
  });

  test('a fresh board (all unmarked) reads zero left-behind', () {
    final t = AttendanceTally.from(List.filled(40, AttendanceMark.unmarked));
    expect(t.left, 0);
    expect(t.unmarked, 40);
    expect(t.present, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/utils/attendance_tally_test.dart -v`
Expected: FAIL — `attendance_tally.dart` does not exist.

- [ ] **Step 3: Create the value type** — `lib/utils/attendance_tally.dart`:

```dart
/// Tri-state boarding mark for one passenger on one leg. `unmarked` is the
/// pre-decision state (no attendance row yet) — it must NEVER be folded into
/// `left` (the board's "40 left behind on open" bug, H-5).
enum AttendanceMark { unmarked, present, left }

/// Present / left-behind / unmarked counts for an attendance roster.
class AttendanceTally {
  final int present;
  final int left;
  final int unmarked;
  const AttendanceTally({
    required this.present,
    required this.left,
    required this.unmarked,
  });

  int get total => present + left + unmarked;

  factory AttendanceTally.from(Iterable<AttendanceMark> marks) {
    var p = 0, l = 0, u = 0;
    for (final m in marks) {
      switch (m) {
        case AttendanceMark.present:
          p++;
        case AttendanceMark.left:
          l++;
        case AttendanceMark.unmarked:
          u++;
      }
    }
    return AttendanceTally(present: p, left: l, unmarked: u);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/utils/attendance_tally_test.dart -v`
Expected: PASS.

- [ ] **Step 5: Add a mark resolver to the screen** — in `lib/screens/handler_bus_chart_screen.dart`, add `import '../utils/attendance_tally.dart';` and a helper next to `_isPresent` (`:141`):

```dart
  /// Tri-state boarding mark: `unmarked` when no attendance row exists yet,
  /// else present/left from the stored row. Distinguishes "not decided" from
  /// "left behind" so the tally never shows unmarked riders as no-shows.
  AttendanceMark _markFor(String passengerId, String busId, AttendanceLeg leg) {
    final row = _attendanceFor(passengerId, busId, leg);
    if (row == null) return AttendanceMark.unmarked;
    return row.present ? AttendanceMark.present : AttendanceMark.left;
  }
```

- [ ] **Step 6: Carry the mark on `_AttendanceEntry`** — replace `:1606-1613`:

```dart
/// One row in the attendance list: a passenger expected on the current leg
/// plus their tri-state boarding [mark].
class _AttendanceEntry {
  final Passenger passenger;
  final AttendanceMark mark;

  const _AttendanceEntry({required this.passenger, required this.mark});

  bool get present => mark == AttendanceMark.present;
}
```

Then at the construction site `:833-839`, build the mark instead of the bool:

```dart
                    rows: [
                      for (final p in _expectedForLeg(manifest, bus, _attLeg))
                        _AttendanceEntry(
                          passenger: p,
                          mark: _markFor(p.id, bus.id, _attLeg),
                        ),
                    ],
```

- [ ] **Step 7: Honest tally in `_AttendanceView.build`** — replace `:2949-2951`:

```dart
    final tally = AttendanceTally.from(rows.map((r) => r.mark));
    final total = tally.total;
    final present = tally.present;
    final left = tally.left;
    final unmarked = tally.unmarked;
```

Change the third stat tile at `:2986-2994` from "total" to "unmarked" (the actionable number), and update the sub-label text `:2998-3007` to use `present`/`left`/`unmarked`:

```dart
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.help_outline_rounded,
                value: '$unmarked',
                label: tr('handler_chart.att_unmarked'),
                variant: UgamStatVariant.neutral,
              ),
            ),
```

```dart
          child: Text(
            tr('handler_chart.att_tally', namedArgs: {
              'present': '$present',
              'left': '$left',
              'unmarked': '$unmarked',
            }),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
```

- [ ] **Step 8: Add the localization keys** — in `assets/translations/en.json` under `handler_chart`, add `att_unmarked` and extend `att_tally` (find the existing `handler_chart.att_tally` and `att_total` keys):

```json
      "att_unmarked": "Unmarked",
      "att_tally": "{present} boarded · {left} left behind · {unmarked} unmarked",
```

Add the SAME keys to `gu.json` and `hi.json`:

- `gu.json`: `"att_unmarked": "અચિહ્નિત"`, `"att_tally": "{present} બેઠા · {left} રહી ગયા · {unmarked} અચિહ્નિત"`
- `hi.json`: `"att_unmarked": "अचिह्नित"`, `"att_tally": "{present} सवार · {left} छूट गए · {unmarked} अचिह्नित"`

(The old `att_tally` had only `present`/`left`; every locale's placeholder set must now include `unmarked`. `att_total` may become unused — leave it in all three locales for key-parity, or delete from all three together.)

- [ ] **Step 9: Verify locale parity + build**

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart` and confirm en/gu/hi each have `att_unmarked` + a 3-placeholder `att_tally` (a quick `grep -n "att_unmarked\|att_tally" assets/translations/*.json`).
Expected: three matches each; no analyzer issues.

- [ ] **Step 10: Manual verification** — open a fresh attendance board: it reads "0 left behind · N unmarked", not "N left behind".

- [ ] **Step 11: Commit**

```bash
git add lib/utils/attendance_tally.dart lib/screens/handler_bus_chart_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/utils/attendance_tally_test.dart
git commit -m "fix(attendance): H-5 add unmarked state so board doesn't read all left-behind"
```

### Task 11: H-6 — optimistic attendance toggle with rollback

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart` — `_togglePresent` at `:185-216`.

**Problem:** the `Switch` value comes from `_markFor`/`_attendance`, which only updates after the server round-trip, so the toggle doesn't move until the network returns and silently reverts on failure. Flip optimistically, then reconcile / roll back.

- [ ] **Step 1: Rewrite `_togglePresent`** — replace `:185-216`:

```dart
  Future<void> _togglePresent(
    Bus bus,
    Passenger p,
    AttendanceLeg leg,
    bool present,
  ) async {
    final tourId = (bus.tourId?.isNotEmpty == true) ? bus.tourId! : p.tourId;
    final key = _attKey(p.id, bus.id, leg);
    final existing = _attendanceFor(p.id, bus.id, leg);
    final base =
        existing ??
        Attendance(tourId: tourId, busId: bus.id, passengerId: p.id, leg: leg);
    final updated = base.copyWith(present: present);

    // Optimistic flip: move the switch immediately so the field feels instant.
    setState(() => _attendance[key] = updated);

    try {
      final saved = await _store.handlerUpsertAttendance(widget.requestId, updated);
      if (saved == null) {
        throw StateError('Handler attendance save was rejected.');
      }
      if (!mounted) return;
      // Reconcile ids/timestamps with the server-returned row.
      setState(() => _attendance[key] = saved);
    } catch (_) {
      if (!mounted) return;
      // Roll back to the prior state (previous row, or none).
      setState(() {
        if (existing == null) {
          _attendance.remove(key);
        } else {
          _attendance[key] = existing;
        }
      });
      AppSnackBar.error(tr('handler_chart.error_save_attendance'));
    }
  }
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart`
Expected: no new issues.

- [ ] **Step 3: Manual verification** — toggle a rider present with a slow/failed connection: the switch flips instantly; on server rejection it rolls back and an error snackbar shows. On success it stays and the tally updates.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart
git commit -m "fix(attendance): H-6 optimistic toggle with rollback"
```

### Task 12: H-7 — bound and ellipsize the attendance seat-id chip

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart` — the seat-id chip in `_AttendanceRow.build` at `:3128-3146`.

**Problem:** the chip `Container` has only `minWidth: 40` and its `Text` has no `maxLines`/`overflow`, so a multi-seat rider's joined label ("A1, A2, A3, A4") overflows the row.

- [ ] **Step 1: Bound the chip** — replace `:3128-3146`:

```dart
          // Seat id chip(s) — bounded + ellipsised so a multi-seat rider's
          // joined label can't overflow the row (H-7).
          Container(
            constraints: const BoxConstraints(minWidth: 40, maxWidth: 84),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            child: Text(
              seatLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart`
Expected: no new issues.

- [ ] **Step 3: Manual verification** — a rider holding 4 seats on one bus shows a bounded, ellipsised chip; the row does not overflow at 360dp or at 1.3× text scale.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart
git commit -m "fix(attendance): H-7 bound + ellipsize the seat-id chip"
```

---

## Theme G — Per-seat leg partitioning (CALC-4)

Attendance and collect-leg partitioning fold the coarse passenger-level `tripType` instead of each seat's own `leg`, so a rider with a mixed same-type booking (e.g. one GO-only seat + one RET-only seat) lands on the wrong or both legs. `Passenger.legForSeat(seatId, {busId}) → TripType` already returns `a.leg ?? tripType`; partition through it.

### Task 13: CALC-4 — partition collect-leg and attendance by `legForSeat`

**Files:**
- Modify: `lib/utils/seat_occupants.dart:155-164` (`occupantsForCollectLeg`) and its two callers — `lib/screens/handler_bus_chart_screen.dart:1271-1273` and `lib/services/seat_chart_pdf.dart:368`.
- Modify: `lib/screens/handler_bus_chart_screen.dart:157-160` (`_expectedForLeg`).
- Test: `test/utils/seat_occupants_leg_test.dart` (new).

**Interfaces:**
- `occupantsForCollectLeg` gains seat context: `List<Passenger> occupantsForCollectLeg(List<Passenger> occupants, CollectLeg leg, {required String seatId, String? busId})`.
- Consumes: `Passenger.legForSeat(String seatId, {String? busId}) → TripType`, and `TripType.usesOutbound` / `usesReturn`.

- [ ] **Step 1: Write the failing test**

Create `test/utils/seat_occupants_leg_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_occupants.dart';

/// A rider with a mixed same-type booking: seat DL1 stamped GO-only, DL2 RET-only.
Passenger _mixed() => Passenger(
      id: 'm', tourId: 't1', name: 'Mix', phone: '+910000000000',
      tripType: TripType.roundTrip, // coarse type disagrees with per-seat legs
      requestLines: [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1, leg: TripType.outboundOnly),
        RequestLine(seatType: SeatType.doubleSofa, qty: 1, leg: TripType.returnOnly),
      ],
      assignedSeats: [
        SeatAssignment(busId: 'b1', seatId: 'DL1', leg: TripType.outboundOnly),
        SeatAssignment(busId: 'b1', seatId: 'DL2', leg: TripType.returnOnly),
      ],
    );

void main() {
  test('collect-leg partitions by the seat leg, not the coarse tripType', () {
    final p = _mixed();
    // GO leg for the GO-only seat keeps the rider; RET leg for that seat drops them.
    expect(occupantsForCollectLeg([p], CollectLeg.go, seatId: 'DL1', busId: 'b1'), [p]);
    expect(occupantsForCollectLeg([p], CollectLeg.ret, seatId: 'DL1', busId: 'b1'), isEmpty);
    // The RET-only seat: present on RET, absent on GO.
    expect(occupantsForCollectLeg([p], CollectLeg.ret, seatId: 'DL2', busId: 'b1'), [p]);
    expect(occupantsForCollectLeg([p], CollectLeg.go, seatId: 'DL2', busId: 'b1'), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/utils/seat_occupants_leg_test.dart -v`
Expected: FAIL — the current signature has no `seatId` param (compile error), and the old logic used `p.tripType`.

- [ ] **Step 3: Partition `occupantsForCollectLeg` by seat leg** — replace `lib/utils/seat_occupants.dart:155-164`:

```dart
List<Passenger> occupantsForCollectLeg(
  List<Passenger> occupants,
  CollectLeg leg, {
  required String seatId,
  String? busId,
}) => occupants.where((p) {
      final seatLeg = p.legForSeat(seatId, busId: busId);
      return leg == CollectLeg.go ? seatLeg.usesOutbound : seatLeg.usesReturn;
    }).toList();
```

- [ ] **Step 4: Update `seatHasLegSplit`** (`:172-179`, same file) — it iterates a single shared seat, so thread its seat id through. Change its signature to `bool seatHasLegSplit(List<Passenger> occupants, {required String seatId, String? busId})` and pass `seatId`/`busId` into both `occupantsForCollectLeg` calls inside it.

- [ ] **Step 5: Fix the callers.** In `lib/screens/handler_bus_chart_screen.dart:1271-1273`, the seat's id is on the row's cell/state (the widget already has the seat context — use the same `seatId` it passes to `amountDueForSeat`/the tile; e.g. `widget.seatId` / `widget.cell.seatId`):

```dart
    final hasSplit = seatHasLegSplit(widget.occupants, seatId: widget.seatId, busId: widget.busId);
    final occ = hasSplit
        ? occupantsForCollectLeg(widget.occupants, _leg, seatId: widget.seatId, busId: widget.busId)
```

(Confirm the exact field names on that widget with `grep -n "seatId\|busId\|cell" ` around `:1240-1280`; pass whatever the widget already holds. If only a `SeatCell cell` is available, use `cell.seatId`.)

In `lib/services/seat_chart_pdf.dart:368`, the loop is over `e` (a seat entry) — pass that seat's id and bus id:

```dart
              in (leg == null ? e.value : occupantsForCollectLeg(e.value, leg, seatId: e.key, busId: busId)))
```

(Confirm `e.key` is the seat id and that a `busId` is in scope in that PDF builder; if the map is keyed differently, pass the seat id the surrounding code already uses.)

- [ ] **Step 6: Partition `_expectedForLeg` by seat leg** — in `lib/screens/handler_bus_chart_screen.dart`, replace the `usesLeg` block at `:155-160`:

```dart
      final seatsOnBus = p.assignedSeats.where((a) => a.busId == bus.id);
      if (seatsOnBus.isEmpty) continue;
      final usesLeg = seatsOnBus.any((a) {
        final seatLeg = p.legForSeat(a.seatId, busId: bus.id);
        return leg == AttendanceLeg.go ? seatLeg.usesOutbound : seatLeg.usesReturn;
      });
      if (!usesLeg) continue;
```

(This replaces both the `onBus` check at `:155-156` and the coarse `usesLeg` at `:157-160`.)

- [ ] **Step 7: Run the new test + attendance/occupants regressions**

Run: `flutter test test/utils/seat_occupants_leg_test.dart` and `flutter analyze lib/utils/seat_occupants.dart lib/screens/handler_bus_chart_screen.dart lib/services/seat_chart_pdf.dart`
Expected: PASS; no new analyzer issues.

- [ ] **Step 8: Commit**

```bash
git add lib/utils/seat_occupants.dart lib/screens/handler_bus_chart_screen.dart lib/services/seat_chart_pdf.dart test/utils/seat_occupants_leg_test.dart
git commit -m "fix(legs): CALC-4 partition collect-leg + attendance by per-seat leg"
```

---

## Theme H — Sync-layer hardening

### Task 14: X-3 — remove the dead cold-start cache path

**Files:**
- Modify: `lib/controllers/tour_controller.dart:382-389`, `lib/services/sync_service.dart:76-81` (the `getCachedList` / `invalidateCache` no-op stubs' comments).

**Problem:** `SyncService.getCachedList` is a permanent `async => null` (the SQLite cache was removed), so the "paint cached tours on cold start" block in `_loadTours` is dead code whose comment promises behaviour that can't run.

- [ ] **Step 1: Delete the dead block** — in `lib/controllers/tour_controller.dart`, remove `:382-389`:

```dart
      // Paint cached tours immediately on cold start so weak networks
      // don't leave the whole app blank while the live fetch crawls.
      if (tours.isEmpty) {
        final cached = await _sync.getCachedList(_tourCacheKey);
        if (cached != null && cached.isNotEmpty) {
          tours.assignAll(cached.map((item) => Tour.fromMap(item)).toList());
        }
      }
```

If `_tourCacheKey` is now unused, delete its declaration too (search: `grep -n "_tourCacheKey" lib/controllers/tour_controller.dart` — remove only if there are no other references).

- [ ] **Step 2: Keep the stubs, fix the promise.** `invalidateCache` is still called (e.g. by `MoneyController.refreshForTour`), so KEEP it. Remove only `getCachedList` if it now has zero callers (`grep -rn "getCachedList" lib/` — if the tour_controller call was its only caller, delete the stub at `sync_service.dart:76-78`; otherwise leave it and just correct the comment to "always null; no cold-start cache remains").

- [ ] **Step 3: Verify nothing else references the removed symbol**

Run: `grep -rn "getCachedList" lib/` and `flutter analyze lib/controllers/tour_controller.dart lib/services/sync_service.dart`
Expected: no dangling references; analyzer clean.

- [ ] **Step 4: Run the tour-controller test suite (guard against regression)**

Run: `flutter test test/controllers/ test/screens/tour_overview_screen_test.dart`
Expected: PASS (behaviour unchanged — the removed path never ran).

- [ ] **Step 5: Commit**

```bash
git add lib/controllers/tour_controller.dart lib/services/sync_service.dart
git commit -m "chore(sync): X-3 remove dead cold-start cache path + fix comments"
```

### Task 15: X-4 — typed retry classification (no message substring matching)

**Files:**
- Modify: `lib/services/sync_service.dart` — `_isRetryable` at `:537-584` and the `_looksLikeTransport` helper at `:587-602`.
- Test: `test/services/sync_retry_classification_test.dart` (new).

**Problem:** unknown-code `PostgrestException`s and unknown exception types fall through to `_looksLikeTransport(message)` — a fragile, locale/SDK-dependent substring match. Classify on typed exceptions/codes; unknown ⇒ non-retryable.

**Interfaces:**
- Produces: a top-level `@visibleForTesting bool syncIsRetryable(Object e, {required bool retryOnTimeout})` in `sync_service.dart` (pure — no `_client`, so testable without a live Supabase). `_isRetryable` delegates to it.

- [ ] **Step 1: Write the failing test**

Create `test/services/sync_retry_classification_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  group('syncIsRetryable', () {
    test('typed transport failures are retryable', () {
      expect(syncIsRetryable(const SocketException('down'), retryOnTimeout: true), isTrue);
      expect(syncIsRetryable(const HttpException('boom'), retryOnTimeout: true), isTrue);
    });

    test('timeout retryable only for idempotent callers', () {
      expect(syncIsRetryable(TimeoutException('t'), retryOnTimeout: true), isTrue);
      expect(syncIsRetryable(TimeoutException('t'), retryOnTimeout: false), isFalse);
    });

    test('terminal Postgrest codes are non-retryable', () {
      expect(syncIsRetryable(const PostgrestException(message: 'x', code: '42501'), retryOnTimeout: true), isFalse);
      expect(syncIsRetryable(const PostgrestException(message: 'x', code: '23505'), retryOnTimeout: true), isFalse);
    });

    test('explicit DB-unreachable Postgrest codes are retryable; 5xx too', () {
      expect(syncIsRetryable(const PostgrestException(message: 'x', code: '503'), retryOnTimeout: true), isTrue);
      expect(syncIsRetryable(const PostgrestException(message: 'x', code: '500'), retryOnTimeout: true), isTrue);
    });

    test('unknown Postgrest code and unknown exception are NON-retryable', () {
      expect(syncIsRetryable(const PostgrestException(message: 'connection reset by peer'), retryOnTimeout: true), isFalse);
      expect(syncIsRetryable(Exception('some network glitch'), retryOnTimeout: true), isFalse);
      expect(syncIsRetryable(const AuthException('expired'), retryOnTimeout: true), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/sync_retry_classification_test.dart -v`
Expected: FAIL — `syncIsRetryable` is undefined; and the current logic returns `true` for the "unknown ... network glitch" cases via substring matching.

- [ ] **Step 3: Extract a pure, typed classifier** — in `lib/services/sync_service.dart`, add a top-level function (import `package:flutter/foundation.dart` for `@visibleForTesting` if not present):

```dart
/// Pure, typed retry classification (X-4): decide from the exception TYPE and
/// known codes, never from message substrings. Unknown ⇒ non-retryable.
@visibleForTesting
bool syncIsRetryable(Object e, {required bool retryOnTimeout}) {
  if (e is TimeoutException) return retryOnTimeout;
  if (e is AuthException) return false;
  if (e is PostgrestException) {
    final code = e.code;
    const terminal = {
      '42501', '23505', '23503', '23514', '23502', '22P02', 'PGRST202', '42883',
    };
    if (code != null && terminal.contains(code)) return false;
    if (code == '503' || code == 'PGRST001') return true;
    final status = int.tryParse(code ?? '');
    if (status != null) {
      if (status >= 500) return true;
      if (status >= 400) return false;
    }
    // Unknown / null code ⇒ terminal (no message sniffing).
    return false;
  }
  if (e is SocketException) return true;
  if (e is HttpException) return true;
  // Unknown exception type ⇒ terminal.
  return false;
}
```

- [ ] **Step 4: Delegate and delete the dead sniffer** — replace the body of `_isRetryable` (`:537-584`) with `return syncIsRetryable(e, retryOnTimeout: retryOnTimeout);`, then delete the now-unused `_looksLikeTransport` (`:587-602`). Leave `_isPreSendConnectionError` (`:609-616`) as-is — it is already narrowed to a typed `SocketException` and only used for the non-idempotent swap RPC.

- [ ] **Step 5: Run test to verify it passes + no dangling refs**

Run: `flutter test test/services/sync_retry_classification_test.dart -v` then `flutter analyze lib/services/sync_service.dart`
Expected: PASS; analyzer reports no unused `_looksLikeTransport` (it was deleted).

- [ ] **Step 6: Commit**

```bash
git add lib/services/sync_service.dart test/services/sync_retry_classification_test.dart
git commit -m "fix(sync): X-4 typed retry classification, drop message substring matching"
```

### Task 16: X-5 — paginate reads instead of silently truncating at the row cap

**Files:**
- Modify: `lib/services/sync_service.dart` — `_fetchFromSupabase` at `:144-166` and the passengers read inside `_fetchToursWithRelations` (`:188+`); add a pure `paginateRows` helper.
- Test: `test/services/sync_paginate_test.dart` (new).

**Problem:** reads apply a fixed `.limit(defaultRowLimit)` (500; passengers 2000) and only `dev.log`-warn on truncation, so roster/capacity/money silently compute on partial data past the cap. Replace the hard cap with range pagination.

**Interfaces:**
- Produces: `@visibleForTesting Future<List<T>> paginateRows<T>(Future<List<T>> Function(int from, int to) fetchPage, {int pageSize})` — loops `fetchPage(from, from+pageSize-1)` until a short page returns. Pure (no client) ⇒ unit-testable with an in-memory fake.

- [ ] **Step 1: Write the failing test**

Create `test/services/sync_paginate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  Future<List<int>> Function(int, int) fakeSource(int total, {required List<int> calls}) {
    return (from, to) async {
      calls.add(from);
      final end = (to + 1).clamp(0, total);
      if (from >= total) return <int>[];
      return [for (var i = from; i < end; i++) i];
    };
  }

  test('stops after a short page and returns every row', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(2300, calls: calls), pageSize: 1000);
    expect(rows.length, 2300);
    expect(calls, [0, 1000, 2000]); // third page is short → stop
  });

  test('exact-multiple boundary fetches one extra empty page then stops', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(2000, calls: calls), pageSize: 1000);
    expect(rows.length, 2000);
    expect(calls, [0, 1000, 2000]); // 2000 rows in 2 full pages, 3rd empty ends it
  });

  test('single short page', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(42, calls: calls), pageSize: 1000);
    expect(rows.length, 42);
    expect(calls, [0]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/sync_paginate_test.dart -v`
Expected: FAIL — `paginateRows` is undefined.

- [ ] **Step 3: Add the pagination helper** — top-level in `lib/services/sync_service.dart`:

```dart
/// Fetch every row by paging through [fetchPage] (a Supabase `.range(from,to)`
/// closure) until a page shorter than [pageSize] returns (X-5). Replaces the
/// silent `.limit(cap)` truncation so roster/capacity/money never compute on a
/// partial read.
@visibleForTesting
Future<List<T>> paginateRows<T>(
  Future<List<T>> Function(int from, int to) fetchPage, {
  int pageSize = SyncService.pageSize,
}) async {
  final all = <T>[];
  var from = 0;
  while (true) {
    final page = await fetchPage(from, from + pageSize - 1);
    all.addAll(page);
    if (page.length < pageSize) break;
    from += pageSize;
  }
  return all;
}
```

Add `static const int pageSize = 1000;` to `SyncService` (Supabase's default max range window) and remove the now-unused `_warnIfCapped` / the `defaultRowLimit`/`passengersRowLimit` caps if nothing else references them (`grep -n "defaultRowLimit\|passengersRowLimit\|_warnIfCapped" lib/services/sync_service.dart`).

- [ ] **Step 4: Page the generic table read** — replace `_fetchFromSupabase`'s limited transform at `:151-165`:

```dart
    List<Map<String, dynamic>> _page(int from, int to) async {} // placeholder — see below
```

Concretely, build the base query then page it:

```dart
    final base = _client.from(table).select();
    var filtered = base;
    if (filters != null) {
      filters.forEach((k, v) { filtered = filtered.eq(k, v); });
    }
    return paginateRows<Map<String, dynamic>>((from, to) async {
      final transform = orderBy != null
          ? filtered.order(orderBy, ascending: false).range(from, to)
          : filtered.range(from, to);
      final rows = await transform;
      return List<Map<String, dynamic>>.from(
        (rows as List).map((r) => Map<String, dynamic>.from(r)),
      );
    });
```

- [ ] **Step 5: Page the passengers read** in `_fetchToursWithRelations` the same way — wrap its `.limit(...)` passengers query in `paginateRows((from,to) => ...range(from,to)...)`. (Buses are small — leave the buses read as-is unless it also carries a `.limit`.)

- [ ] **Step 6: Run the pagination test + analyze**

Run: `flutter test test/services/sync_paginate_test.dart -v` then `flutter analyze lib/services/sync_service.dart`
Expected: PASS; no unused-symbol warnings.

- [ ] **Step 7: Manual verification** — against a tour with >500 passengers (or temporarily set `pageSize = 2` in a scratch run), confirm the full roster loads and capacity/money reflect every row.

- [ ] **Step 8: Commit**

```bash
git add lib/services/sync_service.dart test/services/sync_paginate_test.dart
git commit -m "fix(sync): X-5 paginate reads via range() instead of silent truncation"
```

---

## Theme I — Misc correctness, responsiveness & platform

### Task 17: X-7 — add `NSPhotoLibraryUsageDescription` to iOS Info.plist

**Files:**
- Modify: `ios/Runner/Info.plist`.

**Problem:** the app uses `image_picker` gallery (`create_tour_screen.dart:73-74`) but Info.plist has no photo-library usage string; App Review commonly expects it.

- [ ] **Step 1: Add the key** — in `ios/Runner/Info.plist`, insert after the `NSFaceIDUsageDescription` string (`:42`):

```xml
	<key>NSPhotoLibraryUsageDescription</key>
	<string>Ugam Booking needs access to your photo library so you can pick a cover image for a tour.</string>
```

- [ ] **Step 2: Verify the plist is well-formed**

Run: `plutil -lint ios/Runner/Info.plist` (on macOS) or a quick XML validity check; confirm the new key sits between two complete `<key>/<string>` pairs.
Expected: "OK" / valid.

- [ ] **Step 3: Commit**

```bash
git add ios/Runner/Info.plist
git commit -m "chore(ios): X-7 add NSPhotoLibraryUsageDescription for image_picker gallery"
```

### Task 18: AL-3 — surface outstanding handovers for every tour, not just the loaded one

**Files:**
- Modify: `lib/controllers/money_controller.dart` (add a settlement-snapshot API), `lib/screens/dashboard_screen.dart` (`_needsAttention` at `:196-244`, and trigger the snapshot load).
- Test: `test/controllers/money_settlement_snapshot_test.dart` (new).

**Problem:** the dashboard's settlement alert only fires for `money.loadedTourId == tour.id`; a handler owing cash on any OTHER tour never surfaces. Cache a per-tour outstanding computed with the SAME `TourMoneySummary.compute` the board uses, then read it in the loop.

**Interfaces:**
- Produces on `MoneyController`:
  - `final settlementByTour = <String, double>{}.obs;`
  - `double? outstandingHandoverFor(String tourId)` — the loaded tour's live `tourSummary().totalOutstandingHandover`, else the cached snapshot (or null if not yet loaded).
  - `Future<void> loadSettlementSnapshots(Iterable<String> tourIds)` — fetch each non-loaded tour's four money tables and cache `TourMoneySummary.compute(...).totalOutstandingHandover`.

- [ ] **Step 1: Write the failing test** (the cache-read decision — the aggregation itself is covered by existing `TourMoneySummary` tests):

Create `test/controllers/money_settlement_snapshot_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/money_controller.dart';

void main() {
  test('outstandingHandoverFor reads the per-tour snapshot cache', () {
    final c = MoneyController();
    // No snapshot yet → null (distinct from 0 "settled").
    expect(c.outstandingHandoverFor('t9'), isNull);
    c.settlementByTour['t9'] = 4200.0;
    expect(c.outstandingHandoverFor('t9'), 4200.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/controllers/money_settlement_snapshot_test.dart -v`
Expected: FAIL — `settlementByTour` / `outstandingHandoverFor` undefined.

- [ ] **Step 3: Add the API to `MoneyController`** — after `refreshForTour` (`:151`), using the existing imports (`TourMoneySummary`, `Collection`, `Expense`, `BusHandover`, `IncomeEntry`, `TourController`):

```dart
  /// Per-tour outstanding-handover totals for the dashboard's settlement alerts
  /// (AL-3), so tours OTHER than the currently-loaded one still surface. Filled
  /// by [loadSettlementSnapshots]; read via [outstandingHandoverFor].
  final settlementByTour = <String, double>{}.obs;

  /// Outstanding handover for [tourId]: the exact live value when it's the
  /// loaded tour, else the cached snapshot (null when not yet computed — the
  /// caller must treat null as "unknown", not "settled").
  double? outstandingHandoverFor(String tourId) {
    if (tourId == _loadedTourId) return tourSummary().totalOutstandingHandover;
    return settlementByTour[tourId];
  }

  /// Lightweight settlement pass for [tourIds]: fetch each tour's four money
  /// tables and cache its outstanding handover via the SAME
  /// [TourMoneySummary.compute] the board uses. Never touches the live obs
  /// lists; skips the loaded tour (already exact) and any failed read.
  Future<void> loadSettlementSnapshots(Iterable<String> tourIds) async {
    final tourCtrl =
        Get.isRegistered<TourController>() ? Get.find<TourController>() : null;
    for (final id in tourIds) {
      if (id == _loadedTourId) continue;
      final results = await Future.wait([
        _sync.smartFetch(table: 'collections', cacheKey: _collectionsKey(id), filters: {'tour_id': id}, orderBy: 'created_at'),
        _sync.smartFetch(table: 'expenses', cacheKey: _expensesKey(id), filters: {'tour_id': id}, orderBy: 'created_at'),
        _sync.smartFetch(table: 'bus_handovers', cacheKey: _handoversKey(id), filters: {'tour_id': id}, orderBy: 'created_at'),
        _sync.smartFetch(table: 'incomes', cacheKey: _incomesKey(id), filters: {'tour_id': id}, orderBy: 'created_at'),
      ]);
      if (results.any((r) => r.failed)) continue;
      final tour = tourCtrl?.getTour(id);
      final busRentsTotal =
          tour == null ? 0.0 : tour.buses.fold<double>(0, (s, b) => s + b.busPrice);
      final totalRevenueBilled = tour == null
          ? 0.0
          : tour.buses.fold<double>(
              0, (s, b) => s + tour.passengers.fold<double>(0, (ps, p) => ps + b.amountDueFor(p)));
      final summary = TourMoneySummary.compute(
        collections: results[0].rows.map(Collection.fromMap).toList(),
        expenses: results[1].rows.map(Expense.fromMap).toList(),
        handovers: results[2].rows.map(BusHandover.fromMap).toList(),
        incomes: results[3].rows.map(IncomeEntry.fromMap).toList(),
        busRentsTotal: busRentsTotal,
        totalRevenueBilled: totalRevenueBilled,
      );
      settlementByTour[id] = summary.totalOutstandingHandover;
    }
    settlementByTour.refresh();
  }
```

(Confirm `TourMoneySummary` is already imported via `money_summary.dart`; it is used by `tourSummary()`.)

- [ ] **Step 4: Run the unit test**

Run: `flutter test test/controllers/money_settlement_snapshot_test.dart -v`
Expected: PASS.

- [ ] **Step 5: Wire the dashboard** — in `lib/screens/dashboard_screen.dart`, replace the loaded-tour-only settlement branch at `:223-244` with a cache read that works for any tour:

```dart
      final outstanding = money.outstandingHandoverFor(tour.id);
      if (outstanding != null && outstanding > 0.005) {
        final amount = Formatters.formatMoneyInr(outstanding);
        // ...existing AttentionItem construction unchanged (reason/cta/onTap)...
        continue;
      }
```

Then trigger the snapshot pass once when the dashboard's tours are known — in the dashboard State's `initState` (or the existing post-frame callback), after tours load:

```dart
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final money = Get.find<MoneyController>();
      final ids = Get.find<TourController>().tours.map((t) => t.id).toList();
      money.loadSettlementSnapshots(ids);
    });
```

(The `_needsAttention` list is inside an `Obx`/reactive builder that already reads `money`; `settlementByTour` being `.obs` makes it re-render when snapshots land. Confirm the builder observes `money` — if `_needsAttention` isn't already inside an `Obx` that touches a money obs, wrap the relevant section so `settlementByTour` updates repaint it.)

- [ ] **Step 6: Analyze + manual verification**

Run: `flutter analyze lib/controllers/money_controller.dart lib/screens/dashboard_screen.dart`
Expected: clean. Manual: with two tours each owing a handover, open the dashboard while tour A's money is loaded — both A and B show settlement alerts with correct amounts.

- [ ] **Step 7: Commit**

```bash
git add lib/controllers/money_controller.dart lib/screens/dashboard_screen.dart test/controllers/money_settlement_snapshot_test.dart
git commit -m "feat(dashboard): AL-3 per-tour settlement alerts via cached snapshots"
```

### Task 19: AM-6 — bulk action bar goes icon-only under a width/scale threshold

**Files:**
- Modify: `lib/screens/requests_screen.dart:1074-1126` (the bulk-bar `Row`).

**Problem:** up to four `icon+label` `UgamButton`s pack one `Row`; labels clip on ~360dp phones / large text. Drop the labels below a threshold.

- [ ] **Step 1: Wrap the bulk-bar Row in a `LayoutBuilder`** and compute a `compact` flag from width and text scale; pass an empty label when compact. Replace `:1074`:

```dart
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final compact = constraints.maxWidth < 360 || scale > 1.3;
              String lbl(String s) => compact ? '' : s;
              return Row(
                children: [
                  Expanded(
                    child: isWaitlistTab
                        ? UgamButton(
                            icon: Icons.arrow_back_rounded,
                            label: lbl(tr('requests.bulk.promote')),
                            kind: UgamButtonKind.ghost,
                            expand: true,
                            onPressed: enabled ? onPromote : null,
                          )
                        : UgamButton(
                            icon: Icons.hourglass_top_rounded,
                            label: lbl(tr('requests.bulk.waitlist')),
                            kind: UgamButtonKind.ghost,
                            expand: true,
                            onPressed: enabled ? onWaitlist : null,
                          ),
                  ),
                  if (canConfirm)
                    Expanded(
                      child: UgamButton(
                        icon: Icons.verified_rounded,
                        label: lbl(tr('requests.bulk.confirm')),
                        kind: UgamButtonKind.primary,
                        expand: true,
                        onPressed: enabled ? onConfirm : null,
                      ),
                    ),
                  Expanded(
                    child: UgamButton(
                      icon: Icons.chat_rounded,
                      label: lbl(tr('requests.bulk.send_wa')),
                      kind: canConfirm ? UgamButtonKind.ghost : UgamButtonKind.primary,
                      expand: true,
                      onPressed: enabled ? onSendWA : null,
                    ),
                  ),
                  Expanded(
                    child: UgamButton(
                      icon: Icons.close_rounded,
                      label: lbl(tr('requests.bulk.decline')),
                      kind: UgamButtonKind.dangerTonal,
                      expand: true,
                      onPressed: enabled && canDecline ? onDecline : null,
                    ),
                  ),
                ],
              );
            },
          ),
```

(`UgamButton` renders the icon when `label` is empty; the icon+label `Row` gap after the icon is negligible. Every button here already passes an `icon`, so icon-only stays meaningful.)

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/screens/requests_screen.dart`
Expected: no new issues.

- [ ] **Step 3: Manual verification** — enter selection mode on a 360dp phone (and at 1.4× text): the four bulk buttons show icons only, no clipped labels; on a wide phone the labels return.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/requests_screen.dart
git commit -m "fix(requests): AM-6 icon-only bulk bar under width/scale threshold"
```

### Task 20: AM-5 — localize the two WhatsApp-failure snackbars

**Files:**
- Modify: `lib/screens/requests_screen.dart:297-301` and `:1789-1792`.
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json`.

**Problem:** two hardcoded English WhatsApp-failure snackbars in an otherwise localized screen.

- [ ] **Step 1: Add the keys** — in `assets/translations/en.json` under the existing `requests.bulk` object (near `:499`) add:

```json
      "declined_wa_partial": "Cancelled {n} request(s). WhatsApp sent: {sent}, failed: {failed}."
```

and under `requests.snack` (near the existing `declined_title`/`declined_body`) add:

```json
      "decline_wa_failed": "Request was cancelled, but WhatsApp notification failed."
```

Add the SAME two keys to `gu.json` and `hi.json`:
- `gu.json`: `"declined_wa_partial": "{n} વિનંતી રદ કરી. WhatsApp મોકલ્યા: {sent}, નિષ્ફળ: {failed}."`, `"decline_wa_failed": "વિનંતી રદ કરવામાં આવી, પરંતુ WhatsApp સૂચના નિષ્ફળ ગઈ."`
- `hi.json`: `"declined_wa_partial": "{n} अनुरोध रद्द किए। WhatsApp भेजे: {sent}, विफल: {failed}।"`, `"decline_wa_failed": "अनुरोध रद्द कर दिया गया, लेकिन WhatsApp सूचना विफल रही।"`

- [ ] **Step 2: Replace the bulk snackbar** — `requests_screen.dart:297-301`:

```dart
    if (waFailed > 0) {
      AppSnackBar.warning(
        tr('requests.bulk.declined_wa_partial', namedArgs: {
          'n': '${ids.length}',
          'sent': '$waSent',
          'failed': '$waFailed',
        }),
      );
    }
```

- [ ] **Step 3: Replace the single-decline snackbar** — `requests_screen.dart:1789-1792`:

```dart
    if (waFailed) {
      AppSnackBar.warning(tr('requests.snack.decline_wa_failed'));
    }
```

- [ ] **Step 4: Verify parity + analyze**

Run: `grep -n "declined_wa_partial\|decline_wa_failed" assets/translations/*.json` (expect two hits per locale, six total) and `flutter analyze lib/screens/requests_screen.dart`
Expected: parity confirmed; no analyzer issues; no remaining hardcoded English snackbars in the file (`grep -n "AppSnackBar.\(warning\|error\|success\)('"` should show none with a raw string literal at these sites).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/requests_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json
git commit -m "fix(requests): AM-5 localize WhatsApp-failure snackbars via tr()"
```

---

### Task 21: X-6 — make the `UgamScale` scaling contract honest (extends Theme E)

**Why:** `lib/design/ui_scale.dart:17-20` documents that "fixed-pixel dimensions inside the shared design components multiply by `of` so they track the same curve", implying component chrome scales app-wide. In reality `UgamScale.of` is called in only two places besides its definition — `lib/app.dart:64` (the app-root `MediaQuery.textScaler`) and `lib/design/components/ugam_input.dart:174`. So only **text** scales globally; the per-dimension contract is unfulfilled and reads as a landmine (a future dev expects `* s` everywhere). The audit (X-6) explicitly accepts either "apply `* s` in the shared components" or "drop the unfulfilled contract". A full rollout across every component is YAGNI here — the acute responsiveness cases are already covered by app-wide text scaling, the `_min` 0.85 floor, the `FittedBox`-wrapped grids, and Phase 3 Tasks 8–9. So this task makes the contract **honest** (opt-in, not automatic) and adds a regression guard for the clamp behavior UgamScale genuinely delivers.

**Files:**
- Modify: `lib/design/ui_scale.dart:17-20` (class doc only — no behavior change)
- Test: `test/design/ui_scale_test.dart` (new — characterizes the clamp so a later opt-in rollout can't regress it)

**Interfaces:**
- Consumes: `UgamScale.of(BuildContext) → double` (existing, unchanged).
- Produces: nothing new; documentation + regression coverage only.

- [ ] **Step 1: Write the characterization test**

```dart
// test/design/ui_scale_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/ui_scale.dart';

Future<double> _scaleAtWidth(WidgetTester tester, double width) async {
  late double s;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Builder(builder: (context) {
        s = UgamScale.of(context);
        return const SizedBox();
      }),
    ),
  );
  return s;
}

void main() {
  testWidgets('caps at 1.0 at the baseline and on larger screens', (tester) async {
    expect(await _scaleAtWidth(tester, UgamScale.baseline), 1.0);
    expect(await _scaleAtWidth(tester, 800), 1.0);
  });

  testWidgets('floors at 0.85 on the smallest phones', (tester) async {
    expect(await _scaleAtWidth(tester, 300), 0.85);
    expect(await _scaleAtWidth(tester, 200), 0.85);
  });

  testWidgets('scales proportionally between floor and cap', (tester) async {
    // 360 / 390 baseline ≈ 0.9231
    expect(await _scaleAtWidth(tester, 360), closeTo(0.923, 0.001));
  });
}
```

- [ ] **Step 2: Run it (characterization — expected PASS immediately)**

Run: `flutter test test/design/ui_scale_test.dart`
Expected: PASS. This is a characterization/regression test of the existing clamp, not a red-green cycle — it locks the behavior in before we touch the doc and before any future opt-in rollout.

- [ ] **Step 3: Correct the misleading doc contract**

Replace `lib/design/ui_scale.dart:17-20` (the paragraph starting "Text is scaled once…") with an accurate description:

```dart
/// Text is scaled once, app-wide, by feeding this factor into
/// `MediaQuery.textScaler` at the app root (see `MyApp.build`). That is the
/// ONLY place the factor is applied automatically — it scales text everywhere.
///
/// Fixed-pixel chrome does NOT scale automatically. A shared component MAY opt
/// in for its own fixed dimensions by multiplying by [of] —
/// `final s = UgamScale.of(context);` then `54 * s` — as `UgamInput` does.
/// This is deliberately opt-in: most components rely on the app-wide text
/// scaling plus the `_min` floor rather than per-dimension scaling. Do not
/// assume a given widget's paddings/heights track this curve unless it calls
/// [of] itself.
```

- [ ] **Step 4: Run analyzer + the test again**

Run: `flutter analyze lib/design/ui_scale.dart && flutter test test/design/ui_scale_test.dart`
Expected: no new analyzer issues; test still PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/design/ui_scale.dart test/design/ui_scale_test.dart
git commit -m "docs(ui_scale): make the UgamScale opt-in contract honest + lock clamp behavior (X-6)"
```

> **Deferred (YAGNI, documented):** a full `* s` rollout across dock/card/tile chrome is intentionally NOT done here. If small-phone chrome density is later judged too large despite text scaling, revisit by opting the highest-traffic shared components (bottom dock, card paddings) into `* s` one at a time, each with a no-overflow widget test at 320px width — but only if a real device shows the need.

---

## Final verification (run after all tasks)

- [ ] **Full analyzer**

Run: `flutter analyze`
Expected: no new errors; info/warning count no worse than the pre-Phase-3 baseline (6 items per the audit).

- [ ] **Full test suite**

Run: `flutter test`
Expected: all green, including the new tests:
`test/screens/charts_leg_count_test.dart`, `test/screens/bus_status_leg_count_test.dart`, `test/utils/formatters_money_sign_test.dart`, `test/widgets/money_loading_skeleton_test.dart`, `test/screens/past_tour_seat_history_load_test.dart`, `test/components/seat_chart_tile_textscale_test.dart`, `test/components/combined_seat_grid_scroll_test.dart`, `test/utils/attendance_tally_test.dart`, `test/utils/seat_occupants_leg_test.dart`, `test/services/sync_retry_classification_test.dart`, `test/services/sync_paginate_test.dart`, `test/controllers/money_settlement_snapshot_test.dart`, `test/design/ui_scale_test.dart`.

- [ ] **Locale parity spot-check**

Run: `grep -c '"' assets/translations/en.json assets/translations/gu.json assets/translations/hi.json` and confirm the new keys (`att_unmarked`, `att_tally`, `declined_wa_partial`, `decline_wa_failed`) exist in all three.

---

## Self-review notes (coverage of the §4/§6 scope)

- Leg-share overcount: AS-1 (Task 1), AS-2 (Task 2). ✔
- Money display: CALC-2 (Task 3). ✔
- Loading/refresh/staleness: AM-2 (Task 4), AM-3 (Task 5, realtime optional), AM-4 (Task 6). ✔
- Crash/error: AS-3 (Task 7). ✔
- Tile text scaling: AS-4 (Task 8), H-4 (Task 9). ✔
- Fixed-chrome scaling contract: X-6 (Task 21 — contract made honest, clamp regression-guarded, full rollout YAGNI-deferred). ✔
- Attendance UX: H-5 (Task 10), H-6 (Task 11), H-7 (Task 12). ✔
- Leg partitioning: CALC-4 (Task 13). ✔
- Sync hardening: X-3 (Task 14), X-4 (Task 15), X-5 (Task 16). ✔
- Misc: X-7 (Task 17), AL-3 (Task 18), AM-6 (Task 19), AM-5 (Task 20). ✔
- **AL-4 intentionally SKIPPED** — folded into Phase 2's AL-1 date guard.
