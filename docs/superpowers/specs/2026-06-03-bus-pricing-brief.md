# Bus Pricing — Design Brief

**Date:** 2026-06-03
**Area:** Bus pricing (base price, per-seat-type overrides, the half-built rear-zone tier, and the agent's "per-row / front-premium pricing" ask)
**Status:** Audit + direction; NOT final code
**Depends on:** the just-approved seat-assignment redesign (auto-assign + exception list + approved-priority) and `2026-06-01-money-collection-settlement-design.md`

---

## 1. Current state (honest audit)

Pricing today is a **three-layer cascade**, resolved per berth at fare-calc time. It is more built-out in the model/DB than in the UI — and one whole tier is invisible to the agent.

### Layer 1 — Tour base price (`tours.price_per_seat`)
- Set on `create_tour_screen.dart:300-306` (optional field) and `edit_tour_screen.dart:394-398`.
- Stored as `Tour.pricePerSeat` (`lib/models/tour.dart:17`, `price_per_seat`).
- Pure fallback: it is **only** used to seed a bus's price when the bus is added (`add_bus_screen.dart:144-152` `_maybeSeedPrice`, and `:245-248` on save). It is never used directly in fare math — `amountDueFor` lives entirely on `Bus`.

### Layer 2 — Per-bus base + per-seat-type overrides (`buses.*`)
On the `Bus` model (`lib/models/bus_details.dart`):
- `pricePerSeat` (`:33`) — the bus base, seeded from the tour.
- `singleSofaPrice` / `doubleSofaPrice` / `seaterPrice` (`:38-40`), each nullable, each falling back to `pricePerSeat`.
- **Crucial semantic:** `doubleSofaPrice` is the **WHOLE-sofa** price; one berth is half (`bus_details.dart:257`). Single Sofa and Seater are per-person.
- UI: `add_bus_screen.dart` Step 3 (`_Step3Price`, `:1193-1399`) exposes base price + the three overrides, with a live "if fully booked" preview (`:1361-1395`). Editable in both add and edit mode (edit skips capacity, `:64-65`).
- DB: columns added in migration `004_money_collection.sql:40-42`; resolved as `coalesce(<type>_price, price_per_seat)`.

### Layer 3 — Rear-zone tier (`buses.rear_rows`, `buses.rear_price`) — BUILT IN MODEL + DB, INVISIBLE IN UI
This is the existing answer to "per-row pricing", and it is the **single most important finding**:
- `Bus.rearRows` / `Bus.rearPrice` (`bus_details.dart:47-48`). The last `rearRows` rows of the layout form a "rear zone" charged at `rearPrice` **per person**, overriding the per-type overrides for those rows (`berthPriceFor`, `:248-261`).
- `BusLayout.isRearRow(row, rearRows)` helper exists (`seat_layout.dart:299-300`).
- DB columns exist: `database.sql:181-182` and migration `005_bus_rear_zone_pricing.sql`.
- **But `add_bus_screen.dart` has ZERO UI for `rearRows`/`rearPrice`** (grep confirms: no `rear`/`RearZone` references in any screen). `copyWith` in the edit path (`:267-277`) does not pass `rearRows`/`rearPrice`, so even round-tripping an existing bus through the edit screen is fine only because `copyWith` defaults to the existing value — but the agent can never **set** them. So every bus in the field has `rearRows = 0` and the tier is dead code from the agent's POV.

This rear-zone tier was clearly built to make the **back rows cheaper** (rear seats are less desirable on a sleeper). The agent's new ask is the mirror image: make the **front rows more expensive** (front seats are more desirable, and elderly/priority passengers want them).

### Fare calculation & where it flows
- `Bus.berthPriceFor(SeatType, int row)` (`:248-261`) — per-berth, row-aware (NOTE: the task referred to this as `berthPriceForType`; the actual signature takes a row too).
- `Bus.tripFactor(TripType)` (`:264`) — round trip = 1.0, single leg = 0.5.
- `Bus.amountDueFor(passenger)` (`:270-286`) — sum over the passenger's berths on this bus × trip factor. **Not currently called anywhere** in `lib/` (grep: zero call sites).
- `Bus.amountDueForSeat(passenger, seatId)` (`:291-301`) — per-berth due. **This is the one actually used**, in `collection_screen.dart:60` and `handler_bus_chart_screen.dart:74,144,433`.
- The collection model (`lib/models/collection.dart`) stores `amountDue` as a **snapshot per (passenger, bus, seat)** — seeded from `amountDueForSeat` (`collection_screen.dart:258-261`) but freely editable in the collect sheet. So a later price change never rewrites past collections (correct, matches money spec edge case at `2026-06-01-...md:256`).
- Summaries (`money_summary.dart`, `money_controller.dart:229-240`) never touch price — they only sum `amountReceived/Refunded`. Pricing's only job is to seed `amountDue`.

### Summary of the gap
The pricing **data model is richer than the agent can see**: row-aware pricing exists but has no controls. The collection layer correctly consumes it via `amountDueForSeat(passenger, seatId)`, which is already row-aware. So "per-row price allotment" is **80% built** — it just needs (a) UI, and (b) a decision on whether the premium attaches to the *front* or the *rear*, and whether it's a flat zone or true per-row.

---

## 2. Proposed direction

**Generalize the rear-zone tier into a single "row-band pricing" concept, and surface it as a simple, opt-in control on the bus price step — consistent with the auto-assign + approved-priority redesign.**

1. **Reframe rear-zone as "row bands."** Keep the per-person, row-indexed pricing that already exists, but let the agent define price bands by row position: e.g. *Front N rows = premium*, *Back M rows = discount*, everything else = base. Internally this is still "a price per row," computed by `berthPriceFor(type, row)`; we are only adding the inputs and possibly a second band. Reuse the existing `berthPriceFor` resolution order (band price wins over per-type override wins over base).
2. **Front premium is a PRICING lever, NOT the priority lever.** The seat redesign already has a clean, agent-controlled path for "elderly / needs front": customer note → request → agent **approves** → solver seats approved-priority in front/sofa first. Front-premium pricing is a *different* mechanism aimed at a *different* goal: capturing willingness-to-pay and gently discouraging everyone from demanding the front. Recommendation: they **complement**, they don't replace each other (see Open Question 1 — this is the agent's call). Concretely: approved-priority passengers are *seated* in front regardless of price; a front premium just means whoever lands in a premium row *owes more*, and the collection screen shows the right `amountDue` because it's already row-aware.
3. **Per-bus pricing stays the source of truth; tour price stays a convenience default.** At 20-25 interchangeable buses with a single pickup, the agent almost certainly wants ONE price sheet for the whole tour, not 25 hand-tuned ones. Lean into this: make the tour-level screen able to set the full price sheet (base + per-type + bands) once, push it to all buses, and treat per-bus edits as rare overrides. This matches the "buses are interchangeable" rule from the seat redesign.
4. **Keep the lean-data ethos.** Pricing is agent-only config; nothing here touches the customer booking form (which stays contact + seat-type counts + note). The premium is realized at assignment/collection time, not asked of the customer.
5. **One screen = one job.** A dedicated, optional "Price bands" sub-section on the bus price step (collapsed by default; most buses use flat pricing). The seat-detail screen stays read-only; a premium row simply renders with a subtle band tint, and the collect sheet shows the resolved due.
6. **Preserve snapshots.** `amountDue` remains a per-collection snapshot, so introducing bands never rewrites money already collected.

