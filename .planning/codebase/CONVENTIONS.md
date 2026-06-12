# Coding Conventions

**Analysis Date:** 2026-06-06

## Naming Patterns

**Files:**
- Screens: `snake_case_screen.dart` → `tour_detail_screen.dart`, `seat_detail_screen.dart`
- Design components: `ugam_<name>.dart` → `ugam_cta.dart`, `ugam_dialog.dart`
- Controllers: `<domain>_controller.dart` → `tour_controller.dart`, `auth_controller.dart`
- Services: `<domain>_service.dart` or `<domain>_store.dart` → `sync_service.dart`, `chart_footer_store.dart`
- Models: `<entity>.dart` (no suffix) → `tour.dart`, `passenger.dart`
- Utils: `<purpose>.dart` → `app_snackbar.dart`, `phone_normalize.dart`

**Classes:**
- Screens: `PascalCaseScreen` (`TourDetailScreen`, `SeatDetailScreen`)
- Private sub-widgets within a screen file: `_PascalCase` (`_TopBar`, `_SeatTile`, `_HeroSection`, `_CollectSheet`)
- Controllers: `PascalCaseController` (`TourController`, `AuthController`)
- Design tokens: `UgamColors`, `UgamSpacing`, `UgamRadius`, `UgamMotion`, `UgamText`
- Design components: `UgamButton`, `UgamDialog`, `UgamSheet`, `UgamCTA`, `UgamSnackbar`
- Enums: `PascalCase` with `camelCase` members (`UgamButtonKind.primary`, `TourStatus.busBooked`)

**Functions / methods:**
- `camelCase` throughout. Controller action verbs are descriptive: `createTour`, `assignSeats`, `setSeatForward`, `fillTour`, `refreshTours`.
- Private helpers prefixed `_`: `_loadTours`, `_scheduleNotify`, `_applyRealtimeEvent`.
- Boolean getters use `is*` / `has*`: `isAdmin`, `isPassenger`, `hasError`.

**Variables:**
- Reactive fields (GetX): suffix `.obs` at declaration, accessed via `.value` in logic, wrapped with `Obx()` in UI.
  ```dart
  final isLoading = false.obs;          // lib/controllers/tour_controller.dart
  final tours = <Tour>[].obs;            // lib/controllers/tour_controller.dart
  ```
- Local BuildContext color set: always named `c` (`final c = UgamColors.of(context);`)

## Code Style

**Formatting:**
- `flutter_lints/flutter.yaml` via `analysis_options.yaml` (default ruleset, no project-specific overrides).
- No `.prettierrc` — Dart formatter (`dart format`) is the authority.
- No explicit `prefer_single_quotes` rule; double quotes dominate in string literals.

**Linting:**
- `analysis_options.yaml` uses `include: package:flutter_lints/flutter.yaml` with no overrides.
- Selective suppression via `// ignore: <rule>` at call site (e.g., `// ignore: must_call_super` in fake controllers, `// ignore: prefer_final_fields` for TEMP feature flags).

## Import Organization

Imports are sorted in two blocks separated by a blank line, then sub-sorted alphabetically:

1. **Package imports** (third-party and flutter) — e.g., `package:easy_localization/...`, `package:flutter/...`, `package:get/get.dart`
2. **Relative imports** — controllers, design, models, routes, services, utils, then sibling screens

Example from `lib/screens/tour_detail_screen.dart`:
```dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
...
import 'edit_tour_screen.dart';
import 'seats_screen.dart';
```

**Design system barrel:** Always import `'../design/ugam.dart'` (the barrel) rather than individual design files.

**Path aliases:** None — all relative paths use `../`.

## State Management (GetX)

**Controller lifecycle:**
- Root-level (permanent) controllers registered in `lib/app.dart` via `Get.put(..., permanent: true)`: `AuthController`, `SyncService`, `RealtimeService`, `TourController`, `MoneyController`.
- Feature controllers registered lazily: `Get.lazyPut<TourController>(..., fenix: true)`.
- Screens access controllers via `Get.find<TourController>()` inside `build()` or as a field:
  ```dart
  final _tourCtrl = Get.find<TourController>();      // lib/screens/seat_assignment_screen.dart
  final tourCtrl = Get.find<TourController>();        // lib/screens/tour_detail_screen.dart
  ```

**Reactive observation:**
- `Obx(() { ... })` wraps any widget tree that reads `.value` on an observable.
- Outer `Obx` at screen level is the main pattern (`TourDetailScreen.build` wraps its entire return in `Obx`).
- `_scheduleNotify()` + `tours.refresh()` coalesces burst realtime events into a single frame rebuild (`lib/controllers/tour_controller.dart`).
- Bulk list mutations use `raw.value` (the underlying `List`) + a deferred `tours.refresh()` rather than `tours[i] = x` to avoid per-assignment Obx fires.

