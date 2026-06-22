# Ugam UI Refinement — Depth, Layout & Consistency

**Date:** 2026-06-22
**Status:** Design — pending user review
**Scope:** App-wide UI execution refinement across all 39 screens and all 3 roles (admin, handler, customer). **The champagne-gold palette is kept as-is.** This is *not* a rebrand.

---

## 1. Background & intent

The app already ships a mature, token-driven design system ("Ugam") in `lib/design/`: a champagne-gold accent (`#C9A86A`) on graphite neutrals, dark-first with a full light mirror, ~24 `ugam_*` components, and Inter type. Every screen renders through these tokens + components, so the system is the leverage point — fixing it cascades to all screens.

A live test confirmed the **palette is not the problem**: a warm-saffron alternative was prototyped on the real app and rejected as worse than the existing champagne. The real weaknesses are in **execution**, not color:

1. **Depth / hierarchy** — `bg #0A0A0A`, `card #141414`, `cardElev #1E1E1E` were nearly the same value, so cards read as one flat dark sheet.
2. **Layout / spacing** — dock-clearance and section spacing are ad-hoc per screen; sparse screens leave large dead voids.
3. **Consistency** — buttons, progress bars, chips/badges, icon-circles, headers, and sheets have each drifted into several variants.

The user selected all three as the focus (palette kept).

### Goals
- Make surfaces read with clear depth while staying premium-dark — **without changing any brand color.**
- Give every screen one predictable scaffold (header, gutters, section rhythm, dock clearance) so layouts feel intentional at any data density.
- Collapse each drifted component family to **one canonical version**, used everywhere.

### Non-goals (out of scope)
- Any palette / hue change (champagne stays; `accent`, `good`, `warm`, `danger`, `ink*` unchanged).
- Changing the Inter type family or the radius / motion scales (propose changes only with rationale).
- New features or behavior changes. This is visual/structural only.
- Re-architecting navigation (the 5-tab shell + nested navigators stay).

### Constraints to respect (from the design brief)
- **Dark-first, light a full mirror** — every change must be defined for *both* color sets.
- **Gujarati-first** — layouts must tolerate longer strings; default locale is `gu`.
- **High density on work screens** (seat assignment, requests) — scannability over decoration.
- **Accent rationing is an intentional policy** — champagne is reserved for true primary signals; neutral progress bars and tonal secondary buttons are deliberate. We keep this policy and fix the code that *violates* it, rather than spreading gold.

---

## 2. Foundation — tokens (`lib/design/tokens.dart`)

### 2.1 Depth ramp — DONE & validated live ✅
Locked after live A/B tuning on the emulator (champagne and all other colors untouched):

| token | before | after (locked) |
|---|---|---|
| `card` | `#141414` | **`#181818`** |
| `cardElev` | `#1E1E1E` | **`#242424`** |
| `border` | `#2A2A2A` | **`#323232`** |
| `bg` | `#0A0A0A` | `#0A0A0A` (unchanged) |

Light-mirror equivalents must be reviewed for the same separation logic (lift `cardElev`/`border` a step so cards read on the white ground). Current light set: `card #FFFFFF` / `cardElev #F4F4F5` / `border #E4E4E7` — keep, but verify card-on-card separation where a card sits on `bg #FFFFFF` (may need a hairline border on white cards).

### 2.2 New token: dock clearance
The audit found **eight** different bottom-padding values for "scrollable content above the floating dock" (`8, 20, 24, 32, 40, 112, 140, 160`). Define one source of truth:

```dart
class UgamSpacing {
  ...
  /// Bottom padding for any scrollable whose content scrolls under the
  /// floating UgamDockNav (dock ≈ 80px + safe-area). Use this instead of
  /// hardcoded 140 / 120 / 96.
  static const double dockClearance = 140;
  /// Dock clearance when a selection/action bar overlays the dock.
  static const double dockClearanceTall = 168;
}
```
Screens with a sticky-CTA in `bottomNavigationBar` (forms) keep a small bottom pad (`xxl = 24`) — they don't scroll under the dock, so they are exempt and documented as such.

### 2.3 Standard screen scaffold (documented contract)
Codify the layout every full screen follows. This is documentation + a couple of helpers, not a forced wrapper (work screens need freedom):

- **Lateral gutter:** `UgamSpacing.gutter` (14) everywhere. No ad-hoc 16/20. (Exception: long-form reading text e.g. `legal_document` may use `xl` 20 — documented.)
- **Top:** pushed screens use `UgamAppBar`. Root "home" surfaces (dashboard, customer list) use the shared home-bar component (§3.5).
- **Section rhythm:** `xl` (20) between major sections; `lg`/`md` (16/12) within; `sm` (8) for tight rows.
- **Scroll bottom:** `UgamSpacing.dockClearance` for dock screens; `xxl` for sticky-CTA forms.
- **Sparse/empty:** never leave a raw void — use `UgamEmpty` (centered, with optional CTA) so an empty screen still reads as designed.

