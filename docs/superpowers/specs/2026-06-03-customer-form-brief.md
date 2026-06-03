# Design Brief — Customer Booking Form + Agent Priority Approval

**Date:** 2026-06-03
**Area:** Customer booking-request form (`customer_booking_request_screen.dart`) + the agent-side approval of "priority" (elderly / needs-front) requests.
**Status:** Audit + direction — NOT final code.
**Depends on:** `docs/superpowers/specs/2026-06-03-smart-seat-assignment-design.md` (the approved seat-assignment redesign). This brief is the *capture half* of that brief's priority model.

---

## 1. Current state (honest)

### 1.1 What the customer form captures today
`lib/screens/customer_booking_request_screen.dart` is already lean and on-DNA. It captures exactly:

- **Name** (`_name`, required) — line 57, validated non-empty at line 101.
- **Phone** (`_phone`, required) — 10-digit + `isPlausibleIndianMobile` gate, lines 105-112. Normalised to `+91XXXXXXXXXX` (line 119).
- **Trip type** — round / outbound-only / return-only, radio cards (lines 406-411, `_TripTypeSelector`).
- **Seat-type COUNTS** — Double Sofa and Single Sofa steppers only (lines 419-433). No upper/lower, no seater on the customer side — the doc comment at lines 35-37 is explicit: "The agent decides upper/lower berth assignment later." Capped 0-8 per type (line 739).
- **Optional free-text note** — collapsed behind an "Add a note (optional)" pill (lines 435-473), `maxLength: 200`. Hint copy: "Special requests, group members, etc."

This is already consistent with the LEAN-DATA rule (no per-traveller rows, no gender). A multi-seat booking is **one** `booking_requests` row + **one** `passengers` row with seat-type counts; there is no per-seat structure on the customer side.

### 1.2 How a submit writes data (the dual-write)
`_submitCreate` (lines 188-274) performs a **three-way write**:

1. Insert into **`booking_requests`** (the anonymous audit row): `id`, `tour_id`, `customer_phone`, `customer_name`, `party_size`, `trip_type`, and a `raw_form` jsonb blob `{double_sofa, single_sofa, trip_type, note?}` (lines 198-211).
2. Upsert into **`passengers`** (the live, agent-facing row) on conflict `tour_id,phone` (lines 214-224), built from `_buildRequestLines()` (lines 349-354) → a `List<RequestLine>` of seat-type + qty.
3. Upsert a device-local **`CustomerRequestEntry`** into `CustomerRequestsStore` (SharedPreferences, lines 226-243) — the customer has no Supabase Auth session, so this local journal is the only "my requests" source of truth.

Anti-abuse is device-local only (no server verification): one pending request per `(tour, phone)` and a 15s cooldown (`_preflightCreate`, lines 166-180).

### 1.3 The WhatsApp handoff (must be preserved)
After the DB writes, `WhatsAppService().sendBookingRequest(...)` (lines 254-264) opens WhatsApp with a pre-filled message (`buildBookingRequestMessage`, `whatsapp_service.dart:189-246`). The note is appended as `📝 {note}` (line 236-238). **The note is the only place priority intent can currently travel to the agent — as unstructured text.**

### 1.4 The edit path
`_submitEdit` (lines 276-347) calls RPC `booking_request_customer_update`, gated server-side: only while `status='pending'` AND no seats assigned (`canEdit` in `customer_requests_store.dart:60`). On success it re-sends a WhatsApp "Updated request" variant.

### 1.5 Where the agent triages today
`lib/screens/requests_screen.dart` is the agent workspace. It reads **`passengers`** rows (not `booking_requests`) via `TourController`, bucketed into three filters: **New** (`!isWaitlisted && !isFullyAssigned`), **Waitlist**, **Assigned** (lines 220-232). Per-card actions: Assign seats / Edit / Send WA ack / Move to waitlist / Decline (`_CardActions`, lines 1126-1347). The customer's free-text note is shown as an italic quote block (lines 1031-1062). **There is no concept of priority anywhere — no approve/decline of a priority request, no chip, no filter.**

