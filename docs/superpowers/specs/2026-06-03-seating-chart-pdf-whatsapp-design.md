# Seating Chart — A4 PDF Download + Per-Passenger WhatsApp Chart

**Date:** 2026-06-03
**Status:** Approved design / implementation contract

This spec is the single source of truth for the build. Every implementing agent
MUST read it and match the interfaces exactly so the pieces compile together.

---

## 1. Goal

Two features, both available only **after a tour is locked** (`TourStatus.locked`):

1. **A4 chart download (agent).** From the `TourSeatAssignmentScreen` bottom dock,
   the agent downloads a printable A4 PDF seating chart — one page per bus — that
   reproduces the agent's manual WhatsApp chart: a **bordered table** of berths with
   Gujarati `ઉપર` / `નીચે` (Upper / Lower) column headers, a vertically-merged
   `A C` aisle column, **passenger name + mobile number** in each occupied cell
   (no seat IDs), and a **footer info block** (bus number, boarding place,
   date + departure time, handler/return note). Delivered via the native
   share/print sheet (`printing` package).

2. **Per-passenger highlighted chart (WhatsApp).** On the **Notify** tab, the
   per-passenger **Send** action renders the same chart for that passenger's bus
   with **their seats highlighted**, rasterises it to a **PNG**, and opens the OS
   share sheet (`share_plus`) with the existing ticket text as the caption. The
   agent picks the passenger's WhatsApp chat → image + text go together.

### Reference chart (agent's manual format being reproduced)

```
┌──────────┬──────────┬───┬──────────┬──────────┐
│   ઉપર    │   નીચે   │   │   નીચે   │   ઉપર    │   localized Upper/Lower headers
├──────────┼──────────┤   ├──────────┼──────────┤
│ Praful   │ Vanita   │ A │ Manoj    │ Bharat   │
│ 98796..  │ 79845..  │ C │ 99098..  │ 98791..  │   name + phone, NO seat IDs
├──────────┼──────────┤   ├──────────┼──────────┤
│ Rasik    │ Chandu   │   │ Rasik    │ Rasik    │   "A C" = vertically merged aisle
│ 98250..  │ 99257..  │   │          │          │
└──────────┴──────────┴───┴──────────┴──────────┘
ગાડી નંબર – <bus number>
સ્થળ.. <boarding place>
તારીખ <date> <departure time> — બસ ઉપાડવામાં આવશે, એ પેલા હાજર થઈ જવાનું
<handler / return note>
```

Empty rows are skipped. The balcony back-row upper/lower pair stacks inside the
aisle cell (same rule as `CombinedSeatGrid`). The PDF is **light / print-friendly**
(not the dark app theme). Highlighted seats (feature 2) use the brand terracotta
fill; non-highlighted cells are neutral.

---

## 2. Key existing facts (do not re-derive)

- `TourStatus` enum (`lib/models/tour_status.dart`): `planning, collecting,
  busBooked, assigning, locked, completed`. Download/WhatsApp features gate on
  `tour.status == TourStatus.locked`.
- `Tour` (`lib/models/tour.dart`): `title, fromCity, toCity, departureDate
  (DateTime), returnDate (DateTime?), description, handlerId, buses (List<Bus>),
  passengers (List<Passenger>)`. `tour.handler` → `Passenger?`. No boarding-place
  or departure-time-text field exists — those come from the editable footer.
- `Bus` (`lib/models/bus_details.dart`): `id, name ("Bus 1"), busNumber
  (registration), driverName, driverPhone, busType (String, e.g. "Semi-Sleeper"),
  layout (BusLayout)`.
- `BusLayout` (`lib/models/seat_layout.dart`): `rows, cols (5), grid
  (List<SeatCell>)`, `cellAt(row, col)`, `balconyPair(row)` →
  `({SeatCell upper, SeatCell lower})`, `hasBalcony`. Helpers: `allSeatIds`,
  `totalSeats`.
