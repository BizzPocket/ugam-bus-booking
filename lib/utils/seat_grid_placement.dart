import '../models/seat_layout.dart';
import '../models/tour.dart';
import 'passenger_display.dart';

/// A visible column in the chart table.
///
/// Mirrors the on-screen [CombinedSeatGrid] 5-column scheme as pure data so the
/// PDF/print chart reproduces the same layout: single·upper | single·lower |
/// aisle | double·upper | double·lower. Empty lanes are dropped; the aisle only
/// appears when both sides exist or the bus has a balcony back-row pair.
enum ChartColumn { singleUpper, singleLower, aisle, doubleUpper, doubleLower }

/// Expresses the [CombinedSeatGrid] placement as data so the PDF table matches
/// the on-screen grid exactly. Pure logic — no widgets, only models.
class SeatGridPlacement {
  const SeatGridPlacement._();

  /// Row indices (0..layout.rows-1) that contain at least one seat. In order.
  static List<int> rowsWithSeats(BusLayout layout) {
    final rows = <int>[];
    for (var r = 0; r < layout.rows; r++) {
      if (layout.grid.any((c) => c.row == r && c.hasSeat)) rows.add(r);
    }
    return rows;
  }

  /// Lane cols (excludes aisle) carrying ≥1 seat anywhere. {0,1,3,4} subset.
  static Set<int> usedLaneCols(BusLayout layout) {
    final used = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat && cell.col != SeatGridCols.aisle) used.add(cell.col);
    }
    return used;
  }

  /// Ordered visible columns: each used lane, with [ChartColumn.aisle] inserted
  /// between the single side and double side when (hasLeft && hasRight) OR
  /// layout.hasBalcony. Mirrors `CombinedSeatGrid._row` exactly.
  static List<ChartColumn> columns(BusLayout layout) {
    final used = usedLaneCols(layout);
    final hasLeft = used.contains(SeatGridCols.singleUpper) ||
        used.contains(SeatGridCols.singleLower);
    final hasRight = used.contains(SeatGridCols.doubleUpper) ||
        used.contains(SeatGridCols.doubleLower);
    final showAisle = layout.hasBalcony || (hasLeft && hasRight);

    final cols = <ChartColumn>[];
    if (used.contains(SeatGridCols.singleUpper)) {
      cols.add(ChartColumn.singleUpper);
    }
    if (used.contains(SeatGridCols.singleLower)) {
      cols.add(ChartColumn.singleLower);
    }
    if (showAisle) cols.add(ChartColumn.aisle);
    // Doubles render Lower then Upper (U L | L U) so the two lower columns sit
    // toward the centre aisle — matches the on-screen CombinedSeatGrid.
    if (used.contains(SeatGridCols.doubleLower)) {
      cols.add(ChartColumn.doubleLower);
    }
    if (used.contains(SeatGridCols.doubleUpper)) {
      cols.add(ChartColumn.doubleUpper);
    }
    return cols;
  }

  /// The cell at (row, column) for a lane column, or null for the aisle column.
  /// Use [BusLayout.balconyPair] for the aisle on balcony rows (caller handles).
  static SeatCell? cellFor(BusLayout layout, int row, ChartColumn column) {
    switch (column) {
      case ChartColumn.singleUpper:
        return layout.cellAt(row, SeatGridCols.singleUpper);
      case ChartColumn.singleLower:
        return layout.cellAt(row, SeatGridCols.singleLower);
      case ChartColumn.doubleUpper:
        return layout.cellAt(row, SeatGridCols.doubleUpper);
      case ChartColumn.doubleLower:
        return layout.cellAt(row, SeatGridCols.doubleLower);
      case ChartColumn.aisle:
        return null;
    }
  }
}

/// A passenger occupying a seat, as shown in the chart cell.
class SeatOccupant {
  final String name; // passenger.displayName
  final String? phone; // already run through displayPhone()
  const SeatOccupant({required this.name, this.phone});
}

/// busId -> (seatId -> occupant), built from every passenger's assignedSeats.
///
/// A double-sofa owner's name appears on BOTH berth seatIds because each berth
/// is a distinct [SeatAssignment] on the passenger — we simply iterate every
/// assignment, so both seatIds map to the same owner (matches the screen).
Map<String, Map<String, SeatOccupant>> occupantsByBus(Tour tour) {
  final result = <String, Map<String, SeatOccupant>>{};
  for (final p in tour.passengers) {
    final occupant = SeatOccupant(
      name: p.displayName,
      phone: displayPhone(p.phone),
    );
    for (final a in p.assignedSeats) {
      (result[a.busId] ??= <String, SeatOccupant>{})[a.seatId] = occupant;
    }
  }
  return result;
}

/// Phone display rule (see spec §2): strip non-digits; if more than 10 digits
/// and starting with "91", keep the last 10; otherwise the stripped digits.
/// Empty / no digits → null. Public so tests can cover it.
String? displayPhone(String? raw) {
  if (raw == null) return null;
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  if (digits.length > 10 && digits.startsWith('91')) {
    return digits.substring(digits.length - 10);
  }
  return digits;
}
