# Phase A→B→C Hardening Design

**Date:** 2026-08-08  
**Source:** `docs/superpowers/audits/2026-08-08-lifecycle-full-audit.md`  
**Order:** Feature box A (Request) → B (Sofa) → C (Lock/notify/reallocate)

## Product decision (locked)

**Post-lock buses = Option A:** after lock, admin may still **move/reassign seats**; **add/edit/delete buses and layout changes are frozen**. Wired via `TourStatus.allowsLayoutEdit` in Phase C.

## Phase A — Request pipeline

1. Rename primary CTA **Confirm → Accept** (New + Waitlist + bulk). Confirmed tab keeps **Assign seats** as primary.
2. On **New** cards, elevate **Assign seats** from icon-only to a second labeled tonal button beside Accept.
3. On **Confirmed**, sort **partially assigned** riders first; keep Partial chip.
4. Translations en/gu/hi for Accept + snackbar copy.

## Phase B — Sofa allocation

1. Engine tests for mixed double permutations + same-leg stranger GO.
2. Exception card CTAs: Approve share / Hold / Edit.
3. Atomic `swap_passenger_seats` RPC + safer `fillTour` (fail-stop or batch).

## Phase C — Lock · notify · reallocate

1. Enforce `allowsLayoutEdit` on manage/add bus (post-lock frozen).
2. Dashboard/attention for unre-notified seat changes after lock.
3. Lock copy: bookings closed; seats still editable.

## Status (completed 2026-08-08)

| Phase | Status | Shipped |
|-------|--------|---------|
| **A Request** | Done | Confirm→Accept; Assign elevated on New; partials sort first on ACCEPT tab; en/gu/hi |
| **B Sofa** | Done | Mixed-double engine tests; Approve share / Hold / Edit on stranger-share exceptions; helper `findStrangerShareSeat` |
| **C Lock** | Done | `allowsLayoutEdit` wired; re-notify attention (dashboard + trip hero + tour detail); lock copy corrected (seats still editable) |
| Atomic swap RPC | Done | Client uses `swap_passenger_seats` with two-write fallback (`RpcUnavailableException`) |
| UI Wave 1 (partial) | Done | Dashboard Finance quick action; warmer Inbox unread card; lock/notify/renotify copy; QA visual polish |
