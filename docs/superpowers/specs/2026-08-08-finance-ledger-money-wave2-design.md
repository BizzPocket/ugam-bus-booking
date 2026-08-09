# Finance Ledger Cutover + Money Wave 2 Design

**Date:** 2026-08-08  
**Status:** Approved for planning (pending user review of this file)  
**Source:** Lifecycle audit F1/F5/F6 + redesign Wave 2  
**Companion:** `docs/superpowers/audits/2026-08-08-lifecycle-full-audit.md`

---

## Goal

Ship a **complete seat-booking money loop** end-to-end:

> Request → Accept → Assign seats → (optional UPI advance claim) → Lock/notify → Handler collect without double-charge → Admin settle → Cross-tour Finance P&L

In one milestone:

1. **Ledger read cutover (big-bang to “C”)** — summaries from ledger views; hybrid writes forever  
2. **UPI claim Confirm/Reject** on money surfaces + claim-aware collect  
3. **Full Wave 2 money UI redesign** (six screens)

---

## Locked decisions

| Decision | Choice |
|----------|--------|
| Cutover style | Big-bang ship landing at full ledger **reads** (Approach 3). Internal build order still adapter → wire → UI |
| Phased A→B→C product releases | Not separate releases; land at C |
| Writes | **Hybrid forever** — keep writing `collections` / `expenses` / `incomes` / `bus_handovers`; triggers (062) mirror into ledger |
| UPI | **In scope** — Confirm/Reject + pending visibility on collect |
| UI scope | **Full Wave 2** — tour money board, bus money, collection, finance, charts, handler bus chart |
| Seat-booking completeness | Non-negotiable — advances, seat moves, and collect must stay consistent |

**Out of scope**

- Retiring legacy write tables / posting only via finance RPCs  
- Razorpay / gateway verification  
- Fullscreen chart redesign  
- Dock IA / non-money screens  
- Productized parity banner (A→B style) — skipped for big-bang

---

## Architecture

### Data flow

```text
Writes (unchanged)
  MoneyController / handler RPCs / UPI confirm RPC
       → collections | expenses | incomes | bus_handovers | payment_claims
       → triggers (062) / confirm_payment_claim → finance_entries + finance_lines

Reads (cut over)
  LedgerMoneySource
       → finance_bus_summary
       → finance_rider_balance
       → tour rollup (sum of bus summary / balances view)
       → MoneyController / FinanceController summary APIs
       → Tour money board · Bus money · Finance · Dashboard settlement · Handler money chips

Row lists (still legacy)
  collections / expenses / incomes / handovers rows for edit · delete · Mark paid
```

### Adapter

- New module (e.g. `lib/services/ledger_money_source.dart` or under `lib/services/finance/`)  
- Fetches ledger views scoped by `tour_id` (RLS via tour ownership)  
- Converts `*_minor` / paise → rupees (`/ 100`) at the boundary  
- Maps into existing `BusMoneySummary` / `TourMoneySummary` (or thin wrappers that feed the same getters screens already use) so UI formulas are not forked  
- On failure: set `loadFailed`, show retry — **never** silently fall back to legacy-computed totals after cutover

### Controllers

- **MoneyController**  
  - Continues CRUD on legacy tables  
  - `tourSummary()` / bus summaries prefer ledger adapter once loaded for that tour  
  - Loads `payment_claims` for the tour; expose pending/confirmed lists  
  - Confirm → `confirm_payment_claim`; Reject → `reject_payment_claim`; then refresh ledger + claims  
  - Keep `_invalidateFinance()` so Finance refetches after writes  

- **FinanceController**  
  - Stop paging `collections` / `expenses` / `incomes` for P&L totals  
  - Aggregate from ledger bus/tour summaries (completed tours or same period filter as today)  
  - Preserve `markStale` / `refreshIfStale` contract  

### Account mapping (display)

Use existing SQL view semantics (056):