---

## 3. Components — collapse each family to one canonical version

For each family: keep the existing canonical component, fix the listed outliers to match. File refs are from the audit.

### 3.1 Buttons / CTAs
**Canonical:**
- `UgamCTA` — primary, solid champagne, sticky-footer pill.
- `UgamButton` (in `ugam_dialog.dart`) — secondary, kinds: `primary / tonal / ghost / neutral / danger / dangerTonal`. Tonal-as-default-inline is the intentional accent-rationing pattern — **kept**.

**Fixes:**
- `widgets/group_picker.dart:781` — lone `TextButton.icon` ("Remove from group") → `UgamButton(kind: dangerTonal)`.
- Audit any remaining raw `TextButton`/`ElevatedButton` and route through `UgamButton`.
- Document the rule: **one solid champagne action per screen** (the primary); everything else tonal/ghost. Where two solids currently compete, demote the lesser to tonal.

### 3.2 Progress / capacity bars
**Canonical:** `LinearProgressIndicator`, **height 6**, radius 4, **neutral `ink2` fill** on a `card`/`border` track (accent rationed).

**Fixes:**
- Accent-rationing violations → neutral: `bus_status_screen.dart:443`, `manage_buses_screen.dart:479` (currently `c.accent`).
- Normalize heights to 6: `requests_screen.dart:784` (4), `tours_screen.dart:594` (5), `notify_screen.dart:991` (8).
- `tours_screen.dart:599` uses `ink3` → `ink2`.
- Keep the **semantic** capacity tint in `requests_screen` (good/warm/neutral by seat-type) — that's meaningful, not decorative; document it as the one sanctioned colored-bar exception.
- Consider extracting a tiny `UgamProgressBar(value, {tone})` so height/radius/track can't drift again.

### 3.3 Chips / badges / status dots
**Canonical:** `UgamReqChip` (variants accent/warm/good/neutral), `UgamStatusDot` (4 tones), `TourStatusBadge` (compact/full).

**Fixes:**
- `components/tour_status_badge.dart:25` — hardcoded rose `#EC4899` for "assigning" → use a token (`warm`, or add a dedicated status token if a distinct hue is required). No raw hex in component code.
- Derive fills from `*Fill` tokens, not ad-hoc `withAlpha(36)`.
- Unify count-badge geometry: dock badge (16px / r9) vs icon-circle badge (18px / r9) → pick one (recommend 18 / r9) and share it.

### 3.4 Circular icon buttons
**Canonical:** `UgamIconButton` with a fixed size scale: `sm 38 / md 42 / lg 44` (icon 19). `UgamAppBarAction` and the app-bar back button are the 42 variant.

**Fixes:**
- `tour_detail_screen.dart:986` — `size: 50` → 44.
- `add_bus_screen.dart:1006` — 38px ad-hoc toggle → `UgamIconButton(size: sm)`.
- `collection_screen.dart:397` — 42px rounded-6 (not a circle) → reconcile (true circle, or a clearly separate "toggle tile" component).
- `customer_tour_list_screen.dart:401` `_IconCircle` — re-implements `UgamIconButton` + badge → replace with `UgamIconButton` + the shared badge (§3.3). This also feeds §3.5.

### 3.5 Headers — one home-bar, `UgamAppBar` everywhere else
Three near-identical custom headers exist: dashboard `_Greeting`, customer `_TopBar` (+`_IconCircle`), handler `_StatusAppBar`. All are "title/avatar on the left, circular actions (with optional badge) on the right."

**Plan:**
- Extract **`UgamHomeBar`** (new component): leading title or avatar+greeting, trailing `UgamIconButton` actions with badges. Refactor `dashboard_screen._Greeting`, `customer_tour_list_screen._TopBar`, and `bus_status_screen._StatusAppBar` onto it.
- **Mandate `UgamAppBar`** for pushed screens; refactor the hand-rolled ones: `seats_screen.dart:157` and `settings_screen.dart:28`.
- **Documented exceptions:** the image-hero headers on `tour_detail_screen` and `customer_tour_detail_screen` are intentional (immersive workspace / marketing) — keep, but have them reuse `UgamIconButton` chrome circles for the back/more affordances.

### 3.6 Sheets
**Canonical:** `UgamSheet.show()` (28px top radius, drag handle, title row, consistent padding).

**Fixes:**
- `widgets/occupant_action_sheet.dart` — bypasses `UgamSheet.show()` and re-implements `showModalBottomSheet` chrome → migrate onto `UgamSheet.show()`.
- Normalize sheet inner rhythm to `xl` (20) between major blocks; `chart_footer_sheet` currently uses `lg` (16).

