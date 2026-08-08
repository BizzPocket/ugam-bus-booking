# Booking Lifecycle: Chart Harden + Seat Change Design

**Date:** 2026-08-08  
**Approach:** Incremental harden (reuse seating + collections; bolt holds + change requests)  
**Order:** Wave **A** (admin move + money) → Wave **C** (chart hold + mode switch) → Wave **B** (customer seat-change request)

## Problem

Two customer booking paths already exist (`tours.booking_mode`: `request` | `chart`), but the product rules around them are incomplete:

1. Chart claims seats **immediately**; advance UPI is optional and historically invisible (claim ≠ proof).
2. Booking mode is **locked forever** after the first passenger, so organisers cannot fix or trial the other path.
3. Admin can relocate Bus1 → Bus2 and money **rehomes + reprices**, but the collect/return story is easy to miss.
4. Customers **cannot** request a seat/band change in-app after purchase.

## Product decisions (locked)

| Topic | Decision |
|-------|----------|
| Scope | Sequenced milestone A → C → B |
| Mode switch | Both directions allowed with hard confirm; **existing bookings keep seats/money**; **new** customers use the new mode |
| Who moves seats | Customer **requests**; admin **or** tour handler **approves** |
| Money on change | **Upgrade:** pay/confirm delta **first**, then move. **Downgrade:** move **first**, then return-due (manual refund record) |
| Chart book | Soft hold → seat **final** only after **confirmed advance** or admin **Pay later** |
| Hold TTL | **5 minutes** |
| Final seat truth | `passengers.assigned_seats` only. Holds are temporary overlays, never a second roster |
| Auto bank refund | Out of scope — humans record return on collection / money board |
| Gateway payments | Out of scope — UPI claim + Confirm/Reject remains |

## Architecture invariant

```
assigned_seats  = FINAL occupancy (single source of truth)
seat_holds      = TEMPORARY overlay for chart checkout / (optional) change review
collections     = cash + amount_due keyed (passenger_id, bus_id, seat_id)
payment_claims  = unverified UPI assertions → Confirm posts money / Reject drops
```

Public chart availability = final occupied ∪ active (non-expired) holds.

---

## Wave A — Admin seat move + money truth

### Goal

When an organiser relocates a paid rider (same bus different band, or Bus1 → Bus2), the app always:

- Carries collected cash with the rider (no stranded origin cash / no full re-bill).
- Reprices `amount_due` to the destination seat’s live band.
- Surfaces **collect more** or **return due** when delta ≠ 0.

### Rules

1. Cash columns (`amount_received` / `amount_refunded`) are never rewritten by a seat move.
2. After move: `due = live fare of current seats`; `delta = due − paid`.
3. Same-bus same-band moves: no interrupt dialog.
4. Cross-bus or reprice: show notice with actions **Collect now** / **Mark return later** / **Dismiss**, plus deep-link to that passenger on the money board.
5. Reconcile stays best-effort after admin move (seat already persisted); toast + refetch on money write failure.
6. Prefer ledger write-through where migration 062 already applies; delta UX may still read collections until Finance wave fully cuts over.

### Touch points

- `lib/services/collection_reconciler.dart` — keep as planning core; extend tests for explicit ₹1600→₹2000 / →₹1400 cases if gaps.
- `lib/controllers/money_controller.dart` — `reconcileAfterSeatMove`
- `lib/controllers/tour_controller.dart` — `_reconcileMoneyAfterMove` after `moveSeat` / group moves
- `lib/widgets/seat_move_money_notice.dart` — actions + deep-link
- Copy: `seat_move_money.*`, short helper on Booking settings / seat chart

### Out of Wave A

Customer-initiated change; soft holds; unlocking mode switch.

---

## Wave C — Chart booking harden + mode switch

### Goal

Replace claim-first chart checkout with hold → pay/confirm → finalize. Unlock per-tour mode switching with an explicit confirm.

### Chart checkout (new)

