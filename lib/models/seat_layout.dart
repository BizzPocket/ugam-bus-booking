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
  ///     all-double-sofa behaviour.
  ///   - [allDoubleBackRow] — the create-bus "all-double last row" toggle. It
  ///     fixes the shape of the LAST (back) row for ANY total seat count:
  ///       • true  → the back row is 4 DOUBLE sofas (all-double).
  ///       • false → the back row is 3 SINGLE + 2 DOUBLE sofas (singles on the
  ///                 left, doubles on the right). This is the default.
  ///     The back row is laid first and the remaining berths fill the rows
  ///     above; the seat count is conserved exactly. Ignored for seater buses.
  ///   - [hasBalcony]       — DEPRECATED no-op, kept so old callers still
  ///     compile. The back row is now controlled by [allDoubleBackRow].
  factory BusLayout.generate({
    required BusType busType,
    required int totalSeats,
    int seaterCount = 0,
    int singleSofaCount = 0,
    bool allDoubleBackRow = false,
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

    final requestedSingles = singleSofaCount.clamp(0, sleeperTotal);
    final isSleeperish = busType != BusType.seater;

    // ── The "all-double last row" toggle ───────────────────────────────────
    // The bus's WHOLE composition — the back row INCLUDED — is fixed by the seat
    // count + single-sofa count. A double sofa seats two, so the berths left
    // after the requested singles pair 2-for-1 into doubles; an odd leftover
    // berth can't pair, so it is one more single.
    //   e.g. 37 seats, 13 singles → 24 double-berths = 12 doubles → 13S + 12D.
    final doubleBerthsRaw = sleeperTotal - requestedSingles;
    final totalDoubleCells = doubleBerthsRaw ~/ 2;
    final totalSingleCells = requestedSingles + (doubleBerthsRaw.isOdd ? 1 : 0);

    // The toggle only shapes the LAST row, and its berths are DRAWN FROM that
    // composition — never added on top:
    //   • allDoubleBackRow == true  → last row is 4 double         (needs ≥4 D)
    //   • allDoubleBackRow == false → last row is 3 single+2 double (needs ≥3 S,
    //                                  ≥2 D)
    // so 37/13 OFF → back row 3S+2D, body 10S+10D — still 13S + 12D total.
    final wantBackSingles = allDoubleBackRow ? 0 : 3;
    final wantBackDoubles = allDoubleBackRow ? 4 : 2;

    // ── No-ragged-hole invariant (OFF / default path) ───────────────────────
    // Every lane PAIR — the two single columns (0/1) and the two double columns
    // (3/4) — must hold an EVEN, perfectly-paired count, so col0 mirrors col1
    // and col3 mirrors col4 row-for-row. The only place an ODD leftover berth
    // may live is the centre AISLE (col2), which is exactly the back bench.
    // Anything else strands a tile with a blank partner beside it (the unpaired
    // double-upper at 38/0) or, once a short lane is separated from the bench by
    // taller lanes, a lone tile floating mid-cabin (the 37/2 & 38/8 holes that
    // reached the WhatsApp PDF).
    //
    // So the designed 3S+2D OFF bench is only honoured when, AFTER removing its
    // cells, BOTH body counts stay EVEN. When they would NOT (e.g. 38/8 → body
    // 5S+13D), carving it is what left the hole, so we drop back to a MINIMAL
    // bench that just parks the odd-tail berth(s) in the aisle and keeps every
    // body lane pair even — conserving the exact berth count either way.
    final benchKeepsBodyEven = (totalSingleCells - wantBackSingles).isEven &&
        (totalDoubleCells - wantBackDoubles).isEven;

    // A bus whose composition already pairs perfectly — both cell counts even —
    // lays flat into full [single | double] rows with no leftover, so it needs
    // NO rear bench at all (e.g. 36/12 → six clean rows).
    final pairsCleanly = !allDoubleBackRow &&
        totalSingleCells.isEven &&
        totalDoubleCells.isEven;

    // The lone odd-tail berths that cannot pair into a body lane go to the centre
    // AISLE of the back bench — the one column allowed to carry an unpaired berth
    // — so cols 0/1 and 3/4 stay mirrored row-for-row on the OFF path.
    final aisleSingle = totalSingleCells.isOdd ? 1 : 0;
    final aisleDouble = totalDoubleCells.isOdd ? 1 : 0;

    final int backSingles;
    final int backDoubles;
    final int aisleSingles;
    final int aisleDoubles;
    if (!isSleeperish) {
      backSingles = 0;
      backDoubles = 0;
      aisleSingles = 0;
      aisleDoubles = 0;
    } else if (allDoubleBackRow) {
      // Toggle ON is a PRODUCT GUARANTEE: the last row is always 4 double sofas
      // when the bus has the doubles for it (col3 + col4 + an aisle double pair).
      // An EVEN double count lays out fully paired. An ODD double count keeps the
      // 4-double back row (the toggle's whole point) and leaves its one
      // unavoidable leftover as a trailing half-bunk in the body — never invents
      // a single. Singles requested on an ON bus pair up in the body lanes.
      final canFourDouble = totalDoubleCells >= wantBackDoubles;
      backSingles = 0;
      backDoubles = canFourDouble ? wantBackDoubles : 0; // 4
      aisleSingles = 0;
      aisleDoubles = canFourDouble ? 2 : 0; // the 3rd/4th doubles sit in the aisle
    } else if (!pairsCleanly &&
        benchKeepsBodyEven &&
        totalDoubleCells >= wantBackDoubles &&
        totalSingleCells >= wantBackSingles) {
      // Designed OFF bench: 3S + 2D, body stays even by construction. The 3rd
      // single sits in the aisle; col0/col1 carry the other two.
      backSingles = wantBackSingles;
      backDoubles = wantBackDoubles;
      aisleSingles = 1;
      aisleDoubles = 0;
    } else {
      // Minimal OFF bench: only the odd-tail berth(s) live in the aisle so every
      // body lane pair stays even and hole-free. Zero when both counts are
      // already even (pairsCleanly) → no bench, clean full rows.
      backSingles = aisleSingle;
      backDoubles = aisleDouble;
      aisleSingles = aisleSingle;
      aisleDoubles = aisleDouble;
    }
    final hasBackRow = (backSingles + backDoubles) > 0;

    // The body lanes get everything the bench didn't take — now always EVEN, so
    // each lane pair splits exactly in half with no unpaired tail.
    final bodySingleCells = totalSingleCells - backSingles;
    final bodyDoubleCells = totalDoubleCells - backDoubles;

    final upperSingles = bodySingleCells ~/ 2;
    final lowerSingles = bodySingleCells - upperSingles;
    final upperDoubles = bodyDoubleCells ~/ 2;
    final lowerDoubles = bodyDoubleCells - upperDoubles;

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

    final laneRows = [
      upperSingles,
      lowerSingles,
      upperDoubles,
      lowerDoubles,
    ].fold<int>(0, (m, v) => v > m ? v : m);

    // The dedicated back row sits just below the body lanes. Its left/right LANE
    // berths land in the same col0/1 & col3/4 columns as the body (so they stay
    // paired and contiguous with it), and only the ODD-tail berths sit in the
    // centre aisle — the one column allowed to carry an unpaired berth.
    final benchRow = laneRows;
    if (hasBackRow) {
      final benchColSingles = backSingles - aisleSingles; // col0 + col1 (0 or 2)
      final benchColDoubles = backDoubles - aisleDoubles; // col3 + col4 (0 or 2)

      // RIGHT: a paired double bunk (col3 upper, col4 lower) when the designed
      // bench carries doubles.
      if (benchColDoubles >= 2) {
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.doubleUpper,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
        ));
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.doubleLower,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
        ));
      }

      // LEFT: a paired single bunk (col0 upper, col1 lower) when the designed
      // OFF bench carries its two lane singles.
      if (benchColSingles >= 2) {
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.singleUpper,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
        ));
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.singleLower,
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
        ));
      }

      // AISLE: the odd-tail berths. The aisle holds at most an upper + a lower.
      // ON → a double pair; OFF designed → the 3rd single (lower); minimal bench
      // → the lone odd single and/or odd double. Upper slot is filled first.
      var aisleUpperTaken = false;
      void addAisle(SeatType type) {
        final pos = aisleUpperTaken ? SeatPosition.lower : SeatPosition.upper;
        aisleUpperTaken = true;
        grid.add(SeatCell(
          row: benchRow,
          col: SeatGridCols.aisle,
          seatType: type,
          position: pos,
        ));
      }

      for (var i = 0; i < aisleDoubles; i++) {
        addAisle(SeatType.doubleSofa);
      }
      for (var i = 0; i < aisleSingles; i++) {
        addAisle(SeatType.singleSofa);
      }
    }

    // Seaters fill cols 0,1,3,4 — from row 0 on a pure seater bus, or BELOW the
    // whole sleeper cabin (including its back row) on a mixed bus.
    final seaterStartRow = busType == BusType.seater
        ? 0
        : benchRow + (hasBackRow ? 1 : 0);
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

    return BusLayout(
      rows: maxRow < 0 ? 1 : maxRow + 1,
      cols: SeatGridCols.count,
      grid: grid,
      hasBalcony: hasBackRow,
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
