# Requests Screen Density Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the admin Requests list from tall ~210px cards (2-3 per screen) into compact, swipeable, tap-to-expand rows (~8-9 per screen) without losing any info or action.

**Architecture:** `_RequestCard` in `lib/screens/requests_screen.dart` becomes a two-line **collapsed header** (name + time, then `seats · types` + a Material-icon indicator strip) with an **AnimatedSize expand region** (single-open accordion, tracked by `_expandedId` on the parent state) that reveals the phone, note, full chips, and today's `_CardActions` verbatim. Each row is wrapped in the existing `UgamSwipeAction` (right = the state's positive move, left = decline) for a fast path; a small `_RequestActions` helper is extracted so swipe and `_CardActions` share the same action logic (DRY).

**Tech Stack:** Flutter, GetX (`Get.find<TourController>()`), `easy_localization` (`tr()`), the app's `Ugam*` design system + `UgamSwipeAction` (`Dismissible`-based).

## Global Constraints

- **Icons only, never emoji.** All collapsed indicators are Material `Icons.*` glyphs tinted with `UgamColors` tokens. No emoji characters anywhere in code.
- **No new dependencies.** Reuse `UgamSwipeAction` (already in `lib/design/components/ugam_swipe_action.dart`). No `flutter_slidable`.
- **Scope = the list row only.** Do NOT touch the top bar, search, tour pills, `_CapacityBanner`, the 4 status tabs, the sticky Seats CTA (`_AssignmentCTA`), or `_BulkActionBar`.
- **`plural()` is NOT test-safe.** In an uninitialized test harness `'key'.plural(n)` throws `LateInitializationError` (it reads the unset global `_locale`); `tr()` safely returns the key. Therefore the **collapsed** summary line MUST use plain string interpolation (no `plural()`), and any test that **expands** a row MUST seed that passenger with `requestLines: const []` so the plural-bearing seat chips are guarded out.
- **Conditional build, not `Offstage`.** The expand region must be conditionally *built* (`if (expanded)` / ternary to `SizedBox`), never `Offstage`, so `find.byIcon`/`find.text` genuinely can't see expanded-only widgets while collapsed.
- Preserve existing behavior: long-press enters bulk selection; in selection mode tap toggles the checkbox and rows do not expand or swipe.

---

## Task 1: Collapsed row + tap-to-expand accordion

**Files:**
- Modify: `lib/screens/requests_screen.dart`
  - `_RequestsScreenState`: add `_expandedId` field; clear it in the tour-pill `onChanged` (~line 478-486), the tab `onChanged` (~line 499-501), and `_enterSelection` (~line 146-152); pass `expanded` + `onToggleExpand` into `_RequestCard` in the `itemBuilder` (~line 605-613).
  - `_RequestCard` (~line 1210-1589): add two params; restructure `build()` into a collapsed header + `AnimatedSize` expand region; extract `_seatSummary()`, `_phoneRow()`, `_noteBox()`, `_infoChips()`, `_expandedBody()`.
- Test: `test/screens/requests_screen_test.dart` (create)

