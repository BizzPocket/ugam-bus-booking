# Phase 2 — High-severity correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the five Phase-2 High-severity correctness findings (H-2, H-3, AM-1, AL-1, X-2) so the release has no money double-count, no paid-message re-blast after reload, no invalid tour records, a refreshable handler screen, and a tested write/retry layer.

**Architecture:** Each finding is fixed by pulling its decision logic into a small, pure, unit-testable seam (`lib/utils/*` or `lib/services/sync_retry_policy.dart`) and wiring the existing screen/service to that seam — mirroring how the codebase already extracts test targets (`whatsapp_outbound_decision`, `seat_money_state`). Screen-only concerns that render fine without EasyLocalization/`context.locale` (the handler chart's loading/error states) keep their widget tests; screens whose bodies call `context.locale` (the notify tracker, the tour forms' date preview) are covered through their extracted pure helpers plus a validation-failure widget test that never reaches a `context.locale` code path.

**Tech Stack:** Flutter, GetX, Supabase, easy_localization, flutter_test.

## Global Constraints
- Money formatting always `formatMoneyInr` (₹, en_IN).
- Every user-facing string via `tr()`; keys in en/gu/hi in sync.
- Leg-aware seat counts via `tour.occupiedBerthsFor(busId)`.
- Widget tests calling `plural()` must `Localization.load` a locale in `setUpAll`.
- Dart package import prefix is `package:occubusbooking/...`.
- Tests run with Supabase **uninitialised**: `CustomerRequestsStore` fetches throw, `tr()` returns the raw key, `context.locale` throws unless an EasyLocalization ancestor is present. Design tests around these facts (existing screen tests do).
- Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: H-2 — Handler chart refresh / retry / offline / resume

The handler bus chart (`handler_bus_chart_screen.dart`) loads once in `initState` → `_load()`; the error card is a dead `UgamEmpty` with no retry, offline is indistinguishable from a server error, and mid-shift admin changes never appear. Add pull-to-refresh, a Retry action on the error card, an offline-vs-error distinction, and a re-fetch when the app resumes.

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart` (state fields ~61-67; `initState` :239-248; `_load` :250-299; `_body` :692-720; success `SingleChildScrollView` physics :784; `build` body slot :685)
- Modify: `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json` (add `handler_chart.error_offline_title`, `handler_chart.error_offline`)
- Test: `test/screens/handler_bus_chart_screen_test.dart` (extend existing file)

**Interfaces:**
- Consumes: existing `UgamEmpty.error({Key? key, required VoidCallback onRetry, String? title, String? message})` (adds a `tr('actions.retry')` CTA); `SyncService` (GetxService with `final isOnline = true.obs;`).
- Produces: `_reload()` (`Future<void>`, blanks to skeleton then re-loads), `_offline` bool state; error UI now scrollable + refreshable.

- [ ] **Step 1: Write the failing tests**

Append to `test/screens/handler_bus_chart_screen_test.dart` (keep the two existing tests). Add the SyncService import at the top: `import 'package:occubusbooking/services/sync_service.dart';`

```dart
/// A registrable SyncService whose onInit does no connectivity wiring, so a
/// test can pin isOnline without a live platform channel.
class _FakeSyncService extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

// ... inside main():

testWidgets('error card exposes a Retry action inside a RefreshIndicator',
    (tester) async {
  await tester.pumpWidget(
    GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const HandlerBusChartScreen(requestId: 'req-1'),
    ),
  );
  await tester.pumpAndSettle();

  // Load failed (Supabase uninitialised) → error card with the shared Retry
  // CTA (raw key under test) and a pull-to-refresh wrapper.
  expect(find.text('handler_chart.error_load_title'), findsOneWidget);
  expect(find.text('actions.retry'), findsOneWidget);
  expect(find.byType(RefreshIndicator), findsOneWidget);
});

testWidgets('tapping Retry re-runs the load (skeleton, then error again)',
    (tester) async {
  await tester.pumpWidget(
    GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const HandlerBusChartScreen(requestId: 'req-1'),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('actions.retry'), findsOneWidget);

  await tester.tap(find.text('actions.retry'));
  await tester.pump(); // _reload() sets _loading=true → skeleton, retry gone
  expect(find.text('actions.retry'), findsNothing);

  await tester.pumpAndSettle(); // load fails again → error card returns
  expect(find.text('actions.retry'), findsOneWidget);
});

testWidgets('offline load surfaces the offline copy, not the generic error',
    (tester) async {
  Get.put<SyncService>(_FakeSyncService()..isOnline.value = false);
  await tester.pumpWidget(
    GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const HandlerBusChartScreen(requestId: 'req-1'),
    ),
  );
  await tester.pumpAndSettle();

  expect(find.text('handler_chart.error_offline_title'), findsOneWidget);
  expect(find.text('handler_chart.error_load_title'), findsNothing);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/screens/handler_bus_chart_screen_test.dart`
Expected: the three new tests FAIL — `actions.retry` / `RefreshIndicator` / `error_offline_title` not found (no retry, no refresh wrapper, no offline branch).

- [ ] **Step 3: Add the offline state field + resume observer + `_reload`**

In `_HandlerBusChartScreenState` add `import '../services/sync_service.dart';` at the top of the file, and add the field beside `_error`:

```dart
  bool _loading = true;
  String? _error;
  bool _offline = false;
```

Change the class declaration to observe lifecycle:

```dart
class _HandlerBusChartScreenState extends State<HandlerBusChartScreen>
    with WidgetsBindingObserver {
```

In `initState`, register the observer:

```dart
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Admin changes mid-shift (reassignments, lock/re-notify, recorded
    // handover) land while the handler was in another app — re-pull on resume.
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Retry from the error card: blank back to the skeleton, then re-load.
  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _offline = false;
    });
    await _load();
  }
```

(If the state class already declares `dispose`, merge these lines into it instead of adding a second one.)

- [ ] **Step 4: Clear error on success + classify offline in `_load`'s catch**

In `_load`, inside the success `setState` block, clear the error/offline flags (add these two lines next to `_loading = false;`):

```dart
        _selectedBusId = manifest?.buses.isNotEmpty == true
            ? manifest!.buses.first.id
            : null;
        _error = null;
        _offline = false;
        _loading = false;
      });
