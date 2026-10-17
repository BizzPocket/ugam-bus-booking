part of 'seat_chart_pdf.dart';

// The berth table of [SeatChartPdf]: the print palette plus the table, header,
// body, aisle/balcony and occupant cell builders. Moved verbatim out of the
// class as library-private top-level members — unqualified call sites in
// seat_chart_pdf.dart are unchanged. The `pdf` package fails SILENTLY on bad
// layout (see [_berthDivided]); keep these widgets exactly as they are.

// ── Palette (light / print-friendly) ──────────────────────

final PdfColor _ink = PdfColors.grey900;
final PdfColor _inkMuted = PdfColors.grey600;
final PdfColor _border = PdfColors.grey500;
final PdfColor _headerFill = PdfColors.grey200;
final PdfColor _reserved = PdfColors.grey400;

/// Brand champagne — matches light-mode `Brand.champagneDeep` (0xFFA8854A)
/// in tokens.dart. Constructed from the literal hex so we avoid the
/// deprecated `Color.value` getter; kept in sync with the design tokens.
const PdfColor _accent = PdfColor.fromInt(0xFFA8854A);
const PdfColor _accentFill = PdfColor.fromInt(0xFFF3ECDD);
// Light GO / RET leg-tag fills (mirror the on-screen cyan / violet tint); the
// bold label on top keeps them legible even on a greyscale print.
const PdfColor _goTint = PdfColor.fromInt(0xFFD9F1F7);
const PdfColor _retTint = PdfColor.fromInt(0xFFECE4F6);

// ── Table building ────────────────────────────────────────

pw.Widget _chartTable(
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
bool _isAisleLabelRow(int rowIndex, int rowCount) =>
    rowIndex == (rowCount - 1) ~/ 2;

pw.Widget _headerCell(ChartColumn col) {
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
pw.Widget _bodyCell(
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
pw.Widget _aisleCell(
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
pw.Widget _stackedBalconyEntry(
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
pw.Widget _occupantCell(
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

pw.Widget _emptyCell({bool highlighted = false}) => pw.Container(
      height: 38,
      alignment: pw.Alignment.center,
      decoration:
          highlighted ? pw.BoxDecoration(color: _accentFill) : null,
      child: pw.SizedBox(),
    );

pw.Widget _reservedCell() => pw.Container(
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
pw.Widget _legTag(TripType? leg) {
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
pw.Widget _pickupTag(String? pickup) {
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
pw.Widget _occupantEntry(
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
bool _isBerthPair(List<SeatOccupant> occ) {
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
pw.Widget _berthDivided(pw.Widget child) => pw.Container(
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
