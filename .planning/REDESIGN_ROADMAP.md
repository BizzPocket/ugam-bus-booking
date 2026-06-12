# Full-App UI/UX Redesign Roadmap — Ugam Bus Booking

Graphite + champagne, dark-first. Source: two parallel multi-agent audits (216-finding
component-compliance audit + 7-cluster UX/click-efficiency roadmap). This file is the
execution plan of record.

---

## Status

### ✅ Done (real bugs — shipped first, ahead of cosmetics)
- **Dashboard "See all" → wrong tab.** `dashboard_screen.dart:159` sent users to Charts
  (tab 2) instead of Requests (tab 3). Fixed.
- **BusMoney money deletes had NO confirm** (`bus_money_screen.dart:171,205`) — one mis-tap
  on a small icon permanently wiped expense/handover records. Now gated behind
  `UgamDialog.confirm(destructive: true)` with localized en/gu/hi copy.
- **Requests screen** (earlier pass): tonal per-card primary (accent rationing), localized
  + pluralized SEATS chip, capacity fill bar.

### ⏭ Deferred / debatable
- **Splash `UgamColors.dark`** (`splash_screen.dart:64`): flagged as a hardcode-ban
  violation, but may be an intentional dark brand splash. Left as-is pending a call.

---

## The defining rule: the Accent-Rationing Law

> **At most ONE solid-champagne (`c.accent` fill) focal element per screen — and it is
> always the bottom sticky CTA when one exists.** Everything else "primary-ish" is TONAL:
> `accentFill` bg + `accent` ink + hairline border.

- Repeated/per-row primaries are ALWAYS tonal (Book pills, per-row Confirm/Collect/Send/Edit,
  suggestion-apply, active selector pills).
- Non-champagne tones (good/warm/danger) use **tone-colored ink**, never `c.onAccent`.
- Broken on ~13 screens — this is the single biggest coherence win.

---

## Wave 0 — Foundation components (build FIRST; everything depends on these)

