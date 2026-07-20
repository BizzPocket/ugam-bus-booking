# Handler Redesign — Design Language & Money Cluster

**Date:** 2026-07-20
**Branch:** `feat/money-collection-settlement`
**Status:** Design approved (visual direction signed off via mockup). Money board partially implemented this session; remainder specced below.

---

## 1. Why

The handler/operator app is *functional but not usable for a long working day*. It already has a mature, consistent design system (copper-on-graphite "cockpit", Sora/Inter, 34 components) — so the problem is **not** the absence of a system. The problem is that the system produces **flat, equal-weight screens**: every card is the same graphite block, nothing leads, zeros are shown as if they were data, and the everyday action is buried.

The operator named four concrete pains (all four selected):

1. **Key number not obvious** — can't instantly see the ONE figure that matters.
2. **Too many taps to act** — the everyday action (collect / hand over) is too deep.
3. **Clutter & ₹0 noise** — labels, fields, and zeros to hunt through.
4. **Flat & tiring to scan** — endless equal dark cards, no rhythm or focal point.

**Direction (approved): _elevate_ the existing identity, not replace it.** Keep the copper accent, graphite ground, dark-primary mode, Sora/Inter, and the token architecture. Add real hierarchy, depth, and state-driven rhythm on top.

**Decomposition (approved):** prove the design language on the **money cluster first**, sign off the feel, then cascade the same language to the rest of the handler app (tour workspace → seating → requests → lock/notify → the long tail). This spec covers **(A) the reusable design language** and **(B) its application to the money cluster**. Later clusters get their own specs that inherit Section A.

**Success = the four pains are visibly gone on the money screens, using only the existing tokens + a small set of component upgrades, with no regression in tests or `flutter analyze`.**

---

## 2. Non-goals

- **No new visual identity.** Palette, type, brand, dark-primary all stay. No new accent, no re-skin.
- **No re-widening of density.** The "cockpit" density stays; the fix is *hierarchy*, not more air everywhere. Space is *earned* around a hero, *compressed* everywhere else.
- **No customer-screen work** in this spec (the 7 `customer_*` / `find_my_seat` / `handler_bus_chart` screens are out of scope; they get a separate pass later).
- **No god-screen refactor for its own sake.** We only split a widget out when the redesign of *that* surface needs it. The `Obx`-over-whole-screen perf issue is noted as a risk but is not this spec's goal — we avoid *worsening* it and fix it opportunistically where a hero/section split naturally narrows the reactive scope.
- **No new backend / model / controller logic.** These screens are read-mostly views over `MoneyController`; aggregation stays untouched. This is a view-layer redesign.

---

## 3. Section A — The Design Language (reusable across all handler screens)

Five rules. Every later cluster inherits them verbatim.

### A1. One hero per surface
Every screen — and every card that represents an entity — names the **single figure that matters** and sets it large, tabular (`UgamText.numXl`/`numLg` + `UgamText.tabular`), and tinted by meaning. The eye must land before it reads. Everything else on the surface is quieter (smaller, `ink2`/`ink3`, no competing size).

- A screen has exactly one *screen-level* hero (e.g. the money board's P&L card; a bus cockpit's outstanding-handover figure).
- A repeated card (a bus row) has exactly one *card-level* hero figure.

### A2. Semantic figure color (accent stays rationed)
Figures are colored by **what they mean**, drawn from the existing token set — never by decoration:

