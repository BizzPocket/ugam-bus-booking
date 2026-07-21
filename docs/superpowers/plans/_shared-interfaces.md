# Shared interfaces across the 6-phase release plan (2026-07-21)

Contracts introduced in early phases that later phases depend on. Keep names/types identical across plan files.

## Introduced in Phase 1 (feature-complete)

**Handler settlement (closes H-1) — reuses existing `bus_handovers` table:**
- `HandlerManifest.handovers` → `List<BusHandover>` (parsed in `HandlerManifest.fromJson`).
- `HandlerBusMoney`:
  - `final double handedOver;` — Σ of this bus's handover amounts.
  - `double get expectedHandover => inHand;`  // == admin `BusMoneySummary.expectedHandover` (netCollected)
  - `double get outstandingHandover => expectedHandover - handedOver;`
  - `HandlerBusMoney.compute(...)` gains a `List<BusHandover> handovers` param and folds `handedOver`.
- RPC (SECURITY DEFINER): `handler_upsert_handover(p_request_id uuid, p_handover jsonb) returns jsonb` (+ `handler_delete_handover(p_request_id uuid, p_handover_id uuid) returns boolean`); both re-check `is_request_handler(p_request_id)` and bus-on-tour.
- RPC `handler_tour_manifest` extended to return a tour-scoped `handovers` array.
- `CustomerRequestsStore.handlerUpsertHandover(String requestId, BusHandover h)` → `Future<BusHandover?>` (null = rejected; mirrors the nullable sibling `handler_upsert_*` methods); `handlerDeleteHandover(String requestId, String handoverId)` → `Future<bool>`.
- Migration file: `supabase/migrations/042_handler_handover.sql` (also carries the H-8 `source` columns below).

**Billed-revenue snapshot (closes CALC-1):**
- Persisted per-seat billed amount so `completeOutboundLeg` cannot erase earned revenue.
- Column: `passengers.billed_amount numeric` (nullable; stamped at lock/assignment time), surfaced as `Passenger.billedAmount` (double?), round-trips as `billed_amount` in `toMap`/`fromMap`.
- New model `lib/models/billed_revenue.dart`: `BilledRevenue.forTour({required Tour tour, required List<Collection> collections})` → `Map<String, double>` (busId → billed). `money_controller.dart` `_billedRevenues` delegates to it; reads persisted `billedAmount` (falling back to live `amountDueFor` when the snapshot is null). Known approximation: a retired rider never collected has no collection row and is dropped from per-bus billed (cannot cause the `netBilled < netCollected` paradox).
- Migration file: `supabase/migrations/043_billed_snapshot.sql`. **Must be live before shipping the `Passenger.toMap` change** (unwhitelisted writes → `42703`, same footgun as 040).

**Ledger provenance (closes H-8):**
- Column `source text not null default 'admin'` (backfilled) on `expenses`, `incomes`, and `bus_handovers`.
- Surfaced as `Expense.source` / `IncomeEntry.source` (`String`, default `'admin'`); top-level pure predicate `bool handlerCanModifyLedger(String source)`; handler UI hides delete/edit where `!handlerCanModifyLedger(source)`.
- Folded into migration `042_handler_handover.sql`.

**WhatsApp settings reachability (closes AL-2):**
- New Settings row in `settings_screen.dart` that `Get.to(() => const WhatsAppSettingsScreen())` (or the existing named route).

## Naming conventions to preserve
- Migrations: next free numbers are `042` (handover + provenance), `043` (billed snapshot), `044` (Phase 5 live-RPC capture) — after the pending 039/040/041. One concern per file; header `-- Run THIS FILE ALONE`.
- Money: always `formatMoneyInr` (₹, en_IN). Never `formatCurrency` (dead, `$`).
- Leg-aware seat counts: always `tour.occupiedBerthsFor(busId)`, never raw `assignments.values.length`.
- State gating: `isLoading && !loadedOnce` → skeleton; errors via `UgamEmpty.error`.