```

Replace the `catch` block with an offline-aware one:

```dart
    } catch (_) {
      if (!mounted) return;
      final offline = Get.isRegistered<SyncService>() &&
          !Get.find<SyncService>().isOnline.value;
      setState(() {
        _offline = offline;
        _error = offline
            ? tr('handler_chart.error_offline')
            : tr('handler_chart.error_load');
        _loading = false;
      });
    }
```

- [ ] **Step 5: Make the error/empty states refreshable and add the Retry card; wrap `_body` in a RefreshIndicator**

In `_body`, replace the `_error != null` branch (the `Center(child: Padding(child: UgamEmpty(...)))` at :696-707) with a refreshable error card:

```dart
    if (_error != null) {
      return _refreshableMessage(
        UgamEmpty.error(
          onRetry: _reload,
          title: _offline
              ? tr('handler_chart.error_offline_title')
              : tr('handler_chart.error_load_title'),
          message: _error,
        ),
      );
    }
```

Replace the empty (`manifest == null || buses.isEmpty`) `Center(...)` at :709-720 with `return _refreshableMessage(UgamEmpty(icon: Icons.event_seat_outlined, title: tr('handler_chart.no_bus_chart_title'), body: tr('handler_chart.no_bus_chart_body')));`.

Add this helper method to the state class:

```dart
  /// A single centred message rendered inside an always-scrollable list so the
  /// parent RefreshIndicator's pull gesture works even when there's no content.
  Widget _refreshableMessage(Widget child) => LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(UgamSpacing.lg),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      );
```

In the success branch, change the body `SingleChildScrollView`'s physics (:784) so pull-to-refresh triggers over content too:

```dart
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
```

Finally, in `build`, wrap the body slot (`Expanded(child: _body(c))`, :685) with a RefreshIndicator:

```dart
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: _body(c),
              ),
            ),
```

- [ ] **Step 6: Add the two new translation keys (en, gu, hi)**

In each of the three files, inside the `"handler_chart"` object, add beside `error_load` / `error_load_title`:

`en.json`:
```json
    "error_offline_title": "You're offline",
    "error_offline": "Check your connection, then pull to refresh.",
```
`gu.json`:
```json
    "error_offline_title": "તમે ઑફલાઇન છો",
    "error_offline": "તમારું કનેક્શન તપાસો, પછી રિફ્રેશ કરવા ખેંચો.",
```
`hi.json`:
```json
    "error_offline_title": "आप ऑफ़लाइन हैं",
    "error_offline": "अपना कनेक्शन जांचें, फिर रिफ़्रेश करने के लिए खींचें।",
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/screens/handler_bus_chart_screen_test.dart`
Expected: PASS — the two original tests plus the three new ones (Retry + RefreshIndicator, retry re-runs load, offline copy).

- [ ] **Step 8: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/screens/handler_bus_chart_screen_test.dart
git commit -m "fix(handler): pull-to-refresh, retry, offline distinction & resume re-fetch on bus chart (H-2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: H-3 — Seat-agnostic collection lookup (no duplicate collection row after a seat change)

`_collectionFor(passengerId, busId, seatId)` is seat-keyed. A paid rider who changes seats keeps their collection row on the OLD seat; tapping the NEW seat resolves `existing == null`, so `_showOccupantSheet` creates a SECOND `Collection` (new id) → both rows sit in `_collections.values` → `_summaryForBus` / `BusMoneySummary.compute` (`money_summary.dart:121`) sums both and double-counts the cash. Fix: resolve the existing collection by **passenger + bus** (seat-agnostic), reuse its id, rewrite `seat_id` on save, and de-dupe the cache so exactly one row per passenger-per-bus survives.

**Files:**
- Create: `lib/utils/handler_collection_resolver.dart`
- Modify: `lib/screens/handler_bus_chart_screen.dart` (`_collectionKey` :96-97; `_showOccupantSheet` existing-lookup :354 and save-cache `setState` :403-410)
- Test: `test/utils/handler_collection_resolver_test.dart`

**Interfaces:**
- Consumes: `Collection` (fields `id`, `passengerId`, `busId`, `seatId`; `copyWith({String? seatId, ...})` reuses `id`) from `lib/models/collection.dart`.
- Produces:
  - `String handlerCollectionKey(String passengerId, String busId, String seatId)` → `'$passengerId|$busId|$seatId'`.
  - `Collection? resolveHandlerCollection(Iterable<Collection> collections, {required String passengerId, required String busId})` — first row matching passenger+bus, ignoring seat.
  - `void cacheHandlerCollection(Map<String, Collection> cache, Collection saved)` — drops any prior row for the same passenger+bus, then inserts under the seat-keyed key.

- [ ] **Step 1: Write the failing test**

`test/utils/handler_collection_resolver_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/utils/handler_collection_resolver.dart';