- `SeatCell`: `row, col, seatType (SeatType), position (SeatPosition?), seatId
  (e.g. "DL3"), reserved (bool), hasSeat (bool), isEmpty (bool)`.
- `SeatGridCols` (in `seat_layout.dart`): `singleUpper=0, singleLower=1, aisle=2,
  doubleUpper=3, doubleLower=4`.
- `SeatType` enum: `singleSofa, doubleSofa, seater`. `SeatPosition` enum:
  `upper, lower` (null for seaters).
- `Passenger` (`lib/models/passenger.dart`): `name, displayName, phone,
  assignedSeats (List<SeatAssignment>)`. `SeatAssignment`: `busId, seatId, locked`.
  A passenger's seats on a bus: `p.assignedSeats.where((a) => a.busId == busId)`.
- **Phone display rule** (mirror `seat_assignment_screen.dart` `_phoneDisplay`):
  strip non-digits; if `digits.length > 10 && digits.startsWith('91')` →
  `digits.substring(digits.length - 10)`; else the stripped digits. Empty → null.
- On-screen placement logic lives in `lib/components/combined_seat_grid.dart`
  (`_rowHasSeats`, `_usedLaneCols`, `_row`, `_balconyAisle`). The PDF re-expresses
  this as pure data in a new helper (see §4.1). **Do not modify
  `combined_seat_grid.dart`** — leave the working on-screen grid untouched.
- WhatsApp (`lib/services/whatsapp_service.dart`): `WhatsAppService()` singleton.
  `buildTicketMessage({passenger, tour, busNumber, driverName, driverPhone,
  handlerName, handlerPhone})` → String. `sendToPassenger(...)` → opens a
  text-only `wa.me` deep-link (cannot attach files). Keep it as the fallback.
- Notify screen (`lib/screens/notify_screen.dart`): per-passenger send is
  `_sendOne(Passenger p, {required Tour tour, required String busNo, required
  String driverName, required String? driverPhone})` (line ~61). Bus info via
  `_resolveBusInfo(tour)` → `_BusInfo {busNo, driverName, driverPhone?}`
  (busNo/driverName are comma-joined across buses). Per-row button calls
  `onSend` → `_sendOne(...)`.
- `shared_preferences` is already a dependency (used by theme/locale controllers).
- Design system: `UgamColors.of(context)`, `UgamText`, `UgamSpacing`, `UgamRadius`,
  brand terracotta accent (see `lib/design/tokens.dart`). Localisation via
  `easy_localization` `tr('...')`; strings live in `assets/translations/{en,gu,hi}.json`.
- Build/verify: `flutter pub get`, `flutter analyze`, `flutter test`.

---

## 3. Fonts (Gujarati / Hindi / Latin)

Passenger names may be Gujarati or Devanagari. Use the `printing` package's
`PdfGoogleFonts` (downloads + caches to disk on first use, then works offline):

- Base: `await PdfGoogleFonts.notoSansRegular()` + `notoSansBold()`.
- `fontFallback`: `[await PdfGoogleFonts.notoSansGujaratiRegular(), await
  PdfGoogleFonts.notoSansDevanagariRegular()]` (use whichever helper names the
  installed `printing` version exposes; if a Gujarati/Devanagari helper is
  unavailable, fall back gracefully — see below).

Wrap font loading in try/catch: on any failure, fall back to the `pdf` default
font so generation never throws (Latin names still render; missing-glyph boxes
are acceptable degradation). Cache loaded fonts in a static field so repeated
generations don't re-fetch. **First generation requires internet** (documented
limitation; full offline bundling is a future improvement, out of scope here).

---

## 4. Components

### New files

#### 4.1 `lib/utils/seat_grid_placement.dart` (pure, no Flutter widgets beyond models)

Expresses the `CombinedSeatGrid` placement as data so the PDF table matches the
on-screen grid.

