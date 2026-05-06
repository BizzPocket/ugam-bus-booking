# Appwrite Schema Changes — Phase 5 (Agent Workflow Realignment)

What you need to change in the Appwrite Console for the new build to work.
The code falls back gracefully on missing fields, so you can land changes
incrementally — but the new screens won't render their data correctly
until the new fields exist.

## 1. `passengers` collection

### Fields to ADD

| Field | Type | Size | Required | Default | Notes |
|---|---|---|---|---|---|
| `requestLines` | string | 4000 | no | `[]` | JSON-encoded list of `{seatType, position, qty}` items. Replaces the legacy `seatPreference` + `requestedSeats` pair. |
| `note` | string | 500 | no | (null) | Optional note from the customer when submitting a request. |

`assignedSeats` is now a JSON-encoded string of `[{busId, seatId}]`
objects (was previously a list-of-strings of bare seat IDs). If the
column was already typed as `string` it just works; if it was a list
column you'll need to drop it and recreate as `string` (size 4000).

### Fields you can KEEP (still read by `Passenger.fromAppwrite` for
backward compat with old documents)

- `seatPreference` (string)
- `requestedSeats` (int)

These are no longer written by the app, but old documents still parse.

### Fields unchanged

`tourId`, `userId`, `name`, `phone`, `ageGroup`, `paymentStatus`,
`isHandler`.

## 2. `buses` collection

### Fields to ADD

| Field | Type | Size | Required | Default | Notes |
|---|---|---|---|---|---|
| `name` | string | 50 | no | `Bus` | Display name on the tour, e.g. "Bus 1", "Bus 2". |
| `layout` | string | 16000 | no | (null) | JSON-encoded BusLayout (lower + upper deck of cells). Generated automatically when the agent saves a bus via Add Bus. Large limit because a 60-seat double-deck bus can take ~6 KB of JSON. |

### Fields unchanged

`tourId`, `busNumber`, `driverName`, `driverPhone`, `ownerName`,
`ownerPhone`, `isAC`, `busType`, `totalSeats`, `notes`.

## 3. `tours` collection

No schema changes. The app reads/writes the same fields as before.

## 4. Permissions reminder

Each new field needs the same read/write permissions as the rest of
the collection — usually `users` (or whatever role the admin and the
customer-mode anonymous session use). If you forget, the app will
return permission errors only on the new fields, which can look like
a parser bug.

## 5. Migration ordering

You can do this in any order — the app handles missing fields:

1. Land the new code (already done; this commit).
2. Add the fields above in the Appwrite console.
3. Existing documents continue to work (they just won't have the new
   fields populated until they're rewritten by the new flow).

No data migration script is needed.
