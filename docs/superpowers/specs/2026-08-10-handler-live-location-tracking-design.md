# Handler Live Location Tracking — Client Design

**Date:** 2026-08-10
**Status:** Approved design, ready for implementation planning
**Branch:** `feat/money-collection-settlement`

---

## 1. Why this document exists

Migration [047_bus_live_location.sql](../../../supabase/migrations/047_bus_live_location.sql) shipped a complete,
well-guarded location backend and **is deployed to the live database**. Nothing in
the Flutter app uses it. A repo-wide grep for `handler_push_locations`,
`bus_live_positions`, and `bus_location_fixes` returns zero Dart matches; there
is no GPS plugin, no location permission on either platform, and no map.

This design covers the entire missing client half: GPS capture on the handler's
phone, a durable upload path into the deployed RPC, and an admin map that shows
every bus on a tour moving in real time.

### What the backend already gives us (do not rebuild)

| Object | Shape | Notes |
|---|---|---|
| `bus_live_positions` | one row per bus, PK `bus_id` | current dot; published to Realtime |
| `bus_location_fixes` | append-only trail, bigint identity PK | unique on `(bus_id, recorded_at)` |
| `handler_push_locations(p_request_id uuid, p_bus_id uuid, p_fixes jsonb)` | `SECURITY DEFINER`, returns `jsonb` | the only write path |
| RLS | owner-only on both tables, **no anon policy** | admin reads their own tours only |

The RPC's contract, which the client must respect rather than duplicate:

- Guards with `is_request_handler(p_request_id)` **and** `handler_owns_bus(p_request_id, p_bus_id)`.
  On failure returns `{"accepted":0,"skipped":0,"error":"forbidden"}` — it does **not** raise.
- Accepts fixes only while `tours.status = 'locked'`. Otherwise returns
  `{"error":"window_closed"}`.
- Silently drops individual fixes that are malformed, out of range, older than
  24h, or more than 5 minutes in the future. Caps at 500 fixes per call.
- `on conflict (bus_id, recorded_at) do nothing` — **re-sending a batch is free.**
  This is the property the whole offline design leans on.
- Advances the live dot by re-reading the newest row from the trail, so an
  out-of-order offline flush can never rewind the map.
- Returns `{accepted, skipped, live_updated}`.

---

## 2. Decisions taken

| Question | Decision |
|---|---|
| Background aggressiveness | **Foreground service; keeps tracking with screen off or another app in front.** Does not survive force-kill or reboot. |
| Map | **Google Maps** (`google_maps_flutter`), key on the existing Firebase Google Cloud project. |
| Audience | **Admin live map + handler sees own bus.** No customer-facing tracking in this build. |
| Cadence | **Sample every 30 s / 50 m; upload every 2 min.** |
| Start/stop | **Auto-start** when a handler opens their bus chart on a `locked` tour. |

### Note on auto-start

Auto-start is the chosen behaviour, with consent relocated rather than removed.
Starting background location with no user-visible consent step is the most
common cause of Play Store background-location rejection, and a dual-store
release is on the roadmap. The design therefore keeps auto-start but makes it
compliant:

1. **First run only:** a rationale sheet states what is collected, why, who sees
   it, and how to stop — shown *before* the OS permission dialog. Play policy
   requires this disclosure for `ACCESS_BACKGROUND_LOCATION` regardless.
2. **Every run:** the Android foreground-service notification is persistent and
   carries a Stop action; iOS shows the blue background-location indicator.
3. **In-app:** a tracking status card on the chart screen with a Stop control.

Once permission is granted, subsequent opens start tracking with no prompt —
which is the "nothing to forget" property that was asked for.

---

## 3. Architecture

```
HANDLER DEVICE                                    ADMIN DEVICE
──────────────                                    ────────────
Geolocator.getPositionStream
  30 s interval / 50 m filter
        │
        ▼
LocationTrackerService
  ├── in-memory buffer
  ├── SharedPreferences mirror   ← survives process death
  └── flush timer (2 min)
        │
        │  handler_push_locations(requestId, busId, fixes[])
        ▼
   ┌─────────────────────────────────┐
   │ bus_location_fixes  (trail)     │
   │ bus_live_positions  (live dot)  │──── Realtime ────▶ BusPositionsRepository
   └─────────────────────────────────┘   tour_id=eq.X          │
                                                                ▼
                                                          LiveMapScreen
                                                          (Google Maps markers)
```