**Interfaces:**
- Consumes: `TourController` (test double), `Tour`, `Passenger`, `PassengerGroup` models.
- Produces:
  - `_RequestsScreenState._expandedId` : `String?`
  - `_RequestCard({..., required bool expanded, required VoidCallback onToggleExpand})`
  - `_RequestCard._seatSummary()` → `String` (plural-free)
  - `_RequestCard._infoChips(BuildContext)` → `List<Widget>` (holds today's chip list, incl. the `plural()` seat chips)
  - `_RequestCard._expandedBody(BuildContext)` → `Widget`

- [ ] **Step 1: Write the failing test**

Create `test/screens/requests_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/requests_screen.dart';

/// Skip the real network load + realtime wiring.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, {int seats = 30}) => Bus(
      id: id,
      name: id,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

/// A NEW-tab passenger. Empty requestLines by default so expanding it never
/// hits easy_localization's plural() (which throws in the uninitialised test
/// harness). Pass lines explicitly for collapsed-only assertions.
Passenger _newPassenger(
  String id, {
  String name = 'Anjali QA',
  String phone = '+919000000005',
  List<RequestLine> lines = const [],
  String? note,
  String? groupId,
  String? pickupLocationName,
  PriorityStatus priority = PriorityStatus.none,
  TripType tripType = TripType.roundTrip,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: phone,
      requestLines: lines,
      note: note,
      groupId: groupId,
      pickupLocationName: pickupLocationName,
      priorityStatus: priority,
      tripType: tripType,
    );

Tour _tour({required List<Passenger> passengers, List<PassengerGroup> groups = const []}) => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus('b1')],
      passengers: passengers,
      groups: groups,
    );

Widget _harness() => const GetMaterialApp(
      home: RequestsScreen(),
    );

Future<void> _pumpScreen(WidgetTester tester, Tour tour) async {
  final ctrl = _FakeTourController();
  Get.put<TourController>(ctrl);
  ctrl.tours.assignAll([tour]);
  await tester.binding.setSurfaceSize(const Size(1200, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness());
  await tester.pump();
}

void main() {
  tearDown(Get.reset);

  testWidgets('collapsed row shows name + seat summary, hides actions',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1',
            name: 'Anjali QA',
            lines: [RequestLine(seatType: SeatType.seater, qty: 2)]),
      ]),
    );

    // Name is visible collapsed.
    expect(find.text('Anjali QA'), findsOneWidget);
    // Seat summary is plural-free "2 · <type>" — assert on the count prefix.
    expect(find.textContaining('2 ·'), findsOneWidget);
    // Collapsed → the per-card primary action is NOT built yet.
    expect(find.text('requests.action.confirm_and_seat'), findsNothing);
  });

  testWidgets('tapping a row expands it to reveal note + primary action',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA', note: 'qa-note-xyz'),
      ]),
    );

    expect(find.text('requests.action.confirm_and_seat'), findsNothing);
    expect(find.textContaining('qa-note-xyz'), findsNothing);

    await tester.tap(find.text('Anjali QA'));
    await tester.pumpAndSettle();

    // Expanded → note box + New-state primary action are now in the tree.
    expect(find.textContaining('qa-note-xyz'), findsOneWidget);
    expect(find.text('requests.action.confirm_and_seat'), findsOneWidget);
  });

  testWidgets('only one row is expanded at a time', (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA', note: 'note-A'),
        _newPassenger('p2', name: 'Mahesh QA', note: 'note-B'),
      ]),
    );

    await tester.tap(find.text('Anjali QA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('note-A'), findsOneWidget);

    await tester.tap(find.text('Mahesh QA'));
    await tester.pumpAndSettle();
    // Opening the second collapses the first.
    expect(find.textContaining('note-B'), findsOneWidget);
    expect(find.textContaining('note-A'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/requests_screen_test.dart`
Expected: FAIL — `_RequestCard` has no `expanded`/`onToggleExpand` params (compile error), and tapping does not expand.

- [ ] **Step 3: Add `_expandedId` state + wiring in `_RequestsScreenState`**

Add the field near the other state fields (after `_query`, ~line 66):

```dart
  // Which request row is expanded (single-open accordion). Null = all collapsed.
  String? _expandedId;
```

In `_enterSelection` (~line 146), collapse any open row when selection starts:

```dart
  void _enterSelection(String id) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectionMode = true;
      _expandedId = null;
      _selectedIds.add(id);
    });
  }
```

In the tour-pill `onChanged` (~line 478), also clear the open row:

```dart
            onChanged: (i) => setState(() {
              _selectedTourIndex = i;
              _expandedId = null;
              _exitSelection();
            }),
```

In the tab `onChanged` (~line 499):

```dart
            onChanged: (i) =>
                setState(() {
                  _filter = _RequestFilter.values[i];
                  _expandedId = null;
                }),
```

In the `itemBuilder` (~line 605), pass the two new params:

```dart
                      return _RequestCard(
                        passenger: p,
                        tour: selectedTour,
                        c: c,
                        selectionMode: _selectionMode,
                        selected: selected,
                        expanded: _expandedId == p.id,
                        onToggleExpand: () => setState(() {
                          _expandedId = _expandedId == p.id ? null : p.id;
                        }),
                        onLongPress: () => _enterSelection(p.id),
                        onSelectTap: () => _toggleSelect(p.id),
                      );
```

- [ ] **Step 4: Add the two params to `_RequestCard`**

In the field list (~line 1210-1217) add:

```dart
  final bool expanded;
  final VoidCallback onToggleExpand;
```

In the constructor (~line 1219-1227) add:

```dart
    required this.expanded,
    required this.onToggleExpand,
```

- [ ] **Step 5: Add the plural-free summary + expand helpers to `_RequestCard`**

Add these methods inside `_RequestCard` (next to `_timeAgo`):

```dart
  /// Plural-free collapsed summary: "1/2 · Double Sofa + Seater" (or "2 · …").
  /// Uses plain interpolation — NEVER plural() — so it is safe in the test
  /// harness and stays a single scannable line.
  String _seatSummary() {
    if (passenger.requestLines.isEmpty) return '';
    final types = passenger.requestLines.map((l) => l.label).join(' + ');
    final count = passenger.isPartiallyAssigned
        ? '${passenger.totalSeatsAssigned}/${passenger.seatBerths}'
        : '${passenger.seatBerths}';
    return '$count · $types';
  }

  /// Tap-to-call phone shown only in the expanded body.
  Widget _phoneRow(BuildContext context) {
    if (passenger.phone.trim().isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => PhoneDialer.call(passenger.phone),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_rounded, size: 14, color: c.ink2),
            const SizedBox(width: 4),
            Text(
              passenger.phone,
              style: UgamText.caption.copyWith(color: c.ink2, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// The note quote box (moved verbatim from the old build()).
  Widget _noteBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 16, color: c.ink3),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                '"${passenger.note}"',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(
                  color: c.ink2,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The full info-chip list — the EXACT chip set the old card built. Left as a
  /// method so the expanded body renders it in a Wrap. Keep the body identical
  /// to today's inline chip array (the `plural()` seat chips included).
  List<Widget> _infoChips(BuildContext context) {
    final isAssigned = passenger.isFullyAssigned;
    final PassengerGroup? group = passenger.groupId == null
        ? null
        : tour.groups.firstWhereOrNull((g) => g.id == passenger.groupId);
    return <Widget>[
      // >>> MOVE HERE, UNCHANGED: the chip array currently at
      // requests_screen.dart lines ~1408-1516 (from the first
      // `if (passenger.requestLines.isNotEmpty) UgamReqChip(` through the
      // `..._assignedSeatChips(),`). It already references isAssigned + group.
    ];
  }

  /// Everything revealed on tap: phone, chips, note, and today's action row.
  Widget _expandedBody(BuildContext context) {
    final chips = _infoChips(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _phoneRow(context),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.sm),
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            children: chips,
          ),
        ],
        if (passenger.note != null && passenger.note!.isNotEmpty)
          _noteBox(context),
        const SizedBox(height: UgamSpacing.md),
        _CardActions(
          passenger: passenger,
          tour: tour,
          isAssigned: passenger.isFullyAssigned,
          isWaitlisted: passenger.isWaitlisted,
          isConfirmed: passenger.isConfirmed,
          c: c,
        ),
      ],
    );
  }
```

> When moving the chip array into `_infoChips`, delete the old note-box block
> (lines ~1527-1565) and the old `if (!selectionMode) ... _CardActions` block
> (lines ~1566-1576) from `build()` — they now live in `_expandedBody`.

- [ ] **Step 6: Rewrite `_RequestCard.build()` as collapsed header + accordion**

Replace the body of `build()` (the `card` Column and its return) with:

```dart
  @override
  Widget build(BuildContext context) {
    // Selection mode keeps a leading checkbox; normal mode drops the avatar so
    // the name leads the row.
    final Widget? checkbox = selectionMode
        ? Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: selected ? c.accent : c.cardElev,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? c.accent : c.border,
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: selected
                ? Icon(Icons.check_rounded, size: 14, color: c.onAccent)
                : null,
          )
        : null;

    // Attention edge: a pending customer cancellation gets a warm left edge so
    // it pops during a scan.
    final Color edge = passenger.isCancelRequested
        ? c.warm
        : (selected ? c.accent : Colors.transparent);

    final card = AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border(left: BorderSide(color: edge, width: 3)),
      ),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Collapsed header (always shown) ──
            Row(
              children: [
                if (checkbox != null) ...[
                  checkbox,
                  const SizedBox(width: UgamSpacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              passenger.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.titleS
                                  .copyWith(color: c.ink, fontSize: 15),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          Text(
                            _timeAgo(passenger.createdAt),
                            style: UgamText.caption
                                .copyWith(color: c.ink3, fontSize: 12),
                          ),
                        ],
                      ),
                      // Line 2 — seat summary (Task 1) + indicator strip
                      // (added in Task 2). Rendered only when there's content.
                      Builder(builder: (context) {
                        final summary = _seatSummary();
                        if (summary.isEmpty) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: UgamText.caption.copyWith(
                              color: passenger.isPartiallyAssigned
                                  ? c.warm
                                  : c.accent,
                              fontSize: 12,
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
            // ── Expand region (accordion) ──
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              alignment: Alignment.topCenter,
              child: expanded
                  ? _expandedBody(context)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );

    return GestureDetector(
      onLongPress: selectionMode ? null : onLongPress,
      onTap: selectionMode ? onSelectTap : onToggleExpand,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test test/screens/requests_screen_test.dart`
Expected: PASS (3 tests). Then `flutter analyze` — expect no new issues.

- [ ] **Step 8: Commit**

```bash
git add lib/screens/requests_screen.dart test/screens/requests_screen_test.dart
git commit -m "feat(requests): compact rows with tap-to-expand accordion"
```

---

## Task 2: Collapsed indicator icon strip (Material icons only)

**Files:**
- Modify: `lib/screens/requests_screen.dart` — add `_indicatorIcons()` to `_RequestCard`; render it trailing the summary on line 2.
- Test: `test/screens/requests_screen_test.dart` — add the indicator test.

**Interfaces:**
- Consumes: `_RequestCard` from Task 1.
- Produces: `_RequestCard._indicatorIcons(BuildContext)` → `List<Widget>`.

- [ ] **Step 1: Write the failing test**

Append to `test/screens/requests_screen_test.dart` inside `main()`:

```dart
  testWidgets('collapsed row renders Material-icon indicators for flags',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(
        passengers: [
          _newPassenger('p1',
              name: 'Anjali QA',
              lines: [RequestLine(seatType: SeatType.seater, qty: 1)],
              note: 'has-note',
              groupId: 'g1',
              pickupLocationName: 'Raj Hotel',
              priority: PriorityStatus.approved,
              tripType: TripType.outboundOnly),
        ],
        groups: [PassengerGroup(id: 'g1', tourId: 't1', label: 'A', colorIndex: 2)],
      ),
    );

    // Collapsed → indicator icons present, expanded content still absent.
    expect(find.byIcon(Icons.star_rounded), findsOneWidget); // priority
    expect(find.byIcon(Icons.place_outlined), findsOneWidget); // pickup
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget); // note
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget); // outbound one-way
    // Not yet expanded → the action row is not built.
    expect(find.text('requests.action.confirm_and_seat'), findsNothing);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/requests_screen_test.dart -n "Material-icon indicators"`
Expected: FAIL — the indicator icons are not rendered yet.

- [ ] **Step 3: Add `_indicatorIcons()` to `_RequestCard`**

```dart
  /// Small Material-icon strip on the collapsed row's second line. STRICTLY
  /// Icons.* glyphs tinted with tokens — no emoji. One icon per active flag.
  List<Widget> _indicatorIcons(BuildContext context) {
    final PassengerGroup? group = passenger.groupId == null
        ? null
        : tour.groups.firstWhereOrNull((g) => g.id == passenger.groupId);
    final raw = <Widget>[
      if (passenger.isCancelRequested)
        Icon(Icons.event_busy_rounded, size: 14, color: c.warm),
      if (passenger.isPriorityApproved)
        Icon(Icons.star_rounded, size: 14, color: c.warm),
      if (passenger.tripType.isOneWay)
        Icon(
          passenger.tripType == TripType.outboundOnly
              ? Icons.arrow_forward_rounded
              : Icons.arrow_back_rounded,
          size: 14,
          color: c.warm,
        ),
      if (group != null) GroupDot(colorIndex: group.colorIndex, size: 8),
      if (passenger.pickupLocationName != null &&
          passenger.pickupLocationName!.isNotEmpty)
        Icon(Icons.place_outlined, size: 14, color: c.ink3),
      if (passenger.note != null && passenger.note!.isNotEmpty)
        Icon(Icons.chat_bubble_outline_rounded, size: 14, color: c.ink3),
    ];
    return [
      for (final w in raw)
        Padding(padding: const EdgeInsets.only(left: 6), child: w),
    ];
  }
```

`GroupDot` (from `../widgets/group_picker.dart`) is already imported at the top of `requests_screen.dart` (line 29) — no new import needed.

- [ ] **Step 4: Render indicators on line 2**

In `build()`, replace the line-2 `Builder` (from Task 1 Step 6) with a version that trails the indicators after the summary:

```dart
                      Builder(builder: (context) {
                        final summary = _seatSummary();
                        final indicators = _indicatorIcons(context);
                        if (summary.isEmpty && indicators.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  summary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: UgamText.caption.copyWith(
                                    color: passenger.isPartiallyAssigned
                                        ? c.warm
                                        : c.accent,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              ...indicators,
                            ],
                          ),
                        );
                      }),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/screens/requests_screen_test.dart`
Expected: PASS (4 tests). Then `flutter analyze` — no new issues.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/requests_screen.dart test/screens/requests_screen_test.dart
git commit -m "feat(requests): Material-icon indicator strip on collapsed rows"
```

---

## Task 3: Swipe actions (extract `_RequestActions`, wrap rows)

**Files:**
- Modify: `lib/screens/requests_screen.dart`
  - Add a plain `_RequestActions` helper class holding the swipe-relevant action logic (moved from `_CardActions`).
  - Rewire `_CardActions` to delegate those five actions to `_RequestActions` (no behavior change).
  - Wrap each non-selection `_RequestCard` (in the parent `itemBuilder`) in `UgamSwipeAction` with the per-state mapping.
- Test: `test/screens/requests_screen_test.dart` — add swipe-presence tests.

**Interfaces:**
- Consumes: `TourController`, `WhatsAppOutbound`, `WhatsAppService`, `UgamSwipeAction`, `AppRoutes`, `UgamDialog`, `AppSnackBar`.
- Produces:
  - `class _RequestActions { const _RequestActions({required Passenger passenger, required Tour tour}); void openAssignment(); Future<void> confirmAndSeat(); Future<void> sendConfirmationMessage(); Future<void> sendAck(); Future<bool> confirmDecline(BuildContext); Future<bool> approveCancellation(BuildContext); }`
  - Right-swipe fires the state's positive action (snaps back); left-swipe fires `confirmDecline` and removes the row.

- [ ] **Step 1: Write the failing test**

Append to `test/screens/requests_screen_test.dart`:

```dart
  testWidgets('rows are swipeable normally, not in selection mode',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA'),
        _newPassenger('p2', name: 'Mahesh QA'),
      ]),
    );

    // Each visible request row is wrapped in a swipe action (Dismissible).
    expect(find.byType(Dismissible), findsNWidgets(2));

    // Long-press enters bulk selection → swipe wrappers are removed.
    await tester.longPress(find.text('Anjali QA'));
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/requests_screen_test.dart -n "swipeable"`
Expected: FAIL — no `Dismissible` in the tree yet.

- [ ] **Step 3: Add the `_RequestActions` helper class**

Add above `_CardActions` (~line 1660). Move the bodies verbatim from the current
`_CardActions` methods noted in comments:

```dart
/// Shared request-action logic used by BOTH the swipe wrapper (`UgamSwipeAction`
/// in the list) and the expanded `_CardActions` button row, so the two paths
/// never duplicate the confirm / decline / notify flows.
class _RequestActions {
  final Passenger passenger;
  final Tour tour;
  const _RequestActions({required this.passenger, required this.tour});