### 1.6 Real bugs / mismatches found
- **`priority_status` / `priority_reason` columns do not exist yet.** Neither `passengers` (database.sql:213-229) nor `booking_requests` (database.sql:297-313) has them. `AgeGroup` exists on `Passenger` but is never set by either form and is described as "unused" in the seat brief (§3, line 15).
- **RPC param drift (live bug risk).** `_submitEdit` calls `booking_request_customer_update` with a `p_trip_type` param (line 301), but the shipped `database.sql` definition (lines 480-486) is the **5-param** version with **no** `p_trip_type` and never updates `trip_type`. A 6-param fix exists only in `docs/superpowers/specs/2026-05-12-trip-direction.sql` (lines 102-163). So whether a customer's *trip-type edit actually persists* depends on which SQL was applied to the live DB. Any new RPC param we add (e.g. `p_priority_*`) MUST land in `database.sql` AND a real `supabase/migrations/00X` file, not a loose spec `.sql`.
- **`raw_form` vs `passengers` divergence.** The note + seat counts live in `booking_requests.raw_form` (jsonb) AND in `passengers` (note column + request_lines). Two sources; the agent UI reads only `passengers`. Any new priority field must be written to **`passengers`** (what the agent and solver read) to be effective.

---

## 2. Proposed direction (consistent with seat redesign + DNA)

**Keep the form lean. Add exactly one optional, collapsible block: "Needs a front seat?"** It produces `priority_status='requested'` + an optional short `priority_reason`, written to the `passengers` row. The agent **approves or declines** it in the existing Requests screen; only `approved` is honored by the solver (seat brief §4.2, §5.2). The customer sees a calm, honest status — "Requested" → "Approved"/"Not needed" — never a promise the agent hasn't made.

Concretely:
- **Customer form:** below the seat steppers, a collapsed pill ("Travelling with someone elderly or unwell?") expands to a single toggle + an optional one-line reason field. Same visual language as the existing "Add a note" disclosure (lines 435-473). This stays **whole-booking** scope (see Open Question 2) and does **not** add per-traveller rows or any gender/age input.
- **The free-text note stays** as-is for everything else (group members, special asks). Priority is promoted to a structured flag so the solver can act on it; the note remains the catch-all.
- **Agent approval lives in `requests_screen.dart`**, not a new screen — it is one job done where the agent already triages. A request carrying `priority_status='requested'` gets a **warm chip** ("PRIORITY REQUESTED", `UgamChipVariant.warm`) on `_RequestCard` and surfaces **Approve / Decline** actions in `_CardActions` (alongside the existing menu). Approving sets `approved`; declining sets `declined` (the booking still stands — only the front-seat ask is refused). This matches the seat-detail screen's tap-first, action-in-sheet pattern and the warm-ring priority convention (seat brief §3.4, §6).
- **Solver hand-off:** approved priority → front/sofa, spread across buses (seat brief §5.2 goal 1). A `requested`-but-not-yet-decided request becomes a `PendingPriorityApproval` exception card in the solver (seat brief §5.3) — so the agent can't accidentally lock a plan with un-triaged priority asks.
- **WhatsApp message** gains one line when priority is requested (e.g. "🦯 *Priority:* front seat requested — {reason}"), so the agent sees it even before opening the app. The deep-link mechanism is unchanged.

