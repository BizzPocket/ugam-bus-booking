# Ugam Booking — Full Application Audit Report

**Date:** 8 August 2026  
**Scope:** Operator lifecycle, sofa allocation rules, finance, WhatsApp, handler ops, screen/IA UX  
**Sources:** Live `lib/` + `supabase/migrations` 053–062, operator-described product flow, prior concerns (`.planning/codebase/CONCERNS.md`), redesign roadmap  
**Companion board:** Cursor canvas `app-audit.canvas.tsx`  
**Implementation:** Phase A→B→C started — see `docs/superpowers/specs/2026-08-08-phase-abc-hardening-design.md`

### Implementation progress (8 Aug)

| Item | Status |
|------|--------|
| L1 Confirm→Accept + elevate Assign | **Done** |
| L2 Mixed double permutation tests | **Done** |
| L3 Exception Approve share / Hold / Edit | **Done** |
| L4 Post-lock buses frozen (`allowsLayoutEdit`) | **Done** (policy A) |
| F3 fillTour atomic path | Already present (`applySeatAssignments`) |
| F2 Atomic swap RPC | **Done** (RPC + client fallback) |
| L5 Re-notify attention | **Done** (dashboard + hero + tour detail) |
| Lock copy (seats still editable) | **Done** |
| Dashboard Finance + Inbox UI polish | **Done** (Wave 1 partial) |
| Finance ledger UI cutover / UPI claims / IA dock | **Mostly done** — ledger reads + UPI Confirm/Reject + Wave 2 money polish; IA dock still open |

---

## 1. Executive summary

The app’s core product loop is real and mostly implemented:

> Customer requests seats → Admin accepts (Confirmed) → Admin allocates with leg-aware sofa sharing → Notify / Lock → Post-lock seat edits + re-notify → Handler collects money / expenses / handover.

**What is strong**
- Leg-aware seating engine (GO / RETURN slots, stranger-share review, group 2+2 on doubles)
- Tour money board, collection Mark-paid, soft-delete-aware finance aggregates
- Post-lock seat edit + `seatsChangedSinceNotified` re-notify path
- Handler chart money path (collect, expense, income, handover)

**What is broken or incomplete**
- Money ledger exists in SQL but Flutter still reads legacy tables (dual books)
- Seat swap and auto-fill are non-atomic multi-writes
- Confirm ≠ Assign UX mismatch against operator mental model
- Mixed double-sofa permutations under-tested
- Post-lock bus/layout policy unclear (`allowsLayoutEdit` never enforced)
- Inbox / Finance discoverability weak; several UX placement gaps

**Recommended order:** Integrity (swap/fill + orphan verify) → Sofa permutation truth → Lock/bus policy → Finance ledger cutover → Handler/money polish → Messaging + IA.

---

## 2. Product lifecycle (as specified vs as built)

| # | Stage | Spec (operator) | Current code | Verdict |
|---|--------|-----------------|--------------|---------|
| 1 | **Request** | Customer/admin requests seats (type + leg) | `submit_booking_request` RPC; admin capture form | Works — keep RPC-only (migration 058) |
| 2 | **Confirm** | Admin accepts → Confirmed tab | `setConfirmed` + pre-lock WhatsApp greeting | UX gap — Confirm does not seat |
| 3 | **Allocate** | Assign with sofa sharing rules | Grid + `SeatingEngine` + exceptions | Core strong; gaps below |
| 4 | **Notify** | Send seat/WhatsApp after assign/lock | Notify screen; pre-lock greeting vs post-lock allotment | Works |
| 5 | **Lock** | Close bookings; reveal seats | `TourStatus.locked`; `acceptsBookings` false | Works |
| 6 | **Post-lock edit** | Still edit seats **and** reallocate buses | Seats editable; buses also ungated | Ambiguous — need product decision |
| 7 | **Handler** | Collect, expense, handover (more than passenger) | Handler chart money OK; seats read-only | Works with limits |

---

## 3. Sofa sharing rules — coverage matrix

Double sofa = **2 berths × 2 legs**. Sharing is about **overlapping time on the bus**, not only physical `seatId`.

