# Handler Live Location Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the entire Flutter client for the already-deployed live-location backend, so a handler's phone streams its bus position and an admin watches every bus move on a map.

**Architecture:** `geolocator` captures fixes on a 30 s / 50 m stream kept alive by an Android foreground service and iOS background location mode. Fixes land in a disk-backed buffer and flush every 2 minutes into the deployed `handler_push_locations` RPC, whose `(bus_id, recorded_at)` dedupe makes a re-sent batch free. The admin reads `bus_live_positions` through a dedicated Realtime channel — deliberately *not* the shared `RealtimeService` fan-out — and renders Google Maps markers.

**Tech Stack:** Flutter 3.10.3+, Dart, GetX, Supabase (`supabase_flutter`), `geolocator ^14.0.2`, `google_maps_flutter ^2.18.0`, `shared_preferences`, `connectivity_plus`, `easy_localization`.

**Spec:** [2026-08-10-handler-live-location-tracking-design.md](../specs/2026-08-10-handler-live-location-tracking-design.md)

## Global Constraints

- **Do not write or modify any SQL migration.** Migration 047 is deployed and is the contract. This build is client-only.
- `leg` is `'go' | 'ret'` — matching `attendance.leg`. Never `'outbound'`/`'return'` (that is `tour_seat_snapshots`, a live divergence 047 documents deliberately).
- The RPC returns refusals as **data** (`{"error": "forbidden"}`), not exceptions. Never treat a returned error as a throw.
- Any RPC call that *returns* consumes its entire sent batch. Only a **thrown** exception preserves the buffer.
- Max 500 fixes per RPC call (server-enforced). Local buffer cap 2000, dropping **oldest** on overflow.
- Retry classification must use `isRetryable(e, retryOnTimeout: true)` from `lib/services/sync_retry_policy.dart`. Never sniff exception messages.
- Backoff: 2 → 4 → 8 → 16 min cap, reset on success.
- All handler- and admin-visible strings go through `tr()` with keys in `assets/translations/{en,gu,hi}.json`. **Gujarati is the default locale** and must never fall back to English.
- UI uses `lib/design/ugam.dart` only: `UgamCard.plain`, `UgamStatusDot`, `UgamCTA`, `UgamEmpty`, `UgamSheet`, `UgamSpacing`, `UgamText`, `UgamColors.of(context)`.
- Import models/services in tests as `package:occubusbooking/...`.
- Gate: `flutter analyze` clean and the full suite green (1406 passing at plan time).
- `flutter` is not on PATH. Prefix commands with `export PATH="/c/src/flutter/bin:$PATH"`.
- Another agent edits this working tree concurrently. **Always `git add` explicit file paths, never `git add -A` or `git add .`**

---

### Task 1: Dependencies and native configuration

**Files:**
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/build.gradle.kts`
- Modify: `ios/Runner/Info.plist`
- Create: `ios/Flutter/Secrets.xcconfig`
- Modify: `ios/Flutter/Debug.xcconfig`, `ios/Flutter/Release.xcconfig`
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: `geolocator` and `google_maps_flutter` importable; `MAPS_API_KEY` resolved from gitignored files on both platforms.

- [ ] **Step 1: Add the two dependencies**

In `pubspec.yaml`, after the `qr_flutter: ^4.1.0` line:

```yaml
  # Handler GPS capture. Its AndroidSettings.foregroundNotificationConfig
  # creates the Android foreground service, and AppleSettings covers iOS
  # background updates — so no separate foreground-task package is needed.
  geolocator: ^14.0.2

  # Admin live map. Map loads on the mobile SDKs are not billed.
  google_maps_flutter: ^2.18.0
```

- [ ] **Step 2: Install and verify resolution**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter pub get`
Expected: resolves without conflict; `geolocator 14.0.2` and `google_maps_flutter 2.18.0` appear.

- [ ] **Step 3: Declare Android permissions**

In `android/app/src/main/AndroidManifest.xml`, alongside the existing `<uses-permission>` block (currently lines 2-7):

```xml
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
```

`FOREGROUND_SERVICE_LOCATION` is mandatory at API 34+; this project targets 36.

- [ ] **Step 4: Add the Maps key placeholder to the manifest**

Inside `<application>`, before the closing tag:

```xml
        <meta-data android:name="com.google.android.geo.API_KEY"
                   android:value="${mapsApiKey}"/>
```

- [ ] **Step 5: Feed the placeholder from local.properties**

In `android/app/build.gradle.kts`, near the top where `localProperties` is already read (the file already loads it for `flutter.versionCode`). Inside `defaultConfig`, after `targetSdk = 36`:

```kotlin
        // Maps key lives in android/local.properties (gitignored at .gitignore:58),
        // mirroring the key.properties signing pattern. Empty fallback keeps debug
        // builds compiling — the map renders grey rather than failing the build.
        manifestPlaceholders["mapsApiKey"] =
            localProperties.getProperty("MAPS_API_KEY") ?: ""
```

If `localProperties` is not already a `val` in scope, add above `android {`:

```kotlin
val localProperties = java.util.Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
```

- [ ] **Step 6: Add your key locally**

Append to `android/local.properties` (gitignored — never commit):

```
MAPS_API_KEY=YOUR_KEY_HERE
```

- [ ] **Step 7: Declare iOS usage strings and background mode**

In `ios/Runner/Info.plist`, alongside the existing `NS*UsageDescription` keys (~line 39):

```xml
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Shows the tour operator where your bus is while a trip is running.</string>
	<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
	<string>Keeps sharing your bus location with the tour operator while the trip is running, even when the screen is off.</string>
	<key>UIBackgroundModes</key>
	<array>
		<string>location</string>
	</array>
	<key>MAPS_API_KEY</key>
	<string>$(MAPS_API_KEY)</string>
```

- [ ] **Step 8: Create the gitignored iOS secrets file**

Create `ios/Flutter/Secrets.xcconfig`:

```
MAPS_API_KEY=YOUR_KEY_HERE
```

Add to the **top** of both `ios/Flutter/Debug.xcconfig` and `ios/Flutter/Release.xcconfig`:

```
#include? "Secrets.xcconfig"
```

`#include?` (with the `?`) does not fail the build when the file is absent, so a fresh clone still compiles.

- [ ] **Step 9: Provide the key to the Maps SDK**

In `ios/Runner/AppDelegate.swift`, add the import and the call before `GeneratedPluginRegistrant.register`:

```swift
import GoogleMaps
```

```swift
    if let key = Bundle.main.object(forInfoDictionaryKey: "MAPS_API_KEY") as? String,
       !key.isEmpty {
      GMSServices.provideAPIKey(key)
    }
```

- [ ] **Step 10: Gitignore the iOS secret**

Add to `.gitignore` near the existing `**/ios/Flutter/Generated.xcconfig` line:

```
**/ios/Flutter/Secrets.xcconfig
```

- [ ] **Step 11: Verify the Android build still compiles**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter build apk --debug`
Expected: BUILD SUCCESSFUL. This proves the manifest merge and the placeholder wiring.

- [ ] **Step 12: Commit**

```bash
git add pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml android/app/build.gradle.kts ios/Runner/Info.plist ios/Flutter/Debug.xcconfig ios/Flutter/Release.xcconfig ios/Runner/AppDelegate.swift .gitignore
git commit -m "feat(location): add geolocator + google_maps_flutter and native config"
```

---

### Task 2: Location models

**Files:**
- Create: `lib/models/bus_position.dart`
- Test: `test/models/bus_position_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `class LocationFix` with `LocationFix({required double lat, required double lng, double? accuracyM, double? speedKmh, double? headingDeg, String? leg, required DateTime recordedAt, String trackingState = 'live'})`, `Map<String, dynamic> toJson()`, `factory LocationFix.fromJson(Map<String, dynamic>)`, `factory LocationFix.fromPosition(Position, {String? leg, String trackingState})`
  - `class BusPosition` with `factory BusPosition.fromMap(Map<String, dynamic>)`, fields `busId, tourId, lat, lng, accuracyM, speedKmh, headingDeg, leg, trackingState, recordedAt, receivedAt`, getters `Duration get staleness`, `bool get isStale`, `bool get isMoving`

- [ ] **Step 1: Write the failing tests**

Create `test/models/bus_position_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';

void main() {
  group('LocationFix', () {
    test('toJson uses exactly the keys handler_push_locations reads', () {
      final fix = LocationFix(
        lat: 23.0225,
        lng: 72.5714,
        accuracyM: 12.5,
        speedKmh: 54.0,
        headingDeg: 180.0,
        leg: 'go',
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
      );

      expect(fix.toJson().keys.toSet(), {
        'lat', 'lng', 'accuracy_m', 'speed_kmh',
        'heading_deg', 'leg', 'recorded_at', 'tracking_state',
      });
    });

    test('recorded_at serialises as UTC ISO-8601', () {
      final fix = LocationFix(
        lat: 1, lng: 1,
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
      );
      expect(fix.toJson()['recorded_at'], '2026-08-10T12:00:00.000Z');
    });

    test('a local DateTime is converted to UTC, not written as local', () {
      final local = DateTime(2026, 8, 10, 17, 30);
      final fix = LocationFix(lat: 1, lng: 1, recordedAt: local);
      expect(fix.toJson()['recorded_at'], local.toUtc().toIso8601String());
      expect((fix.toJson()['recorded_at'] as String).endsWith('Z'), isTrue);
    });

    test('defaults tracking_state to live', () {
      final fix = LocationFix(lat: 1, lng: 1, recordedAt: DateTime.utc(2026));
      expect(fix.toJson()['tracking_state'], 'live');
    });

    test('round-trips through fromJson for the disk buffer', () {
      final fix = LocationFix(
        lat: 23.0225, lng: 72.5714, accuracyM: 12.5, speedKmh: 54.0,
        headingDeg: 180.0, leg: 'ret',
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
        trackingState: 'paused',
      );
      final back = LocationFix.fromJson(fix.toJson());

      expect(back.lat, fix.lat);
      expect(back.lng, fix.lng);
      expect(back.accuracyM, fix.accuracyM);
      expect(back.speedKmh, fix.speedKmh);
      expect(back.headingDeg, fix.headingDeg);
      expect(back.leg, 'ret');
      expect(back.trackingState, 'paused');
      expect(back.recordedAt.toUtc(), fix.recordedAt.toUtc());
    });
  });

  group('BusPosition', () {
    BusPosition make({
      DateTime? recordedAt,
      double? speedKmh,
    }) => BusPosition.fromMap({
          'bus_id': 'bus-1',
          'tour_id': 'tour-1',
          'lat': 23.0,
          'lng': 72.0,
          'speed_kmh': speedKmh,
          'tracking_state': 'live',
          'recorded_at':
              (recordedAt ?? DateTime.now().toUtc()).toIso8601String(),
          'received_at': DateTime.now().toUtc().toIso8601String(),
        });

    test('parses a bus_live_positions row', () {
      final p = make();
      expect(p.busId, 'bus-1');
      expect(p.tourId, 'tour-1');
      expect(p.lat, 23.0);
      expect(p.lng, 72.0);
      expect(p.trackingState, 'live');
    });

    test('is not stale just after recording', () {
      expect(make().isStale, isFalse);
    });

    test('is stale past six minutes — three missed uploads', () {
      final old = DateTime.now().toUtc().subtract(const Duration(minutes: 7));
      expect(make(recordedAt: old).isStale, isTrue);
    });

    test('five minutes old is not yet stale', () {
      final recent = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      expect(make(recordedAt: recent).isStale, isFalse);
    });

    test('isMoving is false when parked and true on the highway', () {
      expect(make(speedKmh: 0).isMoving, isFalse);
      expect(make(speedKmh: 3).isMoving, isFalse);
      expect(make(speedKmh: 54).isMoving, isTrue);
    });

    test('tolerates null optional columns', () {
      final p = BusPosition.fromMap({
        'bus_id': 'b', 'tour_id': 't', 'lat': 1.0, 'lng': 2.0,
        'tracking_state': 'live',
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'received_at': DateTime.now().toUtc().toIso8601String(),
      });
      expect(p.accuracyM, isNull);
      expect(p.speedKmh, isNull);
      expect(p.headingDeg, isNull);
      expect(p.leg, isNull);
      expect(p.isMoving, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/models/bus_position_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:occubusbooking/models/bus_position.dart'`