void main() {
  Collection col(String passengerId, String seatId,
          {String? id, double received = 100}) =>
      Collection(
        id: id,
        tourId: 't1',
        busId: 'b1',
        passengerId: passengerId,
        seatId: seatId,
        amountDue: received,
        amountReceived: received,
      );

  test('resolveHandlerCollection matches on passenger+bus, ignoring seat', () {
    final rows = [col('p1', 'A1'), col('p2', 'A2')];
    final found =
        resolveHandlerCollection(rows, passengerId: 'p1', busId: 'b1');
    expect(found, isNotNull);
    expect(found!.passengerId, 'p1');
    // Wrong bus → no match.
    expect(resolveHandlerCollection(rows, passengerId: 'p1', busId: 'bX'),
        isNull);
    expect(resolveHandlerCollection(rows, passengerId: 'pZ', busId: 'b1'),
        isNull);
  });

  test('cacheHandlerCollection keeps ONE row per passenger+bus after a seat '
      'change (no double-count)', () {
    final original = col('p1', 'A1', id: 'fixed-id');
    final cache = <String, Collection>{
      handlerCollectionKey('p1', 'b1', 'A1'): original,
    };

    // Rider moves A1 -> A2: same collection id, seat_id rewritten on save.
    final movedSaved = original.copyWith(seatId: 'A2');
    cacheHandlerCollection(cache, movedSaved);

    expect(cache.length, 1, reason: 'stale old-seat row must be dropped');
    final only = cache.values.single;
    expect(only.id, 'fixed-id');
    expect(only.seatId, 'A2');
    // Summing values gives the cash once, not twice.
    final total =
        cache.values.fold<double>(0, (s, c) => s + c.netCollected);
    expect(total, 100);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/utils/handler_collection_resolver_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'handler_collection_resolver.dart'` / undefined functions.

- [ ] **Step 3: Write the resolver**

`lib/utils/handler_collection_resolver.dart`:

```dart
import '../models/collection.dart';

/// Cache key for a handler collection row. Seat-scoped so the seat grid's
/// per-tile money dot can look a row up by its current seat.
String handlerCollectionKey(String passengerId, String busId, String seatId) =>
    '$passengerId|$busId|$seatId';

/// First collection for [passengerId] on [busId], **ignoring the seat**. A paid
/// rider who changed seats keeps their single row (its `seat_id` is rewritten on
/// save) instead of spawning a duplicate on the new seat — which would let
/// `BusMoneySummary.compute` count their cash twice.
Collection? resolveHandlerCollection(
  Iterable<Collection> collections, {
  required String passengerId,
  required String busId,
}) {
  for (final c in collections) {
    if (c.passengerId == passengerId && c.busId == busId) return c;
  }
  return null;
}

/// Upsert [saved] into [cache]: drop any prior row for the same passenger+bus
/// (e.g. the stale old-seat entry) so the map holds exactly one row per
/// passenger-per-bus, then insert under its current seat key.
void cacheHandlerCollection(Map<String, Collection> cache, Collection saved) {
  cache.removeWhere(
    (_, c) => c.passengerId == saved.passengerId && c.busId == saved.busId,
  );
  cache[handlerCollectionKey(saved.passengerId, saved.busId, saved.seatId)] =
      saved;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/utils/handler_collection_resolver_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the screen to the resolver**

In `lib/screens/handler_bus_chart_screen.dart` add `import '../utils/handler_collection_resolver.dart';`.

Make `_collectionKey` delegate (single definition of the key format):

```dart
  String _collectionKey(String passengerId, String busId, String seatId) =>
      handlerCollectionKey(passengerId, busId, seatId);
```

Add a seat-agnostic resolver method next to `_collectionFor`:

```dart
  /// Seat-agnostic: the collection this passenger has on this bus regardless of
  /// which seat it was first taken on. Prevents a duplicate row (double-counted
  /// cash) when a paid rider changes seats. Cache first, then the manifest.
  Collection? _collectionForPassenger(String passengerId, String busId) {
    final cached = resolveHandlerCollection(
      _collections.values,
      passengerId: passengerId,
      busId: busId,
    );
    if (cached != null) return cached;
    return resolveHandlerCollection(
      _manifest?.collections ?? const <Collection>[],
      passengerId: passengerId,
      busId: busId,
    );
  }
```

In `_showOccupantSheet`, change the existing-lookup (:354) from seat-keyed to seat-agnostic:

```dart
    final existing = _collectionForPassenger(passenger.id, bus.id);
```

In the same method's save-cache `setState` (:403-410), replace the manual map write with the de-duping upsert:

```dart
          if (!mounted) return;
          setState(() => cacheHandlerCollection(_collections, saved));
```

(Leave the per-tile seat-keyed `_collectionFor` at :118 unchanged — after this fix each rider has exactly one row on their current seat, so the tile's money dot still resolves.)

- [ ] **Step 6: Run the analyzer + full model/util suites to confirm no regression**

Run: `flutter analyze lib/screens/handler_bus_chart_screen.dart lib/utils/handler_collection_resolver.dart`
Expected: no new errors.
Run: `flutter test test/utils/handler_collection_resolver_test.dart test/models/money_summary_test.dart test/models/handler_bus_money_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/utils/handler_collection_resolver.dart lib/screens/handler_bus_chart_screen.dart test/utils/handler_collection_resolver_test.dart
git commit -m "fix(handler): resolve collection by passenger+bus so a seat change never duplicates cash (H-3)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: AM-1 — Notify tracker derives from persisted `seatsChangedSinceNotified`, not session `_sentIds`

The tracker's progress bar, filter counts, and per-row "Sent/Pending" badges all read the session-only `_sentIds` set (empty after any reload / tour-switch / restart), so after a reload every rider shows "Pending" / 0-sent — inviting the operator to re-broadcast the paid WhatsApp. The CTA already reads the persisted `Passenger.seatsChangedSinceNotified` (`notify_screen.dart:222`). Move all display derivations onto that same persisted flag via a pure helper, and delete the now-meaningless session tracker.

**Files:**
- Create: `lib/utils/notify_progress.dart`
- Modify: `lib/screens/notify_screen.dart` (`_sentIds` field :41-42; `_resetSent` :77; reset app-bar action :138-143; tour-selector `_sentIds.clear()` :173; counts :124-127; filter :277-279; row `isSent` :337; dispatch `setState(_sentIds.addAll)` :576)
- Test: `test/utils/notify_progress_test.dart`

**Interfaces:**
- Consumes: `Passenger.seatsChangedSinceNotified` (`bool` getter: `assignedSeats.isNotEmpty && seatsNotifiedSig != seatSignature`).
- Produces:
  - `bool isNotified(Passenger p)` → `!p.seatsChangedSinceNotified`.
  - `int notifiedCount(Iterable<Passenger> assigned)` → `assigned.where(isNotified).length`.

- [ ] **Step 1: Write the failing test**

`test/utils/notify_progress_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/utils/notify_progress.dart';

void main() {
  Passenger seated(String id, {required bool notified, String seat = 'A1'}) {
    final base = Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seat)],
    );
    // Notified == the persisted signature equals the current seat signature.
    return notified ? base.copyWith(seatsNotifiedSig: base.seatSignature) : base;
  }

  test('isNotified is true only when current seats were already notified', () {
    expect(isNotified(seated('p1', notified: true)), isTrue);
    expect(isNotified(seated('p2', notified: false)), isFalse);
  });

  test('a seat edit after notify flips isNotified back to false', () {
    final p = seated('p3', notified: true, seat: 'A1')
        .copyWith(seatsNotifiedSig: 'b1:STALE');
    expect(isNotified(p), isFalse);
  });

  test('notifiedCount counts only persisted-notified riders', () {
    final list = [
      seated('p1', notified: true, seat: 'A1'),
      seated('p2', notified: false, seat: 'A2'),
      seated('p3', notified: false, seat: 'A3'),
    ];
    expect(notifiedCount(list), 1);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/utils/notify_progress_test.dart`
Expected: FAIL — `notify_progress.dart` / `isNotified` / `notifiedCount` undefined.

- [ ] **Step 3: Write the helper**

`lib/utils/notify_progress.dart`:

```dart
import '../models/passenger.dart';

/// A seated rider is "notified" iff their CURRENT seat allocation has already
/// been sent — i.e. the PERSISTED [Passenger.seatsChangedSinceNotified] is
/// false. Deriving from persisted state means the tracker survives a reload /
/// tour-switch / restart, unlike the old session-only `_sentIds` set that reset
/// to empty and made every rider read "Pending" (re-blasting paid WhatsApps).
bool isNotified(Passenger p) => !p.seatsChangedSinceNotified;

/// How many of [assigned] have had their current seats notified.
int notifiedCount(Iterable<Passenger> assigned) =>
    assigned.where(isNotified).length;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/utils/notify_progress_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the notify screen to the helper; delete the session tracker**

In `lib/screens/notify_screen.dart` add `import '../utils/notify_progress.dart';`.

Delete the session-only tracker plumbing:
- Remove the field + comment at :41-42 (`final Set<String> _sentIds = <String>{};`).
- Remove `void _resetSent() => setState(_sentIds.clear);` (:77).
- Remove the reset app-bar action block (:138-143):
  ```dart
                  if (isLocked && _sentIds.isNotEmpty)
                    UgamAppBarAction(
                      icon: Icons.refresh_rounded,
                      onTap: _resetSent,
                      tooltip: tr('notify.reset_sent'),
                    ),
  ```
- In the tour-selector `onSelect` (:171-175), remove the `_sentIds.clear();` line (keep `_selectedTourId = id;` and `_filter = _NotifyFilter.all;`).

Replace the counts (:124-127):

```dart
          final sentCount = notifiedCount(assigned);
          final pendingCount = assigned.length - sentCount;
```

Replace the filter derivations (:277-279):

```dart
      _NotifyFilter.pending =>
        assigned.where((p) => !isNotified(p)).toList(),
      _NotifyFilter.notified =>
        assigned.where(isNotified).toList(),
```

Replace the row `isSent` (:337):

```dart
              isSent: isNotified(filtered[i]),
```

In `_dispatchSeatAllocations`, replace the session-set write (:576) — the persisted flip already happens via `markSeatsNotified` (:580), which optimistically updates the reactive `tours` list so the outer `Obx` rebuilds the derived state:

```dart
    if (justSent.isNotEmpty) {
      if (mounted) setState(() {});
      unawaited(
        Get.find<TourController>().markSeatsNotified(t.id, justSent),
      );
    }
```

- [ ] **Step 6: Run the analyzer to confirm no dangling `_sentIds` references**

Run: `flutter analyze lib/screens/notify_screen.dart`
Expected: no errors, no "unused" / "undefined `_sentIds`" diagnostics. (If `tr('notify.reset_sent')` is now unreferenced that is fine — orphan translation keys are harmless; do NOT delete other keys.)

- [ ] **Step 7: Commit**

```bash
git add lib/utils/notify_progress.dart lib/screens/notify_screen.dart test/utils/notify_progress_test.dart
git commit -m "fix(notify): derive Sent/Pending from persisted seatsChangedSinceNotified so a reload no longer re-blasts paid riders (AM-1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: AL-1 (a) — Give `UgamInput` a real `validator` (TextFormField)

`UgamInput` wraps a plain `TextField`, so it is not a `FormField`; the create/edit tour screens call `_formKey.currentState!.validate()` but it always returns `true` (no FormField descendants) → a tour saves with empty title/from/to. Root-cause fix: convert `UgamInput`'s internal field to `TextFormField` and expose an optional `validator`, so an enclosing `Form`'s `validate()` actually collects it. (`TextFormField` builds a `TextField` internally, so the existing `ugam_input_test` `find.byType(TextField)` assertions keep working.)

**Files:**
- Modify: `lib/design/components/ugam_input.dart` (field list :13-34; constructor :35-57; internal `TextField` :98-124)
- Test: `test/design/ugam_input_test.dart` (extend existing file)

**Interfaces:**
- Produces: `UgamInput({..., FormFieldValidator<String>? validator})`. When `validator != null`, the field runs `AutovalidateMode.onUserInteraction` and participates in `Form.validate()`. `onSubmitted` is forwarded via `TextFormField.onFieldSubmitted`.

- [ ] **Step 1: Write the failing test**

Append to `test/design/ugam_input_test.dart`:

```dart
  testWidgets('validator surfaces its error after Form.validate()',
      (tester) async {
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(host(
      Form(
        key: formKey,
        child: UgamInput(
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'field-required' : null,
        ),
      ),
    ));

    // Nothing shown until validate() runs.
    expect(find.text('field-required'), findsNothing);

    formKey.currentState!.validate();
    await tester.pump();

    expect(find.text('field-required'), findsOneWidget);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/design/ugam_input_test.dart`
Expected: FAIL — `No named parameter with the name 'validator'` (compile error).

- [ ] **Step 3: Add `validator` and switch to `TextFormField`**

In `lib/design/components/ugam_input.dart` add the field (next to `errorText`):

```dart
  final String? errorText;
  final FormFieldValidator<String>? validator;
```

Add the constructor parameter (next to `this.errorText,`):

```dart
    this.errorText,
    this.validator,
```

Replace the `TextField(...)` in `build` (:98-124) with a `TextFormField`:

```dart
        TextFormField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          obscureText: _obscured,
          autofillHints: widget.autofillHints,
          autofocus: widget.autofocus,
          maxLength: widget.maxLength,
          maxLines: _obscured ? 1 : widget.maxLines,
          minLines: widget.minLines,
          onChanged: widget.onChanged,
          onFieldSubmitted: widget.onSubmitted,
          readOnly: widget.readOnly,
          enabled: widget.enabled,
          validator: widget.validator,
          autovalidateMode: widget.validator == null
              ? AutovalidateMode.disabled
              : AutovalidateMode.onUserInteraction,
          style: UgamText.body.copyWith(
            color: widget.enabled ? c.ink : c.ink3,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: widget.errorText,
            counterText: '',
            prefixIcon: widget.prefix,
            suffixIcon: suffix,
          ),
        ),
```

- [ ] **Step 4: Run the test to verify it passes (and the file's older tests still pass)**

Run: `flutter test test/design/ugam_input_test.dart`
Expected: PASS — the new validator test plus the three existing tests (`obscureToggle`, no-toggle, `autofillHints`) all green (`find.byType(TextField)` still resolves the `TextFormField`'s internal field).

- [ ] **Step 5: Commit**

```bash
git add lib/design/components/ugam_input.dart test/design/ugam_input_test.dart
git commit -m "feat(ugam-input): TextFormField + optional validator so Form.validate() works (AL-1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: AL-1 (b) — Enforce validation in Create/Edit tour (non-empty title/from/to; return ≥ departure)

With `UgamInput.validator` available (Task 4), attach non-empty validators to title/from/to in both tour forms so `_formKey.currentState!.validate()` blocks an empty save, and add a pure `returnBeforeDeparture` guard (unit-tested) that both `_submit`/`_save` call before hitting the controller, plus mirror edit-tour's departure-moved reset into create-tour.

**Files:**
- Create: `lib/utils/tour_form_validators.dart`
- Modify: `lib/screens/create_tour_screen.dart` (`_pickDate` departure branch :97-106; `_submit` :126-135; the 5 title/from/to `UgamInput`s :246-250, :258-261, :280-283, :288-291, :311-314)
- Modify: `lib/screens/edit_tour_screen.dart` (`_save` :178-184; title/from/to `UgamInput`s :446-448, :457, :476, :480, :498)
- Modify: `assets/translations/en.json`, `gu.json`, `hi.json` (add `create_tour.validation.{title_required,from_required,to_required,return_before_departure}` and `edit_tour.{error_title_required,error_from_required,error_to_required,error_return_before_departure}`)
- Test: `test/utils/tour_form_validators_test.dart`, `test/screens/create_tour_validation_test.dart`

**Interfaces:**
- Consumes: `UgamInput(validator:)` (Task 4); `TourController.createTour({required String title, required String fromCity, required String toCity, required DateTime departureDate, String? departureTime, DateTime? returnDate, String? returnTime, double pricePerSeat = 0, String? description, String? broadcastMessage, String? broadcastImageUrl}) → Future<Tour>`.
- Produces: `bool returnBeforeDeparture(DateTime? departure, DateTime? returnDate)`.

- [ ] **Step 1: Write the failing pure-helper test**

`test/utils/tour_form_validators_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/tour_form_validators.dart';

void main() {
  test('returnBeforeDeparture only when both set and return precedes depart',
      () {
    final d = DateTime(2026, 7, 10);
    expect(returnBeforeDeparture(d, DateTime(2026, 7, 9)), isTrue);
    expect(returnBeforeDeparture(d, DateTime(2026, 7, 10)), isFalse);
    expect(returnBeforeDeparture(d, DateTime(2026, 7, 12)), isFalse);
    expect(returnBeforeDeparture(d, null), isFalse);
    expect(returnBeforeDeparture(null, DateTime(2026, 7, 9)), isFalse);
    expect(returnBeforeDeparture(null, null), isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/utils/tour_form_validators_test.dart`
Expected: FAIL — `tour_form_validators.dart` / `returnBeforeDeparture` undefined.

- [ ] **Step 3: Write the helper**

`lib/utils/tour_form_validators.dart`:

```dart
/// True when a return date is set and falls before the departure date — an
/// invalid tour window. Create/Edit tour call this before persisting; each maps
/// the result to its own localized error string.
bool returnBeforeDeparture(DateTime? departure, DateTime? returnDate) =>
    departure != null &&
    returnDate != null &&
    returnDate.isBefore(departure);
```

- [ ] **Step 4: Run it to verify it passes**

Run: `flutter test test/utils/tour_form_validators_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the translation keys (en, gu, hi)**

`en.json` — inside `"create_tour"` → `"validation"` (currently `invalid_amount`, `select_start_date`), add:
```json
      "title_required": "Enter a tour name",
      "from_required": "Enter the starting city",
      "to_required": "Enter the destination city",
      "return_before_departure": "Return date can't be before the departure date"
```
`en.json` — inside `"edit_tour"` (flat `error_*` keys), add:
```json
    "error_title_required": "Enter a tour name",
    "error_from_required": "Enter the starting city",
    "error_to_required": "Enter the destination city",
    "error_return_before_departure": "Return date can't be before the departure date",
```
`gu.json` — same key paths:
```json
      "title_required": "પ્રવાસનું નામ દાખલ કરો",
      "from_required": "શરૂઆતનું શહેર દાખલ કરો",
      "to_required": "ગંતવ્ય શહેર દાખલ કરો",
      "return_before_departure": "વળતરની તારીખ પ્રસ્થાનની તારીખ પહેલાં ન હોઈ શકે"
```
```json
    "error_title_required": "પ્રવાસનું નામ દાખલ કરો",
    "error_from_required": "શરૂઆતનું શહેર દાખલ કરો",
    "error_to_required": "ગંતવ્ય શહેર દાખલ કરો",
    "error_return_before_departure": "વળતરની તારીખ પ્રસ્થાનની તારીખ પહેલાં ન હોઈ શકે",
```
`hi.json` — same key paths:
```json
      "title_required": "यात्रा का नाम दर्ज करें",
      "from_required": "प्रस्थान शहर दर्ज करें",
      "to_required": "गंतव्य शहर दर्ज करें",
      "return_before_departure": "वापसी की तारीख प्रस्थान की तारीख से पहले नहीं हो सकती"
```
```json
    "error_title_required": "यात्रा का नाम दर्ज करें",
    "error_from_required": "प्रस्थान शहर दर्ज करें",
    "error_to_required": "गंतव्य शहर दर्ज करें",
    "error_return_before_departure": "वापसी की तारीख प्रस्थान की तारीख से पहले नहीं हो सकती",
```

- [ ] **Step 6: Wire validators + guards into create_tour_screen.dart**

Add `import '../utils/tour_form_validators.dart';`.

Attach a validator to each title/from/to `UgamInput`. Title (:246-250):
```dart
                    UgamInput(
                      label: tr('create_tour.label.tour_name'),
                      hint: tr('create_tour.hint.tour_name'),
                      controller: _titleCtrl,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? tr('create_tour.validation.title_required')
                          : null,
                    ),
```
Both `from` inputs (:258-261 narrow, :288-291 wide) get:
```dart
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? tr('create_tour.validation.from_required')
                          : null,
```
Both `to` inputs (:280-283 narrow, :311-314 wide) get:
```dart
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? tr('create_tour.validation.to_required')
                          : null,
```

In `_submit` (:126-135), add the date-order guard after the `_departureDate == null` check and before `setState(() => _saving = true);`:
```dart
    if (returnBeforeDeparture(_departureDate, _returnDate)) {
      setState(() =>
          _dateError = tr('create_tour.validation.return_before_departure'));
      return;
    }
```

In `_pickDate` (:97-106), mirror edit-tour's reset so a departure moved past an existing return clears that return:
```dart
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnDate = picked;
        } else {
          _departureDate = picked;
          _dateError = null;
          if (_returnDate != null && _returnDate!.isBefore(picked)) {
            _returnDate = null;
            _returnTime = null;
          }
        }
      });
    }
```

- [ ] **Step 7: Wire validators + guard into edit_tour_screen.dart**

Add `import '../utils/tour_form_validators.dart';`.

Attach validators: title `UgamInput` (:446-448) → `validator: (v) => (v == null || v.trim().isEmpty) ? tr('edit_tour.error_title_required') : null,`; the `from` inputs (:457 narrow, :480 wide) → `tr('edit_tour.error_from_required')`; the `to` inputs (:476 narrow, :498 wide) → `tr('edit_tour.error_to_required')`.

In `_save` (:178-184), add the guard after the `_departureDate == null` check and before `setState(() => _saving = true);`:
```dart
    if (returnBeforeDeparture(_departureDate, _returnDate)) {
      setState(() =>
          _dateError = tr('edit_tour.error_return_before_departure'));
      return;
    }
```
(edit-tour already resets `_returnDate` in `_pickDate` :152-155, so no picker change here. If `_dateError` is not yet a field/rendered in edit-tour, add `String? _dateError;` beside the other state fields and render it near the date pickers exactly as create-tour does at :388-394.)

- [ ] **Step 8: Write the failing create-tour validation widget test**

`test/screens/create_tour_validation_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/create_tour_screen.dart';

/// No network: onInit is a no-op and createTour just records the call.
class _FakeTourController extends TourController {
  int createCalls = 0;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<Tour> createTour({
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    double pricePerSeat = 0,
    String? description,
    String? broadcastMessage,
    String? broadcastImageUrl,
  }) async {
    createCalls++;
    return Tour(
      title: title,
      fromCity: fromCity,
      toCity: toCity,
      departureDate: departureDate,
      pricePerSeat: pricePerSeat,
    );
  }
}

void main() {
  tearDown(Get.reset);

  testWidgets('empty create form blocks save and shows the title error',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const CreateTourScreen(),
      ),
    );
    await tester.pump();

    // Tap the sticky Create CTA (raw key label under test) with all fields empty.
    await tester.tap(find.text('create_tour.action.create_broadcast'));
    await tester.pump();

    expect(ctrl.createCalls, 0, reason: 'validation must block the save');
    expect(find.text('create_tour.validation.title_required'), findsOneWidget);
  });
}
```

- [ ] **Step 9: Run both new tests to verify they fail, then pass**

Run: `flutter test test/screens/create_tour_validation_test.dart`
Expected before wiring: FAIL (createCalls == 1 / error not shown). After Steps 6-7 are in place: re-run
Run: `flutter test test/utils/tour_form_validators_test.dart test/screens/create_tour_validation_test.dart`
Expected: PASS.

- [ ] **Step 10: Analyze and commit**

Run: `flutter analyze lib/screens/create_tour_screen.dart lib/screens/edit_tour_screen.dart lib/utils/tour_form_validators.dart`
Expected: no errors.

```bash
git add lib/utils/tour_form_validators.dart lib/screens/create_tour_screen.dart lib/screens/edit_tour_screen.dart assets/translations/en.json assets/translations/gu.json assets/translations/hi.json test/utils/tour_form_validators_test.dart test/screens/create_tour_validation_test.dart
git commit -m "fix(tours): validate non-empty title/from/to + return>=departure on create/edit (AL-1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: X-2 — Extract the sync retry/conflict policy into a pure seam and test it

