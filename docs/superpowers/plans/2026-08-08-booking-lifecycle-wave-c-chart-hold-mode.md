# Booking Lifecycle Wave C — Chart Hold + Mode Switch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Soft-hold chart seats for 5 minutes; finalize only after confirmed UPI advance or admin Pay later; allow booking-mode switch both ways with hard confirm.

**Architecture:** New `seat_holds` overlay; `assigned_seats` remains final truth. Tours **without** advance keep instant `chart_claim_seats` (no hold). Tours **with** advance use hold → claim/pay-later → finalize.

**Tech Stack:** Flutter, Supabase SQL migrations, existing `payment_claims`.

**Spec:** `docs/superpowers/specs/2026-08-08-booking-lifecycle-chart-seat-change-design.md` Wave C.

## Global Constraints

- Hold TTL = 5 minutes.
- Holds never become a second roster; finalize writes `passengers.assigned_seats` once.
- Mode switch: both directions; existing bookings untouched; hard confirm required.
- en/gu/hi translations together.
- Migration number: `064_seat_holds_chart_finalize.sql`.

---

### Task 1: Unlock mode switch with hard confirm

**Files:** `lib/widgets/booking_settings_sheet.dart`, translations

- [ ] Remove `_modeLocked` passenger gate
- [ ] On save when mode changed and passengers exist: `UgamDialog` confirm copy
- [ ] Still block Chart if `chartNeedsBus`
- [ ] Translations: `booking_settings.mode_switch_confirm_*`

### Task 2: SQL seat_holds + RPCs

**Files:** `supabase/migrations/064_seat_holds_chart_finalize.sql`

- [ ] Table `seat_holds` (id, tour_id, bus_id, request_id, phone, name, leg, seats jsonb, gender, note, pickup_*, expires_at, status pending|finalized|expired|released, payment_claim_id nullable)
- [ ] `chart_hold_seats(...)` — advisory lock, conflict vs passengers + active holds, insert hold TTL 5m
- [ ] `chart_finalize_hold(p_hold_id, p_pay_later bool)` — owner/handler; creates passenger like claim; marks hold finalized
- [ ] Update `chart_seat_availability` to union active holds
- [ ] Expire helper in availability (expires_at < now() ignored)

### Task 3: Flutter hold path when tour collects advance

**Files:** seat booking service, confirm screen, availability utils

- [ ] `hold()` / `finalizeHold()` on service
- [ ] Confirm screen: if `collectsAdvance` → hold then UPI; else existing claim
- [ ] Availability merges holds from RPC

### Task 4: Admin Pay later + confirm finalizes

**Files:** tour money board, money controller

- [ ] List pending holds; Pay later → finalize
- [ ] `confirm_payment_claim` trigger finalize if claim linked to hold (or Flutter calls finalize after confirm)

### Task 5: Tests + verify gate

- [ ] Unit tests for hold payload / mode switch confirm presence
- [ ] Manual: mode switch; hold expire; confirm; pay later