| Case | Product rule | Engine | Tests | Gap |
|------|--------------|--------|-------|-----|
| Single · full round-trip | Exclusive — one passenger, both legs | Covered | Yes | — |
| Single · GO + RET (two people) | Share same seat across disjoint legs | Covered | Yes | — |
| Double · full RT whole | One passenger both berths both legs — no share | Covered | Yes | — |
| Double · 2 GO + 2 RET (same group) | Up to 4 one-way when same-leg pair related | Covered | Yes | — |
| Double · GO + RET strangers (disjoint legs) | OK — never co-seat in time | Covered | Yes | — |
| Double · same-leg strangers | Block auto; agent must confirm | Blocks + `sharedDoubleNeedsReview` | Partial | No one-tap Approve on exceptions |
| Double · mixed (1 RT berth + GO/RET on other) | Operator-critical permutation | Likely OK | **MISSING** | Add fixtures |
| Cross-fill 2 singles → 1 double line | Engine + consolidate | Covered | Yes | — |
| Manual stranger fill on half-double | Confirm sheet before share | UI path | Light | — |

---

## 4. Feature inventory (backlog boxes)

### A. Request pipeline
- [ ] Customer `submit_booking_request` only (no orphan two-write path)
- [ ] Admin New / Waitlist / Confirmed / Assigned tabs
- [ ] Accept (confirm) + WhatsApp greeting — labels clear vs Assign
- [ ] Assign seats entry from card + bulk confirm
- [ ] Cancel-request approve path
- [ ] Post-lock admin override add request
- [ ] Partial-assignment visibility / “needs remaining berths” filter

### B. Sofa allocation engine
- [x] Single exclusive RT
- [x] Single GO\|RET leg share
- [x] Double whole RT exclusive
- [x] Double 2+2 one-way (group)
- [x] Stranger same-leg → review (engine)
- [ ] Mixed RT-berth + one-way remainder (tests + UI proof)
- [x] Cross-fill singles → double line
- [x] Groups stay on one bus
- [x] Priority front / lower berth
- [ ] Atomic swap RPC
- [ ] Atomic fill / batch assign RPC
- [ ] Exception card: Approve share / Hold / Edit

### C. Lock · notify · reallocate
- [x] Lock requires all seated + handler
- [x] Post-lock seat edit allowed
- [ ] Bus reallocate policy decided + gated (`allowsLayoutEdit`)
- [x] Re-notify changed seats (manual sticky)
- [ ] Attention when locked tour has unre-notified changes
- [x] Customer seat reveal only when locked
- [ ] PDF chart + broadcast body preview in locale
- [ ] Bundle Noto font (no silent glyph boxes)

### D. Handler bus ops
- [x] Phone-gated handler chart
- [x] Collect per seat
- [x] Expenses / extra income
- [x] Cash handover to admin
- [x] Attendance / GO-leg helpers (where RPCs exist)
- [x] No seat edit (by design today)
- [ ] Seat-move vs collection education (cash stays seat-scoped)
- [ ] Optional handler → admin alert for seat problems

### E. Finance sector
- [x] Per-bus / tour money board
- [x] Collection one-tap Mark paid
- [ ] UPI claim Confirm/Reject on board (claim ≠ proof)
- [x] Cross-tour Finance P&L (legacy tables)
- [ ] Ledger as single read source of truth
- [x] Soft-delete aware totals
- [ ] Promote Finance entry (not only Settings)

### F. WhatsApp messaging
- [x] Inbox + conversation reply + media path
- [ ] Unread badge on dock / stronger entry
- [x] Confirm / seat / lock templates
- [x] Re-notify after move (manual)
- [ ] `AppContact.supportWhatsApp` configured
- [ ] Notify Lock→Send guided single flow

### G. IA / screens / CTAs
- [ ] Decide 3 vs 5 dock tabs (tour-first IA)
- [ ] One accent primary CTA per screen
- [ ] Shared date/money formatters
- [ ] Customer Book pill + price visibility
- [ ] Localization parity on seat/handler screens

---

## 5. Findings register

### 5.1 Critical

| ID | Domain | Finding | Impact | Fix direction |
|----|--------|---------|--------|---------------|
| **F1** | Finance | Ledger (`finance_entries`) + write-through (062) exist; Flutter still aggregates `collections` / `expenses` / `incomes` / `bus_price` | Dual books; P&L can drift from ledger truth | Cut money board + Finance to ledger balance RPCs |
| **F2** | Seating | `swapSeats` / `swapSeatContents` are sequential multi-writes | Crash/network mid-swap → two riders on one berth | `swap_passenger_seats` SECURITY DEFINER RPC |
| **F3** | Seating | `fillTour` applies plan passenger-by-passenger | Partial apply → mixed seating plan | Transactional batch assign RPC or hard-stop + rollback |