| Meaning | Token | Used for |
|---|---|---|
| Money to collect / shortfall | `danger` (#FF5247) | "to collect" figures, cannot-cover-rent |
| Money owed onward / attention | `warm` rose (#E98AB4) | outstanding handover due |
| Done / positive / settled | `good` mint (#4ADE9A) | collected, profit, "settled" |
| Neutral / context | `ink2` / `ink3` | expected amounts, zero-state, meta |

**Copper (`accent`) is reserved.** It marks (a) the screen's P&L / outcome hero and (b) the **single primary action** per screen (the one solid-copper CTA). It is never used for arbitrary figures. This preserves the token philosophy: "hierarchy from contrast + the rationed copper accent."

### A3. Nothing shows a zero
A field, row, pill, or breakdown appears **only once it holds a real value** (`> ε`). An untouched entity collapses to `identity + hero figure + primary action`. Secondary detail (to-collect / to-return / expenses breakdown) lives **one tap deeper**, never in an always-on strip. Rule of thumb: if a number is ₹0 because *nothing has happened yet*, don't render its row.

### A4. State creates rhythm (depth, not borders)
Cards are **not** equal walls. An entity is shaped by its state so the page's silhouette itself tells you where to look:

- **Needs action** → card carries a semantic **tone tint** (`UgamCardTone.danger` for a collect shortfall, `UgamCardTone.warm` for a handover due), a bold hero figure, and the primary action on the card. Visually heaviest.
- **Settled / done** → collapses to a **calm slim row** (`UgamCardTone.none` or a whisper of `good`), a mint "Settled" `UgamStatusDot`, a small confirming figure, no CTA.
- **Idle / neutral** → quiet neutral card, `ink2` figure, short status word.

Depth comes from the existing tools — the copper **glow** behind heroes, `card` → `cardElev` elevation, and the floating sticky bar — **not** from adding hairline rails or new borders. (No left accent-rail: that's not our system and it reads as generic.)

### A5. Space is earned
The hero **breathes** (generous padding, room around the big figure). Everything else stays cockpit-tight (`md`=12 gaps, `all(md)` card padding). This is the opposite of uniform density: contrast between a roomy hero and tight supporting rows is what makes the hero read as the hero.

### Status encoding summary
State is shown by **three redundant signals** (never color alone, for accessibility): card **tone tint** + **`UgamStatusDot`** word + **figure color**. Action-needed cards may omit the status word (the tint + tinted figure already say it); settled/idle always carry the word.

---

## 4. Section B — Money Cluster Application

Four screens + supporting component polish. Ordered by build sequence.

### B0. Shared component touch-ups (do first — they unlock the screens)
- **`UgamHeroStat`** ([ugam_hero_stat.dart]) currently renders its own `UgamCard.plain`, so using it *inside* another card creates a card-in-card (violates tokens' "cards never nest"). Add an **`elevated`/`framed` flag** (default true = today's behavior) so callers can render the hero content **without** its own card surface when it already sits inside one. Money board's removed "more detail" used this; the bus cockpit rollup will need the framed-off variant.
- **`UgamCard`**: no API change needed — `UgamCardTone.danger` already exists and is now a first-class state (used for collect-shortfall). Confirm the danger tint/border read well on graphite (they're defined at 12%/32%).
- Confirm `UgamButton` tonal (quiet, `accentFill`) vs `UgamCTA` solid-copper are used per A2: **one** solid-copper CTA per screen; card-level actions are tonal.

### B1. Tour money board — `tour_money_board_screen.dart` *(partially done this session)*
Already implemented this session: state-driven `_BusMoneyRow` (hero figure on the identity line, ₹0 suppression via `hasMoved`, removed the card-in-card `UgamHeroStat`, dropped the duplicated status amount, settled-collapse, tightened padding/gaps), and a scale-to-fit fix on the totals capsule figure. Tests updated & green; `flutter analyze` clean.

**Remaining to match the approved mockup:**
- **Differentiate action tones (A2/A4):** a collect-shortfall bus → `UgamCardTone.danger` + danger figure; a handover-due bus → `UgamCardTone.warm` + warm figure. (Today both use `warm`.)
- **Elevate the P&L entry card (`_PnlEntryCard`) into the screen hero (A1):** `elev: true` + the copper **glow** halo, an outcome headline ("Trip is in profit" / "Trip is at a loss"), the big net figure in `good`/`danger`, and a compact **sparkline** of the trip's running net (small inline `CustomPaint`; static, from available per-bus nets — no new data). This is the screen's one copper-accented hero.
- **Section label** gains a live count ("PER BUS · 3 buses · 1 settled").
- Verify the sticky totals capsule reads as the one *floating* element (`cardElev` + soft shadow + copper hairline) — it already is; just confirm after tone changes.

### B2. Per-bus cockpit — `bus_money_screen.dart`
- **Outstanding hero (`_OutstandingHero`):** keep the single focal figure + copper glow, but **tighten** — the current `SizedBox(height: 96)` + 200×200 halo + `xl` paddings are showroom-sized. Reduce vertical padding to `lg`, shrink the halo, keep the figure prominent (`hero`@~40). Apply A5 (hero breathes but doesn't sprawl).
- **Supporting stat grid:** the 3 `UgamStatTile`s (collected / income / expenses) stay but adopt A2 semantic colors (collected & income = `good`, expenses = `warm`) and A3 (suppress a stat that's ₹0 — e.g. hide "Income" when there's none rather than showing ₹0).
- **Ledger rows (`_ExpenseRow`, `_IncomeRow`, `_HandoverRow`, `_BusOwnerRentRow`):** already compact; align padding to `md`, ensure category chip + label + tabular amount rhythm is consistent, keep swipe-to-delete.
- **Section headers:** the add/record actions stay **tonal** (A2). The one **solid-copper** CTA is the sticky "Collect from passengers".
- **Tour rollup (`_TourRollupCard`)** uses `UgamHeroStat` — switch to the new **framed-off** variant if it visually nests; otherwise leave.
- Empty states: when a bus has no expenses/income/handovers, the calm `UgamEmpty` stays (that's intentional guidance, not ₹0 noise).

### B3. Collection — `collection_screen.dart`
- Per-passenger collect is the operator's highest-frequency money task → apply A1 (a clear "still to collect on this bus" hero at top) + A2 + fast action (record received in ≤2 taps via the existing sheet). Rows show owed vs received; a fully-collected passenger collapses to a calm mint row (A4). Detailed row spec deferred to the implementation plan after reading the current screen in full.

### B4. Trip P&L — `trip_pnl_screen.dart`
- Already hero-led (`_TripTotalCard` with `FittedBox`). Align it to A1/A2 (net figure tinted good/danger, copper reserved for the outcome hero), confirm per-handler / per-bus breakdown rows follow A3 (no ₹0 rows) and A5 spacing. Mostly a polish pass.

---

## 5. Testing & verification

- **Per screen:** update/extend the existing widget test (`tour_money_board_screen_test.dart` exists and is green; add coverage for the danger-vs-warm tone split and the P&L hero). Add a widget test for `bus_money_screen` covering hero + zero-suppressed stats if none exists.
- **Gate every screen on `flutter analyze` (clean) + the touched tests (green)** before moving to the next. `flutter` lives at `C:\src\flutter\bin`.
- **i18n:** any new label uses `tr()` keys added to all three locale files (en/gu/hi). Reuse existing `tour_money_board.*` / `bus_money.*` keys wherever possible; new keys (e.g. profit/loss outcome headline) added to all three.
- **Manual/visual:** the approved mockup is the reference for the money board & cockpit feel.
- **Known pre-existing test debt to fix as we touch it:** the money-board test's stale `tour_totals` assertion was already corrected this session.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Over-broad `Obx`** rebuilds whole money screens on any money mutation. | Don't worsen it. Where a hero/section split naturally narrows scope, wrap the narrower subtree. Full perf pass is out of scope but noted for the tour-workspace cluster (worst offender). |
| **God-screens** (`bus_money` 1070, `collection` 812) mix view + sheets + logic. | Extract only the widgets the redesign reshapes (hero, row) into private classes in-file; avoid gratuitous file splits this pass. |
| **i18n drift** (missing gu/hi keys → raw keys shown). | Add every new key to all three files in the same change; grep-verify. |
| **Density regression** — elevating heroes tempts re-widening everywhere. | A5 is explicit: only the hero breathes; supporting rows stay `md`-tight. Density memory ("do not re-widen") stands. |
| **Cascade scope creep** — "redesign everything" balloons. | Strict cluster-by-cluster: money ships & is signed off before the next spec opens. |

---

## 7. Cascade order (post-money, each its own spec inheriting Section A)

1. **Money cluster** — this spec.
2. **Tour workspace** — `tour_detail_screen` (hub) + `tour_overview_screen`. Highest traffic; also the worst `Obx` offender → pairs redesign with a targeted reactive-scope fix.
3. **Seating** — `seats_screen` / `tour_overview` / `tour_seat_assignment` (the 3,876-line workbench; interaction-heavy, most careful).
4. **Requests** — `requests_screen` (2,414; booking capture + capacity).
5. **Lock / Notify** — `notify_screen` (the "tour lock" gate + tracker).
6. **Long tail** — dashboard, tours list, charts, buses, groups, finance, settings, inbox/conversation.

---

## 8. Open decisions (fold into the plan; none block starting B1 remainder)

- **P&L sparkline source:** running net across buses vs across time. Default: across buses (data on hand), static paint. Revisit if a time series is cheap.
- **Collection screen row spec (B3):** finalize after a full read of `collection_screen.dart` during planning.