  TourController get _ctrl => Get.find<TourController>();

  void openAssignment() {
    Get.toNamed(
      AppRoutes.seatAssignment,
      arguments: {'tourId': tour.id, 'passengerId': passenger.id},
    );
  }

  Future<void> confirmAndSeat() async {
    HapticFeedback.lightImpact();
    await _ctrl.setConfirmed(tour.id, passenger.id, true);
    unawaited(sendConfirmationMessage());
  }

  Future<void> sendConfirmationMessage() async {
    // >>> MOVE HERE, UNCHANGED: body of _CardActions._sendConfirmationMessage
    // (requests_screen.dart lines ~1766-1797).
  }

  Future<void> sendAck() async {
    // >>> MOVE HERE, UNCHANGED: body of _CardActions._sendAck
    // (requests_screen.dart lines ~1679-1731).
  }

  /// Returns true if the request was declined (row removed), false if the
  /// organiser cancelled the confirm dialog.
  Future<bool> confirmDecline(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.decline_dialog.title'),
      message: tr(
        'requests.decline_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.decline_dialog.confirm'),
      destructive: true,
      confirmIcon: Icons.close_rounded,
    );
    if (!confirmed) return false;
    await _ctrl.removePassenger(tour.id, passenger.id);
    var waFailed = false;
    try {
      final wa = await WhatsAppOutbound()
          .sendRequestCancelled(tour: tour, passenger: passenger);
      waFailed = !wa.anySent;
    } catch (_) {
      waFailed = true;
    }
    AppSnackBar.success(
      tr('requests.snack.declined_body',
          namedArgs: {'name': passenger.displayName}),
      title: tr('requests.snack.declined_title'),
    );
    if (waFailed) {
      AppSnackBar.warning(
          'Request was cancelled, but WhatsApp notification failed.');
    }
    return true;
  }

  /// Returns true if the cancellation was approved (row removed).
  Future<bool> approveCancellation(BuildContext context) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('requests.approve_cancel_dialog.title'),
      message: tr(
        'requests.approve_cancel_dialog.body',
        namedArgs: {'name': passenger.displayName},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('requests.approve_cancel_dialog.confirm'),
      destructive: true,
      confirmIcon: Icons.check_rounded,
    );
    if (!confirmed) return false;
    await _ctrl.removePassenger(tour.id, passenger.id);
    var waFailed = false;
    try {
      final wa = await WhatsAppOutbound()
          .sendRequestCancelled(tour: tour, passenger: passenger);
      waFailed = !wa.anySent;
    } catch (_) {
      waFailed = true;
    }
    AppSnackBar.success(
      tr('requests.snack.cancel_approved_body',
          namedArgs: {'name': passenger.displayName}),
      title: tr('requests.snack.cancel_approved_title'),
    );
    if (waFailed) {
      AppSnackBar.warning(tr('requests.snack.cancel_approved_wa_failed'));
    }
    return true;
  }
}
```

Then in `_CardActions`, replace the corresponding method bodies with delegations
(keep the method names the widget already calls):

```dart
  _RequestActions get _act =>
      _RequestActions(passenger: passenger, tour: tour);

  void _openAssignment() => _act.openAssignment();
  Future<void> _confirmAndSeat() => _act.confirmAndSeat();
  Future<void> _sendConfirmationMessage() => _act.sendConfirmationMessage();
  Future<void> _sendAck() => _act.sendAck();
  Future<void> _confirmDecline(BuildContext context) =>
      _act.confirmDecline(context);
  Future<void> _approveCancellation(BuildContext context) =>
      _act.approveCancellation(context);
