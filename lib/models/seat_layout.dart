import 'bus_type.dart';
import 'seat_type.dart';

/// A single cell in the bus seat grid.
///
/// If [seatType] is null, this cell is empty (aisle / door / gap).
/// If [seatType] is set, [seatId] is the auto-generated ID like "DL3", "SU1", "ST2".
class SeatCell {
  final int row;
  final int col;
  final SeatType? seatType;
  final SeatPosition? position; // null for Seater and for empty cells
  final String? seatId; // auto-generated, e.g. "DL3"

  const SeatCell({
    required this.row,
    required this.col,
    this.seatType,
    this.position,
    this.seatId,
  });

  bool get isEmpty => seatType == null;
  bool get hasSeat => seatType != null;

  /// Human-readable label for the seat type at this cell.
  String get typeLabel =>
      seatType != null ? seatTypeLabel(seatType!, position) : 'Empty';

  Map<String, dynamic> toMap() {
    return {
      'row': row,
      'col': col,
      if (seatType != null) 'seatType': seatType!.name,
      if (position != null) 'position': position!.name,
      if (seatId != null) 'seatId': seatId,
    };
  }

  factory SeatCell.fromMap(Map<String, dynamic> map) {
    final typeStr = map['seatType'] as String?;
    return SeatCell(
      row: (map['row'] as num).toInt(),
      col: (map['col'] as num).toInt(),
      seatType: typeStr != null ? SeatType.fromString(typeStr) : null,
      position: SeatPosition.fromString(map['position'] as String?),
      seatId: map['seatId'] as String?,
    );
  }

  SeatCell copyWith({
    SeatType? seatType,
    SeatPosition? position,
    String? seatId,
    bool clearSeat = false,
  }) {
    if (clearSeat) {
      return SeatCell(row: row, col: col);
    }
    return SeatCell(
      row: row,
      col: col,
      seatType: seatType ?? this.seatType,
      position: position ?? this.position,
      seatId: seatId ?? this.seatId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatCell && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);
}

/// The visual seat layout for a bus.
///
/// Contains two decks (lower and upper), each a 2D grid of [SeatCell]s.
/// For non-sleeper buses, the upper deck is all empty cells.
class BusLayout {
  final int rows;
  final int cols;
  final List<SeatCell> lowerDeck; // flattened row-major; row × col cells
  final List<SeatCell> upperDeck;

  const BusLayout({
    required this.rows,
    required this.cols,
    required this.lowerDeck,
    required this.upperDeck,
  });

