# Architecture

**Analysis Date:** 2026-06-06

## Pattern Overview

**Overall:** GetX MVC with reactive Rx state, offline-first optimistic UI, online-only persistence via Supabase.

**Key Characteristics:**
- All business state lives in permanent GetX controllers; screens are pure observers (`Obx`)
- Optimistic mutations: local state changes instantly, server write follows, on failure the local state reverts and a snackbar fires
- Single source of truth is the Supabase database; a thin `SyncService` wraps every read/write with timeouts and online guards — no local SQLite cache remains (deleted in a past refactor)
- Supabase Realtime drives live multi-device sync via `RealtimeService`; `TourController` applies each Postgres CDC event directly to in-memory state without a round-trip

## Layers

**Entry / Bootstrap:**
- Purpose: Concurrent async init (Supabase + EasyLocalization) behind a branded pre-init splash, then mount `GetMaterialApp` with global bindings
- Location: `lib/main.dart`, `lib/app.dart`
- Contains: `_Bootstrap` StatefulWidget, `AppBinding` (registers all permanent + fenix services and controllers)
- Depends on: nothing beyond Flutter SDK
- Used by: OS launch

**Routing:**
- Purpose: Centralized named-route registry; argument parsing for parameterized screens
- Location: `lib/routes/app_routes.dart`
- Contains: `AppRoutes` (static string constants + `GetPage` list)
- Key routes: `/splash` → `SplashScreen`, `/` → `MainShell`, `/seat-assignment` + `/tour-overview` both resolve to `SeatsScreen` (different `initialMode`), `/seat-detail`, `/tour-money`
- Depends on: screen constructors, `SeatsMode` enum

**Controllers (GetX `GetxController` / `GetxService`):**
- Purpose: All mutable reactive state + business operations; screens read via `Obx`, call methods for mutations
- Location: `lib/controllers/`
- Key controllers:
  - `TourController` (`lib/controllers/tour_controller.dart`, 1 561 lines): Owns the `tours` `RxList`; all CRUD for tours, passengers, buses, groups, seat assignments. The heaviest controller in the app. Subscribes to `RealtimeService.events` and applies incremental CDC patches. Exposes `fillTour()` which delegates to `SeatingEngine.propose` + `SeatingPlanApplier.diff`.
  - `AuthController` (`lib/controllers/auth_controller.dart`): Phone+password Supabase Auth (synthetic email mapping). Two-step: `submitPhone()` → lookup admin table, `verifyAdminPassword()` → Supabase sign-in. Persists session in `SharedPreferences`. Exposes `isAdmin`/`isPassenger` and `whenRestored` (a `Completer` the splash awaits before routing).
  - `MoneyController` (`lib/controllers/money_controller.dart`): Loads collections/expenses/bus_handovers for one tour at a time; same optimistic CRUD shape as `TourController`.
  - `CustomerMemoryController` (`lib/controllers/customer_memory_controller.dart`): Captures priority + travel companion data from a tour before it is deleted; restores it on the next matching phone.
  - `ThemeController` (`lib/controllers/theme_controller.dart`): Reactive dark/light/system toggle, persisted in SharedPreferences.
  - `LocaleController` (`lib/controllers/locale_controller.dart`): Locale switching for EasyLocalization.
  - `UserController` (`lib/controllers/user_controller.dart`): Admin's own contact list from the `admin_contacts` table (used by WhatsApp broadcast recipient picker).
  - `ShellController` (`lib/screens/main_shell.dart`): Single `currentIndex` for the bottom-nav IndexedStack.