`sync_service.dart`'s resilience decisions (`_isRetryable`, `_looksLikeTransport`, `_isPreSendConnectionError`, and the insert-conflict 23505 branch in `_writeToServer`) are pure logic entangled in a GetxService that needs a live Supabase client — untestable as-is. Extract them into `lib/services/sync_retry_policy.dart`, have `SyncService` delegate, and unit-test: retryable vs non-retryable classification, the insert-conflict fallback decision, and the swap pre-send predicate.

**Files:**
- Create: `lib/services/sync_retry_policy.dart`
- Modify: `lib/services/sync_service.dart` (`_writeToServer` insert branch :448-468; `_withRetry` default predicate :508-509; `swapPassengerSeats` predicate arg :370; delete/thin `_isRetryable` :537-584, `_looksLikeTransport` :587-602, `_isPreSendConnectionError` :609-616)
- Test: `test/services/sync_service_test.dart`

**Interfaces:**
- Consumes: `RpcUnavailableException` (from `sync_service.dart`), `PostgrestException` / `AuthException` (supabase_flutter), `TimeoutException` (dart:async), `SocketException` / `HttpException` (dart:io).
- Produces (all top-level, pure):
  - `bool isRetryable(Object e, {required bool retryOnTimeout})`
  - `bool looksLikeTransport(String message)`
  - `bool isPreSendConnectionError(Object e)`
  - `enum InsertConflictAction { rethrowError, updateById }`
  - `InsertConflictAction resolveInsertConflict({required String? code, required bool rowWithIdExists})`