---

## 3. Concrete data-model / DB changes

The minimum-viable path reuses what exists; the richer path generalizes it. Both are listed so the agent can pick scope (Open Question 4).

### Minimum (front premium via the existing rear-zone machinery, mirrored)
- **No new columns.** Add `front_rows int default 0` + `front_price numeric` as the symmetric twin of `rear_rows`/`rear_price`, OR repurpose the existing pair if the agent only ever wants ONE band. Given the existing `rear_*` columns, cleanest is to **add `front_rows` / `front_price`** (migration `006_bus_front_zone_pricing.sql`) so front-premium and rear-discount can coexist.
- Extend `berthPriceFor(type, row)` (`bus_details.dart:248`) with a front-band branch that takes precedence (front band → rear band → per-type → base). Define precedence explicitly when a bus is tiny and front+rear overlap (Open Question 5).
- Add `Bus.frontRows` / `Bus.frontPrice` fields + serialization + **fix `copyWith` to actually pass `rearRows`/`rearPrice`/`frontRows`/`frontPrice`** (today's `copyWith` already threads `rear*`, but the edit-save call at `add_bus_screen.dart:267-277` doesn't set them; the new UI must).
- Update the embedding RPCs that inline bus pricing for the handler manifest: `004_handler_collections.sql:53-56` and `database.sql:613-616` must add `front_rows/front_price` (and `rear_rows/rear_price`, which are **already missing** from those JSON payloads — a latent bug: the handler manifest never carries rear pricing, so handler-side `amountDueForSeat` silently ignores the rear zone).