- [ ] **Step 3: Write the models**

Create `lib/models/bus_position.dart`:

```dart
import 'package:geolocator/geolocator.dart';

/// One captured GPS sample — the unit of the handler's outbound buffer.
///
/// [toJson] emits exactly the keys `handler_push_locations` reads. Anything
/// else is ignored by the RPC, and a missing `recorded_at` makes the fix
/// undeliverable, so the key names here are load-bearing.
class LocationFix {
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedKmh;
  final double? headingDeg;

  /// `'go'` or `'ret'` — matching `attendance.leg`. NOT the
  /// `'outbound'`/`'return'` pair used by `tour_seat_snapshots`; migration 047
  /// documents that divergence as deliberate. Null is accepted by the RPC.
  final String? leg;

  final DateTime recordedAt;
  final String trackingState;

  const LocationFix({
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedKmh,
    this.headingDeg,
    this.leg,
    required this.recordedAt,
    this.trackingState = 'live',
  });

  /// Builds a fix from a geolocator sample.
  ///
  /// `Position.speed` is METRES PER SECOND; the column is km/h. A negative
  /// speed or heading means "unavailable" on both platforms, which becomes
  /// null rather than a bogus reading.
  factory LocationFix.fromPosition(
    Position p, {
    String? leg,
    String trackingState = 'live',
  }) {
    return LocationFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracyM: p.accuracy >= 0 ? p.accuracy : null,
      speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
      headingDeg: p.heading >= 0 ? p.heading : null,
      leg: leg,
      recordedAt: p.timestamp,
      trackingState: trackingState,
    );
  }

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
        'speed_kmh': speedKmh,
        'heading_deg': headingDeg,
        'leg': leg,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        'tracking_state': trackingState,
      };

  factory LocationFix.fromJson(Map<String, dynamic> json) => LocationFix(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
        speedKmh: (json['speed_kmh'] as num?)?.toDouble(),
        headingDeg: (json['heading_deg'] as num?)?.toDouble(),
        leg: json['leg'] as String?,
        recordedAt:
            DateTime.parse(json['recorded_at'].toString()).toUtc(),
        trackingState:
            (json['tracking_state'] as String?)?.isNotEmpty == true
                ? json['tracking_state'] as String
                : 'live',
      );
}

/// One row of `bus_live_positions` — a bus's current dot on the admin map.
class BusPosition {
  final String busId;
  final String tourId;
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedKmh;
  final double? headingDeg;
  final String? leg;
  final String trackingState;
  final DateTime recordedAt;
  final DateTime receivedAt;

  const BusPosition({
    required this.busId,
    required this.tourId,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedKmh,
    this.headingDeg,
    this.leg,
    required this.trackingState,
    required this.recordedAt,
    required this.receivedAt,
  });

  factory BusPosition.fromMap(Map<String, dynamic> map) => BusPosition(
        busId: (map['bus_id'] ?? '').toString(),
        tourId: (map['tour_id'] ?? '').toString(),
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        accuracyM: (map['accuracy_m'] as num?)?.toDouble(),
        speedKmh: (map['speed_kmh'] as num?)?.toDouble(),
        headingDeg: (map['heading_deg'] as num?)?.toDouble(),
        leg: map['leg'] as String?,
        trackingState: (map['tracking_state'] as String?) ?? 'live',
        recordedAt: _parseUtc(map['recorded_at']),
        receivedAt: _parseUtc(map['received_at']),
      );

  static DateTime _parseUtc(dynamic v) {
    if (v is DateTime) return v.toUtc();
    return DateTime.tryParse(v?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
  }

  Duration get staleness => DateTime.now().toUtc().difference(recordedAt);

  /// Three missed 2-minute uploads. Below this a quiet bus is simply parked;
  /// above it, assume the handler's phone stopped reporting.
  bool get isStale => staleness > const Duration(minutes: 6);

  /// 5 km/h filters out GPS jitter around a stationary vehicle.
  bool get isMoving => (speedKmh ?? 0) > 5;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/models/bus_position_test.dart`
Expected: PASS — 11 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/models/bus_position.dart test/models/bus_position_test.dart
git commit -m "feat(location): LocationFix and BusPosition models"
```

---

### Task 3: Translation keys

**Files:**
- Modify: `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json`

**Interfaces:**
- Consumes: nothing
- Produces: the `tracking.*` key namespace used by Tasks 6, 7, 8, 10.

- [ ] **Step 1: Add the English keys**

Add a top-level `"tracking"` object to `assets/translations/en.json`:

```json
  "tracking": {
    "notification_title": "Sharing bus location",
    "notification_text": "Your tour operator can see where the bus is while the trip is running.",
    "card_live": "Sharing location",
    "card_updated_ago": "updated {n}",
    "card_starting": "Starting location sharing…",
    "card_denied_title": "Location permission needed",
    "card_denied_body": "Without it the office cannot see where your bus is.",
    "card_denied_cta": "Allow location",
    "card_settings_cta": "Open settings",
    "card_service_off_title": "Location is switched off",
    "card_service_off_body": "Turn on location so the office can follow the bus.",
    "card_service_off_cta": "Turn on location",
    "card_foreground_only": "Sharing only while this screen is open",
    "card_window_closed": "Trip finished — sharing stopped",
    "card_unavailable": "Sharing unavailable",
    "card_stop": "Stop sharing",
    "rationale_title": "Share this bus's location",
    "rationale_body": "While the trip is running, this app sends the bus's position to your tour operator so they can answer passengers asking where the bus is.\n\nIt collects only the bus position — never your calls, messages or contacts. It starts when the trip is locked and stops on its own when the trip is marked complete. You can stop it any time from the notification or this screen.",
    "rationale_continue": "Continue",
    "rationale_not_now": "Not now",
    "map_title": "Live map",
    "map_open": "Live map",
    "map_empty_title": "No bus has shared its location yet",
    "map_empty_body": "A bus appears here once its handler opens the trip on their phone.",
    "map_last_seen": "Last seen {n}",
    "map_moving": "{n} km/h",
    "map_parked": "Parked",
    "map_stale": "Not reporting"
  }
```

- [ ] **Step 2: Add the Gujarati keys**

Add to `assets/translations/gu.json`. Gujarati is the default locale — every key must be present or handlers see English:

```json
  "tracking": {
    "notification_title": "બસનું લોકેશન શેર થાય છે",
    "notification_text": "ટ્રીપ ચાલુ હોય ત્યાં સુધી તમારા ટૂર ઓપરેટર બસ ક્યાં છે તે જોઈ શકે છે.",
    "card_live": "લોકેશન શેર થાય છે",
    "card_updated_ago": "{n} પહેલાં અપડેટ",
    "card_starting": "લોકેશન શેર કરવાનું શરૂ થાય છે…",
    "card_denied_title": "લોકેશનની પરવાનગી જોઈએ",
    "card_denied_body": "તેના વગર ઓફિસ તમારી બસ ક્યાં છે તે જોઈ શકશે નહીં.",
    "card_denied_cta": "લોકેશન ચાલુ કરો",
    "card_settings_cta": "સેટિંગ્સ ખોલો",
    "card_service_off_title": "લોકેશન બંધ છે",
    "card_service_off_body": "લોકેશન ચાલુ કરો જેથી ઓફિસ બસ પર નજર રાખી શકે.",
    "card_service_off_cta": "લોકેશન ચાલુ કરો",
    "card_foreground_only": "ફક્ત આ સ્ક્રીન ખુલ્લી હોય ત્યારે શેર થાય છે",
    "card_window_closed": "ટ્રીપ પૂરી થઈ — શેર કરવાનું બંધ",
    "card_unavailable": "શેર કરવાનું ઉપલબ્ધ નથી",
    "card_stop": "શેર કરવાનું બંધ કરો",
    "rationale_title": "આ બસનું લોકેશન શેર કરો",
    "rationale_body": "ટ્રીપ ચાલુ હોય ત્યારે આ એપ બસનું લોકેશન તમારા ટૂર ઓપરેટરને મોકલે છે, જેથી મુસાફરો બસ ક્યાં છે તે પૂછે ત્યારે તેઓ જવાબ આપી શકે.\n\nફક્ત બસનું લોકેશન લેવાય છે — તમારા કોલ, મેસેજ કે સંપર્કો ક્યારેય નહીં. ટ્રીપ લોક થાય ત્યારે શરૂ થાય છે અને ટ્રીપ પૂરી થતાં જાતે બંધ થાય છે. તમે નોટિફિકેશન કે આ સ્ક્રીન પરથી ગમે ત્યારે બંધ કરી શકો છો.",
    "rationale_continue": "આગળ વધો",
    "rationale_not_now": "હમણાં નહીં",
    "map_title": "લાઇવ નકશો",
    "map_open": "લાઇવ નકશો",
    "map_empty_title": "હજી કોઈ બસે લોકેશન શેર કર્યું નથી",
    "map_empty_body": "હેન્ડલર પોતાના ફોનમાં ટ્રીપ ખોલે પછી બસ અહીં દેખાશે.",
    "map_last_seen": "છેલ્લે {n}",
    "map_moving": "{n} કિમી/કલાક",
    "map_parked": "ઊભી છે",
    "map_stale": "રિપોર્ટ થતું નથી"
  }
