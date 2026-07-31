import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:easy_localization/easy_localization.dart';
// ignore: unnecessary_import
import 'package:intl/intl.dart'; // DateFormat (also re-exported by easy_localization)
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/bus_details.dart';
import '../models/chart_footer.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_grid_placement.dart';
import '../utils/seat_occupants.dart';
import '../utils/time_format.dart';

/// Builds the printable A4 seating chart PDF and the per-passenger highlighted
/// chart images, reproducing the agent's manual WhatsApp chart format.
///
/// The chart is intentionally **light / print-friendly** (white ground, dark
/// ink) rather than the dark app theme. See the design contract
/// `docs/superpowers/specs/2026-06-03-seating-chart-pdf-whatsapp-design.md` §4.4.
class SeatChartPdf {
  const SeatChartPdf._();

  // ── Fonts ─────────────────────────────────────────────────
  //
  // The Noto faces (Latin + Gujarati + Devanagari) are BUNDLED as assets and
  // loaded from rootBundle, so there is no runtime download and passenger names
  // in any script render even on the very first send with no network. If an
  // asset somehow can't be read we fall back to PdfGoogleFonts (online), and if
  // THAT also fails we return null → the pdf built-in default font (Latin only,
  // missing-glyph boxes — acceptable last-resort degradation per §3).

  static pw.ThemeData? _theme;
  static bool _themeLoaded = false;

  static Future<pw.Font?> _assetFont(String path) async {
    try {
      final data = await rootBundle.load(path);
      return pw.Font.ttf(data);
    } catch (_) {
      return null;
    }
  }

  /// Resolve (and cache) the PDF theme with the Noto font stack. Returns null
  /// if fonts could not be loaded — callers pass that straight to [pw.Document]
  /// which then uses the built-in default font.
  static Future<pw.ThemeData?> _resolveTheme() async {
    if (_themeLoaded) return _theme;
    try {
      // 1) Bundled assets (offline-proof).
      var base = await _assetFont('assets/fonts/NotoSans-Regular.ttf');
      var bold = await _assetFont('assets/fonts/NotoSans-Bold.ttf');
      final fallback = <pw.Font>[];
      final guj = await _assetFont('assets/fonts/NotoSansGujarati-Regular.ttf');
      if (guj != null) fallback.add(guj);
      final dev =
          await _assetFont('assets/fonts/NotoSansDevanagari-Regular.ttf');
      if (dev != null) fallback.add(dev);

      // 2) Fall back to the online faces only if a bundled asset was missing.
      base ??= await PdfGoogleFonts.notoSansRegular();
      bold ??= await PdfGoogleFonts.notoSansBold();
      if (fallback.isEmpty) {
        try {
          fallback.add(await PdfGoogleFonts.notoSansGujaratiRegular());
        } catch (_) {}
        try {
          fallback.add(await PdfGoogleFonts.notoSansDevanagariRegular());
        } catch (_) {}
      }

      _theme = pw.ThemeData.withFont(
        base: base,
        bold: bold,
        fontFallback: fallback,
      );
    } catch (_) {
      // Any font failure → null theme → pdf default font. Never throw.
      _theme = null;
    }
    _themeLoaded = true;
    return _theme;
  }

  // ── Palette (light / print-friendly) ──────────────────────

  static final PdfColor _ink = PdfColors.grey900;
  static final PdfColor _inkMuted = PdfColors.grey600;
  static final PdfColor _border = PdfColors.grey500;
  static final PdfColor _headerFill = PdfColors.grey200;
  static final PdfColor _reserved = PdfColors.grey400;

  /// Brand champagne — matches light-mode `Brand.champagneDeep` (0xFFA8854A)
  /// in tokens.dart. Constructed from the literal hex so we avoid the
  /// deprecated `Color.value` getter; kept in sync with the design tokens.
  static const PdfColor _accent = PdfColor.fromInt(0xFFA8854A);
  static const PdfColor _accentFill = PdfColor.fromInt(0xFFF3ECDD);
  // Light GO / RET leg-tag fills (mirror the on-screen cyan / violet tint); the
  // bold label on top keeps them legible even on a greyscale print.
  static const PdfColor _goTint = PdfColor.fromInt(0xFFD9F1F7);
  static const PdfColor _retTint = PdfColor.fromInt(0xFFECE4F6);

