# Ugam Bus Booking — Project Context for Claude

> **What this file is:** a single self-contained briefing that gives Claude (or any AI assistant) everything it needs to be useful on this project.
>
> **How to use it on claude.ai:** create a Project in claude.ai → open *Project knowledge* → upload this file (or paste its contents). Every chat in that project will then have the same context that Claude Code has locally.
>
> Source: distilled from the 12 persistent memory files Claude Code keeps at
> `~/.claude/projects/-Users-zeelshiyani-WorkSpace-occubusbooking/memory/` on the project owner's laptop.

---

## 1. Who the user is

The user (Zeel) runs a **tour / group travel booking business**. They are **a tour booking agent**, not a bus company. Their day-to-day workflow:

- Customers contact them via **WhatsApp** asking for seats (e.g. *"I need 2 seats on the Dwarka tour"*)
- They create tours (decide route + date), broadcast to their WhatsApp contacts
- They collect seat requests, tally the total needed
- They negotiate with a **bus owner**, get bus details (driver, bus number, AC / non-AC)
- They assign specific seats to each passenger
- They assign a **"handler"** — one passenger who acts as on-trip coordinator
- They lock seats and send WhatsApp confirmations with bus + seat details

They are the middleman between passengers and bus owners.

---

## 2. What the app actually is

**Ugam Bus Booking** (Flutter / Supabase) is **a tour-agent management tool**, not a direct consumer bus-booking platform. The whole architecture revolves around a **Tour** entity going through an 8-phase lifecycle:

1. **Create Tour** — route, date, price per seat
2. **Broadcast** — send announcement to WhatsApp contacts
3. **Collect Requests** — passengers submit seat requests (see §3)
4. **Tally & Book Bus** — agent sees totals, contacts bus owner, books the bus
5. **Add Bus Details** — bus number, driver name/phone, AC / non-AC
6. **Assign Seats** — agent picks specific seats per passenger
7. **Assign Handler** — agent designates a passenger as on-trip handler
8. **Lock & Notify** — locked tour, WhatsApp confirmations sent to all passengers

Every screen and model is tour-lifecycle-centric. WhatsApp integration is core UX even though it's deep-link based, not Business API.

---

## 3. Customer request capture (no WhatsApp Business API)

Customer mode in the app is the primary request-capture mechanism:

1. Customer opens app in customer mode, browses public tours
2. Picks a tour, fills request form (name, phone, seat lines: type + position + qty)
3. On submit:
   - App writes a **Request record to the DB** — that's the source of truth
   - App opens a **WhatsApp deep-link** to the agent's configured number with a **pre-filled message** in the customer's voice (e.g. *"Mare 2 double sofa joie che — <tour title>"*)
   - Customer taps Send in WhatsApp — agent gets a familiar WA ping AND the structured data is already in DB

The agent's Requests screen reads from DB, not WhatsApp. WhatsApp is a courtesy notification so the agent doesn't have to switch contexts.

**Important guardrails:**
- Don't propose WhatsApp Business API integration. The deep-link pattern handles it.
- The submit form *is* the parser — don't try to parse natural-language WA messages.
- For old customers who text directly without using the app, the agent screen still needs a manual *"+ Add Request"* entry path.
- The agent's WhatsApp number is a configurable Setting — that's the deep-link target.

---

## 4. Brand identity

The app serves **Ugam Foj (ઉગમ ફોજ)** — the satsangi community of **Ugaram Dada** (Ravi-Bhan / Kabir nirgun-bhakti tradition; greeting *"જય ગુરુદેવ / Jay Gurudev"*). Parent dham brand is **DEVAM — Bhedapipaliya Dham** (devam.org).