```dart
/// A visible column in the chart table.
enum ChartColumn { singleUpper, singleLower, aisle, doubleUpper, doubleLower }

class SeatGridPlacement {
  /// Row indices (0..layout.rows-1) that contain at least one seat. In order.
  static List<int> rowsWithSeats(BusLayout layout);

  /// Lane cols (excludes aisle) carrying ≥1 seat anywhere. {0,1,3,4} subset.
  static Set<int> usedLaneCols(BusLayout layout);

  /// Ordered visible columns: each used lane, with `aisle` inserted between the
  /// single side and double side when (hasLeft && hasRight) OR layout.hasBalcony.
  /// Mirrors CombinedSeatGrid._row exactly.
  static List<ChartColumn> columns(BusLayout layout);

  /// The cell at (row, column) for a lane column, or null for the aisle column.
  /// Use balconyPair(row) for the aisle on balcony rows (caller handles).
  static SeatCell? cellFor(BusLayout layout, int row, ChartColumn column);
}

/// seatId -> occupant, per bus, built from every passenger's assignedSeats.
/// A double-sofa owner's name appears on BOTH berth seatIds (matches the screen).
class SeatOccupant {
  final String name;       // passenger.displayName
  final String? phone;     // already run through displayPhone()
  const SeatOccupant({required this.name, this.phone});
}

/// busId -> (seatId -> occupant)
Map<String, Map<String, SeatOccupant>> occupantsByBus(Tour tour);

/// Phone display rule (see §2). Public so tests can cover it.
String? displayPhone(String? raw);
```

#### 4.2 `lib/models/chart_footer.dart`

```dart
class ChartFooter {
  final String boardingPlace;   // "સ્થળ"
  final String departureTime;   // free text, e.g. "સાંજે 5 વાગ્યે"
  final String note;            // handler / return note
  const ChartFooter({this.boardingPlace = '', this.departureTime = '', this.note = ''});
  bool get isEmpty => boardingPlace.isEmpty && departureTime.isEmpty && note.isEmpty;
  Map<String, dynamic> toJson();
  factory ChartFooter.fromJson(Map<String, dynamic> json);
  ChartFooter copyWith({String? boardingPlace, String? departureTime, String? note});
}
```

#### 4.3 `lib/services/chart_footer_store.dart`

Persists the footer per tour in `shared_preferences` (key
`chart_footer_<tourId>`, JSON-encoded). No DB / schema change.

```dart
class ChartFooterStore {
  static Future<ChartFooter> load(String tourId);   // empty ChartFooter if none
  static Future<void> save(String tourId, ChartFooter footer);
}
```

#### 4.4 `lib/services/seat_chart_pdf.dart`

The core builder. Uses `package:pdf/widgets.dart as pw`, `package:printing`.

```dart
class SeatChartPdf {
  /// One A4 portrait page per bus (or only [onlyBusId] if given). For each bus:
  /// header? + bordered berth table + footer block. Highlights any seatIds in
  /// [highlightByBus] (busId -> seatIds) with the brand accent fill.
  static Future<Uint8List> buildTourChartPdf({
    required Tour tour,
    required ChartFooter footer,
    String? onlyBusId,
    Map<String, Set<String>> highlightByBus = const {},
  });

  /// Feature 1: build the all-buses PDF and open the native share/print sheet.
  static Future<void> shareTourChartA4({
    required Tour tour,
    required ChartFooter footer,
  });

  /// Feature 2: for each bus this passenger occupies, build a single-bus page
  /// with their seats highlighted and rasterise to PNG (via Printing.raster,
  /// ~150 dpi). Returns one PNG per occupied bus (usually one).
  static Future<List<Uint8List>> buildPassengerChartImages({
    required Tour tour,
    required Passenger passenger,
    required ChartFooter footer,
  });
}
```

Table construction rules:
- Columns from `SeatGridPlacement.columns(bus.layout)`. Header row labels:
  `singleUpper`/`doubleUpper` → `tr('chart.col_upper')` (ઉપર); `singleLower`/
  `doubleLower` → `tr('chart.col_lower')` (નીચે); `aisle` → empty header.
