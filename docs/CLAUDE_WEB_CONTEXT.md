# Ugam Bus Booking — Project Context for Claude

> **What this file is:** a single self-contained briefing that gives Claude (or any AI assistant) everything it needs to be useful on this project.
>
> **How to use it on claude.ai:** create a Project in claude.ai → open *Project knowledge* → upload this file (or paste its contents). Every chat in that project will then have the same context that Claude Code has locally.
>
> **Snapshot date:** 2026-08-02 · branch `feat/money-collection-settlement` @ `318b511` · app version `1.0.21+25` · **1003 tests passing** across 111 test files.
>
> Source: distilled from the persistent memory files Claude Code keeps at
> `~/.claude/projects/c--WorkSpace-ugam-bus-booking/memory/`, plus a fresh read of the tree.

---

## 1. Who the user is

The user (Zeel) runs a **tour / group travel booking business**. They are **a tour booking agent**, not a bus company. Their day-to-day workflow:

- Customers contact them via **WhatsApp** asking for seats (e.g. *"I need 2 seats on the Dwarka tour"*)
- They create tours (decide route + date), broadcast to their WhatsApp contacts
- They collect seat requests, tally the total needed
- They negotiate with a **bus owner**, get bus details (driver, bus number, AC / non-AC)
- They assign specific seats to each passenger
- They assign a **"handler"** — one passenger per bus who acts as on-trip coordinator
- They lock seats and send WhatsApp confirmations with bus + seat details
- On the road the handler collects cash, logs expenses, and hands money back; the agent settles per bus and reads P&L

They are the middleman between passengers and bus owners.

---

## 2. What the app actually is

**Ugam Bus Booking** (Flutter / Supabase) is **a tour-agent operations tool**, not a direct consumer bus-booking platform. Everything revolves around a **Tour** entity moving through a lifecycle:

**Sell & fill**
1. **Create Tour** — route, date, pricing (per seat type / per row band)
2. **Broadcast** — announcement to WhatsApp contacts (deep-link *and* Cloud API template send)
3. **Collect Requests** — passengers submit seat requests (see §3)
4. **Tally & Book Bus** — agent sees totals, contacts bus owner, books the bus
5. **Add Bus Details** — bus number, driver name/phone, AC / non-AC, seat layout, price bands

**Commit**
6. **Assign Seats** — agent picks specific seats per passenger (manual board + `SeatingEngine` auto-assign)
7. **Assign Handler** — one handler *per bus*
8. **Lock & Notify** — `Tour.acceptsBookings` is the single gate; locking reveals seats to customers and dispatches WhatsApp / push confirmations

**Run & settle**
9. **Trip day** — handler chart, attendance, pickup grouping, live bus location, find-my-seat by phone
10. **Money** — collection per bus, expenses, income, handler cash handover, settlement, trip P&L
11. **Return leg** — `completeOutboundLeg`, return-ticket resale, `overrideLock` reopening
12. **Past tours** — auto-archive with `TourSeatSnapshot` seat history preserved

Every screen and model is tour-lifecycle-centric.