**Services (GetX `GetxService`):**
- Purpose: Infrastructure concerns that are not themselves state; injected into controllers via `Get.find()`
- Location: `lib/services/`
- Key services:
  - `SyncService` (`lib/services/sync_service.dart`, 353 lines): The only service that touches Supabase CRUD. `smartFetch` / `smartInsert` / `smartUpdate` / `smartDelete` — each enforces online, applies an 8/12 s timeout, throws on failure. The tours fetch is special: it parallel-fetches passengers + buses + passenger_groups and assembles them into embedded maps before returning.
  - `RealtimeService` (`lib/services/realtime_service.dart`): Wraps one Supabase Realtime channel (`admin-data-{uid}`) per authenticated session. Broadcasts `DataChangedEvent` on a single `StreamController.broadcast()` so any controller can subscribe. Re-subscribes on auth state changes.
  - `SeatingEngine` (`lib/services/seating_engine.dart`, 1 857 lines): Stateless pure-Dart greedy algorithm. `SeatingEngine.propose(buses, passengers)` → `SeatingPlan`. No Flutter, no I/O, no randomness. Honors: group cohesion (one bus), priority → front sofa, bus-packing, leg-aware capacity (GO vs RETURN), stranger-share guard on doubles.
  - `SeatingPlanApplier` (`lib/services/seating_plan_applier.dart`): Pure-Dart diff between a `SeatingPlan` and current passenger state; returns only passengers whose seats actually changed.
  - `GroupCascade` (`lib/services/group_cascade.dart`): Pure-Dart planner for drag-move operations — determines which group members must move together and whether the destination bus can accommodate them (delegates back to `SeatingEngine.propose` on a one-bus snapshot).
  - `SwapCandidateFinder` (`lib/services/swap_candidate_finder.dart`): Given a passenger on a seat, finds valid swap targets on the same bus.
  - `AdminAuthService` (`lib/services/admin_auth_service.dart`): Low-level Supabase Auth calls (signIn, signOut, findByPhone, updateAdmin, deleteAccount).
  - `CustomerRequestsStore` (`lib/services/customer_requests_store.dart`): Customer-side: reads the `booking_requests` table for the customer view.
  - `WhatsAppService` / `WhatsAppOutbound` / `WhatsAppCloudService` (`lib/services/whatsapp_*.dart`): WhatsApp deep-link generation, outbound message composition, and Cloud API edge function calls for broadcast.
  - `SeatChartPdf` (`lib/services/seat_chart_pdf.dart`): Generates the handler's seat-chart PDF using the `printing` package.
  - `ContactSyncService` (`lib/services/contact_sync_service.dart`): Reads device contacts (with permission) for the recipient picker.

**Models (plain Dart, immutable):**
- Purpose: Typed value objects with `fromMap` / `toMap` / `copyWith`
- Location: `lib/models/`
- Key models:
  - `Tour` (`lib/models/tour.dart`): Aggregate root. Embeds `List<Bus>`, `List<Passenger>`, `List<PassengerGroup>` (assembled by the sync layer, NOT stored as nested JSON on the server). Has a `TourStatus` state machine: `planning → collecting → busBooked → assigning → locked → completed`.
  - `Passenger` (`lib/models/passenger.dart`): Carries `List<RequestLine>` (what was asked) and `List<SeatAssignment>` (what was allocated). `groupId` links to `PassengerGroup`.
  - `Bus` (`lib/models/bus_details.dart`): Contains a `SeatLayout` grid of `SeatCell` objects (type, position, seatId, forward/reserved flags).
  - `SeatAssignment` (`lib/models/seat_assignment.dart`): `(busId, seatId, locked)` — two entries on the same seatId = whole Double Sofa.
  - `PassengerGroup` (`lib/models/passenger_group.dart`): Cross-booking group; passengers in the same group are seated on one bus by the engine.

**Screens (pure Flutter `Widget`):**
- Purpose: UI only — render reactive state, dispatch user events to controllers
- Location: `lib/screens/`
- Pattern: `Obx(() { final tour = tourCtrl.getTour(id); ... })` drives everything. No business logic in widgets.

**Design System "Ugam":**
- Purpose: Single import for all brand tokens, text styles, theme, and components
- Location: `lib/design/` (barrel: `lib/design/ugam.dart`)
- Tokens: `UgamColors` (dark + light `UgamColorSet`), `UgamRadius`, `UgamSpacing`, `UgamMotion` in `lib/design/tokens.dart`
- Theme: `UgamTheme.dark()` / `.light()` in `lib/design/theme.dart`
- Components: `UgamCta`, `UgamCard`, `UgamSheet`, `UgamDialog`, `UgamInput`, `UgamDockNav`, `UgamTabPills`, `UgamSkeleton`, `UgamSnackbar`, `UgamSeatGrid`, etc. in `lib/design/components/`
- Entry point: `import 'package:occubusbooking/design/ugam.dart'` gives access to every token and component

**Config:**
- Location: `lib/config/`
- `lib/config/supabase_config.dart`: Supabase project URL + anon key (hardcoded constants, not read from .env at runtime)
- `lib/config/whatsapp_cloud_config.dart`: WhatsApp Cloud API edge function URL
- `lib/config/i18n_config.dart`: Supported locales, asset path for EasyLocalization
- `lib/config/app_contact.dart`: Agent's phone number / contact info

## Data Flow

**Admin reads a tour list:**
1. `AppBinding` → `TourController.onInit()` → `_loadTours()`
2. `SyncService.smartFetch(table: 'tours', ...)` → `_fetchToursWithRelations` → parallel Supabase queries for passengers + buses + passenger_groups → assembled map
3. `TourController.tours.assignAll(loaded)` → all `Obx` widgets observing `tours` rebuild