```

> Delete the old full bodies of those six methods in `_CardActions` (they now
> live in `_RequestActions`). Leave every other `_CardActions` method
> (`_toWaitlist`, `_promote`, `_confirm`, `_unconfirm`, `_unassignAll`,
> `_dismissCancellation`, `_openEdit`, `_togglePriority`, `_circleButton`,
> `build`) unchanged. `_confirm()` still calls `_sendConfirmationMessage()`,
> which now delegates — no other change needed.

- [ ] **Step 4: Wrap non-selection rows in `UgamSwipeAction` in the parent**

No new import needed — `UgamSwipeAction` is already exported by the
`../design/ugam.dart` barrel (imported at the top of `requests_screen.dart`).

In the `itemBuilder` (~line 602-614), build the card, then wrap it when not in
selection mode:

```dart
                    itemBuilder: (_, i) {
                      final p = passengers[i];
                      final selected = _selectedIds.contains(p.id);
                      final card = _RequestCard(
                        passenger: p,
                        tour: selectedTour,
                        c: c,
                        selectionMode: _selectionMode,
                        selected: selected,
                        expanded: _expandedId == p.id,
                        onToggleExpand: () => setState(() {
                          _expandedId = _expandedId == p.id ? null : p.id;
                        }),
                        onLongPress: () => _enterSelection(p.id),
                        onSelectTap: () => _toggleSelect(p.id),
                      );
                      if (_selectionMode) return card;
                      return _swipeWrap(selectedTour, p, card);
                    },