- Body: one table row per `rowsWithSeats`. The `aisle` column is a single cell
  that spans all body rows (use a separate column whose cell shows `A C`
  vertically-rotated / centered text — implement as a parallel narrow column,
  not a true rowspan if `pw.Table` rowspan is awkward; a centered `A C` mid-height
  cell is acceptable). On balcony rows the aisle cell shows the stacked
  upper/lower pair occupants.
- Occupied cell: name (bold) over phone. Empty cell: blank. Reserved: light grey
  "—". Highlighted: accent background.
- Footer block under the table: `ગાડી નંબર – <bus.busNumber or bus.name>`,
  `સ્થળ.. <footer.boardingPlace>`, the date line
  `તારીખ <formatted departureDate> <footer.departureTime>` + the fixed reminder
  phrase, then `<footer.note>`. Use `tr()` keys for the static phrases so they
  localise; interpolate the dynamic values. Skip a line if its dynamic value is
  empty. Handler name from `tour.handler?.displayName` may be appended to the note
  line if note is empty.
- Date formatting: reuse a simple `d-M-yy` style (e.g. `17-5-26`) to match the
  reference, via `intl` `DateFormat('d-M-yy')`.

#### 4.5 `lib/widgets/chart_footer_sheet.dart`

```dart
/// Modal bottom sheet: edit boardingPlace / departureTime / note (pre-filled
/// from [initial]). Shows read-only context (bus numbers, departure date,
/// handler name) above the fields. Returns the edited footer, or null on cancel.
Future<ChartFooter?> showChartFooterSheet(
  BuildContext context, {
  required ChartFooter initial,
  required Tour tour,
});
```

Match the app's bottom-sheet styling (rounded top, `UgamColors`, `UgamText`).
Primary action: "Generate chart" (`tr('chart.generate')`).

### Modified files

#### 4.6 `pubspec.yaml`
Add under `dependencies:` (latest stable compatible with Dart `^3.10.3`):
`pdf`, `printing`, `share_plus`. Run `flutter pub get`. No new asset/font entries.

#### 4.7 `lib/screens/tour_seat_assignment_screen.dart`
`_PendingDock` gains `final VoidCallback? onDownloadChart;`. Right-side action:
- if `onLockTour != null` → existing Lock button;
- else if `onDownloadChart != null` → a **Download chart** button
  (`Icons.download_rounded`, label `tr('tour_seat_assignment.btn_download_chart')`).

In `build`, compute `canDownload = tour.status == TourStatus.locked &&
tour.buses.isNotEmpty`. Pass `onDownloadChart: canDownload ? () =>
_downloadChart(tour) : null`. Implement `_downloadChart(Tour tour)`:
1. `final saved = await ChartFooterStore.load(tour.id);`
2. `final footer = await showChartFooterSheet(context, initial: saved, tour: tour);`
   (return if null)
3. `await ChartFooterStore.save(tour.id, footer);`
4. show a generating state (e.g. boolean + snackbar/spinner), then
   `await SeatChartPdf.shareTourChartA4(tour: tour, footer: footer);`
5. wrap in try/catch → `AppSnackBar.error(tr('chart.error'))`; always clear the
   generating flag. Guard `if (!mounted) return;` after awaits.

#### 4.8 `lib/screens/notify_screen.dart`
Change `_sendOne` so that, when seats are assigned, it sends the highlighted
**image + caption** via the share sheet instead of the text-only deep-link:
1. `final footer = await ChartFooterStore.load(tour.id);`
2. `final images = await SeatChartPdf.buildPassengerChartImages(tour: tour,
   passenger: p, footer: footer);`
3. `final caption = WhatsAppService().buildTicketMessage(passenger: p, tour: tour,
   busNumber: busNo, driverName: driverName, driverPhone: driverPhone,
   handlerPhone: tour.handler?.phone);`
4. if `images.isNotEmpty`: `await Share.shareXFiles([for (final (i, png) in
   images.indexed) XFile.fromData(png, name: 'seating_${i+1}.png',
   mimeType: 'image/png')], text: caption);` then `_onSent(p.id)` + success snack.