```

- [ ] **Step 3: Add the Hindi keys**

Add to `assets/translations/hi.json`:

```json
  "tracking": {
    "notification_title": "बस की लोकेशन साझा हो रही है",
    "notification_text": "ट्रिप चलने तक आपका टूर ऑपरेटर देख सकता है कि बस कहाँ है।",
    "card_live": "लोकेशन साझा हो रही है",
    "card_updated_ago": "{n} पहले अपडेट",
    "card_starting": "लोकेशन साझा करना शुरू हो रहा है…",
    "card_denied_title": "लोकेशन की अनुमति चाहिए",
    "card_denied_body": "इसके बिना ऑफ़िस यह नहीं देख पाएगा कि आपकी बस कहाँ है।",
    "card_denied_cta": "लोकेशन चालू करें",
    "card_settings_cta": "सेटिंग्स खोलें",
    "card_service_off_title": "लोकेशन बंद है",
    "card_service_off_body": "लोकेशन चालू करें ताकि ऑफ़िस बस पर नज़र रख सके।",
    "card_service_off_cta": "लोकेशन चालू करें",
    "card_foreground_only": "सिर्फ़ यह स्क्रीन खुली होने पर साझा होगी",
    "card_window_closed": "ट्रिप पूरी हुई — साझा करना बंद",
    "card_unavailable": "साझा करना उपलब्ध नहीं",
    "card_stop": "साझा करना बंद करें",
    "rationale_title": "इस बस की लोकेशन साझा करें",
    "rationale_body": "ट्रिप चलने के दौरान यह ऐप बस की लोकेशन आपके टूर ऑपरेटर को भेजता है, ताकि यात्रियों के पूछने पर वे बता सकें कि बस कहाँ है।\n\nसिर्फ़ बस की लोकेशन ली जाती है — आपके कॉल, संदेश या संपर्क कभी नहीं। यह ट्रिप लॉक होने पर शुरू होती है और ट्रिप पूरी होते ही अपने आप बंद हो जाती है। आप नोटिफ़िकेशन या इस स्क्रीन से कभी भी बंद कर सकते हैं।",
    "rationale_continue": "आगे बढ़ें",
    "rationale_not_now": "अभी नहीं",
    "map_title": "लाइव मैप",
    "map_open": "लाइव मैप",
    "map_empty_title": "अभी किसी बस ने लोकेशन साझा नहीं की",
    "map_empty_body": "हैंडलर अपने फ़ोन पर ट्रिप खोलेगा तो बस यहाँ दिखेगी।",
    "map_last_seen": "आख़िरी बार {n}",
    "map_moving": "{n} किमी/घंटा",
    "map_parked": "खड़ी है",
    "map_stale": "रिपोर्ट नहीं हो रही"
  }
```

- [ ] **Step 4: Verify all three files parse and have identical key sets**

Run:

```bash
cd "c:/WorkSpace/ugam-bus-booking" && python -c "
import json
ks = {}
for l in ['en','gu','hi']:
    d = json.load(open(f'assets/translations/{l}.json', encoding='utf-8'))
    ks[l] = set(d['tracking'].keys())
assert ks['en'] == ks['gu'] == ks['hi'], (ks['en']^ks['gu'], ks['en']^ks['hi'])
print('all three parse; tracking keys identical:', len(ks['en']))
"
```

Expected: `all three parse; tracking keys identical: 26`

- [ ] **Step 5: Commit**

```bash
git add assets/translations/en.json assets/translations/gu.json assets/translations/hi.json
git commit -m "feat(location): tracking.* translation keys for en/gu/hi"
```

---

### Task 4: The fix buffer

**Files:**
- Create: `lib/services/location_fix_buffer.dart`
- Test: `test/services/location_fix_buffer_test.dart`

**Interfaces:**
- Consumes: `LocationFix` from Task 2
- Produces: `class LocationFixBuffer` with `LocationFixBuffer({required String busId, int maxFixes = 2000})`, `int get length`, `List<LocationFix> get fixes`, `Future<void> add(LocationFix)`, `List<LocationFix> take(int n)`, `Future<void> drop(int n)`, `Future<void> clear()`, `Future<void> rehydrate()`

Extracted from the tracker service so the durability rules are testable without GPS, GetX, or a network.

- [ ] **Step 1: Write the failing tests**

Create `test/services/location_fix_buffer_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/location_fix_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocationFix fixAt(int minute) => LocationFix(
      lat: 23.0 + minute / 1000,
      lng: 72.0,
      recordedAt: DateTime.utc(2026, 8, 10, 12, minute),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('LocationFixBuffer', () {
    test('starts empty', () {
      expect(LocationFixBuffer(busId: 'b1').length, 0);
    });

    test('add appends in order', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.add(fixAt(2));
      expect(b.length, 2);
      expect(b.fixes.first.recordedAt, fixAt(1).recordedAt);
    });

    test('drops the OLDEST on overflow, keeping the newest', () async {
      final b = LocationFixBuffer(busId: 'b1', maxFixes: 3);
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      expect(b.length, 3);
      expect(b.fixes.first.recordedAt, fixAt(3).recordedAt);
      expect(b.fixes.last.recordedAt, fixAt(5).recordedAt);
    });

    test('take peeks the oldest n without removing them', () async {
      final b = LocationFixBuffer(busId: 'b1');
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      final batch = b.take(2);
      expect(batch.length, 2);
      expect(batch.first.recordedAt, fixAt(1).recordedAt);
      expect(b.length, 5, reason: 'take must not mutate');
    });

    test('take clamps to what is available', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      expect(b.take(500).length, 1);
    });

    test('drop removes the oldest n', () async {
      final b = LocationFixBuffer(busId: 'b1');
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      await b.drop(2);
      expect(b.length, 3);
      expect(b.fixes.first.recordedAt, fixAt(3).recordedAt);
    });

    test('drop past the end empties rather than throwing', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.drop(99);
      expect(b.length, 0);
    });

    test('survives process death — rehydrate restores fixes', () async {
      final first = LocationFixBuffer(busId: 'b1');
      await first.add(fixAt(1));
      await first.add(fixAt(2));

      final second = LocationFixBuffer(busId: 'b1');
      await second.rehydrate();
      expect(second.length, 2);
      expect(second.fixes.first.recordedAt, fixAt(1).recordedAt);
    });

    test('buffers are scoped per bus', () async {
      final a = LocationFixBuffer(busId: 'bus-a');
      await a.add(fixAt(1));

      final b = LocationFixBuffer(busId: 'bus-b');
      await b.rehydrate();
      expect(b.length, 0);
    });

    test('clear wipes memory and disk', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.clear();

      final reloaded = LocationFixBuffer(busId: 'b1');
      await reloaded.rehydrate();
      expect(reloaded.length, 0);
    });

    test('a corrupt disk entry is skipped, not fatal', () async {
      SharedPreferences.setMockInitialValues({
        'loc_buffer_b1': ['{not json', fixAt(1).toJson().toString()],
      });
      final b = LocationFixBuffer(busId: 'b1');
      await b.rehydrate();
      expect(b.length, 0, reason: 'unparseable entries drop silently');
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_fix_buffer_test.dart`
Expected: FAIL — `location_fix_buffer.dart` does not exist.

- [ ] **Step 3: Implement the buffer**

Create `lib/services/location_fix_buffer.dart`:

```dart
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/bus_position.dart';

/// The handler's outbound queue of GPS fixes: an in-memory list mirrored to
/// SharedPreferences after every mutation.
///
/// WHY DISK. A handler drives through dead zones, and Android's battery saver
/// will kill a backgrounded app. An in-memory-only queue would lose the trail
/// in both cases — exactly the situations the trail is most wanted for.
///
/// WHY OLDEST-OUT ON OVERFLOW. This is the opposite of `ErrorReporter`'s
/// newest-out rule, and deliberately so: in a crash cascade the first error is
/// the informative one, but in a position trail the newest fix is the only one
/// that can still move the map. Position data ages into worthlessness.
class LocationFixBuffer {
  LocationFixBuffer({required this.busId, this.maxFixes = 2000});

  final String busId;

  /// ~16 h at one fix per 30 s. Bounds both the disk footprint and the worst
  /// case flush size after a very long offline stretch.
  final int maxFixes;

  final List<LocationFix> _fixes = <LocationFix>[];

  String get _key => 'loc_buffer_$busId';

  int get length => _fixes.length;
  List<LocationFix> get fixes => List.unmodifiable(_fixes);

  Future<void> add(LocationFix fix) async {
    _fixes.add(fix);
    if (_fixes.length > maxFixes) {
      _fixes.removeRange(0, _fixes.length - maxFixes);
    }
    await _persist();
  }

  /// The oldest [n] fixes, WITHOUT removing them. They are removed by [drop]
  /// only once the RPC has returned, so a thrown call leaves the queue intact.
  List<LocationFix> take(int n) =>
      _fixes.take(n < 0 ? 0 : n).toList(growable: false);

  Future<void> drop(int n) async {
    if (n <= 0) return;
    _fixes.removeRange(0, n > _fixes.length ? _fixes.length : n);
    await _persist();
  }

  Future<void> clear() async {
    _fixes.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Losing the mirror is survivable; memory is already clear.
    }
  }

  /// Reloads from disk, replacing whatever is in memory. Call once on start.
  Future<void> rehydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? const <String>[];
      _fixes
        ..clear()
        ..addAll(raw.map(_decode).whereType<LocationFix>());
      if (_fixes.length > maxFixes) {
        _fixes.removeRange(0, _fixes.length - maxFixes);
      }
    } catch (_) {
      _fixes.clear();
    }
  }

  /// A single malformed entry must not cost the whole trail — the same
  /// reasoning as 047's poison-pill guard on the server side.
  static LocationFix? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return LocationFix.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _key,
        _fixes.map((f) => jsonEncode(f.toJson())).toList(growable: false),
      );
    } catch (_) {
      // Disk full or prefs unavailable: keep going on memory alone rather
      // than dropping a fix that could still be uploaded this session.
    }
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_fix_buffer_test.dart`
Expected: PASS — 11 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/services/location_fix_buffer.dart test/services/location_fix_buffer_test.dart
git commit -m "feat(location): disk-backed fix buffer with oldest-out overflow"
```

---

### Task 5: The tracker service

**Files:**
- Create: `lib/services/location_tracker_service.dart`
- Test: `test/services/location_tracker_service_test.dart`

