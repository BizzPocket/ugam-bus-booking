# Codebase Structure

**Analysis Date:** 2026-06-06

## Directory Layout

```
occubusbooking/
├── lib/                      # All Dart application code
│   ├── main.dart             # Entry point: bootstrap, async init, pre-init splash
│   ├── app.dart              # MyApp + AppBinding (GetX DI root)
│   ├── config/               # Static config constants (Supabase keys, i18n, contacts)
│   ├── controllers/          # GetX controllers — all mutable reactive state
│   ├── design/               # "Ugam" design system (tokens, theme, components)
│   ├── models/               # Immutable plain-Dart value objects
│   ├── routes/               # Named-route registry
│   ├── screens/              # Flutter screen widgets (one file = one screen)
│   ├── services/             # Infrastructure services (Supabase, realtime, engine)
│   ├── utils/                # Stateless helpers (formatters, validators, dialogs)
│   ├── components/           # Domain-specific composite widgets (not design-system)
│   ├── widgets/              # Reusable bottom-sheet widgets
│   └── content/              # Static in-app content (legal text)
├── assets/
│   ├── translations/         # EasyLocalization JSON: en.json, gu.json, hi.json
│   ├── fonts/                # Inter font files (bundled, runtime fetch disabled)
│   ├── images/               # App images / hero assets
│   └── icon/                 # App icon source files
├── supabase/
│   ├── migrations/           # 001–010 SQL migrations (Supabase CLI)
│   └── functions/
│       └── whatsapp-send/    # Edge function: WhatsApp Cloud API broadcast
│           └── index.ts
├── test/                     # Unit + widget tests (mirrors lib/ structure)
│   ├── components/
│   ├── config/
│   ├── design/
│   ├── models/
│   ├── screens/
│   ├── services/
│   └── utils/
├── android/                  # Android platform project
├── ios/                      # iOS platform project
├── scripts/                  # build_ios_release.sh (guards simulator-slice leak)
├── docs/                     # Specs, legal content, publishing guides
├── .planning/                # GSD planning artefacts
│   └── codebase/             # Codebase map documents (this directory)
└── pubspec.yaml              # Dart package manifest
```

## Directory Purposes

**`lib/config/`:**
- Purpose: Compile-time constants; never reads from .env
- Key files:
  - `lib/config/supabase_config.dart` — Supabase project URL + anon key
  - `lib/config/whatsapp_cloud_config.dart` — Edge function URL for broadcast
  - `lib/config/i18n_config.dart` — Supported locales + asset path
  - `lib/config/app_contact.dart` — Agent's WhatsApp/phone contact

**`lib/controllers/`:**
- Purpose: All application state via GetX `GetxController`; screens observe, never hold state
- Key files:
  - `lib/controllers/tour_controller.dart` — Primary controller; 1 561 lines; all tour/passenger/bus/seat CRUD + auto-fill
  - `lib/controllers/auth_controller.dart` — Phone+password Supabase Auth, session restore, admin/passenger role
  - `lib/controllers/money_controller.dart` — Collections, expenses, bus handovers (per-tour, loaded on demand)
  - `lib/controllers/customer_memory_controller.dart` — Returning-customer memory (priority + companions)
  - `lib/controllers/theme_controller.dart` — Dark/light/system theme toggle
  - `lib/controllers/locale_controller.dart` — App locale switching
  - `lib/controllers/user_controller.dart` — Admin's contact list (WhatsApp broadcast recipients)

**`lib/design/`:**
- Purpose: The "Ugam" design system; single barrel import `lib/design/ugam.dart`
- Key files:
  - `lib/design/tokens.dart` — `UgamColors`, `UgamRadius`, `UgamSpacing`, `UgamMotion`; brand seeds in `Brand` class
  - `lib/design/theme.dart` — `UgamTheme.dark()` / `.light()` for `GetMaterialApp`
  - `lib/design/text_styles.dart` — `UgamText` type scale
  - `lib/design/ugam.dart` — Barrel re-export of all tokens + components
  - `lib/design/group_color.dart` — Infinite group color palette for cross-booking groups
  - `lib/design/components/ugam_cta.dart` — Primary action button
  - `lib/design/components/ugam_dialog.dart` — Branded confirm/info dialogs
  - `lib/design/components/ugam_sheet.dart` — Bottom sheet scaffold
  - `lib/design/components/ugam_input.dart` — Branded text field
  - `lib/design/components/ugam_dock_nav.dart` — Bottom navigation pill bar
  - `lib/design/components/ugam_skeleton.dart` — Loading shimmer
  - `lib/design/components/ugam_chrome.dart` — `UgamChromeObserver` (nav observer for status bar management)
  - `lib/design/components/ugam_tab_pills.dart` — Segmented tab pill control
  - `lib/design/components/ugam_seat_grid.dart` — Seat-map grid widget
  - `lib/design/components/ugam_snackbar.dart` — Branded snackbar (use via `lib/utils/app_snackbar.dart`)

