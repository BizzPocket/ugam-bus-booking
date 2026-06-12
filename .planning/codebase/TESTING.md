# Testing Patterns

**Analysis Date:** 2026-06-06

## Test Framework

**Runner:** `flutter_test` (bundled SDK package)
- Config: none — uses Flutter's default test runner. No `jest.config`, no `vitest.config`.
- No `mockito` / `mocktail` — zero generated mocks. All fakes are hand-written subclasses.

**Assertion library:** `flutter_test` built-in (`expect`, `find.*`, `findsOneWidget`, `findsNothing`, `isA<T>()`, `throwsA`).

**Run commands:**
```bash
flutter test                           # Run all tests
flutter test test/services/seating_engine_test.dart   # Single file
flutter test --coverage                # Coverage (lcov)
flutter test -r expanded               # Verbose output
```

**Total test file count:** 28 files  
**Approximate total test cases:** ~263 (including widget + unit tests)

## Test Directory Structure

```
test/
├── widget_test.dart                      # Default Flutter scaffold — empty stub
├── components/
│   └── combined_seat_grid_test.dart      # 4 widget tests
├── config/
│   └── supabase_config_test.dart         # 3 unit tests (phone → email helper)
├── models/
│   ├── admin_test.dart                   # 4 unit tests
│   ├── collection_balance_test.dart      # 6 unit tests
│   ├── fare_calculation_test.dart        # 30 unit tests (largest model file, 684 lines)
│   ├── money_summary_test.dart           # 2 unit tests
│   ├── passenger_group_test.dart         # 4 unit tests
│   ├── passenger_priority_group_test.dart# 4 unit tests
│   ├── priority_status_test.dart         # 3 unit tests
│   ├── seat_assignment_test.dart         # 5 unit tests
│   ├── seat_cell_test.dart               # 12 unit tests
│   └── seat_layout_test.dart             # 12 unit tests
├── screens/
│   ├── handler_bus_chart_screen_test.dart# 2 widget tests
│   ├── seat_detail_screen_test.dart      # 9 widget tests (433 lines)
│   ├── seating_exceptions_screen_test.dart # 3 widget tests
│   ├── seats_screen_test.dart            # 3 widget tests
│   ├── tour_groups_screen_test.dart      # 4 widget tests
│   ├── tour_money_board_screen_test.dart # 2 widget tests
│   └── tour_overview_screen_test.dart    # 3 widget tests
├── services/
│   ├── chart_footer_store_test.dart      # 4 unit tests
│   ├── group_cascade_test.dart           # 15 unit tests
│   ├── seat_chart_pdf_test.dart          # 4 unit tests
│   ├── seating_engine_test.dart          # 69 unit tests (largest file, 1854 lines)
│   ├── seating_plan_applier_test.dart    # 13 unit tests
│   └── swap_candidate_finder_test.dart   # 19 unit tests
└── utils/
    ├── phone_normalize_test.dart         # 8 unit tests
    └── seat_grid_placement_test.dart     # 15 unit tests
```

## The Fake Controller / Harness Pattern

Every widget test that renders a screen backed by a GetX controller uses the **same three-part pattern**:

### Part 1: `_FakeTourController` (or `_FakeMoneyController`, etc.)

A local subclass of the real controller. Its only jobs are:
1. Override `onInit()` to a **no-op** so `Get.put()` never triggers live Supabase/realtime wiring.
2. Override mutating methods to **record** their arguments (and optionally mutate the observable list so `Obx` repaints).

```dart
// From test/screens/seat_detail_screen_test.dart
class _FakeTourController extends TourController {
  final List<String> freedSeats = [];

  @override
  // ignore: must_call_super
  void onInit() {} // no network, no realtime

  @override
  Future<void> cancelOneSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String seatId,
  }) async {
    freedSeats.add('$passengerId:$busId:$seatId'); // record, not write
  }
}
```

The same pattern appears in:
- `test/screens/tour_groups_screen_test.dart` — records `priorityCalls`, `groupCalls`, `createGroupLabels`, `deleteGroupIds`
- `test/screens/tour_overview_screen_test.dart` — records `fillCalls`, seeds canned exceptions into `lastPlanByTour`
- `test/screens/seating_exceptions_screen_test.dart` — exposes `seedPlan(tourId, exceptions)` helper
- `test/screens/tour_money_board_screen_test.dart` — also fakes `MoneyController.loadForTour` as no-op, seeds `collections`/`expenses`/`handovers` directly

### Part 2: Fixture builders