**Admin writes (e.g. assigns a seat):**
1. Screen calls `tourCtrl.assignSeats(tourId, passengerId, assignments)`
2. `_updatePassengerLocal` mutates `tours` in place → `tours.refresh()` → Obx fires instantly (optimistic)
3. `SyncService.smartUpdate(table: 'passengers', ...)` → Supabase REST upsert (12 s timeout)
4. On failure: `refreshTours()` pulls server truth + `AppSnackBar.error(...)` shown

**Realtime sync (multi-device):**
1. `RealtimeService` receives Postgres CDC event on the admin channel
2. Emits `DataChangedEvent` on the broadcast stream
3. `TourController._applyRealtimeEvent()` pattern-matches on table → patches the relevant Tour/Passenger/Bus in `tours.value` in place → `_scheduleNotify()` (microtask-coalesces bursts into one `tours.refresh()`)
4. On any error in the incremental path: `_scheduleRefresh()` falls back to debounced full refetch

**Auto-fill seating:**
1. UI calls `tourCtrl.fillTour(tourId)`
2. `SeatingEngine.propose(buses, passengers)` → `SeatingPlan`
3. `SeatingPlanApplier.diff(plan, passengers)` → only changed passengers
4. For each changed passenger: `assignSeats(...)` → optimistic local update + server write (same path as manual assignment)
5. `SeatingPlan` cached in `lastPlanByTour[tourId]` for the overview screen to read exceptions from

**App startup / auth routing:**
1. `_Bootstrap` fires `Supabase.initialize` + `EasyLocalization.ensureInitialized` concurrently; shows `_BootstrapSplash` in the meantime
2. Once both complete, `MyApp` / `GetMaterialApp` mounts; `AppBinding.dependencies()` registers all controllers
3. Initial route is `/splash` → `SplashScreen._routeWhenReady()`
4. Awaits `auth.whenRestored` (a `Completer` in `AuthController` that completes after `SharedPreferences` + Supabase session check) and a 450 ms minimum display
5. Routes to `/` (admin `MainShell`) or `/customer-home` based on `auth.isLoggedIn && auth.isAdmin`

**State Management:**
- `GetxController` with `Rx` / `RxList` observables; screens wrap in `Obx(() { ... })`
- `tours` RxList in `TourController` is the single in-memory store for all tour data; both admin and customer screens read from it (filtered by visibility scope)
- No Provider, no Riverpod, no BLoC — GetX only

## Key Abstractions

**TourController:**
- Purpose: God-object for all tour domain logic; the single source of mutable tour state in the app
- Location: `lib/controllers/tour_controller.dart`
- Pattern: Optimistic local mutation (`_updateTourLocal` / `_updatePassengerLocal`) → server write via `SyncService` → on failure `refreshTours()` + snackbar

**SyncService:**
- Purpose: Online-only Supabase access layer; enforces timeouts, online gate, RLS owner_id backfill
- Location: `lib/services/sync_service.dart`
- Pattern: Stateless wrappers — all callers are `TourController` / `MoneyController` / `CustomerMemoryController`

**SeatingEngine:**
- Purpose: Deterministic, stateless greedy algorithm for auto-assigning seats
- Location: `lib/services/seating_engine.dart`
- Pattern: Pure function `SeatingEngine.propose(buses, passengers) → SeatingPlan`; no side effects, identical input → identical output

**Ugam Design System:**
- Purpose: Visual language; single `import 'design/ugam.dart'` gives every token and component
- Location: `lib/design/`
- Pattern: `UgamColors.of(context)` for context-aware color; components enforce brand — no hand-rolled dialogs or buttons

**SeatsScreen (unified seat workspace):**
- Purpose: Single route that hosts Auto-fill / Assign / Rearrange modes behind segmented tab pills
- Location: `lib/screens/seats_screen.dart`
- Pattern: `IndexedStack` keeps all three mode sub-screens mounted; `SeatsMode` enum drives initial mode from route arguments

## Entry Points

**`lib/main.dart`:**
- Triggers: OS launch
- Responsibilities: `WidgetsFlutterBinding`, font config, orientation lock, concurrent async init, pre-init splash, mount `EasyLocalization` + `MyApp`

**`lib/app.dart` — `MyApp` / `AppBinding`:**
- Triggers: After async init completes
- Responsibilities: Build `GetMaterialApp` (theme, locale, routing), register all permanent controllers and services via `AppBinding.dependencies()`

