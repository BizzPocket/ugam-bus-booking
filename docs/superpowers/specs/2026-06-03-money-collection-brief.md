# Money Collection & Settlement — Redesign / Build Brief

**Date:** 2026-06-03
**Area:** Money collection & settlement screens (per-passenger collection, overpay/shortfall, per-bus expenses, handler→admin handover, tour roll-up)
**Status:** Audit + design direction; NOT final code.
**Canonical prior spec:** `docs/superpowers/specs/2026-06-01-money-collection-settlement-design.md`

---

## 1. Current state (honest audit)

The money layer is **already largely built** — this is a *consolidation/redesign* job, not a greenfield one. What exists:

### Built and wired
- **Models** — all four exist and follow the repo `toMap`/`fromMap` conventions:
  - `lib/models/collection.dart` — per-(passenger, bus, **seat**) row with `amountDue`, `amountReceived`, `amountRefunded`, derived `balance`/`netCollected`/`changeToReturn`/`stillToCollect`. Note the model carries a `seatId` field (line 16) the original spec did NOT have.
  - `lib/models/expense.dart` — per-bus line items with `ExpenseCategory {driver, fuel, food, toll, other}`.
  - `lib/models/bus_handover.dart` — handler→admin remittance with `expectedAmount`, `handedOverAmount`, derived `shortfall`. Supports multiple (partial) rows per bus.
  - `lib/models/money_summary.dart` — `BusMoneySummary.compute` and `TourMoneySummary.compute`, pure value objects.
- **Controller** — `lib/controllers/money_controller.dart`: GetX controller, offline-first via `SyncService.smartFetch/smartInsert/smartUpdate/smartDelete`, optimistic local mutation + refetch-on-failure. Registered in `lib/app.dart:58` (`Get.lazyPut`, `fenix: true`).
- **Pricing engine** — `lib/models/bus_details.dart`:
  - Per-seat-type override columns `singleSofaPrice`/`doubleSofaPrice`/`seaterPrice` (each falls back to `pricePerSeat`).
  - **Rear-zone pricing** (`rearRows` + `rearPrice`, migration 005) — a second price tier the original spec did not contemplate. `berthPriceFor(type, row)` (line 248) applies rear price per-person for the last `rearRows` rows, overriding per-type prices.
  - `tripFactor(tripType)` halves single-leg fares.
  - `amountDueFor(passenger)` (whole bus) and `amountDueForSeat(passenger, seatId)` (one berth, line 291).
- **Screens** — three exist:
  - `lib/screens/bus_money_screen.dart` — per-bus cockpit: 4 stat tiles (Collected / Expenses / Expected handover / Outstanding), a CTA into collection, an Expenses ledger (add/delete via sheet), a Handover ledger (record/delete via sheet), and a **tour roll-up card at the bottom**.
  - `lib/screens/collection_screen.dart` — per-bus, per-seat collection list with All / To return / To collect filter pills, status chips (Return/Due/Paid/Not collected), and a bottom-sheet collect form with a live balance pill.
  - `lib/screens/handler_bus_chart_screen.dart` — the handler-side view: read-only full bus chart (seat grid recolored by collection status) where tapping an occupied seat opens the same collect sheet, persisted through the `handler_upsert_collection` RPC.
- **DB** — migrations exist: `004_money_collection.sql` (buses price columns, `collections`, `expenses`, `bus_handovers`, RLS via tour-owner join, realtime), `004_handler_collections.sql` (handler RPCs `handler_tour_manifest` + `handler_upsert_collection`), `005_bus_rear_zone_pricing.sql`.
- **Entry point** — reached from `bus_status_screen.dart:949` ("Collection & money" pill) → `BusMoneyScreen` for one bus.

