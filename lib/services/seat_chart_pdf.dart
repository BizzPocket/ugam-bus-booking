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

part 'seat_chart_pdf_table.dart';

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
  ///
  /// **The chart names its bus by plate, for BOTH audiences.**
  ///
  /// This one builder serves the agent's downloaded/printed sheet
  /// ([shareTourChartA4]) and the image attached to each passenger's WhatsApp
  /// confirmation ([buildPassengerChartImages]). It used to print `bus.name`
  /// raw in the title and [Bus.customerLabel] on a line literally headed
  /// "ગાડી નંબર" — so neither sheet carried a vehicle number at all, and a
  /// rider standing in a car park beside two identically-named coaches had
  /// nothing to match against.
  ///
  /// Both now use [Bus.displayLabel] (`name · plate`), by explicit product
  /// decision: the passenger needs to find the physical bus as much as the
  /// agent does. The WhatsApp message BODY that carries this image says the
  /// same thing — its bus line is [Bus.displayLabel] too
  /// (`whatsapp_outbound.dart`), so the text and the chart attached to it can't
  /// name the bus two different ways.
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
    // The agent's own copy: names the vehicle by plate as well as by label.
    final bytes = await buildTourChartPdf(
      tour: tour,
      footer: footer,
      leg: leg,
    );
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
  ///
  /// [maxImages] stops once that many PNGs exist — the WhatsApp send attaches
  /// only the FIRST, so rasterising a second bus's ~8.7 MB bitmap for it was
  /// pure peak memory on a low-end phone. The images returned are the same
  /// leading ones a full render would produce.
  static Future<List<Uint8List>> buildPassengerChartImages({
    required Tour tour,
    required Passenger passenger,
    required ChartFooter footer,
    int? maxImages,
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
      if (maxImages != null && images.length >= maxImages) break;
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
          // Was raw `bus.name`, which meant the plate appeared on NEITHER
          // audience's sheet — the agent printing a chart to hand a driver had
          // no way to tell two identically-named buses apart.
          '${bus.displayLabel} · $route',
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

    // ગાડી નંબર – <bus>. The line is LABELLED "vehicle number", so on the
    // agent's own sheet it had better carry one: it printed [customerLabel] for
    // both audiences, i.e. the bus NAME under a heading that says number, which
    // is why a downloaded chart could not identify the vehicle at all.
    //
    // The recipient's copy keeps the name only — it matches the "બસ: {name}"
    // message body it is attached to, and the plate is an operational detail
    // they have no use for.
    lines.add(
      line(
        '${tr('chart.gaadi_number')} – ${bus.displayLabel}',
        bold: true,
      ),
    );

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
}