| UI concept | Ledger source |
|------------|---------------|
| Outstanding handover | `cash.handler` balance (`outstanding_handover_minor`) |
| Billed / fare | `revenue.fare` |
| Extra income | `revenue.extra` |
| Ground expenses | `expense.ground` |
| Bus rent | `expense.rent` |
| Rider owes / change | `ar.rider` via `finance_rider_balance` |

Integer paise only at rest; float rupees only in Dart display layer (existing `Formatters.formatMoneyInr`).

---

## UPI + seat-booking money loop

### Problem

Customer UPI QR claim is assertion, not proof (`payment_claims`). Without admin review + collect awareness, handlers re-collect the full fare.

### Behavior

1. **Money board** — “Pending UPI claims” strip: amount, passenger/phone, UTR/ref, Claimed at · **Confirm** / **Reject**  
2. **Confirm** — RPC posts ledger advance; claim → `confirmed`; rider still-due drops  
3. **Reject** — claim → `rejected`; full fare remains due; optional note  
4. **Collect sheet (admin + handler)** — show:  
   - Fare from live seats  
   - Confirmed advances (reduce due)  
   - Pending claim (warm/amber — **not** treated as paid)  
   - Still to collect  
5. **Seat moves / reprice** — fare from seats; confirmed advances stay on passenger so moves don’t invent a second full charge  
6. **Customer claim write path** — already exists; this milestone closes admin/handler side only  

### RPCs (already in 060)

- `confirm_payment_claim(uuid, text)`  
- `reject_payment_claim(uuid, text)`  
- `handler_payment_claims` / owner RLS on `payment_claims`  

---

## Wave 2 UI redesign

**Law:** At most one solid champagne focal per screen (sticky CTA when present). Other actions tonal. Error/empty states never solid gold.

| Screen | Changes |
|--------|---------|
| `tour_money_board_screen` | `UgamAppBar` eyebrow; `UgamEmpty` / error; UPI claims strip; ledger-backed hero stats |
| `bus_money_screen` | Demote mid-page Collect to tonal; larger hits; shared category chips |
| Collection surfaces | One-tap Mark paid prominent; pin summary + filters; due = seats − confirmed advances |
| `finance_screen` | Shared header; period pills; ledger totals; proper empty/error |
| Charts selectors | Tonal `UgamSelectorPills`; collapse chrome |
| `handler_bus_chart` | Default List; split Call vs Collect; `UgamTabPills`; skeleton; localize GO/RET/½; claim-aware Collect |

Presentation redesign preserves navigation and business callbacks; ledger + UPI are the intentional behavior additions.

---

## Rollout order (single milestone)

1. Ledger adapter + unit tests (paise mapping, summary shape)  
2. Wire MoneyController / FinanceController / dashboard settlement reads  
3. Payment claims load + Confirm/Reject + collect-sheet claim UI  
4. Wave 2 redesign pass per screen  
5. Verification gates below  

---

## Verification gates

- Spot-check one live tour: board/bus outstanding + net vs SQL `finance_bus_summary`  
- Confirm claim → due drops; Reject → due unchanged  
- Handler/admin collect shows pending claim without treating it as paid  
- Seat move after confirmed advance does not demand full fare again  
- Soft-deleted legacy rows do not inflate ledger (triggers already reverse)  
- Ledger fetch failure → error + retry, not ₹0 silence  
- Automated: adapter tests, claim controller tests, money summary regression, key screen smoke/widget tests  

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Ledger not backfilled / triggers not applied on env | Fail loud; document apply order 053→…→062 |
| Summary field mismatch vs old Dart formulas | Prefer view columns; goldens/snapshots for known fixtures |
| Handler still double-collects | Pending claim mandatory on collect sheet before Mark paid |
| Wave 2 scope creep | No logic rewrites beyond ledger/UPI; no fullscreen chart |

---

## Success criteria

- Money board, bus money, Finance, and settlement chips agree with ledger for the same tour  
- UPI advance can be claimed → confirmed/rejected → reflected in due before boarding  
- Wave 2 screens follow accent-rationing and shared Ugam chrome  
- Seat booking money path is closed: no invisible advances, no silent dual books on screen  