Pure free functions that build minimal, deterministic model objects:

```dart
// Consistent naming across all test files
Bus _bus(String id, String name, {required int seats}) => Bus(...)
Passenger _passenger(String id, String tourId, ...) => Passenger(...)
Tour _fakeTour() => Tour(id: 't1', title: 'Dwarka Yatra', ...)
```

### Part 3: `_harness()` — the widget wrapper

A free function returning a `GetMaterialApp` with `Brightness.dark` forced (primary app mode):

```dart
Widget _harness() => GetMaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: const SeatsScreen(tourId: 't1'),
);
```

### Registration order

```dart
void main() {
  tearDown(Get.reset);  // always present in screen tests

  testWidgets('...', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);          // register BEFORE seeding
    ctrl.tours.assignAll([_fakeTour()]);    // seed observable list

    await tester.pumpWidget(_harness());
    await tester.pump();                    // one frame for Obx rebuild

    expect(find.text('Dwarka Yatra'), findsOneWidget);
  });
}
```

`tearDown(Get.reset)` is mandatory in every screen test file to clear the DI container between tests.

## Mocking Approach

**No external mock library.** No `mockito`, no `mocktail`, no generated `.mocks.dart` files.

All fakes are handwritten subclass overrides. This keeps tests readable but means:
- You cannot verify call counts on non-overridden methods.
- Verification is done by inspecting recorded-call lists (`freedSeats`, `priorityCalls`, etc.).

**Service isolation:** Services that touch Supabase directly (e.g., `CustomerRequestsStore`, `SupabaseService`) have no seam — their tests explicitly acknowledge the limitation (see `handler_bus_chart_screen_test.dart` which tests the *error path* because the happy path requires a live Supabase client).

## Unit Test Patterns (pure Dart)

Unit tests have no GetX, no Flutter widgets, no `testWidgets`. Just `test()` and `group()`:

```dart
// test/services/seating_engine_test.dart
void main() {
  group('priority seats first', () {
    test('approved passenger gets front row', () {
      final result = SeatingEngine.propose(...);
      expect(result.assignmentsByPassenger['p1']?.first.seatId, 'SU1');
    });
  });
}
```

Fixture helpers are `_p(id, ...)`, `_bus(id, cells)`, `_seat(row, col, type, ...)`, `_line(type, pos, qty)` — identical naming convention across all unit test files.

**Pump convention for widget tests:**
- `await tester.pump()` — one frame, preferred after state mutation.
- `await tester.pumpAndSettle()` — used when testing async operations or animations (sheet open/close, `Future.microtask` completions).

## What IS Covered

| Area | File | Test count | Notes |
|------|------|-----------|-------|
| `SeatingEngine` | `test/services/seating_engine_test.dart` | 69 | Most thorough; covers priority, grouping, double-sofa, packing, one-way |
| Fare calculation | `test/models/fare_calculation_test.dart` | 30 | Whole/shared double, rear-zone pricing, price bands |
| `SwapCandidateFinder` | `test/services/swap_candidate_finder_test.dart` | 19 | Candidate selection rules |
| `GroupCascade` service | `test/services/group_cascade_test.dart` | 15 | Group + priority cascading |
| `SeatingPlanApplier.diff` | `test/services/seating_plan_applier_test.dart` | 13 | Diff-only-changed-passengers |
| `SeatCell` model | `test/models/seat_cell_test.dart` | 12 | Cell property assertions |
| `BusLayout.generate` | `test/models/seat_layout_test.dart` | 12 | Column placement, balcony |
| `SeatGridPlacement` util | `test/utils/seat_grid_placement_test.dart` | 15 | Row/lane/column helpers |
| `SeatDetailScreen` | `test/screens/seat_detail_screen_test.dart` | 9 | Tile rendering + free/forward/reserved actions |
| `TourGroupsScreen` | `test/screens/tour_groups_screen_test.dart` | 4 | Priority + group mutations |
| `CombinedSeatGrid` | `test/components/combined_seat_grid_test.dart` | 4 | Grid renders seats |
| `SeatingExceptionsScreen` | `test/screens/seating_exceptions_screen_test.dart` | 3 | Exception display |
| `SeatsScreen` | `test/screens/seats_screen_test.dart` | 3 | Mode selector, tour title |
| `TourOverviewScreen` | `test/screens/tour_overview_screen_test.dart` | 3 | Fill-bus cockpit header |
| `TourMoneyBoardScreen` | `test/screens/tour_money_board_screen_test.dart` | 2 | Per-bus rows + totals |
| `HandlerBusChartScreen` | `test/screens/handler_bus_chart_screen_test.dart` | 2 | Read-only header + failed-load state |
| Phone normalization | `test/utils/phone_normalize_test.dart` | 8 | `normalisePhone`, Indian mobile check |
| `Admin` model | `test/models/admin_test.dart` | 4 | `fromMap`, `effectiveWhatsappNumber` |
| Collection balance | `test/models/collection_balance_test.dart` | 6 | Balance aggregation |
| `SeatChartPdf` | `test/services/seat_chart_pdf_test.dart` | 4 | PDF structure |
| `ChartFooterStore` | `test/services/chart_footer_store_test.dart` | 4 | Footer state |
| `SupabaseConfig` | `test/config/supabase_config_test.dart` | 3 | Phone → synthetic email |

