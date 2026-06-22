# Bug Tracker — Planning Only (no implementation until approved)

> Workflow: each bug is logged here → investigated with multiple read-only agents
> (root cause + similar-code sweep) → a fix plan is written. **No code is changed
> until explicitly approved.**

Status legend: `🆕 new` · `🔍 investigating` · `📋 planned` · `✅ approved-to-fix` · `🚧 fixing` · `✔️ done`

---

## Index

| # | Bug | Status |
|---|-----|--------|
| BUG-001 | Tour detail screen — too many buttons / unclear where to tap | ✔️ done (Option A) → ↩ revised: all actions restored as a clean grid (see update) |
| BUG-002 | Add-bus screen app-bar back button does nothing (from tour detail) — navigator mismatch, affects a whole class of screens | ✔️ done (helper + 8 call sites) |
| BUG-003 | Requests tab — stray tour route in header (wrong/ambiguous with 0 or many tours) + mismatched empty-state CTA | ✔️ done |

| BUG-004 | Charts tab empty state has no action — add a "create a bus" CTA | ✔️ done |
| BUG-005 | Add-Bus "Identity" step — too much intro text + monotonous equal-width inputs | ✔️ done (Option A: grouped sections + paired row) |

> **Implemented 2026-06-19.** `flutter analyze` clean, 500 tests pass, final review APPROVED-WITH-MINORS (the one finding — tour_detail's own back handlers — was fixed too). Shared helper: [lib/utils/app_nav.dart](../lib/utils/app_nav.dart). Not yet committed.

---

## BUG-004: Charts tab empty state is a dead end (no CTA)

- **Status:** ✔️ done (2026-06-19)
- **Reported:** 2026-06-19
- **Description (user):** On the global Charts/ચાર્ટ tab, when no bus exists the empty state ("No charts yet") just shows text with no action. Add a CTA to create a bus so the empty state is actionable.
- **Screen:** [charts_screen.dart](../lib/screens/charts_screen.dart)

### Investigation
- Empty state fires when `_eligibleTours()` is empty ([charts_screen.dart:136](../lib/screens/charts_screen.dart#L136)); eligible = `activeTours.where((t) => t.buses.isNotEmpty)`. So "empty" = no active tour has a bus. Two sub-cases: (a) active tours exist but none have a bus; (b) no active tours at all.
- `UgamEmpty` already supports an optional `cta` widget ([ugam_empty.dart:12](../lib/design/components/ugam_empty.dart#L12)).

### Fix (implemented)
- Added an adaptive `UgamCTA` to the empty state:
  - (a) active tour(s) exist → label `add_bus.title` ("Add Bus"), opens `AddBusScreen` for the **nearest upcoming** active tour (`Get.to`, closes safely via the BUG-002 `AppNav.pop`).
  - (b) no active tours → label `create_tour.title` ("Create Tour"), pushes `CreateTourScreen` — so the CTA is never a dead end.
- Reused existing i18n keys (`add_bus.title`, `create_tour.title`) — **no new strings**. Reactive `Obx` auto-swaps to the chart once a bus is added.

---

## BUG-005: Add-Bus "Identity" step — wall of text + monotonous equal-width inputs

- **Status:** ✔️ done (2026-06-19) — Option A (grouped sections + paired row)
- **Reported:** 2026-06-19
- **Description (user):** Step 1 of the create-bus wizard has too much/too-big intro text, and every field is an identical full-width box with no visible layout/hierarchy.
- **Screen:** [add_bus_screen.dart](../lib/screens/add_bus_screen.dart) — `_Step1Identity`

### Fix (implemented)
- **Cut the intro paragraph.** Step 1 now shows the title only (`add_bus.step1.title`); the long `_StepIntro` body (which just restated the field hints) is dropped. Steps 2–3 keep their `_StepIntro` unchanged.
- **Grouped the 7 controls into 3 labelled sections** via a new `_GroupHeader` (brighter/bolder than field `_Label`): **The bus** (slot · name · number · AC), **Boarding**, **Driver · optional**.
- **Broke the equal-width rhythm:** *Departure place* (flex 3) + *Departure time* (flex 2) now share a `Row`. Added short placeholders so neither ellipsizes in the narrower columns.
- **i18n:** added `add_bus.group.{bus,boarding,driver}` + `add_bus.hint.{boarding_point_short,departure_time_short}` to en/gu/hi (all validated parseable). Reused everything else.
- Within the Ugam design system (no palette/type changes); the lever was hierarchy + rhythm. Verified: `flutter analyze` clean, 500 tests pass. *(Not visually rendered here — eyeball on device; the paired row is the main thing to confirm.)*

---

---

## BUG-002: App-bar back button does nothing on Add-Bus screen (opened from tour detail)

- **Status:** 📋 planned — **scope locked: whole class + shared close helper**
- **Reported:** 2026-06-19
- **Description (user):** Open the create-bus page from the tour details page → the app-bar back button doesn't work (tapping does nothing).
- **Screen:** [add_bus_screen.dart](lib/screens/add_bus_screen.dart)

### Investigation — ROOT CAUSE (confirmed)

The shell gives **each bottom tab its own nested `Navigator`** ([main_shell.dart:152-160](lib/screens/main_shell.dart#L152-L160)). So inside a tab, `Navigator.of(context)` = that tab's **nested** navigator, while GetX's `Get.back()`/`Get.to()` act on the **root** navigator.

- From tour detail, Add-Bus is pushed with `Navigator.of(context).push(MaterialPageRoute(...))` → lands on the **nested** navigator ([tour_detail_screen.dart:1161](lib/screens/tour_detail_screen.dart#L1161), [:1598](lib/screens/tour_detail_screen.dart#L1598); also [manage_buses_screen.dart:67](lib/screens/manage_buses_screen.dart#L67), [:351](lib/screens/manage_buses_screen.dart#L351)).
- Add-Bus app-bar back → `onBack: _goBack` → on the first step calls **`Get.back()`** ([add_bus_screen.dart:315](lib/screens/add_bus_screen.dart#L315)) → pops the **root** navigator, which has nothing to pop here → **nothing happens.**
- The paths that work use `Get.to(...)` (root navigator), so `Get.back()` matches: [bus_status_screen.dart:724](lib/screens/bus_status_screen.dart#L724), [requests_screen.dart:1073](lib/screens/requests_screen.dart#L1073). → **Add-Bus is "MIXED": pushed both ways, but always closes with `Get.back()`.**
- Same latent defect on **save-then-close**: `Get.back()` at [add_bus_screen.dart:510](lib/screens/add_bus_screen.dart#L510) (edit) and [:551](lib/screens/add_bus_screen.dart#L551) (add) — after saving a bus opened from tour detail, the screen won't close either.

Why `UgamAppBar` normally avoids this: its **default** back (no `onBack`) already does the safe thing — `Navigator.canPop() ? pop() : Get.back()` ([ugam_app_bar.dart:60-71](lib/design/components/ugam_app_bar.dart#L60-L71)). Add-Bus **overrides** `onBack`, losing that safety.

### Similar code (same root cause) — sweep results

Other screens that override `onBack`/close with a navigator that may not match how they're pushed (each to be re-verified at implement time):

| Screen | Pushed via | Closes via | Verdict |
|--------|-----------|-----------|---------|
| **add_bus_screen** | Navigator (tour_detail, manage_buses) + Get.to (bus_status, requests) | `Get.back()` (`:315`, `:510`, `:551`) | **BROKEN (mixed)** — the reported bug |
| edit_tour_screen | Navigator (tour_detail:94) | `Get.back()` (~`:205`) | likely BROKEN |
| requests_screen | Navigator (tour_detail:861) + Get.to (tour_overview) | `Get.back()` (~`:313`, `:2162`) | likely BROKEN (mixed) |
| seats_screen | Navigator (dashboard) + Get.to (bus_status) | `Get.back()` (~`:180`) | likely BROKEN (mixed) |
| tour_detail_screen | Navigator (dashboard, tours) | delete-tour `Get.back()` (~`:212`, `:223`) | likely BROKEN on delete-close |
| customer_tour_detail_screen | (verify) | `Get.back()` (`:49` onBack) | verify |

> Line numbers from sibling screens are agent-reported candidates — confirm each before editing.

### Fix plan

**Canonical idiom** (works regardless of which navigator the route is on):
```dart
final nav = Navigator.of(context);
if (nav.canPop()) {
  nav.pop();
} else {
  Get.back();
}
```

1. **Reported bug (Add-Bus):**
   - `_goBack` `else` branch ([:315](lib/screens/add_bus_screen.dart#L315)) → replace `Get.back()` with the idiom (keep the step-back logic for steps > 0 unchanged).
   - `_save` close calls ([:510](lib/screens/add_bus_screen.dart#L510), [:551](lib/screens/add_bus_screen.dart#L551)) → same idiom.
   - The `_BottomBar` back pill already routes through `_goBack`, so it's covered.
2. **Class fix (recommended):** add one shared helper (e.g. `UgamNav.pop(context)` or a `BuildContext` extension) encapsulating the idiom; use it everywhere a pushed screen closes itself. Prevents regressions and de-duplicates. Then apply to the sibling screens above (after verifying each push/close pairing).
3. **i18n:** none needed (no label changes).

- **Risks / regressions:** save-success path calls close right after a snackbar + `mounted` checks — keep ordering. For screens pushed via `Get.to` only, the idiom still works (`canPop()` false on the relevant navigator → falls back to `Get.back()`); verify per screen. Don't change `NotifyScreen` (already uses `Navigator.maybePop`).
- **Test approach:** open Add-Bus from tour detail → back works; from bus_status (Get.to) → back still works; save from both entry points → screen closes. Repeat per sibling screen. Add a widget test asserting back pops from a nested-navigator host.

---

## BUG-001: Tour detail screen is cluttered — unclear where to click / what does what

- **Status:** 📋 planned — **Option A chosen** (Tabs lead, slim Overview)
- **Reported:** 2026-06-19
- **Description (user):** On the tour detail screen (Passengers tab shown), there are too many buttons and it's not clear where to click or what each does. Wants the tab simplified.
- **Screen:** [tour_detail_screen.dart](lib/screens/tour_detail_screen.dart) (handler/admin side)

### Investigation

**Element count (Passengers tab, single viewport):** ~14 tappable + 2 non-tappable chips that look tappable. Full inventory:
- Top: Back `:274`, Status chip `:281` *(display-only)*, 3-dot menu `:312`, `S→A` chip *(display-only)*
- Tabs `:110`: Overview / Passengers / Bus / Activity
- Body empty state: "Copy broadcast message" `:844`, "Manage requests" `:859`
- Sticky bottom: "Seats / બેઠકો" (`_StickyAction` `:1542`)
- Dock nav (`main_shell.dart:27`): Home / Tour / Charts / Requests / Settings

**Root cause — two overlapping navigation systems + irrelevant empty-state actions:**
1. **Tabs duplicate the Overview "Tour Tools" grid** (`_TourTools :1728`). Grid tiles (Seats/Buses/Money/Groups/Requests/Lock) push *separate screens*; tabs (Passengers/Bus/Activity) show some of the same data inline. → "Bus" is both a tab and a tile with **different destinations**; "Requests" is both the Overview tile and the Passengers "Manage requests" button.
2. **Label mismatch:** on the *Passengers* tab the only action is "Manage requests" — the requests→passengers relationship isn't conveyed.
3. **"Copy broadcast message"** is a weak primary action for an empty passengers list and overlaps the Overview Broadcast card (`_BroadcastCard :695`).
4. **"Seats" sticky button shows with 0 buses/0 passengers** → dead-end tap (`_buildCta` / `_StickyAction`).

**Functional overlaps confirmed:**
- Seats: 3 entry points (Overview tile, Passengers sticky, Next-Action card) — deduped to max 2
- Requests: 2 (Passengers tab button + Overview tile)
- Broadcast: 2 (Overview card + Passengers empty-state CTA)
- Buses: 2 with different behavior (Bus tab inline list vs Overview tile → ManageBusesScreen)

**Affected files:**
- [tour_detail_screen.dart](lib/screens/tour_detail_screen.dart) — `_TabBar :110`, `_OverviewTab :549`, `_TourTools :1728`, `_PassengersTab :824`, `_BroadcastCard :695`, `_StickyAction :1542`, `_BusesTab :1142`, `_ActivityTab :1290`
- [main_shell.dart](lib/screens/main_shell.dart) — dock nav (global, likely leave as-is)

### Fix plan — Option A (Tabs lead, slim the Overview) — LOCKED

**Goal:** one obvious primary action per state; kill the tab-vs-grid duplication; remove dead-end taps.

1. **Overview tab (`_OverviewTab :549`, `_TourTools :1728`):**
   - Remove the 6-tile Tools grid as the primary nav surface (it duplicates the tabs).
   - Keep: status header + the single **Next-Action card** (`_NextAction` / `:603`) as the one clear "do this next."
   - Re-home the tiles that have NO tab equivalent — **Money, Groups, Lock/Send** — into a compact secondary row ("More") or the 3-dot menu. Seats/Buses/Requests are dropped from the grid (reachable via their tabs).
2. **Passengers tab empty state (`_PassengersTab :824`, lines `:844`/`:859`):**
   - ONE primary CTA: "Share on WhatsApp to collect riders" (the broadcast send).
   - "Copy message" → demote to a small inline icon/text link, not a full button.
   - "Manage requests" → keep as a quiet secondary link; consider relabel to convey requests→passengers (e.g. "Add riders manually").
3. **Sticky "Seats" button (`_StickyAction :1542`, `_buildCta`):**
   - Hide it when there are 0 buses (and/or 0 passengers) — show only once seating is actionable. Preserve existing `_NextAction` dedup logic.
4. **i18n:** update en/gu/hi strings for any changed/removed labels.

- **Risks / regressions:** seat-assignment entry points are deduped via `_NextAction` — changing grid/sticky visibility must preserve that path so seats stay reachable. Money/Groups/Lock must remain reachable after grid removal. Broadcast copy/send is wired to clipboard + WhatsApp intent — keep both code paths.
- **Test approach:** widget tests for empty vs populated Passengers states; assert Seats hidden at 0 buses; verify Money/Groups/Lock still navigate; verify each remaining CTA routes correctly; manual pass through Planning → Collecting → Locked phases.
- **Open sub-decision (for implement phase):** where Money/Groups/Lock land — compact "More" row on Overview vs inside the 3-dot menu. Will confirm before coding.

### Update (2026-06-19) — partial reversal per user

After living with the slimmed Overview, the user reported the slim went **too far**: "in tour details why you remove the action — I need all actions." The original BUG-001 complaint was **clarity** ("unclear where to tap"), not raw count, so the resolution is **presentation, not removal**:

- Restored **all 6 actions** — Requests · Buses · Seats · Money · Groups · Lock/Send — as a clean, labeled **3×2 grid** (`_ActionsGrid`, replacing `_MoreToolsRow`) in [tour_detail_screen.dart](lib/screens/tour_detail_screen.dart). Order follows the tour lifecycle.
- The **Next-Action card** stays on top as the single highlighted "do this next"; the grid below gives full one-tap access without the old ambiguity (each tile → its real workspace, the same destination the tabs/Next-Action use).
- New i18n keys `tool_buses`, `tool_requests`, `actions_section` (en/gu/hi); `more_tools` eyebrow replaced by `actions_section`.
- **Net:** clarity preserved (one obvious primary + a tidy grid), but nothing is hidden.

---

## BUG-003: Requests/Booking tab — stray tour route in header + empty-state CTA mismatch

- **Status:** 📋 planned — **locked** (header: remove route eyebrow; CTA: hide when zero requests)
- **Reported:** 2026-06-19
- **Description (user):** On the global Booking/Requests tab: (1) the app bar shows a tour route — wrong/ambiguous when there are 0 or multiple tours; remove it from the app bar. (2) The bottom CTA says "Add a bus to start arranging", but when there are **no requests** that action makes no sense — what is the user supposed to do with it?
- **Screen:** [requests_screen.dart](lib/screens/requests_screen.dart) (dock tab index 3 — global, not tour-scoped)

### Investigation

**3a — App-bar route eyebrow.**
- Eyebrow = selected tour's `fromCity → toCity` ([requests_screen.dart:304-306](lib/screens/requests_screen.dart#L304-L306)), built in `UgamAppBar(... eyebrow: ...)` (~`:632`).
- 0 tours → eyebrow already `null` + "No active tours" empty state ([:352-357](lib/screens/requests_screen.dart#L352)). *(So the "no tour" case is already handled — the route does NOT show.)*
- Multiple tours → defaults to `activeTours[0]` ([:59](lib/screens/requests_screen.dart#L59), [:287-294](lib/screens/requests_screen.dart#L287)); a `UgamSelectorPills` switcher appears below ([:434-446](lib/screens/requests_screen.dart#L434)). The app bar still shows only one tour's route → redundant with the pills and misleading on a global tab.
- **Verdict:** remove the route eyebrow from this screen's app bar (per user). Tradeoff: with a single tour there's no route text in the header, but the capacity banner / bus chip still give tour context.

**3b — CTA logic mismatch.** `_AssignmentCTA` ([requests_screen.dart:1043-1079](lib/screens/requests_screen.dart#L1043)):
```dart
label: hasBus ? tr('seats.title') : tr('requests.cta_add_bus'),
... onPressed: hasBus ? Get.toNamed(tourOverview) : Get.to(AddBusScreen)
```
- Label/action keyed **only on `hasBus`**, never on whether requests exist. So with **0 requests** the CTA pushes "Add a bus" — irrelevant when there's no one to seat.
- Current states: no bus → "Add a bus"; has bus → "Seats ({n} left)". Missing: an **empty-requests** state whose job is to *get* riders.

### Fix plan

**3a (header):** Drop the `eyebrow` arg from this screen's `UgamAppBar` (and remove the now-unused route string). Keep title "Requests". Tour context stays in the selector pills + capacity banner.

**3b (CTA) — make it requests-aware. DECISION: hide the CTA when there are zero requests.**
| State | CTA |
|-------|-----|
| Tour, **no requests at all** | **(no CTA)** — rely on empty-state text + app-bar icons |
| Tour, has requests, **no bus** | "Add a bus to start assigning" → AddBusScreen *(unchanged)* |
| Tour, has requests, **has bus** | "Seats ({n} left)" → tour overview *(unchanged)* |
- Implementation: gate the sticky `_AssignmentCTA` on `allPassengers.isNotEmpty` (the post-`journeyDone` filter list, [requests_screen.dart:399-400](lib/screens/requests_screen.dart#L399)). When empty, render no sticky CTA (and drop the body bottom-padding it reserves).
- "Empty" = zero requests across all four tabs for the selected tour. Bus setup stays reachable from tour detail / overview, so removing the empty-state "Add a bus" here loses nothing.
- Manual add of a request is still available via the app-bar person-add icon.

- **Similar code:** the broadcast action already exists in [tour_detail_screen.dart](lib/screens/tour_detail_screen.dart) `_BroadcastCard` (`:695`) — reuse, don't duplicate. Also note: Requests is the only *global* dock tab that renders per-tour data in its header; Dashboard/Charts/Settings don't, so this header issue is likely unique to this screen.
- **Risks / regressions:** CTA also navigates via `Get.to(AddBusScreen)` — see BUG-002 (this is a `Get.to` push, so it closes correctly; leave as-is). i18n: add/adjust keys (`requests.cta_*`) in en/gu/hi. Removing the eyebrow is low-risk (display only).
- **Test approach:** with 1 tour → no route in header; with 0 requests → CTA is the share action and does something useful; with requests+no bus → "Add a bus"; with bus → "Seats". Multi-tour: switcher still works, no route in app bar.

---

<!-- Per-bug template (do not delete)

## BUG-001: <short title>

- **Status:** 🆕 new
- **Reported:** <date>
- **Description (user):** <what the user said>
- **Repro / when it happens:** <steps or conditions>

### Investigation
- **Root cause:** <findings + file:line>
- **Affected files:** <list>
- **Similar code elsewhere (same pattern):** <findings + file:line>

### Fix plan
1. <step>
2. <step>
- **Risks / regressions:** <notes>
- **Test approach:** <notes>

-->