This is un-gameable (ask is free, only agent-approved is honored — seat brief decision #5), needs no new screen, and touches the form by exactly one optional block.

---

## 3. Concrete data-model / DB changes

These are the **capture-side subset** of the seat-redesign migration `supabase/migrations/005_seat_groups_priority.sql` (seat brief §4.2, §7). Do them in that one migration AND mirror into `database.sql` (don't repeat the trip-type drift).

- **`passengers.priority_status text not null default 'none'`** with a check ∈ `{'none','requested','approved','declined'}`. Index optional — small tables.
- **`passengers.priority_reason text null`** (short note; from customer at request time or agent at approve time).
- **Dart `Passenger` model** (`lib/models/passenger.dart`): add `priorityStatus` (enum) + `priorityReason` (String?), wire into `toMap`/`fromMap`/`copyWith` (lines 94-199). Add a small `PriorityStatus` enum (mirror `AgeGroup`'s shape, `age_group.dart`).
- **`CustomerRequestEntry`** (`customer_requests_store.dart:16-170`): add `priorityStatus` so "My Requests" can show the customer whether it was approved. Read it back in `refresh()` (lines 231-258) — which means `booking_request_status_lookup` (database.sql:354-397) must also **return the priority fields** (join from `passengers`, like it already does for `assigned_seats` at lines 387-390).
- **`booking_request_customer_update`** (database.sql:480-540): if priority is editable, add `p_priority_status` / `p_priority_reason` params and write to `passengers`. **Resolve the existing 5-vs-6-param drift first** (Open Question 5) — do not stack another overload on the inconsistency.
- **`raw_form`** in `booking_requests` should also carry `priority` for the audit trail (mirror the note pattern at customer_booking line 209) — but treat `passengers` as the source of truth the agent reads.
- **WhatsApp builder** (`whatsapp_service.dart:189-246`): add optional `priorityReason`/`priorityRequested` params and one message line. No schema change.

No new tables for this brief. (Groups — `passenger_groups` + `group_id` — are owned by the seat redesign brief, not captured on the customer form; see Dependencies.)

---

## 4. Dependencies

- **Seat-assignment redesign** (`2026-06-03-smart-seat-assignment-design.md`) is the parent. This form is the **capture point** for its priority model: it writes `priority_status='requested'`; the agent flips it to `approved`; the solver honors only `approved` and raises `PendingPriorityApproval` for undecided ones. The `priority_status`/`priority_reason` columns are *defined* by the seat migration — this brief just populates and surfaces them. Build the migration once, shared.
- **Requests screen** (`requests_screen.dart`) is where approval lives — it already reads `passengers` via `TourController` and has the card+menu pattern to extend. The seat-assignment overview screen (seat brief §6.1) also lists pending approvals; both must read the same flag.
- **Groups** are explicitly NOT captured here (agent-tagged, per seat brief decision #4). The form's free-text note ("group members, etc.") remains the informal hint the agent uses to tag groups later. If we ever let customers *declare* a group, that's a future, separate decision (see Open Question 3).
- **Handler / money / full-bus-chart** screens consume the priority ring downstream but don't capture it (seat brief §8).

---

## 5. Risks

- **Param drift repeats.** Adding priority params to `booking_request_customer_update` while the trip-type 6-param fix may or may not be live could create a second silently-broken RPC. Mitigate: audit the live DB's actual function signature before touching it; land everything in `database.sql` + a real numbered migration.
- **Dual-write skew.** Priority must be written to `passengers` (agent/solver read it) AND ideally `raw_form` (audit). If only `raw_form` is written, the agent never sees it. The create path upserts `passengers` already (lines 214-224); make sure the new field rides along.
- **Customer over-asks.** If the toggle reads like a free upgrade, everyone ticks it. Copy must frame it as "for someone elderly/unwell" and the customer must see it is **subject to approval**, not granted. The un-gameable design (agent approves) protects the seating, but expectation management is a copy risk.
- **"My Requests" needs a new status visual.** Today it only knows pending/accepted/rejected/seats-assigned (`customer_my_requests_screen.dart:499-510`). Showing priority approved/declined adds a state — keep it secondary so it doesn't compete with the seat-assignment status.
- **i18n.** Three full locales (Gujarati default). New keys under `customer_booking.*` and `requests.*` need gu/hi/en strings, no bilingual sub-labels (DNA). The new agent approval actions also need keys in `requests.action.*`.
- **Backfill.** Existing `passengers` rows have no `priority_status`; default `'none'` covers them, but any read path must tolerate a missing column during the migration window (mirror the `tripType` fallback pattern).

---

## 6. Open questions (agent decides)

These are in the structured output. Each has candidate options; the agent's answers shape the build.