  // ── Public API ────────────────────────────────────────────

  /// Page geometry. The margin and the resulting content width are shared by
  /// both build modes so the scale-to-fit path measures against exactly the
  /// width the flowing path lays the table out at.
  static const double _pageMargin = 28;
  static final double _contentWidth = PdfPageFormat.a4.width - _pageMargin * 2;

  /// One A4 portrait chart per bus (or only [onlyBusId] if given). For each bus:
  /// bordered berth table + footer block. Highlights any seatIds in
  /// [highlightByBus] (busId -> seatIds) with the brand accent fill.
  ///
  /// A bus chart is NOT guaranteed to fit one A4 page — a full sleeper with a
  /// name, phone, leg tag and pickup tag in every cell runs past the page — and
  /// the `pdf` package's Column DROPS the first child that overflows plus every
  /// child after it (it breaks out of the layout loop before advancing
  /// `_context.lastChild`, see pdf/src/widgets/flex.dart). A fixed [pw.Page]
  /// therefore rendered a title-only BLANK page for a busy bus, and silently ate
  /// the footer on a nearly-full one. Two overflow-proof modes replace it:
  ///
  ///  - [fitOnePage] false (print / share) — a [pw.MultiPage] flows the table
  ///    onto a second page, repeating the bus title and the column header row.
  ///  - [fitOnePage] true (the per-passenger WhatsApp image) — one page, with
  ///    the table scaled down to fit so the recipient still gets ONE image.
  ///    A table that already fits is untouched (scaleDown ⇒ factor 1).
  static Future<Uint8List> buildTourChartPdf({
    required Tour tour,
    required ChartFooter footer,
    String? onlyBusId,
    Map<String, Set<String>> highlightByBus = const {},
    CollectLeg? leg,
    bool fitOnePage = false,
  }) async {
    final theme = await _resolveTheme();
    final doc = pw.Document(theme: theme);

    final buses = onlyBusId == null
        ? tour.buses
        : tour.buses.where((b) => b.id == onlyBusId).toList();

    for (final bus in buses) {
      final layout = bus.layout;
      if (layout == null) continue;
      final highlight = highlightByBus[bus.id] ?? const <String>{};
      final byId = _occupantsForBus(tour, bus.id, leg: leg);

      if (fitOnePage) {
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(_pageMargin),
            build: (context) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _busTitle(tour, bus, leg),
                pw.SizedBox(height: 10),
                // Expanded hands the table the EXACT leftover height (the title
                // and footer are measured first), and scaleDown shrinks only
                // when the table genuinely exceeds it. The inner SizedBox pins
                // the table to the real content width so a fitting chart lays
                // out — and renders — identically to the flowing path.
                pw.Expanded(
                  child: pw.FittedBox(
                    fit: pw.BoxFit.scaleDown,
                    alignment: pw.Alignment.topCenter,
                    child: pw.SizedBox(
                      width: _contentWidth,
                      child: _chartTable(layout, byId, highlight),
                    ),
                  ),
                ),
                pw.SizedBox(height: 14),
                _footerBlock(tour, bus, footer),
              ],
            ),
          ),
        );
        continue;
      }

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(_pageMargin),
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          // On the title: a continuation page must still name its bus, so the
          // header repeats it rather than it being a one-shot flow child.
          header: (context) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 10),
            child: _busTitle(tour, bus, leg),
          ),
          build: (context) => [
            _chartTable(layout, byId, highlight),
            pw.SizedBox(height: 14),
            _footerBlock(tour, bus, footer),
          ],
        ),
      );
    }

    return doc.save();
  }

  /// Feature 1: build the all-buses PDF and open the native share / print sheet.
  ///
  /// [leg] scopes the chart to one journey: [CollectLeg.ret] prints the RETURN
  /// roster (round-trip + return-only riders) with the route arrow flipped and a
  /// RETURN banner — the chart the agent needs once the GO leg is done. Null
  /// prints the whole-journey chart.
  static Future<void> shareTourChartA4({
    required Tour tour,
    required ChartFooter footer,
    CollectLeg? leg,
  }) async {
    final bytes = await buildTourChartPdf(tour: tour, footer: footer, leg: leg);
    final legSuffix = leg == null
        ? ''
        : leg == CollectLeg.go
            ? '_go'
            : '_return';
    final filename =
        'seating_${tour.title.replaceAll(RegExp(r'\s+'), '_')}$legSuffix.pdf';
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  /// Feature 2: for each bus this passenger occupies, build a single-bus page
  /// with their seats highlighted and rasterise it to a PNG (~150 dpi). Returns
  /// one PNG per occupied bus (usually one).
  static Future<List<Uint8List>> buildPassengerChartImages({
    required Tour tour,
    required Passenger passenger,
    required ChartFooter footer,
  }) async {
    // Group the passenger's assigned seats by bus.
    final seatsByBus = <String, Set<String>>{};
    for (final a in passenger.assignedSeats) {
      (seatsByBus[a.busId] ??= <String>{}).add(a.seatId);
    }

    // Scope the chart to the recipient's OWN leg: a one-way rider sees only the
    // journey they actually travel, so a leg-shared seat shows just them — never
    // the opposite-leg stranger who reuses the seat on the other leg. Round-trip
    // riders get the whole-journey chart (leg == null).
    final leg = recipientChartLeg(passenger);

    final images = <Uint8List>[];
    for (final busId in seatsByBus.keys) {
      // Skip buses no longer on the tour (stale assignment).
      if (!tour.buses.any((b) => b.id == busId)) continue;

      final bytes = await buildTourChartPdf(
        tour: tour,
        footer: footer,
        onlyBusId: busId,
        highlightByBus: {busId: seatsByBus[busId]!},
        leg: leg,
        // The recipient gets ONE image, so a busy bus scales down rather than
        // flowing onto a second page they would never receive.
        fitOnePage: true,
      );

      // Rasterise with a hard deadline. On Android the plugin renders the page
      // into an ARGB_8888 Bitmap on a background thread whose catch block only
      // handles IOException — an OutOfMemoryError there kills that thread
      // WITHOUT ever signalling the end of the stream, so this `await for`
      // would otherwise wait forever and freeze the whole send behind a
      // spinner. A timeout converts that hang into a reportable failure.
      await for (final page
          in Printing.raster(bytes, dpi: _rasterDpi).timeout(_rasterTimeout)) {
        images.add(await page.toPng());
      }
    }
    return images;
  }

  /// Rasterisation resolution for the WhatsApp chart image. A4 at this dpi is
  /// ~1240x1754px — comfortably legible in WhatsApp while keeping the Android
  /// bitmap (width x height x 4 bytes, allocated twice: Bitmap + ByteBuffer)
  /// well inside a mid-range device's budget.
  static const double _rasterDpi = 150;

  /// Per-page rasterisation deadline. Generous enough for a slow device, short
  /// enough that a stuck native render surfaces as an error instead of a hang.
  static const Duration _rasterTimeout = Duration(seconds: 45);

  /// The journey leg a recipient's per-passenger chart should be scoped to,
  /// derived from the SAME [Passenger.tripType] the occupant filter keys off
  /// (so the recipient is never filtered off their own seat): an outbound-only
  /// rider → [CollectLeg.go], a return-only rider → [CollectLeg.ret], a
  /// round-trip (or mixed) rider → null, i.e. the whole-journey chart.
  @visibleForTesting
  static CollectLeg? recipientChartLeg(Passenger passenger) {
    final t = passenger.tripType;
    if (!t.isOneWay) return null;
    return t.usesOutbound ? CollectLeg.go : CollectLeg.ret;
  }

  // ── Header / footer building ──────────────────────────────

  static pw.Widget _busTitle(Tour tour, Bus bus, [CollectLeg? leg]) {
    // On the RETURN leg the bus drives the other way, so flip the route arrow
    // so the chart unmistakably reads as the homeward journey.
    //
    // The separator is '»', NOT '→': none of the bundled Noto faces (Latin,
    // Gujarati, Devanagari) carry U+2192, so the arrow printed as a
    // missing-glyph box on every chart. '»' lives in Latin-1, is covered by the
    // base face, and still reads directionally.
    final route = leg == CollectLeg.ret
        ? '${tour.toCity} » ${tour.fromCity}'
        : '${tour.fromCity} » ${tour.toCity}';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          tour.title,
          style: pw.TextStyle(
            fontSize: 19,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '${bus.name} · $route',
          style: pw.TextStyle(fontSize: 13, color: _inkMuted),
        ),
        // Leg banner — only on a one-way recipient's leg-scoped chart. Makes the
        // GO vs RETURN journey explicit so a one-way rider never reads their own
        // seat as the wrong leg.
        if (leg != null) ...[
          pw.SizedBox(height: 6),
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 9),
            decoration: pw.BoxDecoration(
              color: _accentFill,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Text(
              leg == CollectLeg.go
                  ? tr('chart.leg_go')
                  : tr('chart.leg_return'),
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: _accent,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static pw.Widget _footerBlock(Tour tour, Bus bus, ChartFooter footer) {
    final lines = <pw.Widget>[];

    // The reference chart's footer is large and fully bold — every line bold by
    // default; pass bold:false for any line that should be lighter.
    pw.Widget line(String text, {bool bold = true}) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Text(
            text,
            style: pw.TextStyle(
              fontSize: 15,
              color: _ink,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        );

    // ગાડી નંબર – <bus name>. This chart is recipient-facing (it's the image
    // attached to each passenger's WhatsApp confirmation), so it uses the
    // customer label — the NAME only, matching the "બસ: {name}" message body.
    // The registration plate is an agent-only detail; it stays on the admin
    // screens' [Bus.displayLabel].
    lines.add(line('${tr('chart.gaadi_number')} – ${bus.customerLabel}', bold: true));

    // સ્થળ.. <boarding place> — per-bus boarding point overrides the tour footer.
    final place =
        bus.boardingPoint.isNotEmpty ? bus.boardingPoint : footer.boardingPlace;
    if (place.isNotEmpty) {
      lines.add(line('${tr('chart.place')}.. $place'));
    }

    // તારીખ <date> <departure time> — <reminder> — the bus's own departure time
    // (localized) overrides the tour-level footer time.
    final dateStr = DateFormat('d-M-yy').format(tour.departureDate);
    final timeStr = (bus.departureTime?.isNotEmpty == true)
        ? formatHhMm(bus.departureTime)
        : (footer.departureTime.isNotEmpty ? footer.departureTime : null);
    final dateLine = StringBuffer('${tr('chart.date')} $dateStr');
    if (timeStr != null && timeStr.isNotEmpty) {
      dateLine.write(' $timeStr');
    }
    dateLine.write(' — ${tr('chart.depart_reminder')}');
    lines.add(line(dateLine.toString()));

    // THIS bus's handler is the on-the-ground contact (per-bus handler wins,
    // else the tour-level handler). The admin/organiser phone is intentionally
    // NOT printed — passengers should reach their bus handler, not the office.
    final handlerId = bus.handlerPassengerId ?? tour.handlerId;
    final handlerMatch = handlerId == null
        ? const <Passenger>[]
        : tour.passengers.where((p) => p.id == handlerId).toList();
    final handler = handlerMatch.isNotEmpty ? handlerMatch.first : tour.handler;
    final handlerName = handler?.displayName.trim() ?? '';
    final handlerPhone = handler?.phone.trim() ?? '';

    // Optional free-text note from the agent.
    if (footer.note.isNotEmpty) {
      lines.add(line(footer.note));
    }

    // Contact – the per-bus HANDLER (name + phone), never the admin. ALWAYS
    // shown so the passenger has a number to reach on the day, even when the
    // handler is also seated on this bus. Falls back to the name alone if the
    // handler has no phone on file.
    if (handlerPhone.isNotEmpty) {
      final label =
          handlerName.isNotEmpty ? '$handlerName – $handlerPhone' : handlerPhone;
      lines.add(line('${tr('chart.contact')}: $label'));
    } else if (handlerName.isNotEmpty) {
      lines.add(line(handlerName));
    }

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  // ── Occupant resolution (leg-aware) ───────────────────────
  //
  // A single physical seat can be LEG-SHARED: a GO-only rider and a different
  // RET-only rider both hold it on disjoint legs. The chart must print BOTH —
  // otherwise a one-leg booker never sees their own name on the per-person
  // chart. We resolve through the shared leg-aware [occupantListForBus] (the
  // same truth the on-screen handler chart uses) which yields the de-duped,
  // GO-first occupant list per seat — a whole double held solo still collapses
  // to one name.

  static Map<String, List<SeatOccupant>> _occupantsForBus(
    Tour tour,
    String busId, {
    CollectLeg? leg,
  }) {
    // Leg scoping keys on the leg the rider holds THIS SEAT on
    // ([Passenger.legForSeat]) — the canonical per-seat truth — not on the
    // coarse passenger-level tripType. A rider with a same-type one-way split
    // (a GO seat and a RET seat) is otherwise printed on BOTH seats of a
    // leg-scoped chart, putting a phantom name on a berth they don't ride.
    bool ridesLeg(Passenger p, String seatId) {
      final l = p.legForSeat(seatId, busId: busId);
      return leg == CollectLeg.go ? l.usesOutbound : l.usesReturn;
    }

    return {
      for (final e in occupantListForBus(tour.passengers, busId).entries)
        e.key: [
          for (final p in (leg == null
              ? e.value
              : e.value.where((p) => ridesLeg(p, e.key))))
            SeatOccupant(
              name: p.displayName,
              phone: displayPhone(p.phone),
              // The leg THIS rider holds this seat on, so the printed cell can
              // tag them GO / RET (a leg-shared seat lists both legs).
              leg: p.legForSeat(e.key, busId: busId),
              // Boarding point for this rider, so the handler's printed chart
              // shows where to collect each passenger.
              pickup: p.pickupLocationName,
            ),
        ],
    };
  }

  /// Test seam: the exact per-seat occupant NAMES the chart will draw for
  /// [busId], GO-leg first. Pass [leg] to scope the names to one journey leg
  /// (a one-way recipient's chart) — a leg-shared seat then collapses to just
  /// that leg's holder; null keeps both. Used to lock leg-shared rendering
  /// without needing the pdfium rasterizer (unavailable under `flutter test`).
  @visibleForTesting
  static Map<String, List<String>> debugOccupantNamesForBus(
    Tour tour,
    String busId, {
    CollectLeg? leg,
  }) =>
      {
        for (final e in _occupantsForBus(tour, busId, leg: leg).entries)
          e.key: [for (final o in e.value) o.name],
      };

  // ── Table building ────────────────────────────────────────

  static pw.Widget _chartTable(
    BusLayout layout,
    Map<String, List<SeatOccupant>> byId,
    Set<String> highlight,
  ) {
    final columns = SeatGridPlacement.columns(layout);
    final rows = SeatGridPlacement.rowsWithSeats(layout);

    final border = pw.TableBorder.all(color: _border, width: 0.8);

    // Column widths: the aisle is a narrow divider (just the "A C" label) UNLESS
    // this layout has BALCONY (middle) seats — those seats render their
    // occupants INTO the aisle cell, so a 34pt-wide column crams the name+phone
    // and the text spills outside the chart. When balcony seats exist, the aisle
    // becomes a full seating lane so names fit like every other column.
    final hasBalconySeats = rows.any((row) {
      final pair = layout.balconyPair(row);
      return pair.upper.hasSeat || pair.lower.hasSeat;
    });
    final widths = <int, pw.TableColumnWidth>{};
    for (var i = 0; i < columns.length; i++) {
      widths[i] = columns[i] == ChartColumn.aisle
          ? (hasBalconySeats
              ? const pw.FlexColumnWidth(1)
              : const pw.FixedColumnWidth(34))
          : const pw.FlexColumnWidth(1);
    }

    final tableRows = <pw.TableRow>[
      // Header row. `repeat` keeps the ઉપર / નીચે lane labels at the top of a
      // continuation page when a busy bus flows past one A4 sheet.
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(color: _headerFill),
        children: [
          for (final col in columns) _headerCell(col),
        ],
      ),
    ];

    // Body rows — one per row that contains seats.
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final cells = <pw.Widget>[];
      for (var c = 0; c < columns.length; c++) {
        final col = columns[c];
        if (col == ChartColumn.aisle) {
          cells.add(
            _aisleCell(
              layout,
              row,
              isMidRow: _isAisleLabelRow(i, rows.length),
              byId: byId,
              highlight: highlight,
            ),
          );
        } else {
          final cell = SeatGridPlacement.cellFor(layout, row, col);
          cells.add(_bodyCell(cell, byId, highlight));
        }
      }
      tableRows.add(pw.TableRow(children: cells));
    }

    return pw.Table(
      border: border,
      columnWidths: widths,
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: tableRows,
    );
  }

  /// The body row that should carry the merged `A C` label — roughly mid-height
  /// of the table so it reads like a vertically-merged aisle column.
  static bool _isAisleLabelRow(int rowIndex, int rowCount) =>
      rowIndex == (rowCount - 1) ~/ 2;

  static pw.Widget _headerCell(ChartColumn col) {
    String label;
    switch (col) {
      case ChartColumn.singleUpper:
      case ChartColumn.doubleUpper:
        label = tr('chart.col_upper');
        break;
      case ChartColumn.singleLower:
      case ChartColumn.doubleLower:
        label = tr('chart.col_lower');
        break;
      case ChartColumn.aisle:
        label = '';
        break;
    }
    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(vertical: 7, horizontal: 2),
      child: pw.Text(
        label,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 16,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    );
  }

  /// A lane (non-aisle) body cell: occupant name(s) + phone, blank, or
  /// reserved "—". A leg-shared seat carries BOTH the GO and RET occupant.
  static pw.Widget _bodyCell(
    SeatCell? cell,
    Map<String, List<SeatOccupant>> byId,
    Set<String> highlight,
  ) {
    if (cell == null || cell.isEmpty || cell.seatId == null) {
      return _emptyCell();
    }
    if (cell.reserved) {
      return _reservedCell();
    }
    final occupants = byId[cell.seatId] ?? const <SeatOccupant>[];
    final highlighted = highlight.contains(cell.seatId);
    return _occupantCell(
      occupants,
      highlighted: highlighted,
      isDouble: cell.seatType == SeatType.doubleSofa,
    );
  }

  /// The aisle cell. On a balcony row it stacks the upper/lower pair occupants;
  /// on the designated mid row it shows the merged `A C` label; otherwise blank.
  static pw.Widget _aisleCell(
    BusLayout layout,
    int row, {
    required bool isMidRow,
    required Map<String, List<SeatOccupant>> byId,
    required Set<String> highlight,
  }) {
    final pair = layout.balconyPair(row);
    final hasBalconyHere = pair.upper.hasSeat || pair.lower.hasSeat;

    if (hasBalconyHere) {
      final children = <pw.Widget>[];
      if (pair.upper.hasSeat) {
        children.add(
          _stackedBalconyEntry(pair.upper, byId, highlight),
        );
      }
      if (pair.lower.hasSeat) {
        children.add(
          _stackedBalconyEntry(pair.lower, byId, highlight),
        );
      }
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: children,
        ),
      );
    }

    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: isMidRow
          ? pw.Text(
              tr('chart.aisle'),
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
            )
          : pw.SizedBox(),
    );
  }

  /// One stacked occupant entry inside the balcony aisle cell. A leg-shared
  /// seat lists both the GO and RET occupant.
  static pw.Widget _stackedBalconyEntry(
    SeatCell cell,
    Map<String, List<SeatOccupant>> byId,
    Set<String> highlight,
  ) {
    if (cell.reserved) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Text('—',
            style: pw.TextStyle(fontSize: 9, color: _reserved)),
      );
    }
    final occupants = byId[cell.seatId] ?? const <SeatOccupant>[];
    final highlighted = cell.seatId != null && highlight.contains(cell.seatId);
    final fill = highlighted ? _accentFill : null;
    if (occupants.isEmpty) return pw.SizedBox();

    // Same berth-pair split as the lane cell: two people sharing one balcony
    // double sofa render LEFT | RIGHT with a dashed divider (leg-share + quads
    // still stack below).
    if (cell.seatType == SeatType.doubleSofa && _isBerthPair(occupants)) {
      return pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 1),
        padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        decoration: fill == null
            ? null
            : pw.BoxDecoration(
                color: fill,
                borderRadius: pw.BorderRadius.circular(3),
              ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              child: _occupantEntry(occupants[0],
                  nameSize: 10, phoneSize: 9, highlighted: highlighted),
            ),
            pw.Expanded(
              child: _berthDivided(
                _occupantEntry(occupants[1],
                    nameSize: 10, phoneSize: 9, highlighted: highlighted),
              ),
            ),
          ],
        ),
      );
    }

    // Tighten the name font when two leg-shared riders must share the cell.
    final nameSize = occupants.length > 1 ? 10.0 : 11.5;
    return pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 1),
      padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      decoration: fill == null
          ? null
          : pw.BoxDecoration(
              color: fill,
              borderRadius: pw.BorderRadius.circular(3),
            ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          for (final occupant in occupants) ...[
            pw.Text(
              occupant.name,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: nameSize,
                fontWeight: pw.FontWeight.bold,
                color: highlighted ? _accent : _ink,
              ),
            ),
            if (occupant.phone != null && occupant.phone!.isNotEmpty)
              pw.Text(
                occupant.phone!,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 9.5, color: _ink),
              ),
            _legTag(occupant.leg),
            _pickupTag(occupant.pickup),
          ],
        ],
      ),
    );
  }

  /// A lane body cell's occupant block. Lists every distinct occupant on the
  /// seat (GO first); a leg-shared seat shows both riders so neither leg's
  /// booker is dropped from the per-person chart.
  static pw.Widget _occupantCell(
    List<SeatOccupant> occupants, {
    required bool highlighted,
    required bool isDouble,
  }) {
    if (occupants.isEmpty) return _emptyCell(highlighted: highlighted);
    final fill = highlighted ? _accentFill : null;
    // Two leg-shared riders share one cell — shrink the name/phone so both fit.
    final shared = occupants.length > 1;
    final nameSize = shared ? 12.5 : 16.0;
    final phoneSize = shared ? 10.0 : 12.0;

    // Two DIFFERENT people, each holding a berth of the SAME double sofa, render
    // LEFT | RIGHT with a dashed "sofa breaker" between them — matching the
    // on-screen split tile. A single berth leg-shared by a GO-only + a RET-only
    // rider, plus 3-4 rider quads, keep the vertical stack below.
    if (isDouble && _isBerthPair(occupants)) {
      return pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        decoration: fill == null ? null : pw.BoxDecoration(color: fill),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              child: _occupantEntry(occupants[0],
                  nameSize: nameSize, phoneSize: phoneSize, highlighted: highlighted),
            ),
            pw.Expanded(
              child: _berthDivided(
                _occupantEntry(occupants[1],
                    nameSize: nameSize,
                    phoneSize: phoneSize,
                    highlighted: highlighted),
              ),
            ),
          ],
        ),
      );
    }

    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 3),
      decoration: fill == null ? null : pw.BoxDecoration(color: fill),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < occupants.length; i++) ...[
            if (i > 0) pw.SizedBox(height: 3),
            pw.Text(
              occupants[i].name,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: nameSize,
                fontWeight: pw.FontWeight.bold,
                color: highlighted ? _accent : _ink,
              ),
            ),
            if (occupants[i].phone != null && occupants[i].phone!.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 2),
                child: pw.Text(
                  occupants[i].phone!,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: phoneSize, color: _ink),
                ),
              ),
            _legTag(occupants[i].leg),
            _pickupTag(occupants[i].pickup),
          ],
        ],
      ),
    );
  }

  static pw.Widget _emptyCell({bool highlighted = false}) => pw.Container(
        height: 38,
        alignment: pw.Alignment.center,
        decoration:
            highlighted ? pw.BoxDecoration(color: _accentFill) : null,
        child: pw.SizedBox(),
      );

  static pw.Widget _reservedCell() => pw.Container(
        height: 38,
        alignment: pw.Alignment.center,
        child: pw.Text(
          '—',
          style: pw.TextStyle(fontSize: 11, color: _reserved),
        ),
      );

  /// A GO / RET tag for a ONE-WAY occupant on the printed chart (a round-trip
  /// rider gets none). Colour-coded like the on-screen tint AND labelled, so a
  /// greyscale print still tells the admin WHICH leg the rider is on — the key
  /// missing detail on a leg-shared seat (e.g. one rider GO, another RET).
  static pw.Widget _legTag(TripType? leg) {
    final String? label = leg == TripType.outboundOnly
        ? tr('chart.leg_go')
        : leg == TripType.returnOnly
            ? tr('chart.leg_ret')
            : null;
    if (label == null) return pw.SizedBox();
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 2),
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: pw.BoxDecoration(
        color: leg == TripType.outboundOnly ? _goTint : _retTint,
        border: pw.Border.all(color: _border, width: 0.5),
        borderRadius: pw.BorderRadius.circular(3),
      ),
      child: pw.Text(
        label,
        style: pw.TextStyle(
          fontSize: 8.5,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    );
  }

  /// A small boarding-point tag under a rider on the printed chart, so the
  /// handler can see where to collect each passenger. Renders nothing when the
  /// rider has no pickup point (the field is optional at booking).
  static pw.Widget _pickupTag(String? pickup) {
    final label = (pickup ?? '').trim();
    if (label.isEmpty) return pw.SizedBox();
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 2),
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        border: pw.Border.all(color: _border, width: 0.5),
        borderRadius: pw.BorderRadius.circular(3),
      ),
      child: pw.Text(
        label,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: 8, color: _inkMuted),
      ),
    );
  }

  /// One rider's name + phone + leg/pickup tags as a vertical block. Used to
  /// fill each half of a side-by-side double-sofa berth split.
  static pw.Widget _occupantEntry(
    SeatOccupant o, {
    required double nameSize,
    required double phoneSize,
    required bool highlighted,
  }) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      mainAxisAlignment: pw.MainAxisAlignment.center,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(
          o.name,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: nameSize,
            fontWeight: pw.FontWeight.bold,
            color: highlighted ? _accent : _ink,
          ),
        ),
        if (o.phone != null && o.phone!.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Text(
              o.phone!,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: phoneSize, color: _ink),
            ),
          ),
        _legTag(o.leg),
        _pickupTag(o.pickup),
      ],
    );
  }

  /// True when two DIFFERENT passengers each hold a berth of one double sofa —
  /// i.e. NOT a single berth leg-shared by a GO-only + a RET-only rider (that
  /// stays stacked, mirroring the on-screen `resolveSeatRender` leg-share rule).
  /// Two same-leg berth-owners (both full, or both one-way same leg) DO split.
  static bool _isBerthPair(List<SeatOccupant> occ) {
    if (occ.length != 2) return false;
    final hasGoOnly = occ.any((o) => o.leg == TripType.outboundOnly);
    final hasRetOnly = occ.any((o) => o.leg == TripType.returnOnly);
    return !(hasGoOnly && hasRetOnly);
  }

  /// The dashed "sofa breaker" between the two berths of a shared double sofa,
  /// drawn as a LEFT BORDER on the second berth rather than as a standalone
  /// divider widget.
  ///
  /// This is load-bearing, not cosmetic. The divider used to be a height-less
  /// `Container(width: 1)` stretched by the parent Row's
  /// `CrossAxisAlignment.stretch` — and pdf's Flex implements stretch as
  /// `minHeight = maxHeight = constraints.maxHeight`. A table cell hands its
  /// child UNBOUNDED height, so that resolved to an **infinite-height** divider
  /// → infinite cell → infinite table. The page Column then dropped the table
  /// (and the footer) outright and printed a title-only BLANK sheet for every
  /// bus that had a double sofa shared by two different riders. A border on a
  /// real child sizes itself to that child, so nothing can run away.
  static pw.Widget _berthDivided(pw.Widget child) => pw.Container(
        margin: const pw.EdgeInsets.only(left: 3),
        padding: const pw.EdgeInsets.only(left: 4),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            left: pw.BorderSide(
              color: _reserved,
              width: 0.8,
              style: pw.BorderStyle.dashed,
            ),
          ),
        ),
        child: child,
      );
}