**Interfaces:**
- Consumes: `LocationFix` (Task 2), `LocationFixBuffer` (Task 4), `isRetryable` from `lib/services/sync_retry_policy.dart`, `ErrorReporter.report` from `lib/services/error_reporter.dart`
- Produces:
  - `enum TrackingStatus { idle, awaitingPermission, denied, deniedForever, serviceDisabled, live, foregroundOnly, windowClosed, forbidden }`
  - `typedef LocationPusher = Future<Map<String, dynamic>> Function(String requestId, String busId, List<Map<String, dynamic>> fixes)`
  - `class LocationTrackerService extends GetxService` with `Rx<TrackingStatus> status`, `Rxn<DateTime> lastUploadAt`, `Future<void> start({required String requestId, required String busId, String? leg})`, `Future<void> stop()`, `Future<void> flushNow()`, `Duration get currentBackoff`, and `@visibleForTesting LocationPusher? pusher`

This task covers buffer→RPC logic only. GPS stream wiring lands in Task 6 so the upload contract can be tested without a device.

- [ ] **Step 1: Write the failing tests**

Create `test/services/location_tracker_service_test.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocationFix fixAt(int minute) => LocationFix(
      lat: 23.0 + minute / 1000,
      lng: 72.0,
      recordedAt: DateTime.utc(2026, 8, 10, 12, minute),
    );

/// Records every batch handed to the RPC and replies with a scripted result.
class FakePusher {
  FakePusher(this.reply);
  final Map<String, dynamic> Function(List<Map<String, dynamic>> fixes) reply;
  final List<List<Map<String, dynamic>>> calls = [];

  Future<Map<String, dynamic>> call(
    String requestId,
    String busId,
    List<Map<String, dynamic>> fixes,
  ) async {
    calls.add(fixes);
    return reply(fixes);
  }
}

Map<String, dynamic> accepted(List<Map<String, dynamic>> f) =>
    {'accepted': f.length, 'skipped': 0};

void main() {
  late LocationTrackerService svc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    svc = LocationTrackerService();
  });

  Future<void> seed(int n) async {
    for (var i = 1; i <= n; i++) {
      await svc.debugAddFix(fixAt(i));
    }
  }

  group('flush — success path', () {
    test('sends buffered fixes and empties the buffer', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await svc.flushNow();

      expect(fake.calls.first.length, 3);
      expect(svc.debugBufferLength, 0);
    });

    test('drops the whole batch even when the server skipped some', () async {
      final fake = FakePusher((f) => {'accepted': 1, 'skipped': f.length - 1});
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(4);

      await svc.flushNow();

      expect(svc.debugBufferLength, 0,
          reason: 'skipped fixes are invalid or already stored — never resend');
    });

    test('caps each call at 500 and loops until drained', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1200);

      await svc.flushNow();

      expect(fake.calls.map((c) => c.length).toList(), [500, 500, 200]);
      expect(svc.debugBufferLength, 0);
    });

    test('records the upload time for the status card', () async {
      svc.pusher = FakePusher(accepted).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      expect(svc.lastUploadAt.value, isNull);
      await svc.flushNow();
      expect(svc.lastUploadAt.value, isNotNull);
    });

    test('sends fixes in the RPC key shape', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      await svc.flushNow();

      expect(fake.calls.first.first.keys.toSet(), {
        'lat', 'lng', 'accuracy_m', 'speed_kmh',
        'heading_deg', 'leg', 'recorded_at', 'tracking_state',
      });
    });
  });

  group('flush — server refusals arrive as data, not throws', () {
    test('window_closed stops tracking and clears the buffer', () async {
      svc.pusher = FakePusher((_) => {'error': 'window_closed'}).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(5);

      await svc.flushNow();

      expect(svc.status.value, TrackingStatus.windowClosed);
      expect(svc.debugBufferLength, 0);
    });

    test('forbidden stops tracking and clears the buffer', () async {
      svc.pusher = FakePusher((_) => {'error': 'forbidden'}).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(5);

      await svc.flushNow();

      expect(svc.status.value, TrackingStatus.forbidden);
      expect(svc.debugBufferLength, 0);
    });

    test('bad_payload drops the batch instead of retrying forever', () async {
      var calls = 0;
      svc.pusher = (_, __, ___) async {
        calls++;
        return {'error': 'bad_payload'};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await svc.flushNow();

      expect(svc.debugBufferLength, 0);
      expect(calls, 1);
      expect(svc.status.value, TrackingStatus.live,
          reason: 'a client bug must not look like a permission failure');
    });
  });

  group('flush — thrown errors preserve the buffer', () {
    test('a retryable failure keeps fixes and escalates backoff', () async {
      svc.pusher = (_, __, ___) async =>
          throw const SocketException('no route to host');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      expect(svc.currentBackoff, const Duration(minutes: 2));
      await svc.flushNow();

      expect(svc.debugBufferLength, 3, reason: 'nothing confirmed — keep it');
      expect(svc.currentBackoff, const Duration(minutes: 4));
    });

    test('backoff escalates 2-4-8-16 and then caps', () async {
      svc.pusher = (_, __, ___) async => throw const SocketException('down');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      final seen = <int>[];
      for (var i = 0; i < 5; i++) {
        await svc.flushNow();
        seen.add(svc.currentBackoff.inMinutes);
      }
      expect(seen, [4, 8, 16, 16, 16]);
    });

    test('a success resets backoff to the floor', () async {
      var fail = true;
      svc.pusher = (_, __, f) async {
        if (fail) throw const SocketException('down');
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      await svc.flushNow();
      expect(svc.currentBackoff, const Duration(minutes: 4));

      fail = false;
      await svc.flushNow();
      expect(svc.currentBackoff, const Duration(minutes: 2));
    });

    test('a terminal failure keeps the buffer and does not escalate', () async {
      svc.pusher = (_, __, ___) async => throw ArgumentError('client bug');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);

      await svc.flushNow();

      expect(svc.debugBufferLength, 2);
      expect(svc.currentBackoff, const Duration(minutes: 2),
          reason: 'no retry storm against an error retrying cannot fix');
    });
  });

  group('concurrency and lifecycle', () {
    test('overlapping flushes do not double-send', () async {
      var calls = 0;
      svc.pusher = (_, __, f) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await Future.wait([svc.flushNow(), svc.flushNow()]);
      expect(calls, 1);
    });

    test('flush is a no-op before start', () async {
      var calls = 0;
      svc.pusher = (_, __, ___) async {
        calls++;
        return {'accepted': 0, 'skipped': 0};
      };
      await svc.flushNow();
      expect(calls, 0);
    });

    test('stop clears status back to idle', () async {
      svc.pusher = FakePusher(accepted).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await svc.stop();
      expect(svc.status.value, TrackingStatus.idle);
    });

    test('a stopped tracker refuses further flushes', () async {
      var calls = 0;
      svc.pusher = (_, __, f) async {
        calls++;
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);
      await svc.stop();

      await svc.flushNow();
      expect(calls, 0);
    });
  });

  group('buffered fixes survive a restart', () {
    test('rehydrates the previous session and uploads it', () async {
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);

      final revived = LocationTrackerService();
      final fake = FakePusher(accepted);
      revived.pusher = fake.call;
      await revived.debugAttach(requestId: 'r1', busId: 'b1');

      await revived.flushNow();
      expect(fake.calls.first.length, 2);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_tracker_service_test.dart`
Expected: FAIL — `location_tracker_service.dart` does not exist.

- [ ] **Step 3: Implement the service**