**`lib/models/`:**
- Purpose: Plain Dart value objects; immutable, with `fromMap` / `toMap` / `copyWith`
- Key files:
  - `lib/models/tour.dart` — Aggregate root; embeds buses, passengers, groups; `TourStatus` state machine
  - `lib/models/passenger.dart` — `RequestLine` list + `SeatAssignment` list; `groupId`, `tripType`, `priorityStatus`
  - `lib/models/bus_details.dart` — `Bus` with embedded `SeatLayout`; 485 lines
  - `lib/models/seat_layout.dart` — `SeatLayout` grid of `SeatCell` objects; 538 lines
  - `lib/models/seat_assignment.dart` — `(busId, seatId, locked)` tuple
  - `lib/models/passenger_group.dart` — Cross-booking group with color index
  - `lib/models/request_line.dart` — `(seatType, position, qty)` — what the customer asked for
  - `lib/models/collection.dart`, `lib/models/expense.dart`, `lib/models/bus_handover.dart` — Money domain models

**`lib/routes/`:**
- Purpose: Single file `lib/routes/app_routes.dart`; all named route strings and `GetPage` list with argument parsing

**`lib/screens/`:**
- Purpose: One file per screen; pure UI; business logic lives in controllers only
- Admin screens:
  - `lib/screens/main_shell.dart` — Bottom-nav shell (Home · Tours · Settings) with lazy-mount IndexedStack
  - `lib/screens/dashboard_screen.dart` — Admin home (1 300 lines)
  - `lib/screens/tours_screen.dart` — Time-grouped tour list (787 lines)
  - `lib/screens/tour_detail_screen.dart` — Per-tour workspace with Overview/Passengers/Buses/Activity tabs (1 765 lines)
  - `lib/screens/seats_screen.dart` — Unified seat workspace (Auto-fill / Assign / Rearrange tabs via IndexedStack)
  - `lib/screens/tour_overview_screen.dart` — Auto-fill mode sub-screen (924 lines)
  - `lib/screens/tour_seat_assignment_screen.dart` — Assign mode sub-screen (1 712 lines)
  - `lib/screens/seat_assignment_screen.dart` — Rearrange / drag-drop mode sub-screen (1 723 lines)
  - `lib/screens/seat_detail_screen.dart` — Per-bus occupant roster (3 074 lines; largest file in the repo)
  - `lib/screens/requests_screen.dart` — Incoming booking requests list (1 836 lines)
  - `lib/screens/add_bus_screen.dart` — Bus builder / seat-layout editor (2 407 lines)
  - `lib/screens/handler_bus_chart_screen.dart` — Handler printable seat chart (2 549 lines)
  - `lib/screens/tour_groups_screen.dart` — Cross-booking group manager (848 lines)
  - `lib/screens/tour_money_board_screen.dart` — Money dashboard per tour (551 lines)
  - `lib/screens/seating_exceptions_screen.dart` — Auto-fill exception review (609 lines)
  - `lib/screens/settings_screen.dart` — Settings root (719 lines)
  - `lib/screens/notify_screen.dart` — WhatsApp broadcast composer (1 278 lines)
  - `lib/screens/manage_buses_screen.dart` — Bus list + management (527 lines)
- Customer screens (under same `lib/screens/`):
  - `lib/screens/customer_tour_list_screen.dart` — Browse public tours (734 lines)
  - `lib/screens/customer_tour_detail_screen.dart` — Tour info + booking CTA (860 lines)
  - `lib/screens/customer_booking_request_screen.dart` — Booking form (996 lines)
  - `lib/screens/customer_my_requests_screen.dart` — "My requests" list (729 lines)
- Auth / setup:
  - `lib/screens/splash_screen.dart` — Session restore + routing gate
  - `lib/screens/login_screen.dart` — Phone + password form
  - `lib/screens/admin_setup_screen.dart` — First-time admin registration

