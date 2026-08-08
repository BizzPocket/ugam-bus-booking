# Booking Lifecycle Wave A — Admin Move + Money Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After an admin relocates a paid rider (especially Bus1→Bus2 / price-band change), money always rehomes, reprices, and the agent gets clear Collect now / Mark return later / Dismiss actions with a path to the collection screen.

**Architecture:** Keep `CollectionReconciler` as the pure planner. Extend it so same-bus **band** reprices also emit deltas (not only cross-bus). Upgrade `SeatMoveMoneyNotice` with actions that deep-link into `CollectionScreen`. Add short education copy on Booking settings. No schema migration in Wave A.

**Tech Stack:** Flutter, GetX, existing `collections` table, `easy_localization` (en/gu/hi).

**Spec:** `docs/superpowers/specs/2026-08-08-booking-lifecycle-chart-seat-change-design.md` (Wave A only).

## Global Constraints

- Do not rewrite `amount_received` / `amount_refunded` on seat move.
- Do not auto-record refunds.
- Admin seat move stays persisted even if money reconcile fails (best-effort).
- No soft holds, mode-unlock, or customer seat-change in this plan (Waves C/B).
- Translations must land in en.json, gu.json, and hi.json together.

## File map

| File | Responsibility |
|------|----------------|
| `lib/services/collection_reconciler.dart` | Emit deltas for same-bus band reprice; keep cross-bus behavior |
| `test/services/collection_reconciler_test.dart` | Pin ₹1600→₹2000 / →₹1400 and same-bus band delta |
| `lib/widgets/seat_move_money_notice.dart` | Collect now / Mark return later / Dismiss + navigation |
| `lib/screens/collection_screen.dart` | Optional `highlightPassengerId` scroll/highlight |
| `lib/widgets/booking_settings_sheet.dart` | One-line education under mode cards |
| `assets/translations/{en,gu,hi}.json` | New `seat_move_money.*` + `booking_settings.move_money_help` keys |
| `test/widgets/seat_move_money_notice_test.dart` | Widget/action smoke (create if missing) |

---

### Task 1: Reconciler — same-bus band reprice deltas + explicit 1600 cases

**Files:**
- Modify: `lib/services/collection_reconciler.dart`
- Modify: `test/services/collection_reconciler_test.dart`

**Interfaces:**
- Consumes: `CollectionReconciler.plan({tour, passengerIds, collections})`
- Produces: unchanged `CollectionReconcilePlan`; deltas also when `amount_due` changed on a matched/rehomed row even if `bus_id` did not cross (band change). Still skip delta when `due ≈ paid` (square).

- [ ] **Step 1: Write the failing tests**

Add to `test/services/collection_reconciler_test.dart`:

```dart
test('₹1600 bus1 → ₹2000 bus2 collects ₹400', () {
  final busCheap = _bus(id: 'bus1', name: 'Bus 1', row0: 1600, row1: 1600);
  final busDear = _bus(id: 'bus2', name: 'Bus 2', row0: 2000, row1: 2000);
  final p = _rider(
    'p1',
    seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
  );
  final plan = CollectionReconciler.plan(
    tour: _tour(buses: [busCheap, busDear], passengers: [p]),
    passengerIds: const ['p1'],
    collections: [
      _row(
        passengerId: 'p1',
        busId: 'bus1',
        seatId: 'bus1_A',
        due: 1600,
        received: 1600,
      ),
    ],
  );
  expect(plan.updates.single.stillToCollect, 400);
  expect(plan.deltas.single.toCollect, 400);
});

test('₹1600 bus1 → ₹1400 bus2 returns ₹200', () {
  final busA = _bus(id: 'bus1', name: 'Bus 1', row0: 1600, row1: 1600);
  final busB = _bus(id: 'bus2', name: 'Bus 2', row0: 1400, row1: 1400);
  final p = _rider(
    'p1',
    seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
  );
  final plan = CollectionReconciler.plan(
    tour: _tour(buses: [busA, busB], passengers: [p]),
    passengerIds: const ['p1'],
    collections: [
      _row(
        passengerId: 'p1',
        busId: 'bus1',
        seatId: 'bus1_A',
        due: 1600,
        received: 1600,
      ),
    ],
  );
  expect(plan.deltas.single.toReturn, 200);
  expect(plan.updates.single.amountRefunded, 0);
});

test('same-bus move into dearer band emits collect delta', () {
  // bus1: row0 ₹1300, row1 ₹1500. Paid front, moved to rear on SAME bus.
  final p = _rider(
    'p1',
    seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_B')],
  );
  final plan = CollectionReconciler.plan(
    tour: _tour(buses: [bus1, bus2], passengers: [p]),
    passengerIds: const ['p1'],
    collections: [
      _row(
        passengerId: 'p1',
        busId: 'bus1',
        seatId: 'bus1_A',
        due: 1300,
        received: 1300,
      ),
    ],
  );
  expect(plan.updates, isNotEmpty);
  expect(plan.deltas, isNotEmpty);
  expect(plan.deltas.single.toCollect, 200);
});

test('same-bus same-band seat move stays silent (no delta)', () {
  final p = _rider(
    'p1',
    seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_C')],
  );
  // bus1_B and bus1_C are both row1 → ₹1500
  final plan = CollectionReconciler.plan(
    tour: _tour(buses: [bus1, bus2], passengers: [p]),
    passengerIds: const ['p1'],
    collections: [
      _row(
        passengerId: 'p1',
        busId: 'bus1',
        seatId: 'bus1_B',
        due: 1500,
        received: 1500,
      ),
    ],
  );
  expect(plan.deltas, isEmpty);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/services/collection_reconciler_test.dart --name "₹1600|same-bus"`