```

Add the `_swipeWrap` helper to `_RequestsScreenState`:

```dart
  /// Wrap a request row in the shared swipe affordance. Right swipe = the
  /// state's positive move (snaps back); left swipe = decline (removes the row).
  /// Assigned rows and pending-cancellation rows expose no left (destructive)
  /// swipe — decline is not offered there.
  Widget _swipeWrap(Tour tour, Passenger p, Widget card) {
    final act = _RequestActions(passenger: p, tour: tour);

    // Right-swipe action + icon by state.
    final IconData rightIcon;
    final VoidCallback onRight;
    if (p.isCancelRequested) {
      rightIcon = Icons.event_busy_rounded;
      onRight = () => act.approveCancellation(context);
    } else if (p.isFullyAssigned) {
      rightIcon = Icons.chat_rounded;
      onRight = act.sendAck;
    } else if (p.isConfirmed) {
      rightIcon = Icons.grid_view_rounded;
      onRight = act.openAssignment;
    } else {
      rightIcon = Icons.event_seat_rounded;
      onRight = act.confirmAndSeat;
    }

    // Left (destructive) swipe = decline, only where decline is offered.
    final bool canDecline = !p.isFullyAssigned && !p.isCancelRequested;

    return UgamSwipeAction(
      key: ValueKey('swipe_${p.id}'),
      borderRadius: BorderRadius.circular(UgamRadius.card),
      rightIcon: rightIcon,
      rightColor: c.accent,
      onRight: onRight,
      confirmDelete: canDecline ? () => act.confirmDecline(context) : null,
      // No onDelete work needed — confirmDecline already removes the passenger;
      // the reactive list drops the row on the next Obx rebuild.
      deleteIcon: Icons.close_rounded,
    );
  }