### Where it falls short / drifts from the spec
1. **Spec says one row per (passenger, bus); code does per-(passenger, bus, SEAT).** The unique index is `collections_passenger_bus_seat_unique` (migration 004 line 68). The whole money layer silently became *per-seat* collection. This is a real product decision that was made in code but never reconciled with the canonical spec. It changes the entire UX (a 4-seat family booking = 4 collection rows, 4 chips, 4 sheets) and the math.
2. **Whole-Double Sofa is mis-priced in the per-seat flow.** `amountDueForSeat` for a `doubleSofa` returns `doubleSofaPrice / 2` (one berth). But `SeatAssignment` is `(busId, seatId)` with equality on those two fields (`lib/models/seat_assignment.dart:22`), and the assignment layer stores a whole-double occupant as a **single** `assignedSeats` entry (`seat_assignment_screen.dart:104-120` builds `occupantsBySeat[seatId] = [pId]` with `berths` derived from the layout, not duplicated entries). So `collection_screen.dart` (`_seatLines`, line 55) iterates `assignedSeats` and produces **one** line for a whole double, charging only HALF the sofa. The code in `amountDueForSeat` even anticipates a `seatId.split('#').first` berth-suffix (`bus_details.dart:294`) that **nothing in the assignment layer ever generates** — confirmed by grep: no `#` seatId is ever produced. This is a latent correctness bug, not just a design wrinkle.
3. **Two conflicting `004` migrations** in `supabase/migrations/`: `004_money_collection.sql` and `004_handler_collections.sql`. Same number, undefined apply order. The header comment inside `004_money_collection.sql` even calls itself "003". Migration numbering/headers need a cleanup pass before this ships.
4. **No tour-level money screen.** The only roll-up is a card buried at the bottom of *each* `BusMoneyScreen`. At 20-25 buses the agent has no single "which buses are settled / which still owe / total net" board. This is the biggest UX gap for the stated scale.
5. **"One screen one job" is violated by `BusMoneyScreen`.** It does summary + expenses + handover + tour roll-up in one scroll. Per the locked DNA that should be split, with actions in bottom sheets.
6. **`collectedBy` is a free-text field surfaced in the collect sheet** (collection_screen.dart:224). With single-login + one-handler-per-bus this is almost always noise the agent re-types; it competes with the lean-data principle.
7. **`paymentStatus` (paid/notPaid) on `Passenger` still exists** and is now redundant/contradictory with the collections ledger. Two sources of truth for "did they pay".
8. **No edit/audit affordance on a saved collection beyond overwrite.** `upsertCollection` rewrites the whole row (consistent with the repo's whole-row-rewrite model) — fine, but there's no history, no "who/when last touched", no undo, no delete surfaced in the collection UI (only `deleteCollection` in the controller, unused by screens).
9. **`amount_due` snapshotting is half-implemented.** The collect sheet always re-seeds `amountDue` from the *live* `amountDueForSeat` on save (collection_screen.dart:260), so a later price/rear-zone change DOES retroactively move historical dues — contradicting the spec's "stored snapshot, past collections not altered" promise (spec lines 256-257).

---

## 2. Proposed direction (consistent with seat redesign + DNA)

Keep the existing models/controller/RPC plumbing (it is good and offline-safe). Redesign the **screens and the collection grain**, and fix the whole-double pricing. Concretely:

### 2a. Re-confirm the collection grain, then make pricing correct for it
The per-seat grain is actually *better* aligned with the new lean seat model than per-passenger (each berth a person physically occupies maps to one collectible line, and groups/shared-doubles fall out naturally). **Recommend keeping per-seat**, but fix the whole-double: a whole-double occupant must either (a) generate two collectible berths (`DL3#1`, `DL3#2`) — which finally makes the dormant `split('#')` code real — or (b) `amountDueForSeat` must detect "this passenger holds the whole sofa" (only occupant of a 2-berth cell) and charge the full `doubleSofaPrice`. Option (b) is less invasive and needs no assignment-layer change. This must be decided (see Open Questions Q1).

### 2b. Three screens, one job each (replacing the current two/three)
- **Tour money board (NEW, the headline screen).** Reached from the tour overview. A scannable list of all 20-25 buses, each a row/card: bus name, collected, net, a settlement state ring (Settled / Owes handover / Has shortfalls to collect / Has change to return) using the *attention* warm `#FB923C` ring only for buses needing action — exactly the "colored ring = needs attention" pattern from the seat redesign. A sticky top capsule shows tour totals (collected, expenses, net, outstanding handover, to-return, to-collect). Tapping a bus → per-bus money.
- **Per-bus money (redesign of `bus_money_screen.dart`).** Mostly read-only: stat tiles + a tabbed body (Collection · Expenses · Handover). Each tab is a list; the "+" and edits are bottom sheets on tap. Drop the embedded tour roll-up (now its own board).
- **Per-bus collection (keep `collection_screen.dart`, light redesign).** Per-seat lines, filter pills, collect sheet on tap. Make `collectedBy` optional/auto-filled. Add overpay/shortfall as the primary visual (warm ring for "return change", danger for "still to collect").

The **handler chart** (`handler_bus_chart_screen.dart`) already embodies the right pattern (read-only grid, tap-seat → collect sheet, status color). Keep it; align its sheet and status logic with whatever the agent-side collect sheet becomes so the two never drift.

### 2c. Reconcile payment_status
Make `Passenger.paymentStatus` *derived* from collections (fully covered across all held berths ⇒ paid) or deprecate it, so there is one source of truth. Decide in Q5.

All of this stays inside the locked DNA: dark-first, coffee accent `#B07A52`, warm `#FB923C` strictly for attention (buses needing action, change-to-return), 22/999/8 radii, tabular figures on every ₹ number, sticky pill CTAs, Gujarati-default full-string i18n (the current screens use raw English literals like `'Collected'`, `'Add expense'` — these need translation keys; see Risks).

---

## 3. Concrete data-model / DB changes

1. **Resolve the duplicate `004` migrations.** Renumber `004_handler_collections.sql` → `006_handler_collections.sql` (or fold into a clean sequence) and fix the "003" header inside `004_money_collection.sql`. No schema change, but required before any further migration lands cleanly.
2. **Whole-double pricing fix** (pick per Q1):
   - *Option (b), no schema change:* `amountDueForSeat` checks whether the passenger is the sole occupant of a 2-berth doubleSofa cell and, if so, charges full `doubleSofaPrice`. Needs `occupantsBySeat`-style context passed in, or a `wholeDouble` flag on the call.
   - *Option (a), schema-touching:* introduce berth-suffixed seat IDs (`DL3#1`/`DL3#2`) at assignment time; then `collections.seat_id` already stores them and the unique index handles it. Larger blast radius (assignment screen, manifest, customer views).
3. **`amount_due` snapshot semantics.** Either (i) stop re-seeding `amountDue` from live price on every save (only seed on first open) to honor the snapshot promise, or (ii) explicitly document that due is always live and drop the "snapshot" language. No column change; a controller/sheet logic change. Decide in Q4.
4. **Optional: `collections.method` (`cash`/`online`) column** if Q6 says online matters. Currently cash-only is assumed; `numeric(10,2)` already allows paise.
5. **Optional: `collections.status` or soft-delete / audit columns** if edit-history/who-can-edit matters (Q3). v1 may skip.
6. **Optional generated/view `balance`** — currently app-derived; fine for v1. A SQL view `tour_money_rollup` would let the new Tour money board load one cheap aggregate instead of pulling every collection row for 25 buses at scale (perf, see Risks).
7. **Deprecate or derive `passengers.payment_status`** (Q5) — if derived, it can stay as a column updated by a trigger, or be dropped from the UI.

No destructive changes to existing live tables are needed for the core redesign; everything is additive or app-side.

---

## 4. Hidden rules & open questions (agent must answer)

These are ranked; each has candidate options.

1. **Whole-Double Sofa charge in the per-seat model.** Today a whole-double is charged HALF (one berth) because it produces one assignment entry and `amountDueForSeat` returns `doubleSofaPrice/2`. What SHOULD a person who books the entire double sofa for themselves pay, and how is it modeled?
   - Options: (a) split into two berth lines `DL3#1`/`DL3#2` so they pay both halves (= full sofa) — activates the dormant `#` code; (b) keep one line but charge full `doubleSofaPrice` when sole occupant — smallest change; (c) one line at `doubleSofaPrice/2` is actually correct because you always re-sell the empty half (current behavior — confirm it's intentional).
   - Why it matters: directly determines revenue correctness on every whole-double seat; it is currently a silent under-charge bug.

2. **Collection grain: per-seat vs per-passenger/booking.** Spec said per-(passenger, bus); code is per-(passenger, bus, seat). A 4-seat family = 4 rows/chips/sheets today.
   - Options: (a) keep per-seat (precise, matches lean seat model, more taps); (b) collapse to per-passenger-per-bus (one row sums all their berths on that bus — fewer taps, matches "lean booking", but loses per-seat refund granularity); (c) per-*booking-group* (one row for a whole linked group — fewest taps, aligns with the new groups feature).
   - Why it matters: defines the core collection screen UX and how many interactions the agent makes per bus at scale; changes the unique index and totals math.

3. **Who can edit/delete a collection, and after handover?** Single-login agent + a handler RPC both write collections today; no lock after settlement.
   - Options: (a) agent can always edit any collection, handler can only edit unsettled ones on their bus; (b) lock a bus's collections once a handover is recorded (edits require "reopen"); (c) fully open, rely on the agent's discipline (current behavior).
   - Why it matters: cash reconciliation integrity; whether the handover snapshot can silently drift after the fact.

4. **Is `amount_due` a frozen snapshot or always live?** Spec promised a snapshot (price changes don't move history); code re-seeds it live on every save.
   - Options: (a) freeze on first collect (snapshot — honors spec, protects past records); (b) always live from current pricing (simpler, but a rear-zone/price edit silently changes what someone "owed"); (c) live until first payment recorded, frozen after.
   - Why it matters: determines whether editing a bus price after the trip corrupts settled books.

5. **Two sources of truth: `passengers.payment_status` vs collections.** Both claim to know "paid".
   - Options: (a) derive payment_status from collections (paid = all held berths fully covered) via app/trigger; (b) drop payment_status from money UI entirely, keep only as a coarse manual flag elsewhere; (c) remove the column.
   - Why it matters: avoids contradictory "Paid" badges between seat screens and money screens.

6. **Cash vs online / UPI.** Spec scoped v1 to cash-only. Real yatra collections increasingly include UPI.
   - Options: (a) cash-only for v1 (current); (b) add an optional `method` (cash/online) per collection for record-keeping only; (c) cash-only but a free-text note covers "paid by GPay".
   - Why it matters: whether the handover-cash math should exclude online payments (online money never passes through the handler's cash bag).

7. **Refunds on cancellation.** `amountRefunded` exists and powers "change to return", but there's no cancellation flow.
   - Options: (a) reuse `amountRefunded` for full cancellation refunds (set received→0 or refunded=received); (b) a distinct `refund`/`cancelled` state on the collection; (c) handle cancellations only in the booking/seat layer and let the collection be deleted.
   - Why it matters: "change owed back from overpay" and "refund because they cancelled" are different events the agent will want to tell apart.

8. **Handover at scale: per-bus only, or batch?** Today handover is recorded one bus at a time. With 20-25 handlers settling near-simultaneously at trip end, that's a lot of taps.
   - Options: (a) per-bus only (current); (b) a "settle all" board where the agent confirms each bus's expected amount in one list; (c) per-handler (a handler running two buses settles once).
   - Why it matters: end-of-tour reconciliation ergonomics — the moment the agent is most time-pressed and cash-anxious.

---

## 5. Dependencies — how this connects to the rest

- **Seat-assignment redesign (the big one):** money is downstream of seat assignment. The collection grain (Q2) and whole-double charge (Q1) depend on how the new auto-assign + groups model records `assignedSeats` (especially whether a whole-double becomes one entry or two berths, and whether grouped bookings share a `group_id`). If groups land first, per-group collection (Q2c) becomes attractive. The "exception list → lock" flow means money collection should only really open *after* seats are locked — the Tour money board could gate on lock state.
- **Per-seat-type + rear-zone pricing** lives on `Bus` (`add_bus_screen.dart` already edits the override fields; rear-zone via migration 005). The money layer consumes these via `berthPriceFor`. Any pricing-screen redesign must keep `amountDueFor`/`amountDueForSeat` as the single fare source so collection and the customer-facing fare never diverge.
- **Handler view** (`handler_bus_chart_screen.dart` + `004_handler_collections.sql` RPCs + `CustomerRequestsStore.handlerUpsertCollection`) is a parallel write path into the same `collections` table. Any change to the collect sheet, status logic, or whole-double charge MUST be mirrored on both the agent screen and the handler screen, and in the `handler_upsert_collection` RPC's `on conflict` target (`passenger_id, bus_id, seat_id`).
- **Tour overview / `bus_status_screen.dart`** owns the entry point (line 949) and would host the new Tour money board pill.
- **Offline-first `SyncService`** — whole-row rewrites + pending-ops queue. The new Tour money board's aggregate (and any SQL roll-up view) must still degrade to the SQLite cache fallback.

---

## 6. Risks

- **Whole-double under-charge is a live money bug**, not cosmetic — every whole-double seat collected to date under the current code took half the fare. Fixing it changes historical `amount_due` unless snapshotting (Q4) is resolved first.
- **Duplicate `004` migrations** can apply in the wrong order on a fresh DB and leave the schema inconsistent (e.g. `seat_id` column / unique index timing). Must be cleaned before the next migration.
- **Scale (20-25 buses × ~40 seats ≈ 1000 collection rows):** loading every collection row into `MoneyController` for a tour-wide board is heavy on the cache fallback path. A SQL roll-up view or paginated/aggregate fetch is likely needed.
- **i18n debt:** the money screens are full of hard-coded English (`'Collected'`, `'Expected handover'`, `'Add expense'`, `'Still to collect'`, `'Change to return'`, etc.). The locked DNA mandates Gujarati-default full-string translations with NO bilingual sub-labels — every string here needs a key in `assets/translations/*.json`.
- **Two write paths into `collections`** (agent direct + handler RPC) can race / diverge if status, locking, or whole-double logic is changed in only one place.
- **`collectedBy` free-text** invites inconsistent data ("me", "handler", "Ramesh bhai") that has no analytic value under single-login; surfacing it competes with lean-data.
- **Float money math** — models use `double` for rupees. Rounding (especially `doubleSofaPrice/2 = 387.50` shared-double halves and trip-factor halving) can produce ₹0.01 drift in roll-ups across 1000 rows. `numeric(10,2)` storage is fine, but the Dart aggregation should round per-line.