1. Customer picks seats → enters details → **create soft hold** (5 minutes). Does **not** write final `assigned_seats`.
2. Held seats appear unavailable on the public chart.
3. Seat becomes final only when:
   - Admin/handler **Confirms** UPI advance claim, **or**
   - Admin marks **Pay later** (explicit override).
4. On Confirm / Pay later: create/finalize passenger + `assigned_seats` (same atomic spirit as today’s `chart_claim_seats`, but gated).
5. Hold expiry or abandon → release hold; seats free; device can keep form for retry.

### Mode switch

- Remove “locked because passengers exist” hard block.
- Hard confirm: *Existing bookings keep their seats and money rules. New customers will use [Request / Chart].*
- Chart still requires a bus with layout.
- Request mode: new customers get request form; already-charted passengers stay seated.

### Data

- New `seat_holds` table (or equivalent) with TTL, tour/bus/seat, phone, expires_at.
- Availability RPCs include active holds.
- This **intentionally revises** migration 048’s “no hold table” stance; holds must never diverge into a second final chart.

### Out of Wave C

Customer seat-change request UI (Wave B).

---

## Wave B — Customer seat-change request

### Goal

Customer with a **final** booking can request a different seat/bus/band; admin/handler approves with upgrade/downgrade money rules.

### Customer flow

1. My Tickets / Find my seat → **Request seat change**
2. Pick target bus + free seat; UI shows **+₹X** or **−₹X** vs current due
3. Submit → `pending` seat-change request (do **not** hold target until admin opens Approve, to avoid blocking inventory on ignored requests)
4. Notify on approve/reject (WhatsApp when available)

### Approve rules

| Case | Money | Seat |
|------|-------|------|
| Upgrade (due ↑) | Collect/confirm **delta first** | Then `moveSeat` + reconcile |
| Downgrade (due ↓) | Move first | Then return-due notice; human records refund |
| Same price | — | Move immediately |

Reject: customer stays on old seat; optional reason.

### Reuse

Wave A reconciler + notice; Wave C payment-claim / pay-later patterns for upgrade delta.

### Out of scope

Instant self-move without approval; auto UPI refund to bank; changing another person’s booking without phone verification.

---

## Edge cases

| Case | Behavior |
|------|----------|
| Two holds same seat | First wins; second fails at create |
| Hold expires mid-UPI | Seat frees; re-pick; no final passenger |
| Confirm claim after expiry | No-op if seat taken; if free, allow finalize |
| Mode switch mid-tour | New customers only |
| Upgrade pay abandoned | No move; old seat kept |
| Group / shared double | Existing `moveSeat` cohesion rules |
| Tour locked/completed | No new chart holds; seat-change requests closed |
| Money reconcile fails (admin path) | Seat stays moved; toast; fix on money board |
| Money fails (Wave B upgrade) | Seat must **not** move |

## Testing (minimum)

- Reconciler: 1600→2000 collect 400; →1400 return 200; same-band no delta interrupt
- Hold TTL release; availability excludes expired
- Mode switch confirm does not rewrite existing passengers
- Seat-change: upgrade blocked without delta settlement; downgrade moves then return-due

## Explicit non-goals (this milestone)

- Payment gateway / Razorpay
- Customer instant self-relocate
- Auto bank refunds
- Rewriting request-mode demand tally / auto-assign engine
- Full Finance UI cutover off collections (tracked in ledger wave2)

## Implementation plans

- Wave A: `docs/superpowers/plans/2026-08-08-booking-lifecycle-wave-a-admin-move-money.md` — **implemented 2026-08-08** (reconciler same-bus deltas, collection highlight, notice actions, booking-settings help)
- Wave C: `docs/superpowers/plans/2026-08-08-booking-lifecycle-wave-c-chart-hold-mode.md` — **in progress 2026-08-08** (mode unlock + `064` seat_holds + Flutter hold/pay-later path). **Deploy migration `064_seat_holds_chart_finalize.sql` on Supabase before testing holds.**
- Wave B: separate plan after Wave C ships
