# Handler Full Bus Chart — Design Spec

**Date:** 2026-06-01
**Status:** Approved (Approach 1)

## Problem

A regular customer's seat view is intentionally private: in
[customer_seat_layout_sheet.dart](../../../lib/widgets/customer_seat_layout_sheet.dart)
they see only their own seats highlighted; everyone else's seats render neutral,
"since the customer should not see who else is on the bus." Data is locked down
by a `SECURITY DEFINER` RPC (`bus_layouts_for_request`) that returns only the
buses the customer has seats on, with **no** passenger names.

But every tour has a mandatory **handler** — one passenger
(`passengers.is_handler = true`, `tours.handler_id`) designated as the group's
point-of-contact. The handler cannot be removed (the tour can't lock without
one). The handler coordinates the whole group, so when the customer who opens
the app *is* the handler, they must see the **entire** bus chart — all
passengers, all buses — not just their own seats, and be able to **call** any
passenger.

## Goal

Give the handler a read-only twin of the agent's assign-seats chart:
- Same `CombinedSeatGrid` layout + bus pills the agent sees, editing removed.
- Tap an occupied seat → sheet with passenger **name + phone + Call** button.
- All passengers across all buses of the tour, names + phones.
- Strict privacy boundary: a non-handler request can never retrieve this data.

## Identification

The handler enters through the normal "My Requests" flow (anonymous customer,
request id in hand). We detect handler-ship server-side from the request id:
`booking_requests (tour_id, customer_phone)` → `passengers (tour_id, phone)` →
`is_handler`.

## Backend (Supabase)

Add to `supabase/migrations/003_handler_tour_manifest.sql` **and** mirror into
`database.sql`. Two `SECURITY DEFINER` functions, `revoke from public`, `grant
execute to anon, authenticated`:

### `is_request_handler(p_request_id uuid) returns boolean`
True iff the request's `(tour_id, phone)` passenger has `is_handler = true`.
Used to decide whether to show the entry point. Never throws; returns false for
unknown/non-handler requests.

### `handler_tour_manifest(p_request_id uuid) returns jsonb`
Returns `null` unless the request is the handler. When handler, returns:
```json
{
  "buses": [
    { "id", "tour_id", "name", "registration_no", "bus_type",
      "total_seats", "layout" }   // every bus where buses.tour_id = req.tour_id
  ],
  "passengers": [
    { "id", "tour_id", "name", "phone", "age_group",
      "assigned_seats", "is_handler" }   // every passenger of the tour
  ]
}
```
Key names match the table columns so existing `Bus.fromJson` /
`Passenger.fromJson` can parse the elements unchanged. `buses` ordered by name,
`passengers` ordered by name.

## Data layer (Dart)

`lib/services/customer_requests_store.dart`:
- `Future<bool> isRequestHandler(String requestId)` → calls `is_request_handler`.
- `Future<HandlerManifest?> handlerTourManifest(String requestId)` → calls
  `handler_tour_manifest`, returns `null` when RPC yields null.

`lib/models/handler_manifest.dart` — new:
```dart
class HandlerManifest {
  final List<Bus> buses;          // reuse existing Bus model
  final List<Passenger> passengers; // reuse existing Passenger model
  // seatOccupant(busId, seatId) -> Passenger? helper for the grid
}
```
Reuse the existing `Bus` and `Passenger` models if their `fromJson` accept the
shapes above; otherwise a slim local type, but prefer reuse.

## UI

`lib/screens/handler_bus_chart_screen.dart` — new, read-only:
- Takes `requestId`. On load: `handlerTourManifest(requestId)`. If null/empty →
  graceful empty state (shouldn't happen; entry is gated).
- Bus pills row (one per bus) like the agent screen's `_BusPills`; selecting a
  pill switches the rendered bus. Hide pills if only one bus.
- Render the selected bus with `CombinedSeatGrid`, reusing the same tile look as
  the agent chart. Occupied seats highlighted (accent), empty neutral. No drag,
  no edit affordances.
- Tap an occupied seat → bottom sheet: passenger name, age group, phone, and a
  **Call** button using the existing `lib/utils/phone_dialer.dart`. The handler
  themselves is labeled (e.g. a "Handler" chip).
- Match the app's dark-first Ugam aesthetic and existing color tokens.

## Entry point

In the "My Requests" screen: after loading a request, call `isRequestHandler`.
If true, show a "View full bus chart" action that pushes
`HandlerBusChartScreen(requestId: ...)`. Non-handlers never see it and keep the
existing private `customer_seat_layout_sheet`.

## Privacy / security boundary

- Full manifest lives behind its own RPC, gated on `is_handler`. A non-handler
  request id returns `null` — names/phones never leak.
- The private customer sheet is untouched; privileged view is a separate screen
  + separate RPC, so the two data paths never mix in one widget.

## Out of scope

No editing/reassigning from the handler view. No realtime; load-on-open is fine.
No changes to how the agent assigns or picks the handler.