**Optimistic updates:**
- Pattern: mutate local state → await server write → on error, call `refreshTours()` + show `AppSnackBar.error(...)`, then `rethrow`.
  ```dart
  // lib/controllers/tour_controller.dart — assignSeats
  _updatePassengerLocal(tourId, passengerId, (p) => updated = p.copyWith(...));
  try {
    await _sync.smartUpdate(...);
  } catch (e) {
    await refreshTours();
    AppSnackBar.error('Could not save seat assignment. $e', title: 'Save failed');
    rethrow;
  }
  ```

## Ugam Design System Usage

**Non-negotiable rules (enforced by convention, not lint):**

1. **Colors — always via `UgamColors.of(context)`**. Never use `Color(0xFF...)` literals in screens or components (except the few intentional alpha overlays like `Color(0x14000000)` for scrim layers, and the group-color palette in `lib/design/group_color.dart`).
   ```dart
   final c = UgamColors.of(context);
   // Then reference: c.bg, c.card, c.accent, c.ink, c.ink2, c.ink3,
   //   c.good, c.danger, c.warm, c.border, c.onAccent, etc.
   ```

2. **Typography — always via `UgamText.*`**. Scale: `display`, `titleXl`, `titleL`, `titleM`, `titleS`, `body`, `bodyStrong`, `caption`, `micro`, `numLg`, `numXl`. Apply colour via `.copyWith(color: c.ink)`.
   ```dart
   Text(title, style: UgamText.titleM.copyWith(color: c.ink))
   ```

3. **Spacing — always via `UgamSpacing.*`**: `xs(4)`, `sm(8)`, `md(12)`, `gutter(14)`, `lg(16)`, `xl(20)`, `xxl(24)`, `huge(32)`, `huge2(40)`, `huge3(56)`. Default lateral gutter is `UgamSpacing.gutter`.

4. **Radius — always via `UgamRadius.*`**: `card(22)`, `photo(16)`, `input(14)`, `chip(999)`, `sheet(28)`, `seat(8)`, etc.

5. **Buttons — use `UgamButton` with a `UgamButtonKind`**. Never hand-roll `TextButton`/`ElevatedButton` for screen actions.
   - `UgamButtonKind.primary` — solid accent, the affirmative action
   - `UgamButtonKind.ghost` — transparent, cancel / dismiss
   - `UgamButtonKind.neutral` — tonal neutral, secondary action
   - `UgamButtonKind.danger` — solid red, confirmed destructive
   - `UgamButtonKind.dangerTonal` — tonal red, inline destructive

6. **Primary full-width action — use `UgamCTA`**. Place it in `Scaffold.bottomNavigationBar` or inside a `UgamStickyCTA` wrapper for gradient fade.

7. **Dialogs — use `UgamDialog.confirm()` / `UgamDialog.show()` (with BuildContext) or `AppDialogs.confirm()` / `AppDialogs.error()` (context-free, from controllers)**. Never hand-roll `AlertDialog`.

8. **Bottom sheets — use `UgamSheet.show(context, builder: ...)`**. Enforces 28 px top radius, drag handle, and platform-adaptive presentation.

9. **Toast notifications — use `AppSnackBar.success()`, `AppSnackBar.error()`, `AppSnackBar.info()`**. Never use `ScaffoldMessenger.of(context).showSnackBar(...)` directly. The chrome-aware positioning (`UgamChrome.bottomInset`) lives inside `AppSnackBar._show`.

10. **Bottom chrome measurement — wrap dock nav and sticky CTAs in `ChromeMeasure`**. `UgamStickyCTA` and `UgamDockNav` do this automatically. Do NOT hard-code `bottom: 90` or any fixed offset for toast placement.

## Localization

**Library:** `easy_localization` (`lib/config/i18n_config.dart`). Language files: `assets/translations/en.json`, `hi.json`, `gu.json`.

**Pattern:** `tr('key.subkey')` called directly in widget `build` methods. No wrapper function.
```dart
// lib/screens/tour_detail_screen.dart
title: tr('tour_detail.not_found_title'),
body:  tr('tour_detail.not_found_body'),
```