Create `lib/services/location_tracker_service.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_position.dart';
import 'error_reporter.dart';
import 'location_fix_buffer.dart';
import 'sync_retry_policy.dart';

/// Where the handler's sharing currently stands. Drives the status card 1:1.
enum TrackingStatus {
  idle,
  awaitingPermission,
  denied,
  deniedForever,
  serviceDisabled,

  /// Streaming and uploading, including with the screen off.
  live,

  /// Permission is "while in use" only — real tracking, but it dies the moment
  /// the handler leaves the app. Told plainly rather than dressed up as live.
  foregroundOnly,

  windowClosed,
  forbidden,
}

/// Test seam for `handler_push_locations`. Production leaves it null.
typedef LocationPusher = Future<Map<String, dynamic>> Function(
  String requestId,
  String busId,
  List<Map<String, dynamic>> fixes,
);

/// Owns the handler's outbound location pipeline: buffer → RPC.
///
/// GPS capture is attached separately (see `startStream` in the chart screen
/// wiring) so this half can be tested without a device.
///
/// THE ONE RULE THAT MATTERS. `handler_push_locations` reports refusals as
/// DATA (`{"error": "forbidden"}`), never as a throw. So:
///   * a call that RETURNS consumes its whole batch — `skipped` fixes are
///     either invalid or already stored, and resending them never helps;
///   * a call that THROWS preserves the buffer for retry.
/// Inverting this produces a queue that never drains.
class LocationTrackerService extends GetxService {
  static const int _maxPerCall = 500;   // server-enforced in 047
  static const Duration _minBackoff = Duration(minutes: 2);
  static const Duration _maxBackoff = Duration(minutes: 16);

  final Rx<TrackingStatus> status = TrackingStatus.idle.obs;
  final Rxn<DateTime> lastUploadAt = Rxn<DateTime>();

  @visibleForTesting
  LocationPusher? pusher;

  String? _requestId;
  String? _busId;
  String? _leg;
  LocationFixBuffer? _buffer;
  bool _flushing = false;
  Duration _backoff = _minBackoff;

  Duration get currentBackoff => _backoff;

  /// True once the tracker has been attached to a bus and not stopped.
  bool get _attached => _requestId != null && _busId != null;

  // ── test helpers ──────────────────────────────────────────

  @visibleForTesting
  int get debugBufferLength => _buffer?.length ?? 0;

  @visibleForTesting
  Future<void> debugAddFix(LocationFix fix) async => _buffer?.add(fix);

  /// Attaches to a bus and rehydrates its buffer WITHOUT touching GPS.
  /// Production calls [start], which does this and then opens the stream.
  @visibleForTesting
  Future<void> debugAttach({
    required String requestId,
    required String busId,
    String? leg,
  }) async {
    _requestId = requestId;
    _busId = busId;
    _leg = leg;
    _buffer = LocationFixBuffer(busId: busId);
    await _buffer!.rehydrate();
    _backoff = _minBackoff;
    status.value = TrackingStatus.live;
  }

  // ── lifecycle ─────────────────────────────────────────────

  /// Attaches to [busId] and restores anything the last session left behind.
  /// The caller opens the GPS stream once this resolves.
  Future<void> start({
    required String requestId,
    required String busId,
    String? leg,
  }) async {
    _requestId = requestId;
    _busId = busId;
    _leg = leg;
    _buffer = LocationFixBuffer(busId: busId);
    await _buffer!.rehydrate();
    _backoff = _minBackoff;
    status.value = TrackingStatus.live;
    // Anything buffered through a dead zone or a kill goes out immediately.
    if (_buffer!.length > 0) await flushNow();
  }

  Future<void> stop() async {
    _requestId = null;
    _busId = null;
    _leg = null;
    _buffer = null;
    _backoff = _minBackoff;
    status.value = TrackingStatus.idle;
  }

  /// The leg stamped on newly captured fixes.
  set leg(String? value) => _leg = value;
  String? get leg => _leg;

  /// Queues one captured sample.
  Future<void> record(LocationFix fix) async {
    if (!_attached) return;
    await _buffer!.add(fix);
  }

  // ── upload ────────────────────────────────────────────────

  Future<void> flushNow() async {
    if (!_attached || _buffer == null) return;
    if (_flushing) return;
    _flushing = true;
    try {
      while (_buffer!.length > 0) {
        final batch = _buffer!.take(_maxPerCall);
        final Map<String, dynamic> result;
        try {
          result = await _send(batch);
        } catch (e, st) {
          // THROWN: nothing confirmed. Keep the buffer.
          if (isRetryable(e, retryOnTimeout: true)) {
            _escalateBackoff();
          } else {
            ErrorReporter.report(
              kind: 'location_push',
              error: e,
              stack: st,
              context: {'bus_id': _busId, 'batch': batch.length},
            );
          }
          return;
        }

        // RETURNED: the batch is spent, whatever it says.
        final error = result['error'] as String?;

        if (error == 'window_closed') {
          await _stopAndClear(TrackingStatus.windowClosed);
          return;
        }
        if (error == 'forbidden') {
          await _stopAndClear(TrackingStatus.forbidden);
          return;
        }
        if (error == 'bad_payload') {
          // A client-side bug. Retrying a poison batch would block every
          // later fix behind it forever, so drop it and keep going.
          await _buffer!.drop(batch.length);
          ErrorReporter.report(
            kind: 'location_bad_payload',
            error: StateError('handler_push_locations rejected a batch'),
            context: {'bus_id': _busId, 'batch': batch.length},
          );
          continue;
        }

        await _buffer!.drop(batch.length);
        lastUploadAt.value = DateTime.now();
        _backoff = _minBackoff;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<Map<String, dynamic>> _send(List<LocationFix> batch) async {
    final payload = batch.map((f) => f.toJson()).toList(growable: false);
    final push = pusher;
    if (push != null) return push(_requestId!, _busId!, payload);

    final raw = await Supabase.instance.client.rpc(
      'handler_push_locations',
      params: {
        'p_request_id': _requestId,
        'p_bus_id': _busId,
        'p_fixes': payload,
      },
    );
    return raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw as Map);
  }

  Future<void> _stopAndClear(TrackingStatus next) async {
    await _buffer?.clear();
    _requestId = null;
    _busId = null;
    _buffer = null;
    _backoff = _minBackoff;
    status.value = next;
  }

  void _escalateBackoff() {
    final doubled = _backoff * 2;
    _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_tracker_service_test.dart`
Expected: PASS — 17 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/services/location_tracker_service.dart test/services/location_tracker_service_test.dart
git commit -m "feat(location): tracker service — batching, refusals, backoff"
```

---

### Task 6: GPS capture, permissions, and the rationale sheet

**Files:**
- Modify: `lib/services/location_tracker_service.dart`
- Create: `lib/widgets/location_rationale_sheet.dart`
- Test: `test/services/location_permission_flow_test.dart`

**Interfaces:**
- Consumes: `TrackingStatus`, `LocationTrackerService` (Task 5); `tracking.*` keys (Task 3)
- Produces:
  - `TrackingStatus resolveTrackingStatus({required bool serviceEnabled, required LocationPermission permission})` — pure, exported from `location_tracker_service.dart`
  - `LocationSettings buildLocationSettings({required bool isAndroid, required String notificationTitle, required String notificationText})` — pure, same file
  - `Future<bool> showLocationRationale(BuildContext)` in `location_rationale_sheet.dart`
  - `LocationTrackerService.startStream()` / `stopStream()`

The decision logic is extracted as pure functions so it is testable; only the thin plugin calls stay untested.

- [ ] **Step 1: Write the failing tests**

Create `test/services/location_permission_flow_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';