- [ ] **Step 1: Write the failing test**

`test/services/sync_service_test.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_retry_policy.dart';
import 'package:occubusbooking/services/sync_service.dart' show RpcUnavailableException;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('isRetryable', () {
    test('missing RPC is terminal', () {
      expect(isRetryable(RpcUnavailableException('fn'), retryOnTimeout: true),
          isFalse);
    });

    test('timeout is retryable only for idempotent callers', () {
      final e = TimeoutException('slow');
      expect(isRetryable(e, retryOnTimeout: true), isTrue);
      expect(isRetryable(e, retryOnTimeout: false), isFalse);
    });

    test('auth error is terminal', () {
      expect(isRetryable(const AuthException('bad session'),
          retryOnTimeout: true), isFalse);
    });

    test('constraint / RLS codes are terminal; 5xx & explicit 503 transient',
        () {
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '42501'),
              retryOnTimeout: true),
          isFalse); // RLS denial
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '23505'),
              retryOnTimeout: true),
          isFalse); // unique_violation (has its own fallback)
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '503'),
              retryOnTimeout: true),
          isTrue);
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '500'),
              retryOnTimeout: true),
          isTrue); // status >= 500
      expect(
          isRetryable(const PostgrestException(message: 'x', code: '400'),
              retryOnTimeout: true),
          isFalse); // status 4xx terminal
    });

    test('null-code postgrest falls back to transport signature of message',
        () {
      expect(
          isRetryable(
              const PostgrestException(message: 'Failed host lookup: db'),
              retryOnTimeout: true),
          isTrue);
      expect(
          isRetryable(const PostgrestException(message: 'permission denied'),
              retryOnTimeout: true),
          isFalse);
    });

    test('dart:io transport failures are transient; unknown errors are not',
        () {
      expect(isRetryable(const SocketException('boom'), retryOnTimeout: true),
          isTrue);
      expect(isRetryable(const HttpException('boom'), retryOnTimeout: true),
          isTrue);
      expect(isRetryable(Exception('totally unknown'), retryOnTimeout: true),
          isFalse);
    });
  });

  group('resolveInsertConflict', () {
    test('23505 with an existing id → update-by-id', () {
      expect(resolveInsertConflict(code: '23505', rowWithIdExists: true),
          InsertConflictAction.updateById);
    });
    test('23505 on a different column (no row at id) → rethrow', () {
      expect(resolveInsertConflict(code: '23505', rowWithIdExists: false),
          InsertConflictAction.rethrowError);
    });
    test('non-23505 codes → rethrow', () {
      expect(resolveInsertConflict(code: '23503', rowWithIdExists: true),
          InsertConflictAction.rethrowError);
      expect(resolveInsertConflict(code: null, rowWithIdExists: false),
          InsertConflictAction.rethrowError);
    });
  });

  group('isPreSendConnectionError (non-idempotent swap)', () {
    test('true only for pre-send socket failures', () {
      expect(
          isPreSendConnectionError(
              const SocketException('Failed host lookup: api')),
          isTrue);
      expect(isPreSendConnectionError(const SocketException('Connection refused')),
          isTrue);
      expect(
          isPreSendConnectionError(
              const SocketException('Network is unreachable')),
          isTrue);
      expect(isPreSendConnectionError(const SocketException('No route to host')),
          isTrue);
    });
    test('false for mid-flight resets and timeouts (never re-swap)', () {
      expect(
          isPreSendConnectionError(
              const SocketException('Connection reset by peer')),
          isFalse);
      expect(isPreSendConnectionError(TimeoutException('slow')), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/services/sync_service_test.dart`
