import 'bus_type.dart';
import 'seat_type.dart';

/// Column indices for the unified 5-column seat grid.
///
/// The grid is one combined layout (no separate decks). The aisle is always
/// the middle column, except on the balcony (back) row where it carries an
/// upper + lower berth pair. Column meaning depends on the bus type:
///
///   SLEEPER / sleeper berths of MIXED
///     0 single·Upper   1 single·Lower   2 aisle   3 double·Upper   4 double·Lower
///   SEATER / seater rows of MIXED
///     0 seater         1 seater         2 aisle   3 seater         4 seater
class SeatGridCols {
  const SeatGridCols._();

  static const int count = 5;
  static const int singleUpper = 0;
  static const int singleLower = 1;
  static const int aisle = 2;
  static const int doubleUpper = 3;
  static const int doubleLower = 4;

  /// Seater seats fill these columns (aisle stays empty).
  static const List<int> seaterCols = [0, 1, 3, 4];
}

/// A single cell in the unified bus seat grid.
///
/// If [seatType] is null, this cell is empty (aisle / gap). If [seatType] is
/// set, [seatId] is the auto-generated ID like "DL3", "SU1", "ST2".
///
/// Identity is `(row, col, position)` — NOT just `(row, col)`. Every lane
/// column already implies its deck (col 0 is always upper-single, col 1 always
/// lower-single, etc.), so the only coordinate that ever holds two cells is the
/// balcony aisle (last row, [SeatGridCols.aisle]), which carries one upper and
/// one lower berth. Including [position] in identity lets that pair coexist.
class SeatCell {
  final int row;
  final int col;
  final SeatType? seatType;
  final SeatPosition? position; // null for Seater and for empty cells
  final String? seatId; // auto-generated, e.g. "DL3"

  /// True when the agent has held this seat back (driver area, VIP hold, etc.).
  /// The seating engine never auto-fills a reserved seat. Not part of identity.
  final bool reserved;

  /// True when the agent has marked this seat as part of the "forward / premium"
  /// zone — these carry the premium price. This flag drives PRICING only; it no
  /// longer affects automatic seat assignment. The seating engine seats
  /// approved-priority (elderly/sick) passengers onto LOWER berths first (see
  /// [SeatPosition.lower]), independent of this flag. Not part of identity.
  final bool forward;

  const SeatCell({
    required this.row,
    required this.col,
    this.seatType,
    this.position,
    this.seatId,
    this.reserved = false,
    this.forward = false,
  });

  bool get isEmpty => seatType == null;
  bool get hasSeat => seatType != null;