void main() {
  group('resolveTrackingStatus', () {
    test('OS location switch off beats any permission state', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: false,
          permission: LocationPermission.always,
        ),
        TrackingStatus.serviceDisabled,
      );
    });

    test('always means fully live', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.always,
        ),
        TrackingStatus.live,
      );
    });

    test('whileInUse is honest about being foreground-only', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.whileInUse,
        ),
        TrackingStatus.foregroundOnly,
      );
    });

    test('denied is recoverable, deniedForever is not', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.denied,
        ),
        TrackingStatus.denied,
      );
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.deniedForever,
        ),
        TrackingStatus.deniedForever,
      );
    });

    test('unableToDetermine is treated as denied, never as live', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.unableToDetermine,
        ),
        TrackingStatus.denied,
      );
    });
  });

  group('buildLocationSettings', () {
    test('Android carries the foreground-service notification', () {
      final s = buildLocationSettings(
        isAndroid: true,
        notificationTitle: 'T',
        notificationText: 'B',
      ) as AndroidSettings;

      expect(s.foregroundNotificationConfig, isNotNull);
      expect(s.foregroundNotificationConfig!.notificationTitle, 'T');
      expect(s.foregroundNotificationConfig!.enableWakeLock, isTrue);
      expect(s.distanceFilter, 50);
      expect(s.intervalDuration, const Duration(seconds: 30));
    });

    test('iOS enables background updates and never auto-pauses', () {
      final s = buildLocationSettings(
        isAndroid: false,
        notificationTitle: 'T',
        notificationText: 'B',
      ) as AppleSettings;

      expect(s.allowBackgroundLocationUpdates, isTrue);
      expect(s.showBackgroundLocationIndicator, isTrue);
      expect(s.pauseLocationUpdatesAutomatically, isFalse,
          reason: 'a bus parked at a dhaba must still report');
      expect(s.activityType, ActivityType.automotiveNavigation);
      expect(s.distanceFilter, 50);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_permission_flow_test.dart`
Expected: FAIL — `resolveTrackingStatus` / `buildLocationSettings` undefined.

- [ ] **Step 3: Add the pure decision functions**

Append to `lib/services/location_tracker_service.dart` (and add the imports
`package:geolocator/geolocator.dart`, `package:geolocator_android/geolocator_android.dart`,
`package:geolocator_apple/geolocator_apple.dart` at the top):

```dart
/// Maps the OS's two independent signals onto one card state.
///
/// Service-enabled is checked FIRST: with the system location switch off,
/// permission is irrelevant and telling the handler to grant permission would
/// send them to the wrong settings screen.
TrackingStatus resolveTrackingStatus({
  required bool serviceEnabled,
  required LocationPermission permission,
}) {
  if (!serviceEnabled) return TrackingStatus.serviceDisabled;
  return switch (permission) {
    LocationPermission.always => TrackingStatus.live,
    LocationPermission.whileInUse => TrackingStatus.foregroundOnly,
    LocationPermission.deniedForever => TrackingStatus.deniedForever,
    // `unableToDetermine` must never be optimistic — treat it as denied.
    _ => TrackingStatus.denied,
  };
}

/// 30 s / 50 m on both platforms.
///
/// iOS honours only `distanceFilter` (there is no interval), which is why the
/// tracker also emits a heartbeat when a flush finds nothing buffered —
/// otherwise a parked bus would be indistinguishable from a dead phone.
LocationSettings buildLocationSettings({
  required bool isAndroid,
  required String notificationTitle,
  required String notificationText,
}) {
  if (isAndroid) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 50,
      intervalDuration: const Duration(seconds: 30),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        enableWakeLock: true,
      ),
    );
  }
  return AppleSettings(
    accuracy: LocationAccuracy.high,
    activityType: ActivityType.automotiveNavigation,
    distanceFilter: 50,
    // A bus idling at a dhaba is exactly when the office looks at the map.
    pauseLocationUpdatesAutomatically: false,
    showBackgroundLocationIndicator: true,
    allowBackgroundLocationUpdates: true,
  );
}
```

- [ ] **Step 4: Run to verify pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/location_permission_flow_test.dart`
Expected: PASS — 7 tests.

- [ ] **Step 5: Add stream, timers, and heartbeat to the service**

Add these members to `LocationTrackerService` (imports: `dart:io show Platform`, `package:connectivity_plus/connectivity_plus.dart`, `package:easy_localization/easy_localization.dart`):

```dart
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _flushTimer;

  /// Opens the GPS stream and the 2-minute flush timer. Call after [start]
  /// once permission has been resolved to live or foregroundOnly.
  void startStream() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: buildLocationSettings(
        isAndroid: Platform.isAndroid,
        notificationTitle: tr('tracking.notification_title'),
        notificationText: tr('tracking.notification_text'),
      ),
    ).listen(
      (p) => record(LocationFix.fromPosition(p, leg: _leg)),
      onError: (Object e, StackTrace st) {
        ErrorReporter.report(kind: 'location_stream', error: e, stack: st);
      },
    );

    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(_tick());
    });

    // A dead zone ends the moment the radio comes back — flush then, rather
    // than waiting out the remainder of the backoff.
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) unawaited(flushNow());
    });
  }

  Future<void> stopStream() async {
    await _positionSub?.cancel();
    await _connSub?.cancel();
    _flushTimer?.cancel();
    _positionSub = null;
    _connSub = null;
    _flushTimer = null;
  }

  /// One scheduled cycle: respect backoff, then flush — or heartbeat if the
  /// distance filter has kept the buffer empty.
  Future<void> _tick() async {
    if (!_attached) return;
    final since = lastUploadAt.value;
    if (_backoff > _minBackoff &&
        since != null &&
        DateTime.now().difference(since) < _backoff) {
      return;
    }
    if (_buffer!.length == 0) {
      await _heartbeat();
    }
    await flushNow();
  }

  /// A 50 m distance filter means a stationary bus emits nothing, leaving the
  /// admin unable to tell "parked" from "app died". One last-known fix per
  /// cycle keeps `recorded_at` moving (~30 rows/hour idle).
  Future<void> _heartbeat() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return;
      await record(LocationFix(
        lat: last.latitude,
        lng: last.longitude,
        accuracyM: last.accuracy >= 0 ? last.accuracy : null,
        speedKmh: 0,
        headingDeg: last.heading >= 0 ? last.heading : null,
        leg: _leg,
        // NOW, not the stale fix's own timestamp — the point is to prove the
        // handler's phone is still reporting.
        recordedAt: DateTime.now().toUtc(),
      ));
    } catch (_) {
      // No last-known fix yet. Nothing to prove; skip this cycle.
    }
  }
```

Extend `stop()` and `_stopAndClear()` to call `await stopStream();` first.

- [ ] **Step 6: Build the rationale sheet**

Create `lib/widgets/location_rationale_sheet.dart`:

```dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// Play policy requires a plain-language disclosure BEFORE the OS prompt for
/// background location: what is collected, who sees it, when it stops, how to
/// stop it early. Shown once ever (the caller owns the seen-flag), and
/// dismissible — the chart stays usable if the handler declines.
///
/// Returns true if the handler chose to continue to the OS prompt.
Future<bool> showLocationRationale(BuildContext context) async {
  final c = UgamColors.of(context);
  final result = await showUgamSheet<bool>(
    context: context,
    builder: (context) => Padding(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.location_on_outlined, color: c.accent, size: 20),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('tracking.rationale_title'),
                  style: UgamText.titleM.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Text(
            tr('tracking.rationale_body'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: tr('tracking.rationale_continue'),
            leadingIcon: Icons.check_rounded,
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                tr('tracking.rationale_not_now'),
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}
```

If `showUgamSheet` is not the helper name exported by `lib/design/components/ugam_sheet.dart`, use whatever that file exports — check it first with
`grep -n "^Future\|^void\|class Ugam" lib/design/components/ugam_sheet.dart`
and match the existing call sites (e.g. in `lib/widgets/occupant_action_sheet.dart`).
Likewise confirm `UgamText.body` / `c.ink2` exist; if not, use `UgamText.caption` / `c.ink3`.

- [ ] **Step 7: Verify analysis is clean**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/services/location_tracker_service.dart lib/widgets/location_rationale_sheet.dart test/services/location_permission_flow_test.dart
git commit -m "feat(location): GPS stream, permission resolution, rationale sheet"
```

---

### Task 7: Tracking status card

**Files:**
- Create: `lib/widgets/tracking_status_card.dart`
- Test: `test/widgets/tracking_status_card_test.dart`

**Interfaces:**
- Consumes: `TrackingStatus` (Task 5), `tracking.*` keys (Task 3)
- Produces: `class TrackingStatusCard extends StatelessWidget` with `TrackingStatusCard({required TrackingStatus status, DateTime? lastUploadAt, required VoidCallback onStop, required VoidCallback onFix})`

`onFix` is the single recovery action; its meaning follows the status (request permission, open app settings, or open location settings).

- [ ] **Step 1: Write the failing tests**

Create `test/widgets/tracking_status_card_test.dart`:

```dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:occubusbooking/widgets/tracking_status_card.dart';

Widget wrap(Widget child) => MaterialApp(
      localizationsDelegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );

void main() {
  Future<void> pump(WidgetTester tester, TrackingStatus s,
      {DateTime? lastUploadAt}) async {
    await tester.pumpWidget(wrap(TrackingStatusCard(
      status: s,
      lastUploadAt: lastUploadAt,
      onStop: () {},
      onFix: () {},
    )));
  }

  testWidgets('idle renders nothing at all', (tester) async {
    await pump(tester, TrackingStatus.idle);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });

  testWidgets('live offers a stop control', (tester) async {
    await pump(tester, TrackingStatus.live, lastUploadAt: DateTime.now());
    expect(find.text(tr('tracking.card_stop')), findsOneWidget);
  });

  testWidgets('live shows the last upload time', (tester) async {
    await pump(tester, TrackingStatus.live,
        lastUploadAt: DateTime.now().subtract(const Duration(minutes: 1)));
    expect(find.textContaining(tr('tracking.card_live')), findsOneWidget);
  });

  testWidgets('denied offers a recovery action, not a stop', (tester) async {
    await pump(tester, TrackingStatus.denied);
    expect(find.text(tr('tracking.card_denied_cta')), findsOneWidget);
    expect(find.text(tr('tracking.card_stop')), findsNothing);
  });

  testWidgets('deniedForever sends the handler to settings', (tester) async {
    await pump(tester, TrackingStatus.deniedForever);
    expect(find.text(tr('tracking.card_settings_cta')), findsOneWidget);
  });

  testWidgets('serviceDisabled asks to turn location on', (tester) async {
    await pump(tester, TrackingStatus.serviceDisabled);
    expect(find.text(tr('tracking.card_service_off_cta')), findsOneWidget);
  });

  testWidgets('foregroundOnly says so plainly', (tester) async {
    await pump(tester, TrackingStatus.foregroundOnly);
    expect(find.text(tr('tracking.card_foreground_only')), findsOneWidget);
  });

  testWidgets('windowClosed reports the trip is over', (tester) async {
    await pump(tester, TrackingStatus.windowClosed);
    expect(find.text(tr('tracking.card_window_closed')), findsOneWidget);
  });

  testWidgets('forbidden leaks no security detail', (tester) async {
    await pump(tester, TrackingStatus.forbidden);
    expect(find.text(tr('tracking.card_unavailable')), findsOneWidget);
    expect(find.textContaining('forbidden'), findsNothing);
  });

  testWidgets('stop fires its callback', (tester) async {
    var stopped = false;
    await tester.pumpWidget(wrap(TrackingStatusCard(
      status: TrackingStatus.live,
      lastUploadAt: DateTime.now(),
      onStop: () => stopped = true,
      onFix: () {},
    )));
    await tester.tap(find.text(tr('tracking.card_stop')));
    await tester.pump();
    expect(stopped, isTrue);
  });

  testWidgets('fix fires its callback', (tester) async {
    var fixed = false;
    await tester.pumpWidget(wrap(TrackingStatusCard(
      status: TrackingStatus.denied,
      onStop: () {},
      onFix: () => fixed = true,
    )));
    await tester.tap(find.text(tr('tracking.card_denied_cta')));
    await tester.pump();
    expect(fixed, isTrue);
  });
}
```

Note: `tr()` without initialised localisation returns the key itself, which is a
stable, comparable value — that is why these assertions use `tr(...)` on both
sides rather than literal English. Do **not** call `plural()` here; per project
precedent it throws in widget tests unless a locale is loaded in `setUpAll`.

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/widgets/tracking_status_card_test.dart`
Expected: FAIL — `tracking_status_card.dart` does not exist.

- [ ] **Step 3: Implement the card**

Create `lib/widgets/tracking_status_card.dart`:

```dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../services/location_tracker_service.dart';

/// The handler's one window onto location sharing: what is happening, and the
/// single thing they can do about it.
///
/// Hidden entirely when idle — a handler on an unlocked tour should not be
/// shown machinery that does not apply to them yet.
class TrackingStatusCard extends StatelessWidget {
  final TrackingStatus status;
  final DateTime? lastUploadAt;

  /// Stop sharing. Only offered while actually sharing.
  final VoidCallback onStop;

  /// The recovery action. Its meaning follows [status]: request permission,
  /// open app settings, or open the OS location settings.
  final VoidCallback onFix;

  const TrackingStatusCard({
    super.key,
    required this.status,
    this.lastUploadAt,
    required this.onStop,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    if (status == TrackingStatus.idle) return const SizedBox.shrink();

    final c = UgamColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: switch (status) {
          TrackingStatus.live => _sharing(c, tone: UgamStatusTone.good),
          TrackingStatus.foregroundOnly =>
            _sharing(c, tone: UgamStatusTone.warm, note: tr('tracking.card_foreground_only')),
          TrackingStatus.awaitingPermission => Row(
              children: [
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Text(tr('tracking.card_starting'),
                    style: UgamText.caption.copyWith(color: c.ink3)),
              ],
            ),
          TrackingStatus.denied => _needsAction(
              c,
              title: tr('tracking.card_denied_title'),
              body: tr('tracking.card_denied_body'),
              cta: tr('tracking.card_denied_cta'),
            ),
          TrackingStatus.deniedForever => _needsAction(
              c,
              title: tr('tracking.card_denied_title'),
              body: tr('tracking.card_denied_body'),
              cta: tr('tracking.card_settings_cta'),
            ),
          TrackingStatus.serviceDisabled => _needsAction(
              c,
              title: tr('tracking.card_service_off_title'),
              body: tr('tracking.card_service_off_body'),
              cta: tr('tracking.card_service_off_cta'),
            ),
          TrackingStatus.windowClosed =>
            _quiet(c, tr('tracking.card_window_closed')),
          // Deliberately vague: the handler cannot act on an authorisation
          // failure, and naming it would leak the ownership model.
          TrackingStatus.forbidden =>
            _quiet(c, tr('tracking.card_unavailable')),
          TrackingStatus.idle => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _sharing(UgamColorSet c, {required UgamStatusTone tone, String? note}) {
    final ago = lastUploadAt == null
        ? null
        : tr('tracking.card_updated_ago',
            namedArgs: {'n': _ago(lastUploadAt!)});
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              UgamStatusDot(
                label: ago == null
                    ? tr('tracking.card_live')
                    : '${tr('tracking.card_live')} · $ago',
                tone: tone,
              ),
              if (note != null) ...[
                const SizedBox(height: 2),
                Text(note, style: UgamText.micro.copyWith(color: c.ink3)),
              ],
            ],
          ),
        ),
        TextButton(
          onPressed: onStop,
          child: Text(
            tr('tracking.card_stop'),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ),
      ],
    );
  }

  Widget _needsAction(
    UgamColorSet c, {
    required String title,
    required String body,
    required String cta,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        UgamStatusDot(label: title, tone: UgamStatusTone.warm),
        const SizedBox(height: 4),
        Text(body, style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: UgamSpacing.sm),
        UgamCTA(
          label: cta,
          leadingIcon: Icons.location_on_outlined,
          onPressed: onFix,
        ),
      ],
    );
  }

  Widget _quiet(UgamColorSet c, String label) =>
      UgamStatusDot(label: label, tone: UgamStatusTone.neutral);

  /// Deliberately plain-Dart rather than `plural()`: this renders inside a
  /// handler's chart on every rebuild, and `plural()` throws in widget tests
  /// unless a locale is loaded.
  static String _ago(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'now';
    if (m < 60) return '${m}m';
    return '${(m / 60).floor()}h';
  }
}
```

If `UgamColorSet` is not the exported type name of `UgamColors.of(context)`,
match whatever `lib/design/tokens.dart` declares (the codebase already uses
`final UgamColorSet c` in `tour_detail_screen.dart`).

- [ ] **Step 4: Run to verify pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/widgets/tracking_status_card_test.dart`
Expected: PASS — 11 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/tracking_status_card.dart test/widgets/tracking_status_card_test.dart
git commit -m "feat(location): handler tracking status card"
```

---

### Task 8: Wire tracking into the handler chart screen

**Files:**
- Modify: `lib/screens/handler_bus_chart_screen.dart`

**Interfaces:**
- Consumes: `LocationTrackerService`, `TrackingStatusCard`, `showLocationRationale`, `resolveTrackingStatus`
- Produces: auto-start behaviour on a locked tour; handler's own-bus lite map.

- [ ] **Step 1: Register the service**

In `lib/main.dart`, beside the existing `Get.put(...)` service registrations, add:

```dart
  Get.put(LocationTrackerService(), permanent: true);
```

- [ ] **Step 2: Add the tracking controller method to the chart state**

In `_HandlerBusChartScreenState`, add fields and the auto-start routine:

```dart
  final _tracker = Get.find<LocationTrackerService>();
  static const _rationaleSeenKey = 'tracking.rationale_seen';
  bool _trackingBootstrapped = false;

  /// Auto-start, per the design: the handler never taps a Start button.
  /// Consent lives at the permission step, not behind a button.
  ///
  /// Runs once per screen open, only on a locked tour with an owned bus.
  Future<void> _bootstrapTracking() async {
    if (_trackingBootstrapped) return;
    final busId = _selectedBusId;
    final manifest = _manifest;
    if (busId == null || manifest == null) return;
    if (manifest.tourStatus != 'locked') return;
    _trackingBootstrapped = true;

    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    var permission = await Geolocator.checkPermission();
    var state = resolveTrackingStatus(
      serviceEnabled: serviceEnabled,
      permission: permission,
    );

    // First ask ever: disclose BEFORE the OS prompt (Play policy), once only.
    if (state == TrackingStatus.denied) {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool(_rationaleSeenKey) ?? false;
      if (!seen) {
        if (!mounted) return;
        final go = await showLocationRationale(context);
        await prefs.setBool(_rationaleSeenKey, true);
        if (!go) {
          _tracker.status.value = TrackingStatus.denied;
          return;
        }
      }
      permission = await Geolocator.requestPermission();
      // Android needs a second ask to move whileInUse -> always. Declining
      // leaves foreground-only tracking, which the card states plainly.
      if (permission == LocationPermission.whileInUse && Platform.isAndroid) {
        permission = await Geolocator.requestPermission();
      }
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      state = resolveTrackingStatus(
        serviceEnabled: serviceEnabled,
        permission: permission,
      );
    }

    if (state == TrackingStatus.live || state == TrackingStatus.foregroundOnly) {
      await _tracker.start(
        requestId: widget.requestId,
        busId: busId,
        leg: _currentLeg,
      );
      _tracker.status.value = state;
      _tracker.startStream();
    } else {
      _tracker.status.value = state;
    }
  }

  /// The card's single recovery action, resolved from the current status.
  Future<void> _onTrackingFix() async {
    switch (_tracker.status.value) {
      case TrackingStatus.serviceDisabled:
        await Geolocator.openLocationSettings();
      case TrackingStatus.deniedForever:
        await Geolocator.openAppSettings();
      default:
        _trackingBootstrapped = false;
        await _bootstrapTracking();
    }
  }
```

`_currentLeg` must resolve to `'go'` or `'ret'` from the screen's existing leg
state. Find it with `grep -n "leg" lib/screens/handler_bus_chart_screen.dart`
and reuse that value — do **not** introduce new leg inference. If the screen
has no leg state, pass `null`; the RPC accepts it.

`manifest.tourStatus` must match whatever `HandlerManifest` exposes for tour
status. Check with `grep -n "status" lib/models/handler_manifest.dart` and use
the real field name; if the manifest carries no status, read it from the
already-loaded tour object on the screen.

- [ ] **Step 3: Call it once the manifest and bus are known**

At the end of the successful-load path (where `_manifest` and `_selectedBusId`
are both set), add:

```dart
    unawaited(_bootstrapTracking());
```

- [ ] **Step 4: Render the card and the handler's own-bus map**

Above the seat chart in `build`:

```dart
            Obx(() => TrackingStatusCard(
                  status: _tracker.status.value,
                  lastUploadAt: _tracker.lastUploadAt.value,
                  onStop: () async {
                    await _tracker.stopStream();
                    await _tracker.stop();
                  },
                  onFix: _onTrackingFix,
                )),
```

Then, only while sharing, a small confirmation map:

```dart
            Obx(() {
              final sharing = _tracker.status.value == TrackingStatus.live ||
                  _tracker.status.value == TrackingStatus.foregroundOnly;
              if (!sharing) return const SizedBox.shrink();
              return const Padding(
                padding: EdgeInsets.only(bottom: UgamSpacing.sm),
                child: SizedBox(height: 180, child: _HandlerOwnBusMap()),
              );
            }),
```

- [ ] **Step 5: Implement the own-bus map**

At the bottom of `handler_bus_chart_screen.dart`:

```dart
/// A small "yes, your dot is moving" confirmation for the handler.
///
/// Lite mode renders a static bitmap rather than a live vector map: this sits
/// on a phone that is already running GPS for hours, and a full map would cost
/// battery and memory for no added information at this size.
class _HandlerOwnBusMap extends StatefulWidget {
  const _HandlerOwnBusMap();

  @override
  State<_HandlerOwnBusMap> createState() => _HandlerOwnBusMapState();
}

class _HandlerOwnBusMapState extends State<_HandlerOwnBusMap> {
  Position? _me;
  StreamSubscription<Position>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 50,
      ),
    ).listen((p) {
      if (mounted) setState(() => _me = p);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) return const UgamSkeleton(height: 180);
    final here = LatLng(me.latitude, me.longitude);
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: here, zoom: 14),
        liteModeEnabled: Platform.isAndroid,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        markers: {Marker(markerId: const MarkerId('me'), position: here)},
      ),
    );
  }
}
```

Check `UgamSkeleton`'s real constructor with
`grep -n "class UgamSkeleton" -A 12 lib/design/components/ugam_skeleton.dart`
and match it; substitute a plain `SizedBox(height: 180)` if the signature differs.

- [ ] **Step 6: Verify analysis and the full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter analyze && flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/handler_bus_chart_screen.dart lib/main.dart
git commit -m "feat(location): auto-start tracking on the handler bus chart"
```

---

### Task 9: Admin positions repository

**Files:**
- Create: `lib/services/bus_positions_repository.dart`
- Test: `test/services/bus_positions_repository_test.dart`

**Interfaces:**
- Consumes: `BusPosition` (Task 2)
- Produces: `class BusPositionsRepository` with `Future<List<BusPosition>> fetchForTour(String tourId)`, `Stream<BusPosition> watchTour(String tourId)`, `void dispose()`, and `static List<BusPosition> mergePositions(List<BusPosition> current, BusPosition incoming)`

`mergePositions` is pure and carries the whole merge rule, so the map's
correctness is testable without Supabase or map tiles.

- [ ] **Step 1: Write the failing tests**

Create `test/services/bus_positions_repository_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/bus_positions_repository.dart';

BusPosition pos(String busId, {DateTime? at, double lat = 23.0}) =>
    BusPosition.fromMap({
      'bus_id': busId,
      'tour_id': 'tour-1',
      'lat': lat,
      'lng': 72.0,
      'tracking_state': 'live',
      'recorded_at': (at ?? DateTime.now().toUtc()).toIso8601String(),
      'received_at': DateTime.now().toUtc().toIso8601String(),
    });

void main() {
  group('mergePositions', () {
    test('adds a bus not yet on the map', () {
      final merged = BusPositionsRepository.mergePositions([], pos('b1'));
      expect(merged.length, 1);
      expect(merged.single.busId, 'b1');
    });

    test('replaces the existing row for the same bus', () {
      final older = pos('b1', lat: 23.0);
      final newer = pos('b1', lat: 24.0);
      final merged = BusPositionsRepository.mergePositions([older], newer);
      expect(merged.length, 1, reason: 'one dot per bus, never two');
      expect(merged.single.lat, 24.0);
    });

    test('leaves other buses untouched', () {
      final merged = BusPositionsRepository.mergePositions(
        [pos('b1'), pos('b2')],
        pos('b2', lat: 25.0),
      );
      expect(merged.length, 2);
      expect(merged.firstWhere((p) => p.busId == 'b1').lat, 23.0);
      expect(merged.firstWhere((p) => p.busId == 'b2').lat, 25.0);
    });

    test('never rewinds to an older fix', () {
      final now = DateTime.now().toUtc();
      final current = pos('b1', at: now, lat: 24.0);
      final stale = pos('b1', at: now.subtract(const Duration(minutes: 5)),
          lat: 23.0);

      final merged = BusPositionsRepository.mergePositions([current], stale);
      expect(merged.single.lat, 24.0,
          reason: 'an out-of-order offline flush must not move the dot back');
    });

    test('accepts a fix with the same timestamp — state may have changed', () {
      final t = DateTime.now().toUtc();
      final merged = BusPositionsRepository.mergePositions(
        [pos('b1', at: t, lat: 23.0)],
        pos('b1', at: t, lat: 24.0),
      );
      expect(merged.single.lat, 24.0);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/bus_positions_repository_test.dart`
Expected: FAIL — `bus_positions_repository.dart` does not exist.

- [ ] **Step 3: Implement the repository**

Create `lib/services/bus_positions_repository.dart`:

```dart
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_position.dart';

/// The admin's read side of live tracking.
///
/// WHY ITS OWN REALTIME CHANNEL. `RealtimeService` is a single broadcast stream
/// feeding every admin controller, each of which debounces and refetches its
/// slice of the world on any event. Position rows update once every two minutes
/// per bus, and routing them through that fan-out would wake unrelated screens
/// into refetches for data they never read. This channel opens with the map and
/// closes with it.
///
/// Authorisation is not this class's business: 047's owner-only RLS already
/// confines every read to the signed-in owner's tours.
class BusPositionsRepository {
  SupabaseClient get _client => Supabase.instance.client;

  RealtimeChannel? _channel;
  StreamController<BusPosition>? _controller;

  Future<List<BusPosition>> fetchForTour(String tourId) async {
    final rows = await _client
        .from('bus_live_positions')
        .select()
        .eq('tour_id', tourId);
    return (rows as List)
        .map((r) => BusPosition.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Live updates for one tour. Filtered SERVER-side, so other tours' buses
  /// never reach this device.
  Stream<BusPosition> watchTour(String tourId) {
    dispose();
    final controller = StreamController<BusPosition>.broadcast();
    _controller = controller;

    final channel = _client.channel('bus-positions-$tourId');
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'bus_live_positions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'tour_id',
        value: tourId,
      ),
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        if (row.isEmpty) return;
        controller.add(BusPosition.fromMap(Map<String, dynamic>.from(row)));
      },
    );
    channel.subscribe();
    _channel = channel;

    return controller.stream;
  }

  void dispose() {
    final channel = _channel;
    if (channel != null) _client.removeChannel(channel);
    _channel = null;
    _controller?.close();
    _controller = null;
  }

  /// One dot per bus, and never a backwards step.
  ///
  /// The server already guards this (047 re-reads the newest fix before
  /// updating the live row), but an offline flush and a real-time fix can still
  /// arrive at the CLIENT out of order. Equal timestamps are accepted because
  /// `tracking_state` can change without the position moving.
  static List<BusPosition> mergePositions(
    List<BusPosition> current,
    BusPosition incoming,
  ) {
    final next = <BusPosition>[];
    var replaced = false;
    for (final p in current) {
      if (p.busId != incoming.busId) {
        next.add(p);
        continue;
      }
      replaced = true;
      next.add(
        incoming.recordedAt.isBefore(p.recordedAt) ? p : incoming,
      );
    }
    if (!replaced) next.add(incoming);
    return next;
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test test/services/bus_positions_repository_test.dart`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/services/bus_positions_repository.dart test/services/bus_positions_repository_test.dart
git commit -m "feat(location): admin positions repository on a dedicated channel"
```

---

### Task 10: Admin live map screen

**Files:**
- Create: `lib/screens/live_map_screen.dart`
- Modify: `lib/screens/tour_detail_screen.dart`

**Interfaces:**
- Consumes: `BusPositionsRepository`, `BusPosition`, `tracking.*` keys
- Produces: `class LiveMapScreen extends StatefulWidget` with `LiveMapScreen({required String tourId, required List<Bus> buses})`

- [ ] **Step 1: Build the screen**

Create `lib/screens/live_map_screen.dart`:

```dart
import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../design/ugam.dart';
import '../models/bus.dart';
import '../models/bus_position.dart';
import '../services/bus_positions_repository.dart';

/// Every bus on one tour, moving. Admin-only — 047's RLS has no anon policy.
class LiveMapScreen extends StatefulWidget {
  final String tourId;
  final List<Bus> buses;

  const LiveMapScreen({
    super.key,
    required this.tourId,
    required this.buses,
  });

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _repo = BusPositionsRepository();

  List<BusPosition> _positions = const [];
  StreamSubscription<BusPosition>? _sub;
  GoogleMapController? _map;
  bool _loading = true;

  /// The camera is fitted ONCE. Re-fitting on every update would wrench the
  /// map out from under an admin who is panning or zoomed into a bus.
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final initial = await _repo.fetchForTour(widget.tourId);
      if (!mounted) return;
      setState(() {
        _positions = initial;
        _loading = false;
      });
      _fitCamera();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }

    _sub = _repo.watchTour(widget.tourId).listen((p) {
      if (!mounted) return;
      setState(() => _positions =
          BusPositionsRepository.mergePositions(_positions, p));
      _fitCamera();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repo.dispose();
    super.dispose();
  }

  String _busName(String busId) => widget.buses
      .firstWhere(
        (b) => b.id == busId,
        orElse: () => widget.buses.isNotEmpty
            ? widget.buses.first
            : throw StateError('no buses'),
      )
      .name;

  void _fitCamera() {
    if (_fitted || _map == null || _positions.isEmpty) return;
    _fitted = true;
    if (_positions.length == 1) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(_positions.first.lat, _positions.first.lng),
        13,
      ));
      return;
    }
    final lats = _positions.map((p) => p.lat);
    final lngs = _positions.map((p) => p.lng);
    _map!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(lats.reduce((a, b) => a < b ? a : b),
            lngs.reduce((a, b) => a < b ? a : b)),
        northeast: LatLng(lats.reduce((a, b) => a > b ? a : b),
            lngs.reduce((a, b) => a > b ? a : b)),
      ),
      64,
    ));
  }

  Set<Marker> get _markers => _positions.map((p) {
        final name = _busName(p.busId);
        final detail = p.isStale
            ? tr('tracking.map_stale')
            : p.isMoving
                ? tr('tracking.map_moving',
                    namedArgs: {'n': p.speedKmh!.round().toString()})
                : tr('tracking.map_parked');
        return Marker(
          markerId: MarkerId(p.busId),
          position: LatLng(p.lat, p.lng),
          rotation: p.headingDeg ?? 0,
          // A stale bus must not read the same as a running one.
          icon: BitmapDescriptor.defaultMarkerWithHue(
            p.isStale
                ? BitmapDescriptor.hueOrange
                : BitmapDescriptor.hueGreen,
          ),
          infoWindow: InfoWindow(
            title: name,
            snippet: '$detail · '
                '${tr('tracking.map_last_seen', namedArgs: {
                  'n': _ago(p.recordedAt),
                })}',
          ),
        );
      }).toSet();

  static String _ago(DateTime t) {
    final m = DateTime.now().toUtc().difference(t).inMinutes;
    if (m < 1) return 'now';
    if (m < 60) return '${m}m';
    return '${(m / 60).floor()}h';
  }

  @override
  Widget build(BuildContext context) {
    return UgamScaffold(
      appBar: UgamAppBar(title: tr('tracking.map_title')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _positions.isEmpty
              ? UgamEmpty(
                  icon: Icons.location_off_outlined,
                  title: tr('tracking.map_empty_title'),
                  body: tr('tracking.map_empty_body'),
                )
              : GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(_positions.first.lat, _positions.first.lng),
                    zoom: 11,
                  ),
                  markers: _markers,
                  myLocationButtonEnabled: false,
                  onMapCreated: (c) {
                    _map = c;
                    _fitCamera();
                  },
                ),
    );
  }
}
```

Confirm `UgamScaffold` / `UgamAppBar` constructor shapes against an existing
screen (`lib/screens/bus_status_screen.dart` uses both) and match them. Confirm
the `Bus` model's name field with `grep -n "final String" lib/models/bus.dart`
— use the real field rather than assuming `name`.

- [ ] **Step 2: Add the entry point**

In `lib/screens/tour_detail_screen.dart`, inside `_BusesTab`'s non-empty branch
(after the stat row), add a button visible only on a locked tour:

```dart
        if (tour.status == 'locked') ...[
          const SizedBox(height: UgamSpacing.sm),
          UgamCTA(
            label: tr('tracking.map_open'),
            leadingIcon: Icons.map_outlined,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    LiveMapScreen(tourId: tour.id, buses: tour.buses),
              ),
            ),
          ),
        ],
```

Add `import 'live_map_screen.dart';` to the import block. Confirm how tour
status is compared elsewhere in this file (`grep -n "status" lib/screens/tour_detail_screen.dart`)
and match that idiom — the codebase has a `TourStatus` model that may make
`tour.status == 'locked'` wrong.

- [ ] **Step 3: Verify analysis and the full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter analyze && flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/live_map_screen.dart lib/screens/tour_detail_screen.dart
git commit -m "feat(location): admin live map screen"
```

---

### Task 11: Final verification

**Files:** none modified unless a defect surfaces.

- [ ] **Step 1: Full static analysis**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 2: Full test suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter test`
Expected: all pass. Baseline was 1406; this plan adds 62 tests (11 + 11 + 17 + 7 + 11 + 5), so expect ~1468 with zero failures.

- [ ] **Step 3: Release-mode Android build**

Run: `export PATH="/c/src/flutter/bin:$PATH" && flutter build apk --debug`
Expected: BUILD SUCCESSFUL. Confirms manifest merge with the new permissions and the Maps placeholder.

- [ ] **Step 4: Confirm no migration was touched**

Run: `git diff --name-only main...HEAD -- supabase/`
Expected: empty. This build is client-only against deployed 047.

- [ ] **Step 5: Manual device pass**

On a real Android device with a `locked` tour and a handler who owns a bus:

1. Open the handler bus chart → rationale sheet appears → allow location.
2. Confirm the persistent notification appears and the status card reads "Sharing location".
3. Lock the screen, walk/drive 200 m, wait ~2 min.
4. On the admin account, open the tour → Buses tab → Live map. The bus marker appears and advances.
5. Enable airplane mode for 5 min, then disable. Confirm buffered fixes upload and the marker jumps forward without duplicating.
6. Mark the tour complete. Confirm the handler card flips to "Trip finished — sharing stopped" and the notification clears.

- [ ] **Step 6: Report**

Summarise: tests added, suite total, analyzer state, device-pass results, and the outstanding Play Console background-location declaration and privacy-policy update (spec §12, steps 3-4) which remain release blockers.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §4 packages, Android/iOS permissions, Maps key | 1 |
| §5 `LocationFix` / `BusPosition` | 2 |
| §10 translation keys | 3 |
| §6.1 buffer, disk mirror, 2000 cap, oldest-out | 4 |
| §6.1 flush, 500 cap, refusal handling, backoff, seam | 5 |
| §6.1 stream settings, heartbeat; §6.2 permission flow, rationale | 6 |
| §6.3 status card | 7 |
| §6.3 auto-start wiring, own-bus lite map; §6.4 leg | 8 |
| §7.1 repository, dedicated channel | 9 |
| §7.2 map screen, entry point, stale styling, camera-fit-once | 10 |
| §9 test gate | 11 |
| §8 error handling | distributed across 4, 5, 6, 9 |

No spec requirement is unassigned. §11 (out of scope) and §12 (manual user steps) correctly have no tasks; §12 is surfaced in Task 11 Step 6.

**Type consistency checked:** `TrackingStatus` has nine members and all nine are handled in the card's `switch` (Task 7) and produced by `resolveTrackingStatus` (Task 6) — `foregroundOnly` was added beyond the spec's original eight because "whileInUse granted" is a real state the handler must be told about honestly. `LocationPusher`'s signature is identical in Task 5's typedef, its fakes, and `_send`. `LocationFixBuffer.take`/`drop` names match between Tasks 4 and 5. `mergePositions` is `static` in both Task 9's definition and Task 10's call site.

**Known verification points flagged inline** (Tasks 6, 7, 8, 10) where the plan depends on an existing symbol whose exact shape was not read during planning: `showUgamSheet`, `UgamText.body`/`c.ink2`, `UgamColorSet`, `UgamSkeleton`, `HandlerManifest` tour-status field, the chart screen's leg state, `Bus`'s name field, and the tour-status comparison idiom. Each carries the grep that resolves it. These are integration details, not design gaps.