**Load-bearing invariants** (single nodes many features hang off — don't duplicate them):
- `Tour.acceptsBookings` — the one lock gate
- `computeTourCapacity` ([`lib/utils/tour_capacity.dart`](lib/utils/tour_capacity.dart)) — one engine snapshot so every meter agrees
- `seatsVisible` — seat reveal is gated on **lock**, not on assignment
- Money is keyed by **`bus_id`**, not by tour
- Rent asymmetry: what the agent owes the bus owner is not the mirror of what passengers owe

---

## 3. How requests come in (three paths, all landing in the DB)

1. **Customer mode in-app** — browse public tours → request form (name, phone, seat lines: type + position + qty, pickup point) → writes a Request record to the DB, then opens a **WhatsApp deep-link** to the agent's number with a pre-filled message in the customer's voice. The DB record is the source of truth; the WA ping is a courtesy so the agent doesn't switch contexts.
2. **Customer seat-chart self-booking** (migration `048`) — customer picks actual seats off the chart; `seat_chart_booking_service.dart` + `customer_seat_layout_sheet.dart`. Optional **online advance payment** via UPI (`049`, `050`, [`lib/widgets/upi_payment_sheet.dart`](lib/widgets/upi_payment_sheet.dart)).
3. **WhatsApp Cloud API inbox** (migration `033`, edge functions `wa-webhook` / `wa-reply`) — inbound WA messages land in an in-app **Inbox** with 24h session-window replies and `wa_resolve_owner` thread routing. [`lib/screens/inbox_screen.dart`](lib/screens/inbox_screen.dart), [`lib/services/whatsapp_inbox_service.dart`](lib/services/whatsapp_inbox_service.dart).

Plus a manual **"+ Add Request"** path for old customers who just text.

**Guardrails:**
- The submit form *is* the parser — don't try to parse natural-language WA messages into requests.
- Deep-link (`whatsapp_service.dart`) and Cloud API (`whatsapp_cloud_service.dart`) coexist on purpose. Deep-link is the zero-config default; Cloud API is opt-in per admin via [`lib/screens/whatsapp_settings_screen.dart`](lib/screens/whatsapp_settings_screen.dart). Don't collapse one into the other.
- The agent's WhatsApp number is a configurable Setting — that's the deep-link target.

---

## 4. Brand identity

The app serves **Ugam Foj (ઉગમ ફોજ)** — the satsangi community of **Ugaram Dada** (Ravi-Bhan / Kabir nirgun-bhakti tradition; greeting *"જય ગુરુદેવ / Jay Gurudev"*). Parent dham brand is **DEVAM — Bhedapipaliya Dham** (devam.org).

- **ઉગમ** = *rising / dawn* → a rising-sun motif is **authentic** to both the name and the saint Ugaram.
- Never fabricate sacred figures (Ugaram Dada's portrait) in generated art.

### Palette — current, live in [`lib/design/tokens.dart`](lib/design/tokens.dart)

The accent moved terracotta → coffee → **cabin-lamp amber on midnight indigo**. This is the *futuristic-simple* rebuild and it is the live palette:

| Token | Dark (primary) | Light (mirror) |
|---|---|---|
| `bg` | `#0C111F` deep indigo — never pure black | `#FFFFFF` white page |
| `card` / `cardElev` | `#141A2B` / `#1F2740` | `#FAFAFA` / `#F1F2F3` |
| `border` | white @ 10% hairline | black @ 11% hairline |
| `ink` / `ink2` / `ink3` | `#EDF1FA` / `#959EBA` / `#5C6584` | `#111214` / `#5E6169` / `#8E939B` |
| **`accent`** | `#FFC24B` amber | `#B07100` deep amber |
| `accentFill` / `glow` | ~14% / ~30% amber | `#FFF3DC` / 20% amber |
| **`action`** (buttons) | `#EDF1FA` near-white | `#111214` near-black |
| `good` (money in) | `#4ADE9A` mint | `#16A34A` |
| `warm` (ladies seat) | `#F58BB8` rose | `#C24D86` |
| `danger` | `#FF6B60` | `#C81E1E` |

**The accent rule — this is the whole design thesis:** amber means exactly one thing, **"this is yours"** — the berth you picked, the leg you chose, your row in a list. It is deliberately **not** the button colour. The primary control uses `action` (max contrast, no brand hue) — the same move Uber (`buttonPrimaryFill: #000000`) and Ola (green brand, black booking button) make. Spending the accent on buttons is what makes a UI read cheap, because then nothing is left to carry meaning.

`theme.dart` derives everything from tokens — no component hardcodes a hex. Re-skinning the app = editing the two `Brand` seeds.

---

## 5. UI / UX direction (locked)

**Density is "glanceable cockpit", not "spacious showroom".** The spacing/radius scale was deliberately compressed — **do not re-widen it.**

- **Radius:** card `16` (was 22), sheet `22` (was 28), stat `16`, row `14`, input `14`, chips/icon buttons `999` (pill). Corners read as a tool, not a toy.
- **Spacing:** `xs 4 · sm 8 · tight 10 · md 12 · gutter 14 · lg 16 · xl 16 · xxl 20 · huge 26 · huge2 32 · huge3 44`. Note `xl == lg` on purpose. `dockClearance = 140` for scrollables under the floating dock.
- **Type:** **Sora** for display voice (hero figures, titles, numerals, micro-labels), **Inter** for body/small UI. Both bundled; `GoogleFonts.config.allowRuntimeFetching = false`. Tabular numerics on every price / count / ID.
- **Dark-first**; light is a complete mirror, not a fallback.
- **Floating dock bottom nav** (capsule, circular icon buttons) — replaces the old `_PillBottomNav`.
- **Sticky pill CTAs** at the thumb zone on workflow screens.
- **Hero photography** on customer-facing tour cards.
- **Status/nav bar is themed app-wide** in the `app.dart` builder — but the custom `UgamAppBar` bypasses `AppBarTheme.systemOverlayStyle`, so overlay style must be set there too.
- **No bilingual sub-labels in UI.** `easy_localization` handles full-string translation in **en / gu / hi**; the user picks one in Settings. Gujarati is the default locale.
- **No decorative noise:** no splash decorative circles, no "FIG. 001 · AUTHENTICATION" filler, no costume serif headlines.

**When Zeel asks for "UI polish", that means polish the existing layout — not re-architect it.** Keep functionality and keep seat-tile content (name + mobile + background colours).

**Rejected directions — don't re-propose:** Khatabook-style dense bilingual ledger · editorial serif "Premium Travel" · Linear-style "Operator Pro" terminal · saffron/cream regional warm · light-mode-first.

Authoritative specs: [`docs/superpowers/specs/2026-05-20-ui-design-system-design.md`](docs/superpowers/specs/2026-05-20-ui-design-system-design.md), then [`2026-06-22-ugam-futuristic-rebuild.md`](docs/superpowers/specs/2026-06-22-ugam-futuristic-rebuild.md) (current), and [`2026-07-20-handler-redesign-money-cluster-design.md`](docs/superpowers/specs/2026-07-20-handler-redesign-money-cluster-design.md) for the handler app's five-rule design language (one hero · semantic colour · no zero-states · state rhythm · space is earned).

---

## 6. Domain rules — Double Sofa pair semantics

A **Double Sofa** cell holds **at most two berths**. Three valid occupancy states:

1. **Empty** — 0 berths held.
2. **Whole-double** — ONE passenger holds BOTH berths (their `assignedSeats` has two `SeatAssignment` entries with the same `seatId`).
3. **Paired double** — TWO different passengers each hold one berth on the same seat (a couple who booked separately and got paired).

### Drag-and-drop rules

**From a paired double:** the two travel as a unit — moving "one of them" moves **both**. Drop target must be a **free Double Sofa**. Otherwise block with: *"This is a paired double — drop it on a free Double Sofa, or break the pair first from the seat dialog."*

**From a whole-double:** target must take 2 berths → free Double Sofa only (`berths > targetCapacity` guard).

**Solo from Single Sofa or shared Double:** berth count 1, lands on any compatible 1-berth slot.

### Cross-fill: 2 single sofas → 1 double sofa request

A `doubleSofa` request line can be satisfied by TWO `singleSofa` assignments when no double is free. Tapping a free Single while a `doubleSofa` line is pending claims 1 berth; `_pendingLines` pairs leftovers and drains one `doubleSofa` line per 2 singles. `_berthsForFreeCell` returns 1 for a single when a pending double exists.

### Cross-fill consolidation: 2 singles → 1 whole double on drag

If a passenger satisfied a `doubleSofa` via two singles (e.g. L5 + L7) and a free Double opens up, dragging **either** single onto it **consolidates** both:
- Source: a Single Sofa held by the passenger · Target: a FREE Double Sofa · Passenger must hold ≥1 other single to release.

`TourController.consolidateOntoDouble({tourId, passengerId, busId, targetSeatId, sourceSeatIds})` — atomic single server write. Snackbar: *"Consolidated &lt;name&gt; onto &lt;target&gt; — &lt;s1&gt; + &lt;s2&gt; freed."* If the passenger holds only one single, the drop falls through to normal `moveSeat` (they end up owning half the target double).

### Source files
- Berth semantics + server writes: [`lib/controllers/tour_controller.dart`](lib/controllers/tour_controller.dart) → `moveSeat`, `swapSeats`, `consolidateOntoDouble`
- Board + drop handling: [`lib/screens/tour_seat_assignment_screen.dart`](lib/screens/tour_seat_assignment_screen.dart)
- Extracted move/swap logic: [`lib/services/seat_move_flow.dart`](lib/services/seat_move_flow.dart), [`swap_candidate_finder.dart`](lib/services/swap_candidate_finder.dart), [`seat_swap_guard.dart`](lib/services/seat_swap_guard.dart)
- Auto-assign: [`lib/services/seating_engine.dart`](lib/services/seating_engine.dart) (pure-Dart greedy), [`seating_plan_applier.dart`](lib/services/seating_plan_applier.dart), [`group_cascade.dart`](lib/services/group_cascade.dart)

---

## 7. iOS specifics

### Scene lifecycle (UISceneDelegate)

`ios/Runner/Info.plist` declares `UIApplicationSceneManifest` → `FlutterSceneDelegate`. `AppDelegate.swift` adopts `FlutterImplicitEngineDelegate` and registers plugins in `didInitializeImplicitFlutterEngine` (not `didFinishLaunchingWithOptions`).

**Consequence:** the window is owned by the scene, so `UIApplication.shared.delegate.window` is `nil` at plugin-registration time. Any native plugin that force-unwraps `UIApplication.shared.delegate!.window!!.rootViewController!` in its `register()` **crashes the app at launch** with *"Unexpectedly found nil while unwrapping an Optional value."*

Hit this with `flutter_contacts` 1.1.9+2 — fixed by upgrading to **2.x** (the 2.0.0-beta.4 *"Migrate to UISceneDelegate"* release resolves rootViewController lazily via `connectedScenes`). Currently on `flutter_contacts: ^2.1.0`. The 2.0 rewrite changed the Dart API: `requestPermission(readonly:)` → `FlutterContacts.permissions.request(PermissionType.read)`, `getContacts(...)` → `getAll(properties: {ContactProperty.phone})`, `Contact.displayName` is now nullable.

**When adding native iOS plugins, prefer scene-compatible versions.** Fallback if a plugin can't be upgraded: revert Runner to the legacy `UIApplicationDelegate` lifecycle.

### Release IPA build — always use the script

**Release iOS by running `./scripts/build_ios_release.sh`** (`flutter clean` → `flutter build ipa` → verifies every framework binary is `platform IOS`, refuses to emit a contaminated IPA).

**Why:** `objective_c.framework` is a Flutter native asset pulled in transitively by `path_provider_foundation` (a dep of sqflite / supabase_flutter / shared_preferences — unavoidable). Native assets cache in `build/native_assets/`. If a **Simulator** build runs first, a later **device** archive silently reuses the simulator-built framework, producing an IPA App Store rejects with: *"objective_c executable references an unsupported platform in the arm64 slice."* (device + simulator both use arm64 on Apple Silicon — the wrong slice isn't obvious.)

**How to apply:** `flutter clean` before any `flutter build ipa`; never archive right after a simulator run. Verify with `vtool -show-build <framework-binary>` → must say `platform IOS`. Build hygiene, not a package bug — swapping the contacts package does not fix it.

---

## 8. Working preferences (how Zeel wants to collaborate)

### No AI co-author trailer in commits
Do **not** add `Co-Authored-By: Claude … <noreply@anthropic.com>` (or any AI co-author trailer) to commit messages. End commit messages at the description.

### Don't pause between roadmap phases
When executing a multi-phase build, **don't stop after each phase to ask "want me to continue?"** Plow through all remaining phases. Zeel uses other AI agents for bug fixes / reviews — the model is *"you build, they fix."* Still pause on a real fork (architecture decision, ambiguous requirement) or if a specific bug has been delegated. Keep todos updated so progress is visible.

### Use built-in file tools, not bash for file work
Use **Read** / **Edit** / **Write** — they surface content and diffs reviewably. Avoid `cat / head / tail / sed -n` for viewing and `sed -i / awk -i inplace / echo >` for editing. Bash is still right for `grep`, `find`, git, and build/test runs.

### UI direction must be grounded in real app references
For any UI / visual question, **don't show abstract aesthetic moods** or speculative combinations of unrelated app DNAs. Either build mockups that map 1:1 to specific screens in references Zeel has pointed at, or ask *"show me 2–3 apps you actually like the look of."* Three rounds of speculative direction proposals were rejected. The pattern that works: Zeel provides references → mockups match them precisely → only small remaining choices get asked about.

### Migrations are deployed by hand, one file at a time
SQL under `supabase/migrations/` is applied manually in the Supabase console. Assume a migration is **not** live until confirmed.

### Some RPCs exist only in the live DB
A few customer RPCs (`bus_layouts_for_request`, `booking_request_status_lookup`) exist in production but have no migration file in the repo. **Add a NEW RPC and merge client-side — never blind-replace one of these.**

### Tests: `easy_localization`
`plural()` throws `LateInitializationError` in widget tests unless a locale is loaded via `Localization.load` in `setUpAll`. `tr()` is safe without it. (The `[🌎 Easy Localization] key not found` warnings in test output are harness noise, not missing keys.)

---

## 9. Tech stack quick reference

- **Framework:** Flutter **3.44.2** stable · Dart SDK `^3.10.3` · app version `1.0.21+25`
- **Backend:** Supabase (Postgres + Auth + Realtime + Storage). **51 migrations** in [`supabase/migrations/`](supabase/migrations/) (`001` … `051_broadcast_bucket_public`). Baseline schema also in [`database.sql`](database.sql).
- **Edge functions:** [`supabase/functions/`](supabase/functions/) — `bus-message`, `quick-action`, `send-push`, `wa-webhook`, `wa-reply`
- **State management:** GetX (`Get.to`, `GetxController`, `Obx`) — 10 controllers in [`lib/controllers/`](lib/controllers/)
- **Push:** Firebase Core 4.x + Messaging 16.x → [`lib/services/push_service.dart`](lib/services/push_service.dart)
- **Auth:** Supabase auth + admin password + **biometric unlock** (`local_auth`, [`biometric_credential_store.dart`](lib/services/biometric_credential_store.dart))
- **i18n:** `easy_localization` — [`assets/translations/en.json`](assets/translations/en.json) / [`gu.json`](assets/translations/gu.json) / [`hi.json`](assets/translations/hi.json). Keys are dot-notation over nested dicts. **All three files must stay in parity.** Helper: [`scripts/merge_translations.dart`](scripts/merge_translations.dart)
- **Design system:** [`lib/design/`](lib/design/) — `tokens.dart`, `text_styles.dart`, `theme.dart`, `ugam.dart` barrel, 15 `Ugam*` components. Legacy `lib/config/theme.dart` (`AppTheme` / `AppText`) is **deprecated** — no new call sites.
- **WhatsApp:** deep-link ([`whatsapp_service.dart`](lib/services/whatsapp_service.dart)) **and** Cloud API ([`whatsapp_cloud_service.dart`](lib/services/whatsapp_cloud_service.dart), [`whatsapp_inbox_service.dart`](lib/services/whatsapp_inbox_service.dart))
- **Platform:** Android `com.occubitsolution.ugambooking`; iOS bundle in [`ios/Runner.xcodeproj/project.pbxproj`](ios/Runner.xcodeproj/project.pbxproj)
- **Shape of the code:** 45 screens · 37 models · 25 services · 21 widgets · 44 design files · 28 utils · 10 components · 111 test files / **1003 tests**

---

## 10. Where to look first for common tasks

| Task | Start here |
|---|---|
| Add or change a translation | [`assets/translations/en.json`](assets/translations/en.json) + `gu.json` + `hi.json` — keep all three in sync |
| Change brand colour / radius / spacing | [`lib/design/tokens.dart`](lib/design/tokens.dart) — single source of truth |
| Customer-facing screens | `lib/screens/customer_*.dart`, `find_my_seat_screen.dart`, `seat_selection_screen.dart`, `seat_booking_confirm_screen.dart` |
| Agent-facing screens | `lib/screens/` — `dashboard`, `tours`, `tour_detail`, `tour_overview`, `requests`, `tour_seat_assignment`, `seats`, `notify`, `manage_buses` |
| Handler / trip-day screens | `handler_bus_chart_screen.dart`, `charts_screen.dart`, `fullscreen_chart_screen.dart`, `bus_status_screen.dart` |
| Money & settlement | `collection_screen.dart`, `bus_money_screen.dart`, `tour_money_board_screen.dart`, `trip_pnl_screen.dart`, `finance_screen.dart` + [`money_controller.dart`](lib/controllers/money_controller.dart), [`finance_controller.dart`](lib/controllers/finance_controller.dart), [`collection_reconciler.dart`](lib/services/collection_reconciler.dart) |
| Seat assignment / drag-drop | [`tour_seat_assignment_screen.dart`](lib/screens/tour_seat_assignment_screen.dart) + [`tour_controller.dart`](lib/controllers/tour_controller.dart) + `lib/services/seat_*.dart` |
| Capacity / free-seat maths | [`lib/utils/tour_capacity.dart`](lib/utils/tour_capacity.dart) — `computeTourCapacity` is the one snapshot |
| WhatsApp deep-link copy | [`lib/services/whatsapp_service.dart`](lib/services/whatsapp_service.dart) |
| WhatsApp Cloud API / inbox | [`whatsapp_cloud_service.dart`](lib/services/whatsapp_cloud_service.dart), `supabase/functions/wa-webhook`, [`WHATSAPP_INBOX_SETUP.md`](supabase/functions/WHATSAPP_INBOX_SETUP.md) |
| Build iOS release | `./scripts/build_ios_release.sh` (never raw `flutter build ipa`) |
| Build Android release | bump `version:` in [`pubspec.yaml`](pubspec.yaml), then `flutter build appbundle` |
| Store / submission docs | [`docs/publishing/`](docs/publishing/) and [`docs/legal/`](docs/legal/) |
| Known bugs / open findings | [`docs/BUGS.md`](docs/BUGS.md) and [`docs/superpowers/audits/2026-07-21-full-app-audit.md`](docs/superpowers/audits/2026-07-21-full-app-audit.md) |
| End-to-end behaviour spec | [`docs/use-cases/`](docs/use-cases/) (9 use cases + 6 scenarios) — the behavioural charter |
| Codebase knowledge graph | `graphify-out/` — `graphify query "<question>"`, `graphify path "A" "B"`, `graphify explain "X"`; rebuild with `graphify update .` |

---

## 11. Where the work stands (2026-08-02)

- **Branch:** `feat/money-collection-settlement`, in sync with its origin remote; `main` is 49 commits behind it.
- **Health:** `flutter test` → **1003 passing, 0 failing**.
- **Recently shipped:** customer seat-chart booking flow end-to-end · handler redesign (money cluster, pickup chips, lock gate, de-anonymised seat sheet) · money collection & settlement (collection, bus money, trip P&L, handover) · past-tours archive with seat snapshots · login/biometric redesign · app-wide density overhaul.
- **The working backlog** is the 6-phase plan in [`docs/superpowers/plans/`](docs/superpowers/plans/) (`2026-07-21-phase-0-unblock` … `phase-5-release-engineering`), driven by the full-app audit. Phase 0 was about hand-deploying migrations `039`–`041`; migrations now run to `051`, so treat the phase docs as the *plan of record* and verify against the live DB before assuming a step is still open.

---

*This doc is a snapshot. The live source of truth for conventions discovered after this date stays in the Claude Code memory directory; re-export this file when the picture changes materially.*