**`lib/services/`:**
- Purpose: Infrastructure; no UI; injected into controllers
- Key files:
  - `lib/services/sync_service.dart` — Online-only Supabase access layer (353 lines)
  - `lib/services/realtime_service.dart` — Supabase Realtime channel + broadcast stream (130 lines)
  - `lib/services/seating_engine.dart` — Deterministic greedy seat algorithm (1 857 lines)
  - `lib/services/seating_plan_applier.dart` — Diff engine output vs current state (90 lines)
  - `lib/services/group_cascade.dart` — Group-move fit planner (299 lines)
  - `lib/services/swap_candidate_finder.dart` — Drag-swap candidate lookup (528 lines)
  - `lib/services/seat_chart_pdf.dart` — PDF generation for handler chart (535 lines)
  - `lib/services/customer_requests_store.dart` — Customer-side booking-requests reader (393 lines)
  - `lib/services/whatsapp_service.dart` — WA deep-link + broadcast helpers (424 lines)
  - `lib/services/whatsapp_outbound.dart` — Outbound message template builder (128 lines)
  - `lib/services/whatsapp_cloud_service.dart` — WhatsApp Cloud API edge function client (138 lines)
  - `lib/services/supabase_service.dart` — Thin Supabase client wrapper + ping (24 lines)
  - `lib/services/admin_auth_service.dart` — Supabase Auth low-level calls (90 lines)
  - `lib/services/contact_sync_service.dart` — Device contacts reader
  - `lib/services/chart_footer_store.dart` — Persistent chart footer text
  - `lib/services/user_service.dart` — Admin contacts CRUD

**`lib/utils/`:**
- Purpose: Stateless pure helper functions; no state, no Flutter framework dependency
- Key files:
  - `lib/utils/app_snackbar.dart` — `AppSnackBar.error/warning/success` (delegates to `UgamSnackbar`)
  - `lib/utils/app_dialogs.dart` — Pre-built confirm/info dialog helpers
  - `lib/utils/formatters.dart` — Date, currency, phone formatters
  - `lib/utils/validators.dart` — Field validation functions
  - `lib/utils/phone_normalize.dart` — Phone number normalisation (used by memory + dedup)
  - `lib/utils/seat_grid_placement.dart` — Grid coordinate helpers for the seat editor
  - `lib/utils/passenger_display.dart` — Passenger display name/initials helpers
  - `lib/utils/constants.dart` — App-wide magic constants

**`lib/components/`:**
- Purpose: Domain-aware composite widgets (not generic design-system components)
- Key files:
  - `lib/components/seat_map.dart` — Full seat-map widget (uses `UgamSeatGrid` internally)
  - `lib/components/combined_seat_grid.dart` — Multi-bus combined grid view
  - `lib/components/tour_card.dart` — Tour list card
  - `lib/components/seat_chart_tile.dart` — Per-seat tile for the chart view
  - `lib/components/phase_indicator.dart` — Tour lifecycle phase progress indicator
  - `lib/components/ugam_logo.dart` — Brand logo widget (SVG/canvas; used by splash + bootstrap)

**`lib/widgets/`:**
- Purpose: Reusable bottom-sheet widgets with their own logic
- Key files:
  - `lib/widgets/edit_request_sheet.dart` — Edit booking request bottom sheet
  - `lib/widgets/customer_seat_layout_sheet.dart` — Customer-facing seat layout preview sheet
  - `lib/widgets/chart_footer_sheet.dart` — Chart footer editor sheet
  - `lib/widgets/settings_scaffold.dart` — Shared scaffold for settings sub-screens
  - `lib/widgets/language_picker_sheet.dart` — Language selection sheet
  - `lib/widgets/seat_occupant_label.dart` — Seat occupant overlay label widget

**`assets/translations/`:**
- Purpose: EasyLocalization JSON files; all user-visible strings
- Files: `en.json`, `gu.json`, `hi.json` — must be kept in sync

**`supabase/migrations/`:**
- Purpose: Supabase CLI SQL migrations; defines schema + RLS policies
- Files: `001_initial_schema.sql` through `010_handler_expenses.sql`
- Note: Two pairs of duplicate-numbered files exist (`004_*` × 2, `006_*` × 2) — sequence is unreliable

**`supabase/functions/whatsapp-send/`:**
- Purpose: Deno Edge Function for WhatsApp Cloud API broadcast (TypeScript)
- Key file: `supabase/functions/whatsapp-send/index.ts`

## Key File Locations

**Entry Points:**
- `lib/main.dart` — Bootstrap; starts async init + pre-init splash
- `lib/app.dart` — `MyApp` (GetMaterialApp) + `AppBinding` (DI)
- `lib/routes/app_routes.dart` — All named routes

**Configuration:**
- `lib/config/supabase_config.dart` — Supabase URL + anon key
- `lib/config/i18n_config.dart` — Locale config
- `pubspec.yaml` — Package manifest, asset declarations

**Core Logic:**
- `lib/controllers/tour_controller.dart` — Primary domain controller (1 561 lines)
- `lib/services/sync_service.dart` — Only file that writes to Supabase REST
- `lib/services/seating_engine.dart` — Auto-fill algorithm (1 857 lines)
- `lib/services/realtime_service.dart` — Live sync channel
- `lib/design/tokens.dart` — Brand color/spacing/motion tokens

