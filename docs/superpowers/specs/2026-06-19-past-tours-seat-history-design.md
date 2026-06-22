# Past Tours + Seat-History Snapshot — Design

Date: 2026-06-19
Branch: feat/money-collection-settlement

## Goal

Keep every tour after its trip date passes (they are already soft-archived, never
deleted) and let an **admin browse and fully track past trips** — including the
**seat-assignment chart**, which is the one piece of data that today gets
destroyed.

Two coordinated parts:

- **Part A** — surface a browsable "Past" section in the admin tours list.
- **Part B** — snapshot the per-leg seat chart so the outbound (GO) chart
  survives the seat-recycling that frees those seats for the return leg.

Customer side is **unchanged** (it intentionally hides old trips).

---

## Background (current behavior, verified)

- Tours are **never hard-deleted** on expiry. `_archiveExpiredTours()`
  (`lib/controllers/tour_controller.dart:365`) flips an expired tour to
  `completed` one day after its end date (`returnDate ?? departureDate`) via
  `completeTour()` (`:579`), which only sets status — it does **not** clear seats.
- The admin fetch filters only by `owner_id` (`:268`) — **no status filter** — so
  completed tours load with all passengers, buses, money, groups, and seats.
- `SeatsScreen` has **no** completed-tour block; the detail screen's 6-tool grid
  (Requests/Buses/Seats/Money/Groups/Lock) renders regardless of status. So a
  past tour is already fully navigable; the only gaps are (A) visibility in the
  list and (B) the GO-leg seat chart.
- **The one place seat data dies:** `completeOutboundLeg()` (`:598`) sets
  outbound-only riders' `assignedSeats = []` (and `journeyDone = true`) to free
  those seats for return-leg rebooking. Passenger records are kept; only the
  GO seat *positions* are lost.

---

## Part A — Browsable "Past" section (admin tours list)

File: `lib/screens/tours_screen.dart`

`_group()` already computes a date-based `past` bucket
(`:240-254`, end day = `returnDate ?? departureDate` before today) but only
returns it `if (_query.isNotEmpty)` (`:271`).

Changes:

1. Always return the `_Bucket.past` group (remove the search gate).
2. Render the Past group as a **collapsed-by-default** section at the bottom via a
   new local `_CollapsibleGroup` StatefulWidget:
   - Reuses the `_GroupHeader` label+count look, made tappable, with a rotating
     `Icons.expand_more_rounded` chevron and an `AnimatedCrossFade` body (mirror
     `UgamExpander` motion: `UgamMotion.sheet` / `easeOut`).
   - `initiallyExpanded: false`. Carries a stable `const ValueKey('tours-past-group')`
     so its open/closed state survives `Obx` rebuilds.
   - Rows stay dimmed (`dim: true`) and newest-first (existing `byDateDesc`).
   - Upcoming groups (This week / Next 30 / Later) render unchanged.
3. Empty Past → render nothing (keep the existing `g.tours.isEmpty` guard).

No controller/model/i18n changes (reuses `tours.group.past`).

---

## Part B — Seat-history snapshot (seats only)

### B1. Storage

New table, migration `supabase/migrations/031_tour_seat_snapshots.sql`,
**lazy-loaded** only when a past tour's seat view opens (never rides along with
the tours-list fetch).

```sql
create table if not exists public.tour_seat_snapshots (
  id           uuid primary key default gen_random_uuid(),
  tour_id      uuid not null references public.tours(id) on delete cascade,
  leg          text not null check (leg in ('outbound','return')),
  snapshot_data jsonb not null,
  captured_at  timestamptz not null default now(),
  unique (tour_id, leg)
);
create index if not exists tour_seat_snapshots_tour_idx
  on public.tour_seat_snapshots(tour_id);

alter table public.tour_seat_snapshots enable row level security;
-- owner-scoped select/insert/update/delete: auth.uid() = (select owner_id from tours where id = tour_id)
```

`snapshot_data` JSON shape (stable contract):

```json
{
  "buses": [
    {
      "busId": "uuid",
      "seats": [ { "seatId": "DL3", "name": "Ravi Patel", "phone": "9876543210" } ]
    }
  ]
}
```

One occupant per seat per leg (a seat cannot be double-booked within one leg).

### B2. Dart model

New file `lib/models/tour_seat_snapshot.dart`:

```dart
enum SnapshotLeg { outbound, return_ }   // 'return_' to dodge the reserved word; map to/from 'return'

class SnapshotSeat   { final String seatId; final String name; final String? phone; }
class SnapshotBus    { final String busId;  final List<SnapshotSeat> seats; }
class TourSeatSnapshot {
  final String tourId;
  final SnapshotLeg leg;
  final List<SnapshotBus> buses;
  final DateTime capturedAt;
}
```