## Coverage Gaps

The following have **zero** test coverage. Priority assessment based on complexity and risk.

### Controllers (none tested)
- `lib/controllers/auth_controller.dart` — login flow, session restoration, phone OTP — **HIGH RISK**: no test for failed auth, session expiry, or role resolution.
- `lib/controllers/tour_controller.dart` — the core CRUD + realtime apply + optimistic update logic — **HIGH RISK**: the `_applyRealtimeEvent` switch, `_applyPassengerEvent`, and `_applyBusEvent` incremental-update paths are entirely untested. A regression here corrupts local state silently.
- `lib/controllers/money_controller.dart` — collection/expense aggregation logic.
- `lib/controllers/customer_memory_controller.dart` — priority auto-restore.
- `lib/controllers/user_controller.dart` — device contacts sync.

### Services (partially tested; gaps)
- `lib/services/sync_service.dart` — `smartFetch`, `smartUpdate`, offline cache invalidation — **HIGH RISK**: no coverage of the cache-hit / cache-miss / offline queue paths.
- `lib/services/realtime_service.dart` — Supabase channel subscription, event routing — no tests.
- `lib/services/whatsapp_cloud_service.dart` — broadcast + PDF send — no tests.
- `lib/services/whatsapp_outbound.dart` — deep-link URL builder — no tests.
- `lib/services/whatsapp_service.dart` — legacy WA share — no tests.
- `lib/services/group_cascade.dart` — has 15 tests; good.
- `lib/services/contact_sync_service.dart` — no tests.

### Screens (untested — no widget test at all)
- `lib/screens/dashboard_screen.dart` — the agent's primary home; the "Needs attention" section logic, revenue hero, quick-action tile routing — **HIGH PRIORITY**.
- `lib/screens/tour_detail_screen.dart` — the main admin workspace with 4 tabs; only entry point to most management flows.
- `lib/screens/requests_screen.dart` — passenger management, selection mode, bulk-action bar.
- `lib/screens/create_tour_screen.dart` — form validation, date/time pickers, broadcast composer.
- `lib/screens/edit_tour_screen.dart` — same as above.
- `lib/screens/seat_assignment_screen.dart` — drag-and-drop seat assignment.
- `lib/screens/add_bus_screen.dart` — bus type + layout configuration.
- `lib/screens/manage_buses_screen.dart` — bus list management.
- `lib/screens/notify_screen.dart` — WA broadcast.
- `lib/screens/login_screen.dart` — phone + OTP flow.
- `lib/screens/settings_screen.dart` — settings root.
- `lib/screens/handler_bus_chart_screen.dart` — partially tested (2 tests: header render + failed load only).
- `lib/screens/collection_screen.dart` — money collection entry.
- `lib/screens/bus_money_screen.dart` — per-bus money summary.
- All customer-side screens: `customer_booking_request_screen.dart`, `customer_tour_list_screen.dart`, `customer_tour_detail_screen.dart`, `customer_my_requests_screen.dart`, `customer_more_screen.dart`.

### Models (partially tested; gaps)
- `lib/models/tour.dart` — `fromMap` / `copyWith` / `toMap` — no test.
- `lib/models/passenger.dart` — `fromMap` / serialization — no test.
- `lib/models/bus_details.dart` — `BusLayout.generate` covered; `Bus.fareForSeat` partially covered via `fare_calculation_test.dart`.

### Utils (untested)
- `lib/utils/validators.dart` — form field validators — no test.
- `lib/utils/formatters.dart` — currency / date formatters — no test.
- `lib/utils/time_format.dart` — no test.

## Coverage

**Requirements:** None enforced (no coverage threshold in CI or pubspec).

**View coverage:**
```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

---

*Testing analysis: 2026-06-06*