Expected: FAIL — same-bus dearer band currently returns `deltas` empty because `_planForPassenger` only emits delta when `rehomedFromBus` is non-empty.

- [ ] **Step 3: Implement delta emission for same-bus reprice**

In `lib/services/collection_reconciler.dart` `_planForPassenger`, after computing `updates` / `totalDue` / `paid`:

- Keep emitting delta when `rehomedFromBus.isNotEmpty` (cross-bus).
- Also emit delta when any update changed `amountDue` by more than `Collection.kMoneyEpsilon` **and** `paid` vs `totalDue` is not square — even if buses did not change.
- For same-bus band change, set `fromBusNames` / `toBusNames` to that bus’s name (same list is fine).
- Do not emit when square (`(totalDue - paid).abs() <= epsilon`).

Do not change cash columns.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/services/collection_reconciler_test.dart`

Expected: PASS (including existing cross-bus cases).

- [ ] **Step 5: Commit**

```bash
git add lib/services/collection_reconciler.dart test/services/collection_reconciler_test.dart
git commit -m "$(cat <<'EOF'
fix: surface seat-move money deltas for same-bus band changes

Cross-bus rehome already collected the difference; same-bus upgrades
into a dearer band were silent, so agents missed collect/return.
EOF
)"
```

---

### Task 2: CollectionScreen highlight passenger

**Files:**
- Modify: `lib/screens/collection_screen.dart`
- Test: `test/screens/collection_screen_highlight_test.dart` (create)

**Interfaces:**
- Consumes: existing `CollectionScreen({tour, bus})`
- Produces: `CollectionScreen({tour, bus, highlightPassengerId})` — when set, scroll/filter so that passenger’s row is visible (prefer auto-select filter: to-collect if they owe, to-return if they are owed).

- [ ] **Step 1: Write a failing widget test**

```dart
testWidgets('highlightPassengerId selects to-collect filter when rider owes',
    (tester) async {
  // Build a tour+bus with one passenger stillToCollect > 0 and pump
  // CollectionScreen(..., highlightPassengerId: 'p1').
  // Expect filter chip / visible row for p1 (use key or text finder on name).
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/collection_screen_highlight_test.dart`

Expected: FAIL — constructor has no `highlightPassengerId`.

- [ ] **Step 3: Implement**

Add optional `final String? highlightPassengerId` to `CollectionScreen`.

In `initState` / first frame after lines load:

```dart
if (widget.highlightPassengerId != null) {
  final line = /* find passenger collection line */;
  if (line != null && line.stillToCollect > epsilon) _filter = 2; // To collect
  else if (line != null && line.changeToReturn > epsilon) _filter = 1; // To return
}
```

Use existing list keys / `Scrollable.ensureVisible` if a `GlobalKey` is practical; otherwise filter alone is enough for Wave A.

- [ ] **Step 4: Run test — PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/screens/collection_screen.dart test/screens/collection_screen_highlight_test.dart
git commit -m "$(cat <<'EOF'
feat: allow CollectionScreen to highlight a passenger after seat move

Lets the seat-move money notice deep-link into the right collect/return list.
EOF
)"
```

---

### Task 3: SeatMoveMoneyNotice actions + deep-link

**Files:**
- Modify: `lib/widgets/seat_move_money_notice.dart`
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json`
- Test: `test/widgets/seat_move_money_notice_test.dart` (create)

**Interfaces:**
- Consumes: `List<SeatMoveMoneyDelta>`, `Tour` (need tourId + destination bus ids — extend `show` signature)
- Produces: `SeatMoveMoneyNotice.show(deltas, {required Tour tour})` with actions:
  - **Collect now** → pop dialog, `Get.to(() => CollectionScreen(tour: tour, bus: destBus, highlightPassengerId: firstCollect.id))`
  - **Mark return later** → pop, `AppSnackBar.info` reminding return shows on collection
  - **Dismiss** → pop only

If multiple passengers, Collect now targets the first collect-more delta’s destination bus (`toBusNames` → resolve bus by name, or better: extend `SeatMoveMoneyDelta` with `toBusIds`).

- [ ] **Step 1: Extend SeatMoveMoneyDelta with bus ids (test first)**

In reconciler tests, assert `toBusIds` / `fromBusIds` when present.

Add to `SeatMoveMoneyDelta`:

```dart
final List<String> fromBusIds;
final List<String> toBusIds;
```

Populate in `_planForPassenger`. Keep name lists for copy.

- [ ] **Step 2: Update notice UI + translations**

Keys (en; mirror gu/hi):

```json
"seat_move_money": {
  "title": "Fare changed with the seat",
  "subtitle": "Money already collected stays credited. Settle only the difference at the new price.",
  "action_collect": "Collect now",
  "action_return_later": "Mark return later",
  "action_dismiss": "Dismiss",
  "return_later_toast": "Return due stays on the collection list until you record the handover."
}
```

Replace single OK button with the three actions (show Collect now only if any `isCollectMore`; show Mark return later only if any `isReturnDue`; always show Dismiss).

- [ ] **Step 3: Wire Tour into show() and update call sites**

`TourController._reconcileMoneyAfterMove` already has `tour` — pass it:

```dart
await SeatMoveMoneyNotice.show(deltas, tour: tour);
```

- [ ] **Step 4: Widget test — tapping Collect now navigates**

Pump notice with a fake navigator / GetMaterialApp; tap Collect now; expect `CollectionScreen` pushed (or verify callback if you inject `onCollect` for testability). Prefer injectable callbacks for unit-testability:

```dart
static Future<void> show(
  List<SeatMoveMoneyDelta> deltas, {
  required Tour tour,
  void Function(SeatMoveMoneyDelta d)? onCollectNow,
  VoidCallback? onReturnLater,
})
```

Default implementations navigate / toast; tests pass fakes.

- [ ] **Step 5: Run tests + commit**

```bash
flutter test test/services/collection_reconciler_test.dart test/widgets/seat_move_money_notice_test.dart
git add lib/services/collection_reconciler.dart lib/widgets/seat_move_money_notice.dart lib/controllers/tour_controller.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/widgets/seat_move_money_notice_test.dart
git commit -m "$(cat <<'EOF'
feat: seat-move money notice with collect / return-later actions

Agents can jump straight to collection after a cross-bus or band reprice.
EOF
)"
```

---

### Task 4: Booking settings education line

**Files:**
- Modify: `lib/widgets/booking_settings_sheet.dart`
- Modify: `assets/translations/{en,gu,hi}.json`

**Interfaces:**
- Produces: micro helper under mode cards: `booking_settings.move_money_help`

- [ ] **Step 1: Add copy**

en: `"Moving a paid rider to another bus or price band keeps money already taken and only asks for the difference."`

Mirror gu/hi (accurate localisations, not placeholders).

- [ ] **Step 2: Render under mode cards** (always visible, ink3 micro style — not only when mode locked).

- [ ] **Step 3: Commit**

```bash
git add lib/widgets/booking_settings_sheet.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json
git commit -m "$(cat <<'EOF'
docs(ui): explain seat-move money behaviour on booking settings

Reduces roadside confusion when organisers relocate paid riders.
EOF
)"
```

---

### Task 5: Wave A verification gate

- [ ] **Step 1: Run focused suite**

```bash
flutter test \
  test/services/collection_reconciler_test.dart \
  test/widgets/seat_move_money_notice_test.dart \
  test/screens/collection_screen_highlight_test.dart