### Isolation boundaries

Each unit has one purpose and a stated dependency surface:

- **`LocationTrackerService`** — owns GPS capture, buffering, and upload. Depends
  on geolocator, SharedPreferences, and a single injectable RPC function. Knows
  nothing about widgets.
- **`BusPositionsRepository`** — owns the admin read: initial fetch plus a
  Realtime subscription. Depends on Supabase only. Knows nothing about maps.
- **`LiveMapScreen`** — owns presentation. Depends on the repository. Knows
  nothing about Supabase.

**Deliberate choice:** the map gets its **own** Realtime channel rather than a new
`LiveTable` entry in [realtime_service.dart](../../../lib/services/realtime_service.dart).
That service is a single broadcast stream feeding every admin controller; adding
position updates would wake unrelated screens into debounced refetches for data
they do not consume. A dedicated channel, created with the map and torn down
with it, contains the churn and risks no regression in existing screens.

---

## 4. Packages and native configuration

### Dependencies (resolved against `sdk: ^3.10.3`)

```yaml
geolocator: ^14.0.2
google_maps_flutter: ^2.18.0
```

`flutter_foreground_task` is **not** needed. `AndroidSettings.foregroundNotificationConfig`
creates the Android foreground service and its notification, and
`AppleSettings.allowBackgroundLocationUpdates` covers iOS.

### Android — `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
```

`FOREGROUND_SERVICE_LOCATION` is mandatory at API 34+; the project targets 36.

Maps key, inside `<application>`:

```xml
<meta-data android:name="com.google.android.geo.API_KEY"
           android:value="${mapsApiKey}"/>
```

### Android — `android/app/build.gradle.kts`

Read `MAPS_API_KEY` from `android/local.properties` (already gitignored at
`.gitignore:58`) and expose it as a manifest placeholder. Mirrors the existing
`key.properties` signing pattern. Absent key falls back to `""` so debug builds
still compile — the map renders grey rather than crashing the build.

### iOS — `ios/Runner/Info.plist`

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Shows the tour operator where your bus is while a trip is running.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Keeps sharing your bus location with the tour operator while the trip is running, even when the screen is off.</string>
<key>UIBackgroundModes</key>
<array><string>location</string></array>
```

### iOS — key handling

New gitignored `ios/Flutter/Secrets.xcconfig` holding `MAPS_API_KEY`, included
from `Debug.xcconfig`/`Release.xcconfig`, surfaced into `Info.plist` and read in
`AppDelegate.swift` via `GMSServices.provideAPIKey(...)`. Add
`**/ios/Flutter/Secrets.xcconfig` to `.gitignore`.

---

## 5. Data model — `lib/models/bus_position.dart`

Two classes; both pure, both trivially testable.

**`LocationFix`** — one captured sample, the unit of the outbound buffer.

Fields: `lat`, `lng`, `accuracyM?`, `speedKmh?`, `headingDeg?`, `leg?`,
`recordedAt`, `trackingState`.

- `toJson()` emits exactly the keys the RPC reads: `lat`, `lng`, `accuracy_m`,
  `speed_kmh`, `heading_deg`, `leg`, `recorded_at`, `tracking_state`.
- `recordedAt` serialises as UTC ISO-8601. The RPC rejects anything >5 min ahead
  or >24 h behind server time.
- `leg` is `'go' | 'ret'` — **matching `attendance.leg`, not**
  `tour_seat_snapshots.leg` which uses `'outbound' | 'return'`. 047's header
  calls out this live divergence explicitly; do not "harmonise" it here.
- `speedKmh` converts from geolocator's `Position.speed`, which is **m/s**
  (`speed * 3.6`). A negative speed means "unavailable" and maps to null.
- Round-trips through `fromJson` for the SharedPreferences mirror.

**`BusPosition`** — one row read back from `bus_live_positions` for the map.

Fields: `busId`, `tourId`, `lat`, `lng`, `accuracyM?`, `speedKmh?`,
`headingDeg?`, `leg?`, `trackingState`, `recordedAt`, `receivedAt`.

Derived getters used by the UI:
- `staleness` → `DateTime.now().difference(recordedAt)`
- `isStale` → `staleness > 6 min` (three missed 2-minute uploads)
- `isMoving` → `(speedKmh ?? 0) > 5`

---

## 6. Handler side