**Shell / Navigation:**
- `lib/screens/main_shell.dart` — Admin shell + `ShellController`
- `lib/screens/splash_screen.dart` — Auth-aware routing gate

**Largest / Most Complex Files:**
| File | Lines | Complexity driver |
|------|-------|-------------------|
| `lib/screens/seat_detail_screen.dart` | 3 074 | Seat roster + occupant logic + PDF export |
| `lib/screens/handler_bus_chart_screen.dart` | 2 549 | Full chart rendering + print flow |
| `lib/screens/add_bus_screen.dart` | 2 407 | Interactive seat-layout builder |
| `lib/services/seating_engine.dart` | 1 857 | Full greedy algorithm + internal state |
| `lib/screens/requests_screen.dart` | 1 836 | Passenger requests list + inline actions |
| `lib/screens/tour_detail_screen.dart` | 1 765 | Per-tour workspace + 4 sub-tabs |
| `lib/screens/seat_assignment_screen.dart` | 1 723 | Drag-drop rearrange UI |
| `lib/screens/tour_seat_assignment_screen.dart` | 1 712 | Tap-to-assign UI |
| `lib/controllers/tour_controller.dart` | 1 561 | All tour domain CRUD + realtime |

## Naming Conventions

**Files:**
- `snake_case.dart` for all Dart files
- Screens: `<noun>_screen.dart` (e.g. `tour_detail_screen.dart`)
- Controllers: `<noun>_controller.dart`
- Services: `<noun>_service.dart` or `<noun>_store.dart` (for passive data stores)
- Models: singular noun (e.g. `tour.dart`, `passenger.dart`)
- Design components: `ugam_<component>.dart`
- Utilities: descriptive noun (e.g. `phone_normalize.dart`, `formatters.dart`)

**Classes:**
- `PascalCase` for all classes
- Screen widgets: `<Noun>Screen` (e.g. `TourDetailScreen`)
- Controllers: `<Noun>Controller`
- Services: `<Noun>Service`
- Models: plain `<Noun>` (e.g. `Tour`, `Passenger`, `Bus`)
- Design tokens: `Ugam<Category>` (e.g. `UgamColors`, `UgamSpacing`)
- Design components: `Ugam<Component>` (e.g. `UgamCta`, `UgamDockNav`)

**Directories:**
- All lowercase with no separators (matches Flutter convention)

## Where to Add New Code

**New admin screen:**
- Implementation: `lib/screens/<noun>_screen.dart`
- Register route: add to `lib/routes/app_routes.dart` as `static const String <camelCase> = '/<kebab>'` + `GetPage` entry
- Navigation: `Get.toNamed(AppRoutes.<camelCase>, arguments: {'tourId': id})`

**New customer screen:**
- Same pattern as admin screen; customer screens go in `lib/screens/` with `customer_` prefix

**New domain operation on tours/passengers:**
- Add method to `lib/controllers/tour_controller.dart`; follow the `_updatePassengerLocal → smartUpdate → catch/refreshTours` pattern

**New money operation:**
- Add method to `lib/controllers/money_controller.dart`

**New model:**
- Add `lib/models/<noun>.dart` with `fromMap`, `toMap`, `copyWith`, `==`, `hashCode`

**New service (infrastructure concern):**
- Add `lib/services/<noun>_service.dart`; register in `AppBinding.dependencies()` if needed globally

**New design component:**
- Add `lib/design/components/ugam_<component>.dart`
- Add re-export line to `lib/design/ugam.dart`

**New domain-specific widget (not design-system):**
- Shared composite: `lib/components/<noun>.dart`
- Bottom-sheet widget: `lib/widgets/<noun>_sheet.dart`

**Utility / pure helper:**
- Add `lib/utils/<noun>.dart`; no framework imports preferred

**New translation key:**
- Add to all three files: `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json`

**New Supabase table / RLS change:**
- Add `supabase/migrations/<NNN>_<description>.sql` (next sequential number; avoid duplicates)

## Special Directories

**`.planning/`:**
- Purpose: GSD planning artefacts (codebase maps, phase plans)
- Generated: No
- Committed: Yes

**`build/`:**
- Purpose: Flutter build outputs
- Generated: Yes
- Committed: No

**`.dart_tool/`:**
- Purpose: Dart tooling cache
- Generated: Yes
- Committed: No

**`supabase/.temp/`:**
- Purpose: Supabase CLI temp files
- Generated: Yes
- Committed: No

---

*Structure analysis: 2026-06-06*