**Inconsistency — hardcoded strings:** A number of UI labels are plain string literals rather than `tr()` calls. Known examples:
- `lib/screens/tour_detail_screen.dart:66` — `label: 'Back'`
- `lib/screens/handler_bus_chart_screen.dart:410` — `confirmLabel: 'Delete'`
- `lib/screens/handler_bus_chart_screen.dart:2163` — `label: _saving ? 'Saving…' : 'Save'`
- `lib/screens/requests_screen.dart:846` — `label: 'Cancel'`
- `lib/screens/tour_groups_screen.dart:126, 364` — `'Cancel'`, `'New group'`
- `lib/screens/manage_buses_screen.dart:153` — `confirmLabel: 'Delete'`
- `lib/screens/edit_tour_screen.dart:360` — `confirmLabel: 'Delete'`
- `lib/screens/collection_screen.dart:248` — `label: 'Save'`
- `lib/screens/seat_detail_screen.dart:2855` — `label: 'Cancel'`

These are action-verb labels in `UgamButton`/`UgamCTA`/`UgamDialog` calls. They should use `tr('app.action.cancel')`, `tr('app.action.save')`, etc. (pattern already established in `lib/utils/app_dialogs.dart`).

## Navigation

**Two patterns coexist — inconsistency:**

1. **Named routes via `AppRoutes.*`**: `Get.toNamed(AppRoutes.tourOverview, arguments: {...})` — preferred for parameterized screens with arguments unpacked in `app_routes.dart`.
2. **Anonymous push via `Get.to(() => Screen())`**: `Get.to(() => EditTourScreen(tourId: id), transition: Transition.cupertino)` — used for screens not in the route table, passing arguments directly as constructor params.

No rule enforces which to use. `TourDetailScreen` uses both patterns in the same file.

## Error Handling

**Controller layer:**
- Async methods wrap Supabase/sync calls in `try { ... } catch (e) { ... }`. On catch: (1) refresh local state, (2) show `AppSnackBar.error(...)`, (3) `rethrow` so callers can gate UI.
- Realtime event processing uses a defensive catch that falls back to `_scheduleRefresh()` rather than crashing (`lib/controllers/tour_controller.dart:126`).

**UI layer:**
- Loading state: `isLoading.obs` + `Obx` shows `UgamSkeleton` shimmer or `_LoadingShimmer`.
- Error state: `hasError.obs` + `errorMessage.obs` — screen shows `UgamEmpty` with error copy and a retry CTA.
- Destructive actions: always `await UgamDialog.confirm(...)` first; proceed only on `true`.

## Logging

- `dart:developer` (`dev.log`) used in controllers for internal diagnostic noise: `dev.log('realtime apply failed: $e', name: 'TourController')`.
- `debugPrint` used in `UserController` for less critical service warnings.
- No structured logging / analytics SDK. No `print()` in production paths.

## Comment Style

Heavy inline documentation throughout. Patterns:
- **Triple-slash doc comments** (`///`) on public classes and non-obvious public methods.
- Multi-sentence **block comments** (`//`) explaining WHY a decision was made (not what the code does). E.g., the `_scheduleNotify` coalescing rationale in `tour_controller.dart`.
- **TEMP** / **TODO(scope)** markers for intentional stubs: `// TEMP: hides the "today's trip" hero`, `// TODO(seat-ui): entry point into SLICE 1`.

## Screen Structure Pattern

All screens follow the same outer shell:

```dart
class FooScreen extends StatefulWidget {           // or StatelessWidget when no local state
  final String tourId;
  const FooScreen({super.key, required this.tourId});

  @override
  State<FooScreen> createState() => _FooScreenState();
}

class _FooScreenState extends State<FooScreen> {
  // 1. Controller lookups (final fields or inside build)
  // 2. Scaffold with c.bg background
  // 3. Obx wrapper at the outermost reactive boundary
  // 4. Body: CustomScrollView with slivers, or SingleChildScrollView
  // 5. bottomNavigationBar: UgamCTA or UgamDockNav (wrapped in UgamStickyCTA / ChromeMeasure)
}

// Private helper widgets (StatelessWidget, named _PascalCase) defined
// below the screen state class in the same file.
```

`LoginScreen` is the only screen using `GetView<AuthController>` (binds controller as `controller` field) — not the preferred pattern used elsewhere.

## Model Pattern

All domain models are hand-written plain Dart classes (no codegen/freezed):
- `final` fields, immutable by convention (not enforced by `@immutable` — only `UgamColorSet` and `UgamSeatGridConfig` carry the annotation).
- Factory constructor `fromMap(Map<String, dynamic> map)` for Supabase row → model.
- Instance method `toMap()` for model → Supabase insert/update payload.
- `copyWith({...})` for state mutation throughout.

---

*Convention analysis: 2026-06-06*