### 6.1 `lib/services/location_tracker_service.dart`

A `GetxService` (matching `RealtimeService`) exposing an observable
`TrackingState` and three methods: `start({requestId, busId, leg})`, `stop()`,
`flushNow()`.

```dart
enum TrackingStatus {
  idle,            // never started, or cleanly stopped
  awaitingPermission,
  denied,          // user said no; card offers Settings
  deniedForever,   // must go to Settings; no re-prompt possible
  serviceDisabled, // OS location toggle is off
  live,            // streaming and uploading
  windowClosed,    // server says tour is no longer 'locked'
  forbidden,       // server rejected ownership
}
```

**Capture.** One `Geolocator.getPositionStream` subscription.

```dart
// Android
AndroidSettings(
  accuracy: LocationAccuracy.high,
  distanceFilter: 50,
  intervalDuration: Duration(seconds: 30),
  foregroundNotificationConfig: ForegroundNotificationConfig(
    notificationTitle: tr('tracking.notification_title'),
    notificationText: tr('tracking.notification_text'),
    enableWakeLock: true,
  ),
)

// iOS
AppleSettings(
  accuracy: LocationAccuracy.high,
  activityType: ActivityType.automotiveNavigation,
  distanceFilter: 50,
  pauseLocationUpdatesAutomatically: false,
  showBackgroundLocationIndicator: true,
  allowBackgroundLocationUpdates: true,
)
```

`pauseLocationUpdatesAutomatically` is **false** on purpose: iOS otherwise pauses
updates when it decides the device is stationary, which is exactly the dhaba
stop where the admin still wants a live dot.

**Buffer.** Every sample appends to an in-memory `List<LocationFix>` and is
mirrored to SharedPreferences under `loc_buffer_<busId>`. The mirror is what
survives a battery-saver kill or a reboot; on `start()` the service rehydrates
it and flushes before capturing anything new.

Bounded at **2000 fixes** (~16 h at 30 s). On overflow the **oldest** fix is
dropped — a stale position has no value once newer ones exist, and this caps
worst-case disk and payload size.

**Flush.** A 2-minute periodic timer, plus an immediate flush on connectivity
regained (via `connectivity_plus`, already a dependency) and on app resume.

