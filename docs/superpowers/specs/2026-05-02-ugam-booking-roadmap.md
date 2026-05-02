# Ugam Booking — Multi-Phase Roadmap

**Date:** 2026-05-02
**Status:** Approved by user (Phase 1 ready for implementation plan; later phases at high-level only).

## Context

The app (current Flutter package: `occubusbooking`, current display name: `TourPro`) is a tour-agent management tool for an Ugam Foj community member who organizes group bus trips. The current admin-side flow follows the 8-phase tour lifecycle documented in user memory. The codebase compiles cleanly (`flutter analyze` returns 0 issues).

The user has asked for:
1. App rename to **Ugam Booking** with religiously-appropriate branding (sun + bus logo, gold/red palette, `ઉગમ` Gujarati script).
2. Verification that the existing admin flow actually works end-to-end.
3. Real admin authentication (replacing the current hardcoded-phone bypass).
4. A customer-facing mode where anonymous users browse tours and submit booking requests via a WhatsApp deep-link handoff to the admin.

## Phases

| # | Title | Goal | Status |
|---|---|---|---|
| 1 | Rebrand to Ugam Booking | App identity refresh, no behavior change | **Ready for implementation plan** |
| 2 | Fix & verify existing admin flow | Walk all 8 lifecycle phases on a real device, fix bugs | Pending |
| 3 | Real admin login (DB-backed) | Phone + password auth backed by an Appwrite `admins` collection | Pending |
| 4 | Customer mode (browse + WhatsApp handoff) | Anonymous tour browsing, one-tap WhatsApp booking with standardized message | Pending |
| 5 | UI redesign polish | Screen-by-screen UX cleanup using new branding | Pending (optional, last) |

Each phase will get its own detailed spec → implementation plan → execution cycle. This document is the umbrella.

## Why this order

- Rebrand first: visible win, low risk, unblocks everything that follows visually.
- Fix existing flow before adding features: don't build on a broken base.
- Real admin login before customer mode: required so that opening the app to anonymous customers does not also expose admin actions to anyone who types the right phone number.
- Customer mode after auth + working backend: the largest new surface, depends on the rest.
- Polish last: avoid polishing screens that might be rewritten.

## Architectural decisions locked

### WhatsApp inbound problem
We are **not** building WhatsApp inbound capture (no Business API, no notification listener, no Web automation). Instead, the customer composes the booking inside Ugam Booking (Phase 4) and the app uses a `wa.me` deep link to open the customer's own WhatsApp with a pre-filled, standardized message addressed to the admin. The customer hits send. The admin receives a uniformly-formatted message that the existing parser (extended) can handle. Zero infrastructure, zero ToS risk, works on iOS and Android.

### Customer authentication
Customers do **not** authenticate. They browse public tours read-only and hand off booking via WhatsApp. The admin remains the only writer to the Appwrite database. Keeps the security model simple.

### Admin authentication (Phase 3)
Phone + password, with both credentials stored in an Appwrite `admins` collection. SHA-256 + per-admin salt. No SMS/OTP — avoids cost and Appwrite-SMS-provider setup. Adding/rotating admins is a DB operation, not a code change.

### Branding direction (Phase 1)
**Subtle community identity** (the user picked option A from the branding direction question): sun + bus logo and Gujarati script appear on splash, login, and launcher icon; inside-the-app working screens stay clean and functional with gold/saffron used as an accent only, not a wash.

## Out of scope across all phases

- WhatsApp Business API and any inbound message capture mechanism.
- Real OTP SMS auth.
- Customer in-app accounts, customer login, or customer-side database writes.
- Renaming the Flutter package `occubusbooking` (the package name is invisible to users; an import-wide rename creates churn for no user benefit).

## Cross-references

- Phase 1 detailed spec: `2026-05-02-ugam-booking-rebrand-design.md`
- User memory: `~/.claude/projects/-Users-zeelshiyani-WorkSpace-occubusbooking/memory/project_real_workflow.md` (8-phase tour lifecycle)
- User memory: `~/.claude/projects/-Users-zeelshiyani-WorkSpace-occubusbooking/memory/user_role.md` (tour booking agent role)