Build/extend before touching screens, or the waves re-fragment. (`UgamButton` +
`UgamButtonKind{ghost,danger,primary}` already exist — extend, don't recreate.)

- **Buttons:** add `UgamButtonKind.tonal` + `.neutral`; lock vocab: `UgamCTA` = solid sticky
  (one/screen), `UgamButton(kind:)` = everything else. Delete all `GestureDetector+Container`
  pseudo-buttons.
- **`UgamAppBar`** — add **eyebrow** + **subtitle** slots; delete ~10 hand-rolled
  `_TopBar`/`_Header`/`_WizardHeader`/`_ChromeCircle`/`_IconCircle` headers. Largest reuse win.
  Fix `widgets/settings_scaffold.dart:47` FIRST (fixes Account/WhatsApp/Notifications/Payment
  in one edit).
- **`UgamIconButton`** — adopt everywhere; delete every private circle-button widget; fixes
  sub-44px tap targets (~20 screens).
- **`UgamCard`** — add a `tone` prop (danger/attention) so cards stop being hand-rolled;
  replace raw `Container(cardElev, radius 20/22)`. Add `UgamRadius`-mapped radii.
- **`UgamListRow` / `UgamToggleRow`** — collapse `_SettingsRow`/`_AccountRow`/`_DangerRow`/
  `_ToggleRow`/`_MoreRow` (5+ near-identical icon-tile rows) into one.
- **`UgamSelectorPills`** (tonal active) — for charts/requests/notify/seat-assignment/handler
  selector strips. `UgamTabPills` for 2-segment view toggles.
- **`UgamPickerField`** (date/time), **`UgamSearchField`** (one shared search) — mandate
  `UgamInput` for all filled fields.
- **`UgamSectionLabel`** (single casing — `.toUpperCase()` everywhere), **`UgamExpander`**.
- **Shared utils:** one localized `formatDateShort()` (DateFormat — kills 6+ hardcoded English
  month arrays), one `formatMoneyInr()` (kills 5 divergent `_money()`), one `TourMiniCard`.

---

## Wave plan (most-used first)

### Wave 1 — Daily-driver core
- **dashboard** — restore Requests/Assign quick actions (drop Settings), de-solidify attention
  rows, swap in `UgamStatTile`/`UgamRequestRow`. *(nav bug already fixed)*
- **requests** — promote "Confirm & seat" to primary (it's hidden in the kebab today), tonal
  tour pills + add circle, labelled sort pill, rebuild on `UgamRequestRow`. *(accent already rationed)*
- **tour_seat_assignment** — collapse dual passenger-switchers to one dock, single gold focal,
  route sheets/dialogs through `UgamSheet`/`UgamDialog` (currently raw `showModalBottomSheet` ×2
  + mixed `AppDialogs.confirm`).
- **tour_detail** — make `_NextActionCard` tappable (fire the sticky CTA action), demote in-body
  broadcast to neutral, inline request edits.
- **tour_overview** — solid; swap last `_BannerAction` → `UgamButton`.
- **main_shell** — reconsider 5→3 dock to match tour-first IA.
- *(seats_screen is the reference shell — leave; promote its header pattern.)*

### Wave 2 — Money & finance
- **collection** — one-tap "Mark paid (₹due)" (biggest cumulative click win); pin summary+filters.
- **bus_money** — demote mid-page Collect to tonal, enlarge hit areas, shared category chips.
  *(delete-confirm already added)*
- **tour_money_board** — shared eyebrow header + `UgamEmpty`.
- **finance** — default to "this month", `UgamEmpty` for empty/error (no solid gold in error),
  shared header.
- **charts** — tonal active pills, extract `UgamSelectorPills`, collapse selectors.
- **handler_bus_chart** — default to List view, split Call from Collect, `UgamTabPills`,
  `UgamSkeleton` loading, localize `'GO'/'RET'/' ½'`.
- *(fullscreen_chart — leave.)*

### Wave 3 — Tour setup
- **add_bus** — de-gold Step 3, `_Field`→`UgamInput`, "Duplicate bus"/defaults, `UgamExpander`,
  `UgamSwitch`, `UgamPickerField`.
- **create_tour / edit_tour** — `UgamAppBar`, shared `UgamPickerField`, lift the ~250 duplicated
  tour-form widgets into a shared file.
- **manage_buses** — localize month array, `UgamAppBar`, `UgamCard.media`, per-row WhatsApp.
- **bus_status** — title/subtitle into `UgamAppBar`.
- **tour_groups** — auto-name groups + inline rename, pin roster search, tonal suggestion/checkbox.
- **seating_exceptions** — route "not-yet-placed" taps into the grid pre-selected (no dead-end toast).

### Wave 4 — Customer funnel
- **customer_my_requests** — worst gold over-use → tonal; fix hardcoded month array; drop
  redundant refresh; fix dead row tap.
- **customer_tour_list** — tonal Book pill, `UgamCard.media`, shared `TourMiniCard`/date helper.
- **customer_tour_detail** — add visible price line, share success toast, collapse Schedule into About.
- **customer_booking_request** — `UgamAppBar`, shared `TourMiniCard`, seed initial seat counts.
- **customer_more** — `UgamAppBar` + real version from package_info.

### Wave 5 — Settings, notify, onboarding, legal
- **settings** — tappable Account shortcuts, add Legal/About section, tone down avatar, `UgamAppBar`.
- **notify** — tonal send circles, collapse Lock→Notify double-confirm, localize months, drop
  debugPrints + on-system progress dialog.
- **notifications_settings** — auto-save-on-toggle (drop Save CTA + back-loss).
- **whatsapp_settings** — inline WA-number validation; consider merging with Notifications.
- **login** — gate diagnostic Ping behind kDebugMode, `UgamDialog` for ping, `UgamButton(ghost)`.
- **admin_setup** — `UgamAppBar`, tap-to-copy email, convert to a `UgamSheet` from login.
- **legal_document** — `UgamAppBar`, wire into Settings.
- *(payment_settings / account_details — solid; only `'+91 '` literal → tr.)*

---

## Localization debt (gu/hi parity mandate)
English month arrays (tours, manage_buses, notify, customer_my_requests/list/booking);
`_durationLabel` "day(s)" (tour_detail); notify hardcoded snackbar + debugPrints; admin_setup
mailto subject; account_details `'+91 '`; settings/customer_more hardcoded version strings →
`package_info`. → one shared localized `DateFormat` helper kills most month-array cases.
