# Bus chart: pickup-location grouping + attendance call button

**Date:** 2026-07-20
**Screen:** `lib/screens/handler_bus_chart_screen.dart` (the handler's read-only "બસ ચાર્ટ")

## Problem

The handler's call-first views list passengers as one flat roster. Two field
needs are unmet:

1. **Pickup grouping.** A handler boards people pickup point by pickup point.
   The roster should be grouped under pickup-location headers so they can work
   one stop at a time.
2. **Call from attendance.** The **હાજરી (Attendance)** tab can only toggle
   present/left-behind — there is no way to call a no-show from that tab. The
   **યાદી (List)** tab already has a call button; Attendance does not.

`Passenger` already snapshots `pickupLocationId` + `pickupLocationName`
(`lib/models/passenger.dart`), so the data is present on every row.

## Decisions (confirmed with user)

- **Scope:** both call-first tabs — **List (યાદી)** and **Attendance (હાજરી)** —
  get pickup grouping. The Grid tab is untouched.
- **Group order:** named pickups sorted **alphabetically A→Z** by name. No extra
  fetch of the global pickup list (the manifest only carries name snapshots).
- **No-pickup passengers:** collected into a **"No pickup location"** bucket
  rendered **last**.
- **Header style:** **distinct color per location**, from the existing
  `groupColorForId` golden-angle generator (same generator that colors group
  dots), so each pickup reads as its own color as in the target screenshot.
- **Attendance call button:** added between the name block and the
  present/left-behind Switch, gated on the passenger having a phone.
- **Head-count:** each header shows a subtle count suffix (`· 3`).

## Design

### 1. `lib/utils/pickup_grouping.dart` (new, pure, unit-tested)

```dart
class PickupGroup<T> {
  final String? locationId;    // null → no-pickup bucket
  final String? locationName;  // null → no-pickup bucket
  final List<T> items;
  bool get isUnassigned;       // name null or blank
}

List<PickupGroup<T>> groupByPickup<T>(
  Iterable<T> items, {
  required String? Function(T) idOf,
  required String? Function(T) nameOf,
});
```

Rules:
- Group key = pickup name normalized (trim + case-fold). Blank/null → the
  unassigned bucket.
- Named groups sorted case-insensitively A→Z; unassigned bucket always last.
- **Order within a group preserves input order** — so Attendance stays
  name-sorted and List stays seat-ordered inside each section.
- Header display uses the first-seen original-cased name and first-seen id
  (the id feeds the header color).

### 2. Widgets in `handler_bus_chart_screen.dart`

- **`_CallButton(phone)`** — extract the call-button currently duplicated in
  `_RosterRow` and `_LegSharedTile` into one widget; reuse in both plus the new
  Attendance placement. (Targeted DRY cleanup in code we're already editing.)
- **`_PickupSectionHeader`** — leading color bar/dot + pickup name + muted count.
  Color from `groupColorForId(locationId ?? name)`, with a theme-aware lightness
  clamp so it reads on both light and dark grounds. The unassigned bucket uses
  neutral ink + a localized `handler_chart.pickup_none` label.

### 3. Wiring

- **`_AttendanceView`**: group its `rows` by pickup; render header + its
  `_AttendanceRow`s per section. GO/RET toggle, tally header, and cross-fade
  unchanged. `_AttendanceRow` gains the `_CallButton` before the Switch.
- **`_SeatRoster`** (List): build `(seatId, passenger)` entries in seat order,
  group by pickup, render header + `_RosterRow`s per section. Money chips, trip
  badges, and tap-to-collect unchanged.

### 4. i18n

One new key `handler_chart.pickup_none` = "No pickup location" in **gu / en / hi**.

## Testing

- **Unit** (`test/utils/pickup_grouping_test.dart`): alphabetical ordering,
  unassigned-last, within-group order preserved, blank/null → unassigned,
  same-name-different-id merge, empty input.
- **Widget** (extend `test/screens/handler_bus_chart_screen_test.dart`):
  Attendance renders pickup headers and a call button on a row with a phone;
  List renders pickup headers.

## Out of scope

Money totals, boarded tally, GO/RET logic, the Grid tab, and the shared-seat
chooser sheet.