- `TourSeatSnapshot.fromMap(Map)` / `toMap()` — DB row <-> model (column `leg`
  is the string `'outbound'`/`'return'`; `snapshot_data` is the JSON above).
- `SnapshotBus.occupant(String seatId) -> SnapshotSeat?` convenience lookup.

### B3. Capture (controller)

File: `lib/controllers/tour_controller.dart`. Add:

```dart
// In-memory cache, keyed by tourId.
final RxMap<String, List<TourSeatSnapshot>> _seatSnapshots = <String, List<TourSeatSnapshot>>{}.obs;

/// Build a per-leg snapshot from the LIVE tour and upsert it.
/// leg=outbound -> per-seat SeatOccupancy.go ; leg=return -> .ret
/// (uses seatOccupantsForBus from lib/utils/seat_occupants.dart).
Future<void> _captureSeatSnapshot(String tourId, SnapshotLeg leg,
    {required bool overwriteIfExists}) async { ... }

/// Lazy-fetch snapshots for a tour (used by the past-tour seat view); caches.
Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async { ... }
```

Capture is **best-effort**: wrap the upsert in try/catch, log, and never block the
status transition. If the table does not exist yet (migration not applied),
`smartFetch` returns `[]` / writes throw and are swallowed — the app degrades
gracefully and simply has no history.

**Capture points & semantics** (robust across one-way and round trips):

| Call site | leg | overwriteIfExists | Rationale |
|---|---|---|---|
| `completeOutboundLeg()` — **before** clearing seats | outbound | true | authoritative pre-wipe GO chart |
| `completeTour()` | outbound | **false** | covers tours that expire without a GO-leg completion (seats still intact); never clobbers the pre-wipe capture |
| `completeTour()` | return | true | round-trip + return-only riders (`.ret`); empty for one-way → skip writing an empty snapshot |

Helper skips writing a snapshot that has zero occupants across all buses.

### B4. Read & render (read-only, decoupled from the live editor)

New screen `lib/screens/past_tour_seat_history_screen.dart`:
`PastTourSeatHistoryScreen({ required String tourId })`.

- On open, calls `TourController.loadSeatSnapshots(tourId)`.
- Renders each bus with the **existing `CombinedSeatGrid`** (live frozen
  `BusLayout` from the preserved `Bus` records — `allowsLayoutEdit` is false once
  completed) plus a thin static `_SnapshotSeatTile` that shows the occupant name
  from the snapshot map. No tap-to-edit, no live passenger dependency.
- **GO / RETURN** segmented toggle appears only when both `outbound` and `return`
  snapshots exist; otherwise the single snapshot renders with no toggle.
- **Fallback:** if no snapshot exists (legacy tours completed before this ships,
  or capture failed), render the live passenger chart read-only so the view never
  breaks.

Routing: in `lib/screens/tour_detail_screen.dart`, the `_ActionsGrid` **Seats**
tile (`:2023`) — when `tour.status == TourStatus.completed`, push
`PastTourSeatHistoryScreen(tourId: tour.id)`; otherwise push `SeatsScreen` as
today. (The Passengers-tab sticky "Seats" CTA may keep its current behavior; the
tool-grid tile is the canonical past-tour entry.)

### B5. i18n

Add keys to `assets/translations/en.json`, `gu.json`, `hi.json`:
`seat_history.title`, `seat_history.leg_go`, `seat_history.leg_return`,
`seat_history.empty` (no history captured), `seat_history.fallback_note`
(viewing live data — history not captured for this tour).

---

## Edge cases

- Bus deleted after completion → skip that bus's snapshot section (render keyed by
  live `busId`).
- One-way tour (no return) → only an outbound snapshot; no toggle.
- Round-trip rider appears in both legs (correct — rode both).
- Migration not yet applied → no history, graceful fallback to live chart.

## Testing

- Unit: `_captureSeatSnapshot` serializes the chart correctly; `completeOutboundLeg`
  writes the outbound snapshot **before** wiping seats (assert the snapshot retains
  the seat the live passenger just lost). `TourSeatSnapshot.fromMap/toMap` round-trip.
- Widget: `PastTourSeatHistoryScreen` renders occupants from a snapshot map and shows
  the GO/RETURN toggle only when both legs exist; falls back when none exist.
- Widget: Part A — date-past tours appear under a collapsed "Past" header in browse
  mode (no search) and reveal on tap; upcoming groups stay expanded.

## Rollout

- Migration `031` must be applied to Supabase by the owner (outward action — not
  applied automatically). The Dart code degrades gracefully until then.
- No customer-facing change.

## Scope guardrails

- No change to the live seat-editing pipeline or `resolveSeatRender`.
- Snapshot is **seats-only** — passengers, money, buses, groups are already retained
  and viewable on completed tours.