### 5.2 High

| ID | Domain | Finding | Impact | Fix direction |
|----|--------|---------|--------|---------------|
| **L1** | Requests | Confirm vs Assign mental model mismatch | Agent thinks Confirmed = seated; seating secondary | Rename Confirm → Accept; promote Assign; optional Accept+open-grid |
| **L2** | Sofa | Mixed double permutations untested | Silent regressions on operator-critical mixes | Permutation matrix tests in `seating_engine_test` |
| **L3** | Sofa | `sharedDoubleNeedsReview` has no Approve action | Agent must rediscover pair in grid | Exception CTAs: Approve / Hold / Edit |
| **L4** | Lifecycle | `allowsLayoutEdit` declared, never used | Post-lock bus add/edit/delete ungated vs status intent | Decide policy; wire or delete flag |
| **F4** | Customer | Orphan booking-request failure mode | Notify fired, no roster row (migration 058 repairs) | Verify 058 on live; keep RPC-only |
| **F5** | Finance | UPI advance is claim-not-proof | Double-collect or false paid | Pending claims on money board Confirm/Reject |
| **F6** | Finance | Finance buried in Settings | Operators miss cross-tour P&L | Dashboard / Tours Finance entry |
| **F7** | WhatsApp | Inbox is side channel | Missed customer replies | Unread badge / stronger shell entry |
| **F8** | Seating | God screens (~4k assignment, ~3.7k handler) | Stale money, hard correctness | Split widgets; Obx on handler money |
| **F9** | IA | 5-tab dock fights tour-first IA | Same tools via 3 stacks | 3-tab dock or demote Charts |

### 5.3 Medium

| ID | Domain | Finding | Impact | Fix direction |
|----|--------|---------|--------|---------------|
| **L5** | Notify | Post-lock seat change needs manual re-notify | Forgotten WhatsApps after reallocate | Attention item + leave-grid prompt |
| **L6** | Handler | Cannot fix seats; cash seat-scoped after move | Ground friction; double-collect risk | Docs + alert path |
| **L7** | Requests | Assigned = fully assigned only | Partial doubles stay on Confirmed | Needs-seats filter |
| **L8** | Sofa | Same-leg stranger GO pair under-tested | Weak regression net | Explicit test + copy |
| **F11** | WhatsApp | Notify/Lock complexity; PDF font network fetch | Wrong-language body; missing glyphs | Preview + bundle Noto |
| **F12** | Customer | `supportWhatsApp` empty | Contact falls back to email | Set public WA number |
| **F13** | Integrity | `smartFetch` swallows errors; hard row limits | Silent stale/truncated data | Toast on fail; warn at cap |
| **F14** | Handler | Authz thin historically; chart holds PII | Over-privileged if session wrong | Bus-scoped RLS + clear login |

### 5.4 Low

| ID | Domain | Finding | Impact | Fix direction |
|----|--------|---------|--------|---------------|
| **L9** | Lifecycle | “Lock” wording vs editable reality | Fear unlocking to edit | Copy: bookings closed; seats still editable |
| **F15** | UX | Localization + accent-rationing debt | HI/GU gaps; gold overuse | Extract strings; tonal row actions |

---

## 6. Buttons & placement improvements

| Screen / area | Current | Improve to |
|---------------|---------|------------|
| **Requests** card primary | “Confirm” (accept only) | “Accept request”; elevate “Assign seats” |
| **Requests** bulk bar | Confirm + Send WA | Clear Accept vs Seat labels |
| **Seating exceptions** | Tap → grid only | Approve share / Hold waitlist / Edit |
| **Seat assignment** | Dual passenger switchers, heavy CTAs | One dock; one accent focal |
| **Notify** | Lock then Send; heavy screen | One guided Lock & notify; preview body |
| **Dashboard Money** | Opens nearest tour money board | Also expose **Finance P&L** |
| **Settings Finance card** | Only cross-tour entry | Keep + promote elsewhere |
| **Inbox** | Home nudge / header icon | Unread badge on Home or Requests |
| **Handler chart** | Call+Collect combined friction | Split Call vs Collect |
| **Bus money** | Mid-page Collect can steal accent | Tonal Collect; sticky primary sparingly |
| **Collection** | Mark paid exists | Keep prominent per shortfall row |
| **Tour Detail tools** | Requests / Seats / Money + More | Align naming with dock; avoid 3-way stack confusion |
| **Main shell** | 5 tabs | Consider Home · Tours · Settings (+ Requests badge) |

