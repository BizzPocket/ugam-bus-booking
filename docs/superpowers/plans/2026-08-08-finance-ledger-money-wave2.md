# Finance Ledger + Money Wave 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut money summaries to ledger reads, close UPI claim Confirm/Reject in the seat-booking loop, then redesign Wave 2 money screens.

**Architecture:** Hybrid writes forever (legacy tables + 062 triggers). New `LedgerMoneySource` reads enriched `finance_bus_summary` / rider balances. `MoneyController` / `FinanceController` prefer ledger for totals; row CRUD stays legacy. Payment claims load/review on money board + claim-aware collect.

**Tech Stack:** Flutter/Dart, GetX, Supabase PostgREST views/RPCs, easy_localization, Ugam design system.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-08-finance-ledger-money-wave2-design.md`
- Ledger amounts are integer minor (paise); convert `/ 100` only at Dart boundary
- After cutover: never silently fall back to legacy-computed **totals** on ledger fetch failure — error + retry
- Accent-rationing: one solid champagne CTA per screen
- Preserve seat-booking money loop: fare from seats − confirmed advances; pending claims never count as paid
- Do not commit unless the user asks

---

### Task 1: Ledger amount helpers + bus rollup model

**Files:**
- Create: `lib/models/ledger_bus_rollup.dart`
- Create: `lib/utils/ledger_money.dart`
- Test: `test/models/ledger_bus_rollup_test.dart`
- Test: `test/utils/ledger_money_test.dart`

**Produces:**
- `double minorToRupees(int minor)`
- `class LedgerBusRollup` with fields matching SQL view columns (rupees after parse)
- `BusMoneySummary toBusMoneySummary()` mapping

- [ ] **Step 1: Failing tests for paise conversion and rollup → BusMoneySummary**
- [ ] **Step 2: Implement helpers + model**
- [ ] **Step 3: Tests pass**

---

### Task 2: Enrich `finance_bus_summary` view (collected, handed over, AR)

**Files:**
- Create: `supabase/migrations/063_finance_bus_summary_display.sql`

**Produces:** View columns:
- existing: `outstanding_handover_minor`, `billed_minor`, `income_minor`, `ground_expenses_minor`, `rent_minor`, `owner_unpaid_minor`
- add: `collected_minor` (cash_receipt + refund on `cash.handler`), `handed_over_minor` (handover on `cash.handler` absolute), `to_collect_minor` / `to_return_minor` from `ar.rider` sign-split for that bus’s passengers (or tour-scoped rider sum joined by seating — prefer entry lines tagged with bus via cash side; if AR has null bus_id, aggregate tour-level rider balances separately)

- [ ] **Step 1: Write migration SQL**
- [ ] **Step 2: Document apply-after-062 in migration header**

---

### Task 3: `LedgerMoneySource` fetch

**Files:**
- Create: `lib/services/ledger_money_source.dart`
- Test: `test/services/ledger_money_source_test.dart` (fake client / map parsing)

**Produces:**
- `Future<List<LedgerBusRollup>> fetchBusRollups(String tourId)`
- `Future<Map<String, double>> fetchRiderOwesRupees(String tourId)` // passengerId → owes (positive = due)

- [ ] **Step 1: Failing parse/mapping tests**
- [ ] **Step 2: Implement source via SupabaseService**
- [ ] **Step 3: Tests pass**

---

### Task 4: Wire MoneyController summaries to ledger

**Files:**
- Modify: `lib/controllers/money_controller.dart`
- Modify: `test/controllers/money_settlement_snapshot_test.dart` (inject fake source or keep legacy path under test flag)
- Test: `test/controllers/money_controller_ledger_test.dart`

**Behavior:**
- On `loadForTour`, also fetch ledger rollups; store `_ledgerByBus`, `_ledgerLoadFailed`
- `summaryForBus` / `tourSummary` / `summariesForBuses` build from ledger when available
- `toCollect`/`toReturn` from rollup; still load legacy rows for CRUD
- If ledger fails: set loadFailed (or dedicated flag) — UI shows retry

- [ ] **Step 1: Failing controller test with fake source**
- [ ] **Step 2: Wire load + summary methods**
- [ ] **Step 3: Tests pass**

---

### Task 5: Wire FinanceController to ledger

**Files:**
- Modify: `lib/controllers/finance_controller.dart`
- Modify: `test/controllers/finance_controller_test.dart`

**Behavior:**
- `load()` pages/fetches `finance_bus_summary` (all owner tours via RLS), folds per `tour_id`: revenue←collected, expenses←ground+rent, income←income
- Keep `markStale` / `refreshIfStale` / `financesFor` period API

- [ ] **Step 1: Unit-test fold logic with injected rows**
- [ ] **Step 2: Replace legacy paging**
- [ ] **Step 3: Tests pass**

---

### Task 6: Payment claims model + MoneyController review APIs

**Files:**
- Create: `lib/models/payment_claim.dart`
- Modify: `lib/controllers/money_controller.dart`
- Test: `test/models/payment_claim_test.dart`
- Test: `test/controllers/payment_claims_test.dart`

**Produces:**
- `PaymentClaim` fromMap / status enum
- `claims` obs list; load with tour
- `confirmClaim(id, {note})` → RPC `confirm_payment_claim`
- `rejectClaim(id, {note})` → RPC `reject_payment_claim`
- Helpers: `pendingClaims`, `confirmedAdvanceForPassenger(id)`

- [ ] **Step 1: Model + controller tests**
- [ ] **Step 2: Implement**
- [ ] **Step 3: Tests pass**

---

### Task 7: Money board UPI strip + collect claim awareness

**Files:**
- Modify: `lib/screens/tour_money_board_screen.dart`
- Modify: `lib/screens/collection_screen.dart`
- Modify: `lib/screens/handler_bus_chart_screen.dart` (collect sheet)
- Modify: `lib/utils/seat_money_state.dart` or collect due helper
- Modify: `assets/translations/{en,gu,hi}.json`
- Test: widget/unit for due-with-advance

**Behavior:**
- Board: pending claims list Confirm/Reject
- Collect: due = live seat fare − confirmed advances; show pending claim warm chip (not paid)

- [ ] **Step 1: Due helper tests**
- [ ] **Step 2: UI + i18n**
- [ ] **Step 3: Tests pass**

---

### Task 8: Wave 2 UI — tour money board + bus money + finance

**Files:**
- Modify: `lib/screens/tour_money_board_screen.dart`
- Modify: `lib/screens/bus_money_screen.dart`
- Modify: `lib/screens/finance_screen.dart`
- Modify: `lib/screens/collection_screen.dart` (Mark paid prominence if needed)

- [ ] Accent-rationing + UgamEmpty/error; tonal Collect; shared chips
- [ ] Smoke/widget tests still pass

---

### Task 9: Wave 2 UI — charts pills + handler bus chart

**Files:**
- Modify: charts selector usage (find charts screen)
- Modify: `lib/screens/handler_bus_chart_screen.dart`

- [ ] Tonal selector pills; handler default List; split Call/Collect; localize GO/RET/½
- [ ] Verify claim-aware collect still works

---

### Task 10: Verification pass

- [ ] Run: `flutter test test/models/ledger_bus_rollup_test.dart test/utils/ledger_money_test.dart test/services/ledger_money_source_test.dart test/controllers/money_controller_ledger_test.dart test/controllers/finance_controller_test.dart test/controllers/payment_claims_test.dart`
- [ ] Update audit progress for F1/F5 in `docs/superpowers/audits/2026-08-08-lifecycle-full-audit.md`

---

## Spec coverage

| Spec item | Task |
|-----------|------|
| Ledger read cutover | 1–5 |
| Hybrid writes | 4 (unchanged CRUD) |
| UPI Confirm/Reject + collect | 6–7 |
| Seat-booking due loop | 7 |
| Wave 2 six screens | 8–9 |
| Fail loud on ledger miss | 4–5 |
| Enrich view for display fields | 2 |