**`lib/screens/splash_screen.dart` — `SplashScreen`:**
- Triggers: Initial route `/splash`
- Responsibilities: Await `AuthController.whenRestored`, then route to admin shell (`/`) or customer home (`/customer-home`). Guarantees no routing happens before session restore completes.

**`lib/screens/main_shell.dart` — `MainShell`:**
- Triggers: Named route `/`; only reachable after admin login
- Responsibilities: Bottom-nav (`UgamDockNav`) + `IndexedStack` for Home · Tours · Settings; lazy-mounts tabs on first visit

**`lib/routes/app_routes.dart`:**
- Triggers: Every `Get.toNamed(...)` call
- Responsibilities: Central route registry; parses `Get.arguments` for parameterized screens

## Error Handling

**Strategy:** Optimistic mutations with explicit revert-on-failure; errors are surfaced as `AppSnackBar` calls, never silently swallowed.

**Patterns:**
- Every controller write: `try { await _sync.smartX(...) } catch (e) { await refreshTours(); AppSnackBar.error(...); rethrow; }`
- Reads: `smartFetch` never throws — returns `[]` and logs on failure; controllers show empty/error state or snackbar
- Realtime: Incremental apply wrapped in `try/catch`; any failure falls back to `_scheduleRefresh()` (debounced full refetch)
- Connectivity: `SyncService._ensureOnline()` throws an `Exception` immediately on any write when `isOnline.value` is false, so the UI gets a snackbar without hanging

## Cross-Cutting Concerns

**Logging:** `dart:developer` `dev.log(...)` with `name:` tags (`TourController`, `SyncService`, `RealtimeService`, `TourDiag`). No crash-reporting SDK wired up.

**Validation:** Form-level only (`lib/utils/validators.dart`); no domain-layer validation layer.

**Authentication:** Supabase Auth (synthetic email from phone number). RLS enforces data isolation on the server. `AuthController` mirrors session state locally. Admin writes that need `owner_id` have it backfilled by `SyncService._writeToServer`.

**Localization:** EasyLocalization with JSON files in `assets/translations/` (en, gu, hi). All user-visible strings use `tr('key')`.

**Offline:** No offline writes — `SyncService._ensureOnline()` blocks all writes. Reads fall back to `[]` when offline. The old SQLite write queue was removed; the app is fully online-first now.

## Architectural Strengths

- **Reactive, coalesced updates**: Microtask coalescing in `TourController._scheduleNotify()` means a burst of realtime events fires one Obx rebuild, not N.
- **Clean engine boundaries**: `SeatingEngine`, `SeatingPlanApplier`, `GroupCascade` are pure Dart — no Flutter, no state, fully unit-testable.
- **Optimistic UI**: Every mutation feels instant; failures revert correctly.
- **Lazy tab mounting**: `MainShell` only mounts tabs that have been visited; unvisited tabs don't observe reactive state.
- **Design system**: Single `ugam.dart` barrel enforces brand consistency across all screens.

## Architectural Weaknesses

- **TourController is a god object**: 1 561 lines, 30+ public methods covering tours, passengers, buses, groups, seat assignments, priority, handler, auto-fill. Hard to navigate and test in isolation.
- **No offline write queue**: Any write while offline fails immediately. The app is not usable in the field without connectivity.
- **Diagnostic log left in production**: `TourController._loadTours()` contains an explicitly-commented `// DIAGNOSTIC (temporary)` block that logs session details on every tours load — should be removed.
- **Duplicate migration numbering**: `supabase/migrations/` has two files starting with `004_` and two starting with `006_`, indicating migrations were applied out-of-band and the naming sequence is unreliable.
- **No error reporting service**: All errors go to `dev.log` (debug console only) and user-facing snackbars. No Sentry / Firebase Crashlytics. Production crashes are invisible.
- **`Tour.busDetails` deprecated getter**: `lib/models/tour.dart` carries a `@Deprecated('Use tour.buses')` accessor that is still compiled but should be removed.
- **Screens are too large**: `seat_detail_screen.dart` (3 074 lines), `handler_bus_chart_screen.dart` (2 549 lines), `add_bus_screen.dart` (2 407 lines) mix layout, local state, and presentation logic in single files. Splits into sub-widgets or partial files would improve maintainability.
- **`SyncService` cache stubs**: `getCachedList`, `invalidateCache`, `pendingEntityIdsForTable` are no-op stubs retained for call-site compat after the offline DB was removed — they add noise and could confuse future contributors.

---

*Architecture analysis: 2026-06-06*