### Richer (generalized row bands)
- Replace the four scalar columns with a `price_bands jsonb` on `buses`: e.g. `[{ "from_row": 0, "to_row": 1, "price": 1800 }, ...]`. More flexible (any number of bands, true per-row), but heavier and a migration off the existing `rear_*` columns. Only worth it if the agent wants more than front+rear (Open Question 4).

### Latent fixes to fold in regardless
- **Handler manifest pricing gap:** add `rear_rows`/`rear_price` (and any new band columns) to the manifest JSON in `004_handler_collections.sql` and `database.sql` RPC, or the handler bus chart will undercharge rear/front seats.
- **Duplicate migration files:** `004_handler_collections.sql` and `004_money_collection.sql` share the `004` prefix — renumber before adding `006` to keep ordering deterministic.

---

## 4. Hidden rules & open questions (agent must decide)

These are the calls only the agent can make. Each drives schema/UX.

(see structured output)

---

## 5. Dependencies on the rest of the redesign

- **Seat-assignment redesign:** the solver seats *approved-priority* passengers in front/sofa first. If front rows also carry a premium, the agent is effectively charging the people they *chose* to put up front. The brief assumes premium pricing and priority-approval are orthogonal (one is money, one is seating), but the agent must confirm whether an approved-priority passenger should be *exempt* from the front premium (compassion case) or pay it like anyone else (Open Question 1).
- **Reserved/blocked & handler seat:** the seat redesign adds a per-seat reserved/blocked flag and gives the handler a free front/door seat. A reserved/handler seat in a premium row should presumably bill ₹0 (handler) or its band price (held-for-VIP) — pricing must respect the reserved flag once it exists.
- **Groups (whole group on one bus):** if a group spans premium and base rows, each member's due differs by their actual row. The collection screen already itemizes per seat, so this works — but the agent may want a group to be quoted a single blended price (Open Question 6).
- **Money/collection screens:** all consume `amountDueForSeat`, which is already row-aware, so bands flow through with **no collection-screen changes** beyond optionally tinting premium rows. The tour/bus money summaries are price-agnostic and need no change.
- **Customer-facing flow:** unaffected — pricing is agent config; the customer still only picks seat-type counts.

---

## 6. Risks

- **Invisible feature already shipped to schema:** `rear_rows`/`rear_price` exist in prod DB but no UI — agents may have rows of dead columns, and the handler manifest RPC silently ignores them (undercharge risk). Surfacing pricing must also close that gap.
- **Snapshot vs. live price confusion:** because `amountDue` is snapshotted per collection, changing a band after some cash is collected leaves a mixed picture (some seats at old price). Need a clear "re-price unsettled seats" affordance or the agent will distrust the totals.
- **Front+rear band overlap on small buses** (e.g. a 20-seat coach where front 2 + rear 2 nearly meet) needs a defined precedence, or fares double-count.
- **Tour-vs-bus price drift:** if pushing a tour price sheet to all buses isn't atomic/clear, the agent ends up with 25 buses subtly out of sync — the exact pain the single-pickup/interchangeable model is meant to avoid.
- **Per-berth vs whole-sofa premium math:** a front-row whole double sofa under a flat per-person band = 2 × band, which may surprise the agent who thinks "front double = ₹X". The whole-sofa semantic (`doubleSofaPrice` is whole; band is per-person) is a known foot-gun and must be shown explicitly in the preview.
- **Scope creep to per-row UI:** true per-row pricing (vs. front/rear bands) is a much heavier UI on a phone; the auto-assign DNA argues for the simplest control that works (2-3 bands), not a per-row editor.