  /// Create an empty layout with the given dimensions.
  factory BusLayout.empty(int rows, int cols) {
    final lower = <SeatCell>[];
    final upper = <SeatCell>[];
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        lower.add(SeatCell(row: r, col: c));
        upper.add(SeatCell(row: r, col: c));
      }
    }
    return BusLayout(
      rows: rows,
      cols: cols,
      lowerDeck: lower,
      upperDeck: upper,
    );
  }

  /// Generate a layout from a [busType] and total seat count, plus optional
  /// per-class counts:
  ///   - [seaterCount]      — number of seater berths (only used for `mixed`).
  ///   - [singleSofaCount]  — how many sleeper berths should be Single Sofa
  ///     (1-person berth). The remaining sleeper berths become Double Sofa
  ///     (2-person shared berth). Defaults to 0 so legacy callers get the
  ///     previous all-double-sofa behaviour.
  ///
  /// Layout mimics a real Indian sleeper bus (2x1 berth split):
  ///   col 0      : Single Sofa lane (1-wide berths, one per row)
  ///   col 1      : aisle (always empty)
  ///   col 2, 3   : Double Sofa lane (2-wide berths, two per row)
  /// Seaters (mixed buses) fill row-major below the sleeper rows.
  /// If only one type exists (all-double or all-single), the layout
  /// fills row-by-row to avoid one-column waste.
  factory BusLayout.generate({
    required BusType busType,
    required int totalSeats,
    int seaterCount = 0,
    int singleSofaCount = 0,
  }) {
    final int cols = busType == BusType.seater ? 5 : 4;

    int sleeperTotal;
    int seaterTotal;
    switch (busType) {
      case BusType.sleeper:
        sleeperTotal = totalSeats;
        seaterTotal = 0;
        break;
      case BusType.seater:
        sleeperTotal = 0;
        seaterTotal = totalSeats;
        break;
      case BusType.mixed:
        seaterTotal = seaterCount.clamp(0, totalSeats);
        sleeperTotal = totalSeats - seaterTotal;
        break;
    }

    final singleTotal = singleSofaCount.clamp(0, sleeperTotal);
    final doubleTotal = sleeperTotal - singleTotal;

    // Distribute sleepers ~evenly across the two decks. Lower deck gets the
    // ceiling so single-row buses still produce a valid layout.
    final singleLower = (singleTotal / 2).ceil();
    final singleUpper = singleTotal - singleLower;
    final doubleLower = (doubleTotal / 2).ceil();
    final doubleUpper = doubleTotal - doubleLower;
    final seaterLower = seaterTotal; // seaters stay on lower deck

    /// Lay out sleeper berths in two lanes (singles col 0, doubles cols 2-3)
    /// when BOTH types are present. When only one type exists, we still
    /// preserve the aisle (col 1) to prevent blocked walking paths.
    void fillSleeperDeck(
      List<SeatCell> cells,
      int singles,
      int doubles,
      SeatPosition position,
      String idPrefix,
      int Function() nextId,
    ) {
      if (singles > 0 && doubles > 0) {
        // Mixed deck — left lane = singles (col 0), right lane = doubles (cols 2-3)
        for (var i = 0; i < singles; i++) {
          cells.add(SeatCell(
            row: i,
            col: 0,
            seatType: SeatType.singleSofa,
            position: position,
            seatId: '$idPrefix${nextId()}',
          ));
        }
        for (var i = 0; i < doubles; i++) {
          cells.add(SeatCell(
            row: i ~/ 2,
            col: 2 + (i % 2),
            seatType: SeatType.doubleSofa,
            position: position,
            seatId: '$idPrefix${nextId()}',
          ));
        }
      } else if (singles > 0) {
        // Only singles — 2+1 layout with aisle at col 1 (singles at col 0, 2, 3)
        for (var i = 0; i < singles; i++) {
          final row = i ~/ 3;
          final cInRow = i % 3;
          cells.add(SeatCell(
            row: row,
            col: cInRow == 0 ? 0 : cInRow + 1,
            seatType: SeatType.singleSofa,
            position: position,
            seatId: '$idPrefix${nextId()}',
          ));
        }
      } else if (doubles > 0) {
        // Only doubles — 2+1 layout with aisle at col 1 (doubles at col 2, 3)
        for (var i = 0; i < doubles; i++) {
          cells.add(SeatCell(
            row: i ~/ 2,
            col: 2 + (i % 2),
            seatType: SeatType.doubleSofa,
            position: position,
            seatId: '$idPrefix${nextId()}',
          ));
        }
      }
    }

    final lowerCells = <SeatCell>[];
    final upperCells = <SeatCell>[];
    var lowerIdCounter = 0;
    var upperIdCounter = 0;

    fillSleeperDeck(
      lowerCells,
      singleLower,
      doubleLower,
      SeatPosition.lower,
      'L',
      () => ++lowerIdCounter,
    );
    fillSleeperDeck(
      upperCells,
      singleUpper,
      doubleUpper,
      SeatPosition.upper,
      'U',
      () => ++upperIdCounter,
    );

    // Sleeper rows occupied on the lower deck, so seaters can sit below.
    int sleeperLowerRows;
    if (singleLower > 0 && doubleLower > 0) {
      final singleRows = singleLower;
      final doubleRows = (doubleLower / 2).ceil();
      sleeperLowerRows = singleRows > doubleRows ? singleRows : doubleRows;
    } else if (singleLower > 0) {
      sleeperLowerRows = (singleLower / 3).ceil();
    } else if (doubleLower > 0) {
      sleeperLowerRows = (doubleLower / 2).ceil();
    } else {
      sleeperLowerRows = 0;
    }

    if (busType == BusType.seater) {
      // Standard 2+2 layout (cols = 5, aisle = 2, seats = 0, 1, 3, 4)
      for (var i = 0; i < seaterLower; i++) {
        final rowOffset = i ~/ 4;
        final cInRow = i % 4;
        lowerCells.add(SeatCell(
          row: rowOffset,
          col: cInRow < 2 ? cInRow : cInRow + 1,
          seatType: SeatType.seater,
          position: null,
          seatId: 'L${++lowerIdCounter}',
        ));
      }
    } else {
      // Mixed seater rows — 2+1 layout (cols = 4, aisle = 1, seats = 0, 2, 3)
      for (var i = 0; i < seaterLower; i++) {
        final rowOffset = i ~/ 3;
        final cInRow = i % 3;
        lowerCells.add(SeatCell(
          row: sleeperLowerRows + rowOffset,
          col: cInRow == 0 ? 0 : cInRow + 1,
          seatType: SeatType.seater,
          position: null,
          seatId: 'L${++lowerIdCounter}',
        ));
      }
    }

    int rowsFor(List<SeatCell> cells) {
      var maxRow = -1;
      for (final c in cells) {
        if (c.row > maxRow) maxRow = c.row;
      }
      return maxRow + 1;
    }

    final lowerRows = rowsFor(lowerCells);
    final upperRows = rowsFor(upperCells);
    final maxRows = lowerRows > upperRows ? lowerRows : upperRows;

    return BusLayout(
      rows: maxRows == 0 ? 1 : maxRows,
      cols: cols,
      lowerDeck: lowerCells,
      upperDeck: upperCells,
    )._regenerateIds();
  }

  /// Get a cell from the lower deck by position.
  SeatCell getLowerCell(int row, int col) =>
      lowerDeck.firstWhere((c) => c.row == row && c.col == col,
          orElse: () => SeatCell(row: row, col: col));

  /// Get a cell from the upper deck by position.
  SeatCell getUpperCell(int row, int col) =>
      upperDeck.firstWhere((c) => c.row == row && c.col == col,
          orElse: () => SeatCell(row: row, col: col));

  /// Count of seats (non-empty cells) across both decks.
  int get totalSeats =>
      lowerDeck.where((c) => c.hasSeat).length +
      upperDeck.where((c) => c.hasSeat).length;

  /// Count seats by type+position across both decks.
  Map<String, int> get seatCounts {
    final counts = <String, int>{};
    for (final cell in [...lowerDeck, ...upperDeck]) {
      if (cell.hasSeat) {
        final key = seatIdPrefix(cell.seatType!, cell.position);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// All seat IDs across both decks.
  List<String> get allSeatIds => [
    ...lowerDeck.where((c) => c.hasSeat).map((c) => c.seatId!),
    ...upperDeck.where((c) => c.hasSeat).map((c) => c.seatId!),
  ];

  /// Returns a new layout with updated cell at (row, col) on the given deck.
  BusLayout updateCell({
    required bool isUpperDeck,
    required int row,
    required int col,
    required SeatCell newCell,
  }) {
    final deck = isUpperDeck
        ? List<SeatCell>.from(upperDeck)
        : List<SeatCell>.from(lowerDeck);
    final idx = deck.indexWhere((c) => c.row == row && c.col == col);
    if (idx >= 0) {
      deck[idx] = newCell;
    } else {
      deck.add(newCell);
    }

    final updatedLayout = BusLayout(
      rows: rows,
      cols: cols,
      lowerDeck: isUpperDeck ? lowerDeck : deck,
      upperDeck: isUpperDeck ? deck : upperDeck,
    );

    // Re-generate all seat IDs after any cell change
    return updatedLayout._regenerateIds();
  }

  /// Re-generate seat IDs in row-major order across both decks.
  /// IDs are unique per prefix (e.g. DL1, DL2, DL3…).
  BusLayout _regenerateIds() {
    final counters = <String, int>{};

    List<SeatCell> regenerate(List<SeatCell> deck) {
      return deck.map((cell) {
        if (cell.isEmpty) return cell;
        final prefix = seatIdPrefix(cell.seatType!, cell.position);
        final num = (counters[prefix] ?? 0) + 1;
        counters[prefix] = num;
        return SeatCell(
          row: cell.row,
          col: cell.col,
          seatType: cell.seatType,
          position: cell.position,
          seatId: '$prefix$num',
        );
      }).toList();
    }

    // Lower deck first, then upper deck — row-major within each
    final newLower = regenerate(lowerDeck);
    final newUpper = regenerate(upperDeck);

    return BusLayout(
      rows: rows,
      cols: cols,
      lowerDeck: newLower,
      upperDeck: newUpper,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'rows': rows,
      'cols': cols,
      'lowerDeck': lowerDeck.map((c) => c.toMap()).toList(),
      'upperDeck': upperDeck.map((c) => c.toMap()).toList(),
    };
  }

  factory BusLayout.fromMap(Map<String, dynamic> map) {
    return BusLayout(
      rows: (map['rows'] as num).toInt(),
      cols: (map['cols'] as num).toInt(),
      lowerDeck: (map['lowerDeck'] as List)
          .map((e) => SeatCell.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
      upperDeck: (map['upperDeck'] as List)
          .map((e) => SeatCell.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}