```

Expected: all PASS.

- [ ] **Step 2: Manual checklist (record in commit message or PR notes)**

1. Tour with two buses, different bands; collect ₹1600 on Bus1.
2. Relocate rider to dearer Bus2 seat → notice shows collect difference → Collect now opens collection with that passenger.
3. Relocate to cheaper seat → return-due → Mark return later → toast; collection still lists return.
4. Same-bus same-band drag → no dialog.

- [ ] **Step 3: Commit docs status (optional)**

Update spec Wave A status line to “implemented” only after manual checklist passes.

---

## Spec coverage (self-review)

| Spec Wave A requirement | Task |
|-------------------------|------|
| Cash never rewritten | Task 1 (existing invariant + tests) |
| due = live fare; delta = due − paid | Task 1 |
| Same-band silent; cross-bus/band notice | Task 1 + 3 |
| Collect now / Mark return later / Dismiss | Task 3 |
| Deep-link money board/collection | Task 2 + 3 |
| Education copy | Task 4 |
| No auto-refund | Task 1 asserts `amountRefunded == 0` |
| Out of scope holds/mode/customer change | Not in this plan |

## Next plans (not this file)

- Wave C: soft hold 5m + finalize on claim confirm / pay-later + unlock mode switch
- Wave B: customer seat-change request + upgrade/downgrade settlement