```

> Note: `UgamSwipeAction` requires a non-null `confirmDelete` OR it dismisses on
> any left swipe. When `canDecline` is false we still pass `rightIcon`, so the
> `Dismissible.direction` is `horizontal`; a left swipe with a null
> `confirmDelete` would dismiss the row with no action. To prevent an
> accidental destructive left swipe on Assigned / cancel-pending rows, pass a
> `confirmDelete` that returns `false` there instead of null:

```dart
      confirmDelete: canDecline
          ? () => act.confirmDecline(context)
          : () async => false,
```

Use the `() async => false` form (not null) so Assigned / cancel-pending rows
never dismiss on a left swipe.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/screens/requests_screen_test.dart`
Expected: PASS (5 tests). Then run the full suite to catch regressions from the
`_CardActions` refactor:

Run: `flutter test`
Expected: PASS (no regressions). Then `flutter analyze` — no new issues.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/requests_screen.dart test/screens/requests_screen_test.dart
git commit -m "feat(requests): swipe rows to confirm/assign/notify + decline"
```

---

## Self-Review Notes

- **Spec coverage:** Collapsed 2-line row (Task 1) ✓; Material-icon indicators, no emoji (Task 2) ✓; tap-to-expand single-open accordion (Task 1) ✓; swipe right=positive / left=decline with Assigned/cancel exclusions (Task 3) ✓; selection mode disables swipe + expand (Tasks 1 & 3) ✓; note/chips/`_CardActions` reused verbatim in expand (Task 1) ✓; capacity banner / tabs / sticky CTA untouched ✓.
- **`plural()` guard:** collapsed `_seatSummary()` is interpolation-only; expand tests seed `requestLines: const []`. ✓
- **Type consistency:** `_RequestActions.confirmDecline`/`approveCancellation` return `Future<bool>`; `_CardActions` delegations return `Future<void>` (drop the bool) — intentional and consistent. `_swipeWrap` uses the bool via `confirmDelete`. ✓
- **Manual verification after Task 3:** run the app, open Requests, confirm ~8-9 rows fit, tap expands one at a time, right/left swipe fire the right actions, long-press still enters bulk selection.