---

## 7. Already fixed (do not re-open)

- Dashboard “See all” → Requests tab (was Charts)
- Bus money delete confirmation dialogs
- Finance soft-delete filter + bus rent in P&L
- Finance stale refresh after money writes
- Seating exceptions tap → grid (no dead-end toast)
- Collection one-tap Mark paid
- Inbox send shows Meta error detail
- Soft-delete / archive migrations (vs silent hard prune)
- Orphan booking repair migration authored (058) — **verify applied on live**

---

## 8. Open product decision

**After lock, may admin still add / edit / delete buses and change layouts?**

| Option | Meaning |
|--------|---------|
| **A — Seats only** | Post-lock: move/reassign people; buses frozen. Wire `allowsLayoutEdit`. |
| **B — Seats + buses** | Current behaviour; delete or rewrite `allowsLayoutEdit` docs; add safety confirms on bus delete with seated pax. |

Seat editing after lock is already intended and implemented. Only bus/layout policy needs a call.

---

## 9. Workstreams (execution plan)

### Stream 1 — Sofa & allocation truth
1. Permutation test matrix (esp. mixed double + same-leg stranger GO)
2. Exception Approve / Hold / Edit CTAs
3. Atomic swap + fill RPCs
4. Confirm vs Assign UX rename

### Stream 2 — Lifecycle lock policy
1. Decide post-lock bus edit (A or B above)
2. Wire or delete `allowsLayoutEdit`
3. Attention for unre-notified seat changes
4. Lock copy clarifying seats still editable

### Stream 3 — Handler + money
1. Handler Call/Collect split + reactive money
2. Seat-move vs collection UX/docs
3. UPI pending claims Confirm/Reject
4. Ledger cutover for money board + Finance
5. Promote Finance entry point

### Stream 4 — Messaging + IA
1. Inbox unread badge
2. Notify preview + bundled PDF fonts
3. Set `AppContact.supportWhatsApp`
4. Dock 3 vs 5 decision + accent rationing pass

---

## 10. Suggested priority queue (first 10 fixes)

1. Verify migration **058** (and 053–062) applied on live  
2. **Atomic seat swap RPC** (F2)  
3. **Atomic / safe fillTour** (F3)  
4. **Confirm → Accept** + promote Assign (L1)  
5. **Mixed double permutation tests** (L2)  
6. **Exception Approve share** (L3)  
7. **Post-lock bus policy decision** (L4)  
8. **UPI pending claims on money board** (F5)  
9. **Finance entry promotion** (F6)  
10. **Inbox unread badge** (F7)

---

## 11. Screen map (quick reference)

### Operator (admin) shell
Home · Tours · Charts · Requests · Settings  

Tour workspace: Detail → Requests / Seats / Money / Buses / Groups / Lock·Notify  

### Customer shell
Tour list → Detail → Book · My requests · Find my seat · More  

### Handler
Handler bus chart (money + read-only seats) via phone/RPC — not full admin dock  

---

## 12. Appendix — key files

| Area | Paths |
|------|--------|
| Seating engine | `lib/services/seating_engine.dart`, `test/services/seating_engine_test.dart` |
| Assignment UI | `lib/screens/tour_seat_assignment_screen.dart` |
| Requests | `lib/screens/requests_screen.dart` |
| Tour status | `lib/models/tour_status.dart` |
| Notify | `lib/screens/notify_screen.dart`, `lib/services/whatsapp_outbound.dart` |
| Money | `lib/controllers/money_controller.dart`, `lib/controllers/finance_controller.dart`, money screens |
| Ledger SQL | `supabase/migrations/056_*.sql`, `058_finance_backfill.sql`, `062_ledger_write_through.sql` |
| Orphans | `supabase/migrations/058_orphan_booking_requests.sql` |
| Handler | `lib/screens/handler_bus_chart_screen.dart`, `lib/models/handler_bus_money.dart` |
| Prior concerns | `.planning/codebase/CONCERNS.md` |
| Redesign roadmap | `.planning/REDESIGN_ROADMAP.md` |

---

*End of report — 8 August 2026*