5. else (no images / build failed) fall back to the existing
   `WhatsAppService().sendToPassenger(...)` path (unchanged behaviour).
6. try/catch around image build → on failure, fall back to text-only send.
   Keep `_sendAllPending` looping over `_sendOne` (share sheet opens per
   passenger — acceptable; do not change that contract).

`share_plus` API: `import 'package:share_plus/share_plus.dart';` →
`Share.shareXFiles(List<XFile>, {String? text})`. `XFile.fromData` from
`package:cross_file` (re-exported by share_plus).

#### 4.9 `assets/translations/{en,gu,hi}.json`
Add keys. English values shown; provide Gujarati (gu) and Hindi (hi) translations.
- `chart.col_upper` → en "Upper" / gu "ઉપર" / hi "ऊपर"
- `chart.col_lower` → en "Lower" / gu "નીચે" / hi "नीचे"
- `chart.aisle` → "A C" (same all locales)
- `chart.gaadi_number` → en "Vehicle no." / gu "ગાડી નંબર" / hi "गाड़ी नंबर"
- `chart.place` → en "Place" / gu "સ્થળ" / hi "स्थान"
- `chart.date` → en "Date" / gu "તારીખ" / hi "तारीख"
- `chart.depart_reminder` → gu "બસ ઉપાડવામાં આવશે, એ પેલા હાજર થઈ જવાનું"
  (translate for en/hi)
- `chart.generate` → "Generate chart"
- `chart.boarding_place_label` / `chart.departure_time_label` / `chart.note_label`
  (+ hints) for the footer sheet
- `chart.error` → "Couldn't create the chart. Please try again."
- `chart.generating` → "Creating chart…"
- `tour_seat_assignment.btn_download_chart` → en "Download chart" /
  gu "ચાર્ટ ડાઉનલોડ કરો" / hi "चार्ट डाउनलोड करें"

Keep all three JSON files' key sets identical.

### New tests (`test/`)

- `test/utils/seat_grid_placement_test.dart`: `rowsWithSeats`, `usedLaneCols`,
  `columns` (single-only, double-only, both+aisle, balcony), `cellFor`;
  `occupantsByBus` (double-sofa name on both berths); `displayPhone`
  (`91XXXXXXXXXX`→last10, 10-digit passthrough, junk→null, empty→null).
- `test/services/chart_footer_store_test.dart`: save→load round-trip; missing →
  empty footer. (Use `SharedPreferences.setMockInitialValues({})`.)
- `test/services/seat_chart_pdf_test.dart`: `buildTourChartPdf` returns non-empty
  bytes and page count == bus count for a 2-bus fixture (balcony + double-sofa +
  Gujarati name); `onlyBusId` → 1 page; build doesn't throw with empty footer.
  (Font fetch may need network; if unavailable in CI the try/catch fallback must
  still yield a valid PDF — assert bytes non-empty, not glyph content.)

---

## 5. Data flow

**Feature 1:** lock tour → `status == locked` → dock shows Download → tap →
load saved footer → footer sheet (edit) → save footer → build all-buses PDF
(occupants from `occupantsByBus`) → `Printing.sharePdf` → Save/Print/WhatsApp.

**Feature 2:** Notify tab (post-lock) → per-passenger Send → load saved footer →
build highlighted PNG(s) for the passenger's bus(es) → `Share.shareXFiles` with
ticket text caption → agent picks the WhatsApp chat.

## 6. Error handling

No buses / no assigned seats → Download hidden (gated on `buses.isNotEmpty`) or
"nothing to export" snackbar. Font/build/raster failure → caught; Feature 1 shows
error snackbar; Feature 2 falls back to the existing text-only deep-link. Generating
flags always cleared. All post-`await` `BuildContext` use guarded by `mounted`.

## 7. Out of scope

Bundling fonts for full offline use; editing the on-screen `CombinedSeatGrid`;
adding persistent tour DB fields for boarding place/time; broadcast-list image
sending.