- **ઉગમ** = *rising / dawn* → a rising-sun motif is **authentic** to both the name and the saint Ugaram.
- The app books the community's satsang **yatra bus** trips. The canonical logo concept is **terracotta rising sun + cream ઉગમ + deep-brown side-view bus**.
- Never fabricate sacred figures (Ugaram Dada's portrait) in generated art.

### Palette (current, as of 2026-05-28)

The accent has shifted over time. Current locked accent is **coffee / espresso brown** — locked in [`lib/design/tokens.dart`](lib/design/tokens.dart) via a `Brand` seed block:

| Token | Light | Dark | Notes |
|---|---|---|---|
| Brand seed (terracotta) | `#C56A3F` | `#E07A4F` (bright) | legacy reference; kept in `Brand` but unused as live accent |
| **Live accent (coffee)** | `#3B2A20` | `#B07A52` (lifted mocha) | dark-first app; pure coffee on near-black `#0A0A0A` is illegible — so dark mode uses a lifted mocha |
| accentFill | `#EADFD6` (pale latte) | 16%-alpha mocha | |
| Background | `#FBF3EC` (cream) | `#0A0A0A` | dark-first; light is a full mirror |
| Ink (primary text) | `#4A2F25` (dark brown) | `#FAFAFA` | |
| Warm callout (attention / ladies) | `#C2410C` | `#FB923C` | only for attention chips / ladies seats / low-inventory |

`theme.dart` auto-derives from tokens — no hardcoded accent. Tour-tile palette in [`lib/design/components/ugam_bus_backdrop.dart`](lib/design/components/ugam_bus_backdrop.dart) was also recoloured into the coffee/espresso family.

---

## 5. UI / UX direction (locked)

Phase 0 design DNA is **locked**. Don't re-litigate it.

**Locked properties:**
- **Dark-first** mode; light is a complete mirror, not a fallback. Both customer and admin default to dark.
- **Single accent color** (coffee — see §4), brightened for dark. One warm callout (`#FB923C` dark / `#C2410C` light) used only for "needs attention" — ladies seats, attention chips, low-inventory pills.
- **Big rounded geometry**: cards 22 px, photos inside cards 16 px, buttons / chips 999 px (pill), dock nav 999 px.
- **Hero photography** on every customer-facing tour card (gradient overlay, title bottom-left, price bottom-right).
- **Floating dock bottom nav**: capsule, 4–5 circular icon buttons, active = solid accent circle with white icon. Replaces the old `_PillBottomNav`.
- **Sticky pill CTAs** at thumb-zone (full-width minus 28 px, 56 px tall, 999 px radius, accent solid) on every workflow screen.
- **Seat grid**: "image-5" pattern — 5 cols including aisle, discrete 8 px-radius cells, state colors `available / selected / taken / ladies`, deck toggle pill above, summary bar with running total + Continue pill below.
- **No bilingual sub-labels in UI**. `easy_localization` still handles full-string translation in **en / gu / hi** — user picks one language in Settings.
- **No decorative noise**: no splash decorative circles, no "FIG. 001 · AUTHENTICATION · SECURE" filler, no costume serif headlines.
- **Inter only** (already bundled), tabular numerics on every price / count / ID.

**Rejected directions — don't re-propose:**
- Khatabook-style dense bilingual ledger
- Editorial serif "Premium Travel"
- Linear-style "Operator Pro" terminal aesthetic
- Saffron / cream regional warm
- Light-mode-first

Authoritative spec: [`docs/superpowers/specs/2026-05-20-ui-design-system-design.md`](docs/superpowers/specs/2026-05-20-ui-design-system-design.md).

---

## 6. Domain rules — Double Sofa pair semantics

A **Double Sofa** cell in the seat layout holds **at most two berths**. Three valid occupancy states:

1. **Empty** — 0 berths held.
2. **Whole-double** — ONE passenger holds BOTH berths (their `assignedSeats` has two `SeatAssignment` entries with the same `seatId`).
3. **Paired double** — TWO different passengers each hold one berth on the same seat. Common case: a couple who booked separately and got paired.

### Drag-and-drop rules

**From a paired double:**
- The two passengers travel as a unit. Moving "one of them" actually moves **both**.
- Drop target **must be a free Double Sofa**.
- Drop on Single Sofa / Seater / occupied seat → block with: *"This is a paired double — drop it on a free Double Sofa, or break the pair first from the seat dialog."*

**From a whole-double:**
- Target must accommodate 2 berths → free Double Sofa only. Single sofa / seater → block (existing `berths > targetCapacity` guard).

**Solo from Single Sofa or shared Double:**
- Owner berth count is 1; can land on any compatible 1-berth slot.
- Dropping a solo onto a Double already holding 1 person → future "2-singles-into-double" allotment flow (not implemented yet).

### Cross-fill: 2 single sofas → 1 double sofa request

A passenger with `request_lines` containing `doubleSofa qty: 1` ideally takes a whole double, but a bus may not have one free. `TourSeatAssignmentScreen` lets the agent satisfy a `doubleSofa` request with TWO `singleSofa` assignments:
- Tapping a free Single Sofa while a `doubleSofa` line is pending claims 1 berth on the single.
- Once the passenger holds two single berths (or one single + one half-double, etc.), `_pendingLines` pairs them and drains one `doubleSofa` line.

Implementation lives in `TourSeatAssignmentScreen`: `_berthsForFreeCell` returns 1 for a single when a pending double exists; `_pendingLines` tracks leftovers and drains in 2-for-1 pairs.

### Cross-fill consolidation: 2 singles → 1 whole double on drag

If a passenger satisfied a `doubleSofa` request via two singles (e.g. L5 + L7) and a free Double opens up, dragging EITHER single onto the free Double **consolidates** both into the whole double:
- Source: a Single Sofa held by the passenger
- Target: a FREE Double Sofa
- Passenger must hold at least one OTHER single on the same bus (the partner that releases)

`_handleSeatDrop` in [`lib/screens/seat_assignment_screen.dart`](lib/screens/seat_assignment_screen.dart) → `TourController.consolidateOntoDouble({tourId, passengerId, busId, targetSeatId, sourceSeatIds})`. Atomic single server write. Snackbar: *"Consolidated <name> onto <target> — <s1> + <s2> freed."*

If the passenger holds only one single (no partner to release), the drop falls through to normal `moveSeat` — they end up owning half the target double.

### Source files
- Berth-count semantics: [`lib/controllers/tour_controller.dart`](lib/controllers/tour_controller.dart) → `moveSeat`, `swapSeats`
- Drag-drop guards: [`lib/screens/seat_assignment_screen.dart`](lib/screens/seat_assignment_screen.dart) → `_handleSeatDrop`

---

## 7. iOS specifics

### Scene lifecycle (UISceneDelegate)

`ios/Runner/Info.plist` declares `UIApplicationSceneManifest` → `FlutterSceneDelegate`. `AppDelegate.swift` adopts `FlutterImplicitEngineDelegate` and registers plugins in `didInitializeImplicitFlutterEngine` (not `didFinishLaunchingWithOptions`).

**Consequence:** the window is owned by the scene, so `UIApplication.shared.delegate.window` is `nil` at plugin-registration time. Any native plugin that force-unwraps `UIApplication.shared.delegate!.window!!.rootViewController!` in its `register()` **crashes the app at launch** with *"Unexpectedly found nil while unwrapping an Optional value."*

Hit this with `flutter_contacts` 1.1.9+2 — fixed by upgrading to **2.1.0** (the 2.0.0-beta.4 *"Migrate to UISceneDelegate"* release resolves rootViewController lazily/scene-safely via `connectedScenes`). 2.2.0 needs Flutter 3.44+; project is on Flutter 3.41.6, so **2.1.0 is the ceiling**. The 2.0 rewrite also changed the Dart API: `requestPermission(readonly:)` → `FlutterContacts.permissions.request(PermissionType.read)`, `getContacts(...)` → `getAll(properties: {ContactProperty.phone})`, `Contact.displayName` is now nullable.

**When adding native iOS plugins, prefer scene-compatible versions.** Fallback if a plugin can't be upgraded: revert Runner to the legacy `UIApplicationDelegate` lifecycle (drop `UIApplicationSceneManifest`, register in `didFinishLaunchingWithOptions`).

### Release IPA build — always use the script

**Release iOS by running `./scripts/build_ios_release.sh`** (does `flutter clean` → `flutter build ipa` → verifies every framework binary is `platform IOS`, refuses to emit a contaminated IPA).

**Why:** `objective_c.framework` is a Flutter native asset pulled in transitively by `path_provider_foundation` (a dep of sqflite / supabase_flutter / shared_preferences — unavoidable). Native assets are cached in `build/native_assets/`. If a **Simulator** build runs first, it leaves a simulator-built `objective_c.framework` there; a later **device** archive silently reuses it, producing an IPA App Store rejects with: *"objective_c executable references an unsupported platform in the arm64 slice. Simulator platforms aren't permitted."* (device + simulator both use arm64 on Apple Silicon — the wrong slice isn't obvious.)

**How to apply:** `flutter clean` before any `flutter build ipa`, and never archive right after a simulator run. Verify with `vtool -show-build <framework-binary>` → must say `platform IOS`, not `IOSSIMULATOR`. The script automates all of this. Build-hygiene, not a package bug — swapping the contacts package does not fix it.

---

## 8. Working preferences (how Zeel wants to collaborate)

### No AI co-author trailer in commits
Do **not** add `Co-Authored-By: Claude … <noreply@anthropic.com>` (or any AI co-author trailer) to commit messages. End commit messages at the description. Applies retroactively to future commits only.

### Don't pause between roadmap phases
When executing a multi-phase build, **don't stop after each phase to ask "want me to continue?"** Plow through all remaining phases. Zeel uses other AI agents for bug fixes / reviews — model is *"you build, they fix."* Pausing slows throughput without adding value.

Still pause if you hit a real fork (architecture decision, ambiguous requirement). Still pause if a specific bug has been delegated. Update todos as you go so progress is visible — but don't ask before each phase.

### Use built-in file tools, not bash for file work
For viewing and editing files, use the assistant's built-in **Read** and **Edit** / **Write** tools — they surface content and diffs in a reviewable form. Avoid `cat / head / tail / sed -n` for viewing and `sed -i / awk -i inplace / echo >` for editing — those are silent and break review.

Bash is still correct for: `grep` (multi-file search), `find` (locating files), git commands, build/test runs, genuine shell ops. After `grep` finds a hit, switch to Read for the context and Edit for the change.

### UI direction must be grounded in real app references
For any UI / visual direction question, **don't show abstract aesthetic moods** ("Premium Travel", "Operator Pro", "Regional Warm") or speculative combinations of unrelated app DNAs. Either:
- Build mockups that map 1:1 to specific screens in references Zeel has pointed at, **or**
- Ask "show me 2–3 apps you actually like the look of" if no references exist yet.

Three earlier rounds of speculative direction proposals were rejected. The pattern that works: Zeel provides references → mockups match them precisely → only the small remaining choices (e.g. accent color) get asked about.

---

## 9. Tech stack quick reference

- **Framework:** Flutter (Dart) — pinned to **Flutter 3.41.6**
- **Backend:** Supabase (Postgres + Auth + Realtime). Schema lives in [`docs/superpowers/specs/2026-05-11-supabase-schema-patch.sql`](docs/superpowers/specs/2026-05-11-supabase-schema-patch.sql) and [`database.sql`](database.sql).
- **State management:** GetX (`Get.to`, `GetxController`, `Obx`)
- **i18n:** `easy_localization` — translation files at [`assets/translations/en.json`](assets/translations/en.json) / [`gu.json`](assets/translations/gu.json) / [`hi.json`](assets/translations/hi.json). Keys are dot-notation mapping to nested dicts (e.g. `customer_tour_detail.label_route`). Use `tr('key')` for plain, `tr('key', namedArgs: {'x': value})` for parameterised.
- **Design system:** [`lib/design/`](lib/design/) — `tokens.dart` (colors / radius / spacing / motion), `ugam.dart` (barrel export), components in `lib/design/components/`
- **WhatsApp:** deep-link only via [`lib/services/whatsapp_service.dart`](lib/services/whatsapp_service.dart) — no Business API
- **Platform:** Android package `com.occubitsolution.ugambooking` (renamed from `tourpro` 2026-05-28); iOS bundle managed in [`ios/Runner.xcodeproj/project.pbxproj`](ios/Runner.xcodeproj/project.pbxproj)

---

## 10. Where to look first for common tasks

| Task | Start here |
|---|---|
| Add or change a translation | [`assets/translations/en.json`](assets/translations/en.json) + `gu.json` + `hi.json` — keep all three in sync |
| Change brand color / radius / spacing | [`lib/design/tokens.dart`](lib/design/tokens.dart) — single source of truth, everything else derives |
| Customer-facing screens | `lib/screens/customer_*.dart` (tour_list, tour_detail, booking_request, my_requests, more) |
| Agent-facing screens | `lib/screens/` — tour_detail, requests, seat_assignment, dashboard, etc. |
| Seat assignment / drag-drop | [`lib/screens/seat_assignment_screen.dart`](lib/screens/seat_assignment_screen.dart) + [`lib/controllers/tour_controller.dart`](lib/controllers/tour_controller.dart) |
| WhatsApp deep-link copy | [`lib/services/whatsapp_service.dart`](lib/services/whatsapp_service.dart) |
| Build iOS release | `./scripts/build_ios_release.sh` (never raw `flutter build ipa`) |
| Build Android release | bump `versionCode` in [`android/app/build.gradle.kts`](android/app/build.gradle.kts), then `flutter build appbundle` |
| Store / submission docs | [`docs/publishing/`](docs/publishing/) and [`docs/legal/`](docs/legal/) |

---

*This doc is a snapshot. The live source of truth for new conventions discovered after this date stays in the Claude Code memory directory; re-export this file when the picture changes materially.*