---

## 4. Screen-by-screen pass (all roles)

After the foundation + components land, sweep each screen to: adopt the scaffold (§2.3), swap to `dockClearance`, replace any leftover ad-hoc components, and fix voids. Per-screen work items from the audit:

### Admin (primary)
| Screen | Fixes |
|---|---|
| `dashboard_screen` | `_Greeting` → `UgamHomeBar`; keep `140` via `dockClearance` token. |
| `tours_screen` | progress bar height 5→6; `dockClearance` token; (already uses `UgamAppBar` + `UgamEmpty`). |
| `tour_detail_screen` | hero kept (documented); chrome circles → `UgamIconButton`; `size:50`→44; Passengers-tab empty → card-wrapped `UgamEmpty` (not bare `huge` gap); `dockClearance`. |
| `requests_screen` | replace `112/160` ad-hoc math with `dockClearance` / `dockClearanceTall`; progress height 4→6 (keep semantic tint). |
| `seats_screen` | hand-rolled header → `UgamAppBar` (dynamic subtitle/actions). |
| `tour_seat_assignment_screen` | verify dock/selection-bar clearance uses tokens; density review (work screen). |
| `charts_screen` | empty tour/bus inline logic → `UgamEmpty`; legend density pass (cramped 9-item wrap). |
| `manage_buses_screen` | progress accent→neutral (`:479`). |
| `add_bus_screen` | 38px toggle circles → `UgamIconButton(sm)`. |
| `bus_status_screen` | `_StatusAppBar` → `UgamHomeBar`/`UgamAppBar`; progress accent→neutral (`:443`). |
| `tour_money_board_screen` | bottom pad `8`→`dockClearance`. |
| `finance_screen` | bottom pad `24`→`dockClearance`. |
| `settings_screen` | manual header → `UgamAppBar`; bottom pad `24`→`dockClearance`. |
| `notify_screen` | progress height 8→6. |
| `account_details` / `*_settings` | confirm `SettingsScaffold` uses `UgamAppBar` + `dockClearance` internally (fixes all wrapped screens at once). |
| `tour_groups`, `seating_exceptions`, `past_tour_seat_history`, `create_tour`, `edit_tour` | normalize bottom pad to token; confirm `UgamEmpty`; `past_tour` consolidate its 3 fallback paths into one empty + one loading. |

### Customer
| Screen | Fixes |
|---|---|
| `customer_tour_list` | `_TopBar`/`_IconCircle` → `UgamHomeBar` + `UgamIconButton`; `dockClearance`. |
| `customer_tour_detail` | hero kept; chrome circles → `UgamIconButton`; `-28` overhang → token-derived; `dockClearance`. |
| `customer_my_requests` | `dockClearance`; (uses `UgamAppBar`). |
| `customer_booking_request` | keep sticky-CTA form exemption (bottom `24`). |
| `customer_more` | section-label padding → token; bottom `40`→`dockClearance`. |

### Handler
| Screen | Fixes |
|---|---|
| `bus_money` | bottom `32`→`dockClearance`. |
| `handler_bus_chart` | verify clearance + density (complex manifest viewer). |
| `collection` | icon-tile reconcile (§3.4); confirm roster `dockClearance`. |
| `find_my_seat` | sticky-CTA form exemption documented. |

### Auth / misc
| Screen | Fixes |
|---|---|
| `legal_document` | 20px gutter → 14 (or document as sanctioned reading-width exception). |
| `login`, `splash`, `admin_setup` | already consistent; no change beyond depth cascade. |

---

## 5. Verification
- The app runs on the **Pixel_9 emulator** with hot-restart via a controllable stdin pipe; the persisted admin session ("zeel") + test tour give live data.
- For each phase, capture **before/after** of representative screens (dashboard, tours, charts, requests, settings, customer list) and eyeball on-device in **dark + light** and **Gujarati + English**.
- Run the existing test suite (503+ tests) after component refactors; add/adjust widget tests where a shared component (`UgamHomeBar`, `UgamProgressBar`) is introduced.
- No regressions to behavior — these are visual/structural edits only.

## 6. Risks
- **Shared-header extraction** touches 3 high-traffic screens at once — refactor behind the existing widgets' public shape; verify badges (requests count) still react via `Obx`.
- **`SettingsScaffold` change** cascades to all settings sub-screens — verify each.
- **Light-mode** is easy to forget — every token/component change must be checked in both modes.
- **Accent-rationing**: resist "fixing" neutral bars to gold; the policy is intentional.

## 7. Decisions already made
- Palette: **champagne kept**, saffron rejected (live test).
- Depth ramp: **locked** (`card #181818 / cardElev #242424 / border #323232`), already applied in the working tree.
- Slicing: **one comprehensive spec** (this doc) covering foundation + components + all screens, per user.