Expected: FAIL — `sync_retry_policy.dart` does not exist; `isRetryable` / `resolveInsertConflict` / `isPreSendConnectionError` / `InsertConflictAction` undefined.

- [ ] **Step 3: Create the policy module (move the logic verbatim)**

`lib/services/sync_retry_policy.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_service.dart' show RpcUnavailableException;

/// What to do when an INSERT fails with 23505 (unique_violation).
enum InsertConflictAction { rethrowError, updateById }

/// Pure decision for the insert-conflict fallback. A 23505 whose row already
/// exists at this id means the same entity id was re-inserted → convert to an
/// UPDATE. A 23505 on a DIFFERENT column (e.g. (tour_id, phone) on passengers)
/// with no row at this id is a genuine conflict → rethrow. Any non-23505 code
/// is not this fallback's concern → rethrow.
InsertConflictAction resolveInsertConflict({
  required String? code,
  required bool rowWithIdExists,
}) {
  if (code != '23505') return InsertConflictAction.rethrowError;
  return rowWithIdExists
      ? InsertConflictAction.updateById
      : InsertConflictAction.rethrowError;
}

/// Classifies whether [e] is a transient failure worth retrying. Retry only
/// network/transport/5xx failures (and, when [retryOnTimeout], timeouts); every
/// constraint, permission, auth, and missing-function error is terminal.
bool isRetryable(Object e, {required bool retryOnTimeout}) {
  if (e is RpcUnavailableException) return false; // deploy issue — never helps
  if (e is TimeoutException) return retryOnTimeout; // only idempotent callers
  if (e is AuthException) return false; // invalid/expired session — terminal

  if (e is PostgrestException) {
    final code = e.code;
    const terminal = {
      '42501', // insufficient_privilege (RLS denial)
      '23505', // unique_violation (has insert->update fallback)
      '23503', // foreign_key_violation
      '23514', // check_violation
      '23502', // not_null_violation
      '22P02', // invalid_text_representation
      'PGRST202', // function not found
      '42883', // function does not exist
    };
    if (code != null && terminal.contains(code)) return false;
    if (code == '503' || code == 'PGRST001') return true;
    final status = int.tryParse(code ?? '');
    if (status != null) {
      if (status >= 500) return true;
      if (status >= 400) return false;
    }
    return looksLikeTransport(e.message);
  }

  if (e is SocketException) return true;
  if (e is HttpException) return true;
  return looksLikeTransport(e.toString());
}

/// True when [message] carries a network/transport failure signature.
bool looksLikeTransport(String message) {
  final m = message.toLowerCase();
  return m.contains('socketexception') ||
      m.contains('clientexception') ||
      m.contains('httpexception') ||
      m.contains('connection closed') ||
      m.contains('connection reset') ||
      m.contains('connection refused') ||
      m.contains('connection terminated') ||
      m.contains('failed host lookup') ||
      m.contains('network is unreachable') ||
      m.contains('no route to host') ||
      m.contains('timed out') ||
      m.contains('timeout') ||
      m.contains('network');
}

/// Certain the request never left the device: DNS failure, no route, or
/// connection refused BEFORE any bytes were sent. Excludes connection
/// reset/closed (can happen mid-flight after a write may already have landed)
/// and timeouts — used only for the non-idempotent swap RPC.
bool isPreSendConnectionError(Object e) {
  if (e is! SocketException) return false;
  final m = e.toString().toLowerCase();
  return m.contains('failed host lookup') ||
      m.contains('connection refused') ||
      m.contains('network is unreachable') ||
      m.contains('no route to host');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/services/sync_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Make `SyncService` delegate to the policy module**

In `lib/services/sync_service.dart` add `import 'sync_retry_policy.dart';`.

Replace the private `_isRetryable`, `_looksLikeTransport`, and `_isPreSendConnectionError` method bodies (:537-616) — delete `_looksLikeTransport` and `_isPreSendConnectionError` entirely and re-point their call sites:
- In `_withRetry`, the default predicate (:508-509) becomes:
  ```dart
    final predicate = isRetryable ??
        ((Object e) => isRetryable_(e, retryOnTimeout: retryOnTimeout));
  ```
  To avoid the parameter/function name clash (the local param is also `isRetryable`), rename the delegation: keep a thin private wrapper instead —
  ```dart
    final predicate = isRetryable ??
        ((Object e) =>
            syncIsRetryable(e, retryOnTimeout: retryOnTimeout));
  ```
  and expose the policy function under that name. Simplest concrete approach: import the policy with a prefix. Change the import to `import 'sync_retry_policy.dart' as retry;` and use `retry.isRetryable(...)`, `retry.isPreSendConnectionError`, `retry.resolveInsertConflict(...)`, `retry.InsertConflictAction`. Then:
  ```dart
    final predicate = isRetryable ??
        ((Object e) => retry.isRetryable(e, retryOnTimeout: retryOnTimeout));
  ```
- In `swapPassengerSeats` (:370) change `isRetryable: _isPreSendConnectionError` → `isRetryable: retry.isPreSendConnectionError`.
- Delete the now-unused private methods `_isRetryable`, `_looksLikeTransport`, `_isPreSendConnectionError`.

Refactor the insert branch of `_writeToServer` (:448-468) to use the pure decision:

```dart
      case 'insert':
        try {
          await _client.from(table).insert(clean);
        } on PostgrestException catch (e) {
          final existing = e.code == '23505'
              ? await _client
                  .from(table)
                  .select('id')
                  .eq('id', entityId)
                  .maybeSingle()
              : null;
          switch (retry.resolveInsertConflict(
            code: e.code,
            rowWithIdExists: existing != null,
          )) {
            case retry.InsertConflictAction.updateById:
              final updateData = Map<String, dynamic>.from(clean)..remove('id');
              await _client.from(table).update(updateData).eq('id', entityId);
            case retry.InsertConflictAction.rethrowError:
              rethrow;
          }
        }
        break;
