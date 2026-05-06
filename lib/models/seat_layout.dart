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

  /// Generate a layout from a [busType] and total seat count, plus an
  /// optional [seaterCount] used only for `mixed`. Lays cells out 4 columns
  /// wide. Sleepers split half lower / half upper as `doubleSofa`. Seaters
  /// live on the lower deck only with `null` position.
  factory BusLayout.generate({
    required BusType busType,
    required int totalSeats,
    int seaterCount = 0,
  }) {
    const cols = 4;

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

    final sleeperLower = (sleeperTotal / 2).ceil();
    final sleeperUpper = sleeperTotal - sleeperLower;

    final lowerCells = <SeatCell>[];
    final upperCells = <SeatCell>[];

    var idCounter = 0;
    for (var i = 0; i < sleeperLower; i++) {
      idCounter++;
      lowerCells.add(SeatCell(
        row: i ~/ cols,
        col: i % cols,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
        seatId: 'L$idCounter',
      ));
    }
    for (var i = 0; i < seaterTotal; i++) {
      idCounter++;
      final seq = sleeperLower + i;
      lowerCells.add(SeatCell(
        row: seq ~/ cols,
        col: seq % cols,
        seatType: SeatType.seater,
        position: null,
        seatId: 'L$idCounter',
      ));
    }
    for (var i = 0; i < sleeperUpper; i++) {
      upperCells.add(SeatCell(
        row: i ~/ cols,
        col: i % cols,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.upper,
        seatId: 'U${i + 1}',
      ));
    }

    final lowerRows = sleeperLower + seaterTotal == 0
        ? 1
        : ((sleeperLower + seaterTotal - 1) ~/ cols) + 1;
    final upperRows =
        sleeperUpper == 0 ? 0 : ((sleeperUpper - 1) ~/ cols) + 1;
    final maxRows = lowerRows > upperRows ? lowerRows : upperRows;

    return BusLayout(
      rows: maxRows,
      cols: cols,
      lowerDeck: lowerCells,
      upperDeck: upperCells,
    );
  }

  /// Get a cell from the lower deck by position.
  SeatCell getLowerCell(int row, int col) => lowerDeck[row * cols + col];

  /// Get a cell from the upper deck by position.
  SeatCell getUpperCell(int row, int col) => upperDeck[row * cols + col];

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
    deck[row * cols + col] = newCell;

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
