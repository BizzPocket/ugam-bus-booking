import 'dart:typed_data';

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
import '../models/tour.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_grid_placement.dart';
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

  // ── Public API ────────────────────────────────────────────

  /// One A4 portrait page per bus (or only [onlyBusId] if given). For each bus:
  /// bordered berth table + footer block. Highlights any seatIds in
  /// [highlightByBus] (busId -> seatIds) with the brand accent fill.
  static Future<Uint8List> buildTourChartPdf({
    required Tour tour,
    required ChartFooter footer,
    String? onlyBusId,
    Map<String, Set<String>> highlightByBus = const {},
  }) async {
    final theme = await _resolveTheme();
    final doc = pw.Document(theme: theme);

    final occupants = occupantsByBus(tour);
    final buses = onlyBusId == null
        ? tour.buses
        : tour.buses.where((b) => b.id == onlyBusId).toList();

    for (final bus in buses) {
      final layout = bus.layout;
      if (layout == null) continue;
      final highlight = highlightByBus[bus.id] ?? const <String>{};
      final byId = occupants[bus.id] ?? const <String, SeatOccupant>{};

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _busTitle(tour, bus),
              pw.SizedBox(height: 10),
              _chartTable(layout, byId, highlight),
              pw.SizedBox(height: 14),
              _footerBlock(tour, bus, footer),
            ],
          ),
        ),
      );
    }

    return doc.save();
  }

  /// Feature 1: build the all-buses PDF and open the native share / print sheet.
  static Future<void> shareTourChartA4({
    required Tour tour,
    required ChartFooter footer,
  }) async {
    final bytes = await buildTourChartPdf(tour: tour, footer: footer);
    final filename =
        'seating_${tour.title.replaceAll(RegExp(r'\s+'), '_')}.pdf';
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

    final images = <Uint8List>[];
    for (final busId in seatsByBus.keys) {
      // Skip buses no longer on the tour (stale assignment).
      if (!tour.buses.any((b) => b.id == busId)) continue;

      final bytes = await buildTourChartPdf(
        tour: tour,
        footer: footer,
        onlyBusId: busId,
        highlightByBus: {busId: seatsByBus[busId]!},
      );

      await for (final page in Printing.raster(bytes, dpi: 150)) {
        images.add(await page.toPng());
      }
    }
    return images;
  }

  /// Full tour chart (every bus, NO highlight) rasterised to PNGs — one image
  /// per bus. Used to send the handler the complete chart of everyone, since the
  /// handler coordinates the whole bus and should not get a self-highlighted view.
  static Future<List<Uint8List>> buildTourChartImages({
    required Tour tour,
    required ChartFooter footer,
  }) async {
    final bytes = await buildTourChartPdf(tour: tour, footer: footer);
    final images = <Uint8List>[];
    await for (final page in Printing.raster(bytes, dpi: 150)) {
      images.add(await page.toPng());
    }
    return images;
  }

  // ── Header / footer building ──────────────────────────────

  static pw.Widget _busTitle(Tour tour, Bus bus) {
    final route = '${tour.fromCity} → ${tour.toCity}';
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

    // ગાડી નંબર – <bus number or name>
    final vehicle = bus.busNumber.isNotEmpty ? bus.busNumber : bus.name;
    lines.add(line('${tr('chart.gaadi_number')} – $vehicle', bold: true));

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

    // <note> — or fall back to the handler name when the note is empty.
    if (footer.note.isNotEmpty) {
      lines.add(line(footer.note));
    } else {
      final handler = tour.handler?.displayName;
      if (handler != null && handler.isNotEmpty) {
        lines.add(line(handler));
      }
    }

    // Contact – organiser phone, plus the handler's phone if present & different.
    final phones = <String>[];
    final organiser = tour.createdBy?.trim() ?? '';
    if (organiser.isNotEmpty) phones.add(organiser);
    final handlerPhone = tour.handler?.phone.trim() ?? '';
    if (handlerPhone.isNotEmpty && handlerPhone != organiser) {
      phones.add(handlerPhone);
    }
    if (phones.isNotEmpty) {
      lines.add(line('${tr('chart.contact')}: ${phones.join(', ')}'));
    }

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  // ── Table building ────────────────────────────────────────

  static pw.Widget _chartTable(
    BusLayout layout,
    Map<String, SeatOccupant> byId,
    Set<String> highlight,
  ) {
    final columns = SeatGridPlacement.columns(layout);
    final rows = SeatGridPlacement.rowsWithSeats(layout);

    final border = pw.TableBorder.all(color: _border, width: 0.8);

    // Column widths: aisle is narrow, lanes share the rest evenly.
    final widths = <int, pw.TableColumnWidth>{};
    for (var i = 0; i < columns.length; i++) {
      widths[i] = columns[i] == ChartColumn.aisle
          ? const pw.FixedColumnWidth(34)
          : const pw.FlexColumnWidth(1);
    }

    final tableRows = <pw.TableRow>[
      // Header row.
      pw.TableRow(
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

  /// A lane (non-aisle) body cell: occupant name + phone, blank, or reserved "—".
  static pw.Widget _bodyCell(
    SeatCell? cell,
    Map<String, SeatOccupant> byId,
    Set<String> highlight,
  ) {
    if (cell == null || cell.isEmpty || cell.seatId == null) {
      return _emptyCell();
    }
    if (cell.reserved) {
      return _reservedCell();
    }
    final occupant = byId[cell.seatId];
    final highlighted = highlight.contains(cell.seatId);
    return _occupantCell(occupant, highlighted: highlighted);
  }

  /// The aisle cell. On a balcony row it stacks the upper/lower pair occupants;
  /// on the designated mid row it shows the merged `A C` label; otherwise blank.
  static pw.Widget _aisleCell(
    BusLayout layout,
    int row, {
    required bool isMidRow,
    required Map<String, SeatOccupant> byId,
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

  /// One stacked occupant entry inside the balcony aisle cell.
  static pw.Widget _stackedBalconyEntry(
    SeatCell cell,
    Map<String, SeatOccupant> byId,
    Set<String> highlight,
  ) {
    if (cell.reserved) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Text('—',
            style: pw.TextStyle(fontSize: 9, color: _reserved)),
      );
    }
    final occupant = byId[cell.seatId];
    final highlighted = cell.seatId != null && highlight.contains(cell.seatId);
    final fill = highlighted ? _accentFill : null;
    if (occupant == null) return pw.SizedBox();
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
          pw.Text(
            occupant.name,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 11.5,
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
        ],
      ),
    );
  }

  static pw.Widget _occupantCell(
    SeatOccupant? occupant, {
    required bool highlighted,
  }) {
    if (occupant == null) return _emptyCell(highlighted: highlighted);
    final fill = highlighted ? _accentFill : null;
    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 3),
      decoration: fill == null ? null : pw.BoxDecoration(color: fill),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            occupant.name,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
              color: highlighted ? _accent : _ink,
            ),
          ),
          if (occupant.phone != null && occupant.phone!.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 2),
              child: pw.Text(
                occupant.phone!,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 12, color: _ink),
              ),
            ),
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
}