- Sends at most **500 fixes per call** (the server's own cap), oldest first, in
  `recordedAt` order.
- Drops from the buffer only what the call confirms. Because the server dedupes
  on `(bus_id, recorded_at)`, a retried batch that partially landed is safe and
  the client does not need to reason about which half succeeded — it re-sends
  the window and trusts `accepted + skipped`.
- More than 500 buffered → keeps flushing in a loop until drained or a call fails.

**Parked-bus heartbeat.** A 50 m distance filter means a stationary bus emits
nothing, leaving the admin unable to distinguish "parked" from "app died". So
when a flush finds an empty buffer, it sends a single fix built from
`Geolocator.getLastKnownPosition()`. Keeps `recorded_at` advancing at ~30
rows/hour while idle, which the `isStale` getter then reads correctly.

**Response handling.** The RPC returns refusals as data, not exceptions:

| Response | Action |
|---|---|
| `{accepted, skipped}` | drop the **whole sent batch**, stay `live` (see note) |
| `error: "window_closed"` | stop stream, clear buffer + mirror, status `windowClosed` |
| `error: "forbidden"` | stop stream, clear buffer + mirror, status `forbidden` |
| `error: "bad_payload"` | drop the batch (client bug — never retry a poison batch), log via `error_reporter` |
| throws, `isRetryable == true` | keep buffer, back off |
| throws, `isRetryable == false` | keep buffer, surface on card, no retry storm |

**Note on dropping the whole batch.** The server returns
`skipped = length(p_fixes) - accepted`, which lumps together fixes it rejected
as invalid and fixes that already existed (the `on conflict do nothing` path).
Neither is worth re-sending: an invalid fix stays invalid forever, and a
duplicate is already stored. So any RPC call that *returns* — as opposed to
throwing — consumes its entire batch. Only a thrown exception preserves the
buffer for retry. Getting this backwards produces a buffer that never drains.

Retry classification reuses `isRetryable(e, retryOnTimeout: true)` from
[sync_retry_policy.dart](../../../lib/services/sync_retry_policy.dart).
`retryOnTimeout: true` is correct **because the RPC is idempotent** — a timed-out
flush that actually landed will dedupe on retry.

Backoff on retryable failure: 2 min → 4 → 8 → capped at 16 min, reset on success.
The buffer keeps filling meanwhile; that is the intended behaviour, not a leak.

**Test seam.** Following the `HandlerBusChartScreen.manifestReader` precedent:

```dart
typedef LocationPusher = Future<Map<String, dynamic>> Function(
  String requestId, String busId, List<Map<String, dynamic>> fixes);
```

Production passes null and the service calls Supabase directly. Tests inject a
fake and drive every branch above without a network or a GPS.

### 6.2 Permission flow

1. Chart screen opens on a `locked` tour, handler owns a bus.
2. `Geolocator.isLocationServiceEnabled()` → false ⇒ `serviceDisabled`, card
   offers `Geolocator.openLocationSettings()`.
3. `checkPermission()`:
   - `denied` ⇒ show **rationale sheet first**, then `requestPermission()`.
   - `deniedForever` ⇒ card with `Geolocator.openAppSettings()`; never re-prompt.
   - `whileInUse` ⇒ usable; on Android request once more to reach `always`. If the
     handler declines, tracking still runs while the app is foregrounded and the
     card says so plainly rather than pretending to be fully live.
   - `always` ⇒ start.

The rationale sheet (`lib/widgets/location_rationale_sheet.dart`, built on
`UgamSheet`) is shown **once ever**, gated by a SharedPreferences flag, and states:
what is collected (bus position while the trip runs), who sees it (the tour
operator), when it stops (when the trip is marked complete), and how to stop it
early (notification Stop, or the card).

### 6.3 Handler UI

`lib/widgets/tracking_status_card.dart`, rendered at the top of
[handler_bus_chart_screen.dart](../../../lib/screens/handler_bus_chart_screen.dart),
which already holds both values the RPC needs: `widget.requestId` and
`_selectedBusId`.

Built from `UgamCard` + `UgamStatusDot` + `UgamCTA`, per `lib/design/ugam.dart`.
States map 1:1 onto `TrackingStatus`:

| Status | Card |
|---|---|
| `live` | green dot, "Sharing location · updated 1 min ago", Stop button |
| `awaitingPermission` | neutral, spinner |
| `denied` / `deniedForever` | amber, why-it-matters line, Open Settings |
| `serviceDisabled` | amber, Turn on location |
| `windowClosed` | grey, "Trip finished — sharing stopped" |
| `forbidden` | grey, generic "Sharing unavailable" (no security detail leaked) |
| `idle` | hidden entirely when the tour is not `locked` |

Below the card, a small `GoogleMap` (fixed ~180 dp, `liteModeEnabled: true` on
Android) showing the handler's own bus — the "handler sees own bus" decision.
Lite mode renders a static bitmap: enough to confirm the dot is moving, at a
fraction of the battery and memory of a full map on a phone that is already
running GPS for hours.

**Auto-start, stated precisely.** On mount, when the tour is `locked` and the
handler owns the selected bus, the card runs the §6.2 flow unconditionally:

- permission already granted ⇒ tracking starts immediately, no prompt, no tap
- permission not yet asked ⇒ rationale sheet, then the OS prompt, then start if granted
- previously denied ⇒ no re-prompt; the card sits in its `denied` state

So "auto-start" means the handler never taps a Start button — not that a prompt
is skipped on first run. The card never blocks the chart behind a modal; the
rationale sheet is dismissible and the chart is fully usable without tracking.

### 6.4 Leg detection

`leg` is set from the handler's currently selected leg on the chart screen, which
already tracks go/return state for attendance. No new inference logic — if the
screen does not know the leg, `leg` is sent as null, which the RPC accepts.

---

## 7. Admin side

### 7.1 `lib/services/bus_positions_repository.dart`

```dart
Future<List<BusPosition>> fetchForTour(String tourId);
Stream<BusPosition> watchTour(String tourId);   // own channel
void dispose();
```

`watchTour` opens `channel('bus-positions-$tourId')` with
`onPostgresChanges(event: all, schema: 'public', table: 'bus_live_positions',
filter: PostgresChangeFilter(type: eq, column: 'tour_id', value: tourId))`.
Server-side filtering keeps other tours' buses off the wire entirely.

Reads are plain PostgREST selects; RLS already confines them to the signed-in
owner's tours, so the repository carries no authorisation logic of its own.

### 7.2 `lib/screens/live_map_screen.dart`

Entry point: a "Live map" action in `_BusesTab` of
[tour_detail_screen.dart](../../../lib/screens/tour_detail_screen.dart), visible
only when `tour.status == 'locked'`.

- Initial `fetchForTour`, then merge `watchTour` events into a
  `Map<String, BusPosition>` keyed by `busId`.
- One marker per bus, labelled with the bus name and rotated by `headingDeg`.
  Stale buses (`isStale`) render in a muted colour with "last seen 14 min ago" in
  the info window — the admin must be able to distinguish a stopped bus from a
  dead phone.
- Camera fits all markers on first load; afterwards the admin's camera is left
  alone, because auto-recentering on every update makes a map unusable while
  panning.
- Tapping a marker opens an `UgamSheet` with bus name, driver, handler phone
  (tap to call, reusing `phone_dialer.dart`), speed, and last-seen.
- Empty state via `UgamEmpty`: "No bus has shared its location yet."

Trail playback from `bus_location_fixes` is **out of scope** for this build. The
table and its `(bus_id, recorded_at desc)` index exist for it; 047 already
specifies it as fetch-on-tap rather than streamed.

---

## 8. Error handling summary

| Condition | Behaviour |
|---|---|
| Permission denied | card explains, offers Settings, no crash, no retry loop |
| OS location off | card offers `openLocationSettings()` |
| Offline / dead zone | buffer grows on disk; auto-flush on reconnect |
| Partial batch landed then timeout | re-sent; server dedupes; no duplicates |
| Corrupt buffer entry | server drops that fix, batch-mates still land (047 poison-pill guard) |
| Tour completed mid-drive | `window_closed` → stop + clear |
| Handler reassigned to another bus | `forbidden` → stop + clear |
| App force-killed | tracking ends (accepted); buffer survives and flushes on next open |
| Maps key missing | grey map tiles; app functions; no crash |

Unexpected exceptions route to the existing `error_reporter` service rather than
surfacing raw to the handler mid-drive.

---

## 9. Testing

Unit tests, no network and no GPS, using the `LocationPusher` seam:

- `LocationFix.toJson` key names and UTC formatting match the RPC exactly
- m/s → km/h conversion; negative speed → null
- buffer overflow drops oldest, retains newest
- SharedPreferences rehydrate → flush → clear round trip
- `accepted: n` drops exactly n
- `window_closed` and `forbidden` stop and clear
- `bad_payload` drops the batch without retrying
- retryable vs terminal exception classification, and backoff escalation/reset
- >500 buffered flushes in repeated calls until drained
- empty buffer emits exactly one heartbeat fix

Widget tests:

- `TrackingStatusCard` renders the correct affordance for all eight statuses
- `LiveMapScreen` merges a Realtime event into an existing marker set
- stale styling appears past the 6-minute threshold

Per project precedent, any widget test touching `plural()` must `Localization.load`
a locale in `setUpAll`; `tr()` alone is safe.

`LiveMapScreen` tests inject positions directly rather than rendering real map
tiles — `google_maps_flutter` has no widget-test surface.

**Gate:** `flutter analyze` clean and the full suite green (1406 passing at time
of writing) before this is considered done.

---

## 10. Translation keys

New keys in `assets/translations/{en,gu,hi}.json` under a `tracking.*` namespace:
card statuses, rationale sheet body, notification title/text, map empty state,
last-seen phrasing. Gujarati is the default locale and must not fall back to
English for anything a handler sees.

---

## 11. Out of scope

- Customer-facing "where is my bus"
- Trail playback / route replay
- Geofenced arrival alerts or ETA computation
- Tracking that survives force-kill or reboot
- Any new SQL migration — this build targets deployed 047 exactly

---

## 12. Manual steps required from the user

1. Enable **Maps SDK for Android** and **Maps SDK for iOS** on the existing
   Firebase Google Cloud project; create an API key restricted to the two app
   bundle IDs.
2. Put `MAPS_API_KEY=...` in `android/local.properties` and
   `ios/Flutter/Secrets.xcconfig` (both gitignored).
3. Complete the Play Console **background location declaration** before release,
   describing the handler tracking feature and linking a demo video.
4. Add the matching disclosure to the privacy policy served by
   `legal_document_screen.dart`.

Steps 3 and 4 are release blockers, not build blockers — implementation and
testing can complete without them.