```

- [ ] **Step 6: Verify nothing regressed and the analyzer is clean**

Run: `flutter analyze lib/services/sync_service.dart lib/services/sync_retry_policy.dart`
Expected: no errors (no undefined `_isRetryable` / `_isPreSendConnectionError` references remain).
Run: `flutter test test/services/sync_service_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/services/sync_retry_policy.dart lib/services/sync_service.dart test/services/sync_service_test.dart
git commit -m "test(sync): extract pure retry/conflict policy seam and cover retryable, insert-conflict fallback & swap predicate (X-2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Run the whole suite**

Run: `flutter test`
Expected: all suites green (no regression in the ~680 existing cases; new tests added by Tasks 1-6).

- [ ] **Analyze the changed surface**

Run: `flutter analyze`
Expected: 0 errors (baseline was 6 info/warning items; do not exceed that materially).

---

## Self-review (coverage vs Phase-2 scope)

- **H-2** → Task 1: pull-to-refresh (`RefreshIndicator` over every state), Retry on the error card (`UgamEmpty.error`), offline-vs-error copy (`SyncService.isOnline`), resume re-fetch (`WidgetsBindingObserver`). Realtime is intentionally out of scope (audit says "ideally"), see Open Questions.
- **H-3** → Task 2: seat-agnostic `resolveHandlerCollection` + de-duping `cacheHandlerCollection`; one row per passenger-per-bus, seat rewritten on save.
- **AM-1** → Task 3: `isNotified`/`notifiedCount` off persisted `seatsChangedSinceNotified`; session `_sentIds` deleted.
- **AL-1** → Tasks 4-5: `UgamInput.validator` (working `Form.validate()`), non-empty title/from/to validators on both forms, `returnBeforeDeparture` guard, create-tour departure-reset mirror.
- **X-2** → Task 6: `sync_retry_policy.dart` seam with tests for `isRetryable`, `resolveInsertConflict`, `isPreSendConnectionError`.
- Every user-facing string added goes through `tr()` with en/gu/hi kept in sync (Tasks 1 & 5).
- Type consistency: `Collection.copyWith(seatId:)`, `Passenger.seatsChangedSinceNotified`, `TourController.createTour(...)→Future<Tour>`, `UgamEmpty.error(onRetry:...)`, `PostgrestException(message:, code:)` all match the real signatures read from source.