  /// True when this is a seat sitting in the aisle column — only the balcony
  /// (back) row does this. The renderer stacks the upper/lower balcony pair
  /// into the single aisle column as a split tile.
  bool get isBalconyAisle => col == SeatGridCols.aisle && hasSeat;

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
      if (reserved) 'reserved': true,
      if (forward) 'forward': true,
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
      reserved: map['reserved'] as bool? ?? false,
      forward: map['forward'] as bool? ?? false,
    );
  }

  SeatCell copyWith({
    SeatType? seatType,
    SeatPosition? position,
    String? seatId,
    bool? reserved,
    bool? forward,
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
      reserved: reserved ?? this.reserved,
      forward: forward ?? this.forward,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeatCell &&
          other.row == row &&
          other.col == col &&
          other.position == position;

  @override
  int get hashCode => Object.hash(row, col, position);
}

/// The visual seat layout for a bus.
///
/// One combined [grid] of [SeatCell]s laid out on a fixed 5-column scheme (see
/// [SeatGridCols]). Upper and lower berths sit in adjacent columns of the same
/// row rather than on two separate decks. Capacity, IDs, and assignment all key
/// off [grid].
class BusLayout {
  final int rows;
  final int cols; // always SeatGridCols.count (5); kept for serialisation
  final List<SeatCell> grid; // flat; only [hasSeat] cells are stored
  final bool hasBalcony;

  const BusLayout({
    required this.rows,
    required this.cols,
    required this.grid,
    this.hasBalcony = false,
  });

  /// Create an empty layout with the given number of rows (always 5 columns).
  factory BusLayout.empty(int rows) {
    return BusLayout(rows: rows, cols: SeatGridCols.count, grid: const []);
  }

  /// Generate a layout from a [busType] and total seat count, plus optional
  /// per-class counts:
  ///   - [seaterCount]      — number of seater seats (only used for `mixed`).
  ///   - [singleSofaCount]  — how many sleeper berths should be Single Sofa
  ///     (1-person berth). The remaining sleeper berths become Double Sofa
  ///     (2-person shared berth). Defaults to 0 so legacy callers get the
  ///     previous all-double-sofa behaviour.
  ///   - [hasBalcony]       — when true, fills the aisle column of the LAST seat
  ///     row with an upper + lower Single Sofa pair (the "balcony" / back bench),
  ///     so it renders as a full-width back row rather than a separate line.
  ///     These 2 berths are added on top of the requested sleeper berths.
  ///     Ignored for pure seater buses.
  factory BusLayout.generate({
    required BusType busType,
    required int totalSeats,
    int seaterCount = 0,
    int singleSofaCount = 0,
    bool hasBalcony = false,
  }) {
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

    // A Double Sofa physically seats TWO people. The berths left after the
    // single sofas are therefore paired up 2-for-1 into double cells — a 40-seat
    // bus with 10 singles has 30 berths left, which is 15 doubles, NOT 30.
    // If that leftover is odd, the spare berth becomes one extra single sofa so
    // no seat is lost (the add-bus screen warns the agent when this happens).
    final requestedSingles = singleSofaCount.clamp(0, sleeperTotal);
    final doubleBerths = sleeperTotal - requestedSingles;
    final doubleTotal = doubleBerths ~/ 2;
    final singleTotal = requestedSingles + (doubleBerths.isOdd ? 1 : 0);

    // An unpaired single (odd single count) can't sit beside a lane partner, so
    // it rides in the balcony aisle of the back row instead of dangling alone in
    // a half-empty row. The lane keeps an even number, split evenly.
    final orphanSingle = singleTotal.isOdd && busType != BusType.seater;
    final laneSingles = orphanSingle ? singleTotal - 1 : singleTotal;
    final upperSingles = laneSingles ~/ 2;
    final lowerSingles = laneSingles ~/ 2;
    final upperDoubles = (doubleTotal / 2).ceil();
    final lowerDoubles = doubleTotal - upperDoubles;

    final grid = <SeatCell>[];

    void addLane(int n, int col, SeatType type, SeatPosition pos) {
      for (var i = 0; i < n; i++) {
        grid.add(SeatCell(row: i, col: col, seatType: type, position: pos));
      }
    }

    addLane(upperSingles, SeatGridCols.singleUpper, SeatType.singleSofa,
        SeatPosition.upper);
    addLane(lowerSingles, SeatGridCols.singleLower, SeatType.singleSofa,
        SeatPosition.lower);
    addLane(upperDoubles, SeatGridCols.doubleUpper, SeatType.doubleSofa,
        SeatPosition.upper);
    addLane(lowerDoubles, SeatGridCols.doubleLower, SeatType.doubleSofa,
        SeatPosition.lower);

    final sleeperRows = [
      upperSingles,
      lowerSingles,
      upperDoubles,
      lowerDoubles,
    ].fold<int>(0, (m, v) => v > m ? v : m);

    // Seaters fill cols 0,1,3,4 — from row 0 on a pure seater bus, or below the
    // sleeper rows on a mixed bus.
    final seaterStartRow = busType == BusType.seater ? 0 : sleeperRows;
    for (var i = 0; i < seaterTotal; i++) {
      grid.add(SeatCell(
        row: seaterStartRow + i ~/ 4,
        col: SeatGridCols.seaterCols[i % 4],
        seatType: SeatType.seater,
      ));
    }

    var maxRow = -1;
    for (final c in grid) {
      if (c.row > maxRow) maxRow = c.row;
    }

    // Back bench (full-width last row). The leftover berths — an unpaired single
    // and/or the explicit balcony pair — ride the aisle column of the LAST seat
    // row rather than spawning their own near-empty row. The renderer draws any
    // row carrying aisle seats as a flat, full-width bench (no centre gap, full
    // size), so the remainder reads as a real back bench instead of a tiny
    // half-height middle sofa stranded on its own line.
    final wantsPair = hasBalcony && busType != BusType.seater;
    final hasBalconyResult = orphanSingle || wantsPair;
    if (hasBalconyResult) {
      final benchRow = maxRow < 0 ? 0 : maxRow;
      // Lower slot — the relocated orphan, or a toggle-added berth.
      grid.add(SeatCell(
        row: benchRow,
        col: SeatGridCols.aisle,
        seatType: SeatType.singleSofa,
        position: SeatPosition.lower,
      ));
      // Upper slot — only the explicit toggle adds this.
      if (wantsPair) {
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.aisle,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
        ));
      }
      maxRow = benchRow;
    }

    return BusLayout(
      rows: maxRow < 0 ? 1 : maxRow + 1,
      cols: SeatGridCols.count,
      grid: grid,
      hasBalcony: hasBalconyResult,
    )._regenerateIds();
  }

  /// Cell at a coordinate. When [position] is given it must also match — needed
  /// to disambiguate the balcony aisle pair, which shares (row, col). Returns an
  /// empty cell when nothing is there.
  SeatCell cellAt(int row, int col, {SeatPosition? position}) {
    return grid.firstWhere(
      (c) =>
          c.row == row &&
          c.col == col &&
          (position == null || c.position == position),
      orElse: () => SeatCell(row: row, col: col),
    );
  }

  /// The (upper, lower) berths sitting in the aisle of [row] — only the balcony
  /// row has these. Either may be an empty cell.
  ({SeatCell upper, SeatCell lower}) balconyPair(int row) => (
        upper: cellAt(row, SeatGridCols.aisle, position: SeatPosition.upper),
        lower: cellAt(row, SeatGridCols.aisle, position: SeatPosition.lower),
      );

  /// All seat cells in [row], ordered by column.
  List<SeatCell> cellsInRow(int row) {
    final cells = grid.where((c) => c.row == row && c.hasSeat).toList()
      ..sort((a, b) => a.col.compareTo(b.col));
    return cells;
  }

  /// True when [row] is in the rear zone — the last [rearRows] rows of the bus.
  /// Used by the pricing UI to highlight which seats get the rear-zone price,
  /// and mirrors the rear-zone test in [Bus.berthPriceFor].
  bool isRearRow(int row, int rearRows) =>
      rearRows > 0 && row >= rows - rearRows;

  /// Compatibility view: cells on the upper deck (position == upper).
  /// Retained for callers that have not moved to [grid] yet.
  List<SeatCell> get upperDeck =>
      grid.where((c) => c.position == SeatPosition.upper).toList();

  /// Compatibility view: cells on the lower deck (position == lower) plus
  /// seaters (which have no deck).
  List<SeatCell> get lowerDeck => grid
      .where((c) =>
          c.position == SeatPosition.lower || c.seatType == SeatType.seater)
      .toList();

  /// Total passenger capacity (berths). A Double Sofa cell counts as TWO berths
  /// because it physically seats two people; every other seat type is one berth.
  int get totalSeats {
    var berths = 0;
    for (final cell in grid) {
      if (!cell.hasSeat) continue;
      berths += cell.seatType == SeatType.doubleSofa ? 2 : 1;
    }
    return berths;
  }

  /// Number of physical seat cells (tiles) — a Double Sofa counts once here,
  /// unlike [totalSeats] which counts its two berths.
  int get totalCells => grid.where((c) => c.hasSeat).length;

  /// Count seats by type+position.
  Map<String, int> get seatCounts {
    final counts = <String, int>{};
    for (final cell in grid) {
      if (cell.hasSeat) {
        final key = seatIdPrefix(cell.seatType!, cell.position);
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// All seat IDs, row-major.
  List<String> get allSeatIds => _orderedSeats().map((c) => c.seatId!).toList();

  /// Seats in stable row-major order (row, then col, then upper-before-lower).
  List<SeatCell> _orderedSeats() {
    final seats = grid.where((c) => c.hasSeat).toList();
    seats.sort((a, b) {
      if (a.row != b.row) return a.row.compareTo(b.row);
      if (a.col != b.col) return a.col.compareTo(b.col);
      return _posRank(a.position).compareTo(_posRank(b.position));
    });
    return seats;
  }

  static int _posRank(SeatPosition? p) => switch (p) {
        SeatPosition.upper => 0,
        SeatPosition.lower => 1,
        null => 2,
      };

  /// Returns a new layout with [newCell] placed at its (row, col, position),
  /// replacing any existing cell that matches that identity.
  BusLayout updateCell(SeatCell newCell) {
    final next = List<SeatCell>.from(grid);
    final idx = next.indexWhere((c) =>
        c.row == newCell.row &&
        c.col == newCell.col &&
        c.position == newCell.position);
    if (newCell.isEmpty) {
      if (idx >= 0) next.removeAt(idx);
    } else if (idx >= 0) {
      next[idx] = newCell;
    } else {
      next.add(newCell);
    }

    var maxRow = rows - 1;
    for (final c in next) {
      if (c.row > maxRow) maxRow = c.row;
    }

    return BusLayout(
      rows: maxRow < 0 ? 1 : maxRow + 1,
      cols: SeatGridCols.count,
      grid: next,
      hasBalcony: next.any((c) => c.isBalconyAisle),
    )._regenerateIds();
  }

  /// Re-generate seat IDs in row-major order. IDs are unique per prefix
  /// (e.g. DL1, DL2, DL3…). Empty cells are dropped from storage.
  BusLayout _regenerateIds() {
    final counters = <String, int>{};
    final seats = _orderedSeats();
    final renumbered = seats.map((cell) {
      final prefix = seatIdPrefix(cell.seatType!, cell.position);
      final num = (counters[prefix] ?? 0) + 1;
      counters[prefix] = num;
      // copyWith threads reserved + forward (and keeps seatType/position and
      // row/col), so agent-marked flags survive every re-numbering pass. A
      // plain SeatCell(...) here would silently drop them — see regression test.
      return cell.copyWith(seatId: '$prefix$num');
    }).toList();

    return BusLayout(
      rows: rows,
      cols: SeatGridCols.count,
      grid: renumbered,
      hasBalcony: hasBalcony,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'rows': rows,
      'cols': cols,
      'hasBalcony': hasBalcony,
      'grid': grid.where((c) => c.hasSeat).map((c) => c.toMap()).toList(),
    };
  }

  factory BusLayout.fromMap(Map<String, dynamic> map) {
    // New single-grid format.
    if (map['grid'] is List) {
      final cells = (map['grid'] as List)
          .map((e) => SeatCell.fromMap(Map<String, dynamic>.from(e)))
          .where((c) => c.hasSeat)
          .toList();
      var maxRow = -1;
      for (final c in cells) {
        if (c.row > maxRow) maxRow = c.row;
      }
      return BusLayout(
        rows: maxRow < 0 ? 1 : maxRow + 1,
        cols: SeatGridCols.count,
        grid: cells,
        hasBalcony: map['hasBalcony'] as bool? ??
            cells.any((c) => c.isBalconyAisle),
      );
    }

    // Legacy two-deck format — convert, preserving seat IDs so existing
    // assignments stay valid.
    final lower = (map['lowerDeck'] as List? ?? const [])
        .map((e) => SeatCell.fromMap(Map<String, dynamic>.from(e)))
        .where((c) => c.hasSeat)
        .toList();
    final upper = (map['upperDeck'] as List? ?? const [])
        .map((e) => SeatCell.fromMap(Map<String, dynamic>.from(e)))
        .where((c) => c.hasSeat)
        .toList();
    return _fromLegacyDecks(lower: lower, upper: upper);
  }

  /// Convert old two-deck cells into the unified grid. Original [seatId]s are
  /// preserved (so already-assigned seats keep their identity); only the grid
  /// coordinates are rebuilt onto the 5-column scheme.
  static BusLayout _fromLegacyDecks({
    required List<SeatCell> lower,
    required List<SeatCell> upper,
  }) {
    int byRowCol(SeatCell a, SeatCell b) =>
        a.row != b.row ? a.row.compareTo(b.row) : a.col.compareTo(b.col);

    List<SeatCell> pick(List<SeatCell> src, SeatType type) =>
        src.where((c) => c.seatType == type).toList()..sort(byRowCol);

    final grid = <SeatCell>[];

    void place(List<SeatCell> src, int col, SeatPosition? pos) {
      for (var i = 0; i < src.length; i++) {
        grid.add(SeatCell(
          row: i,
          col: col,
          seatType: src[i].seatType,
          position: pos,
          seatId: src[i].seatId,
        ));
      }
    }

    place(pick(upper, SeatType.singleSofa), SeatGridCols.singleUpper,
        SeatPosition.upper);
    place(pick(lower, SeatType.singleSofa), SeatGridCols.singleLower,
        SeatPosition.lower);
    place(pick(upper, SeatType.doubleSofa), SeatGridCols.doubleUpper,
        SeatPosition.upper);
    place(pick(lower, SeatType.doubleSofa), SeatGridCols.doubleLower,
        SeatPosition.lower);

    // Seaters live on the lower deck in the old model; lay them below sleepers.
    var sleeperRows = -1;
    for (final c in grid) {
      if (c.row > sleeperRows) sleeperRows = c.row;
    }
    sleeperRows += 1;
    final seaters = pick([...lower, ...upper], SeatType.seater);
    for (var i = 0; i < seaters.length; i++) {
      grid.add(SeatCell(
        row: sleeperRows + i ~/ 4,
        col: SeatGridCols.seaterCols[i % 4],
        seatType: SeatType.seater,
        seatId: seaters[i].seatId,
      ));
    }

    var maxRow = -1;
    for (final c in grid) {
      if (c.row > maxRow) maxRow = c.row;
    }
    return BusLayout(
      rows: maxRow < 0 ? 1 : maxRow + 1,
      cols: SeatGridCols.count,
      grid: grid,
      hasBalcony: false,
    );
  }
}
