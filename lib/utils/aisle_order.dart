// The physical walking order of a bus — the backbone of the Board's
// "next outstanding" advance (Board interaction spec §4).
//
// Pure logic: no widgets, no I/O, no clock, no randomness. The Board calls this
// on every auto-advance, so it has to be cheap and it has to be identical every
// time — a walk that reshuffled between two taps would send the handler back up
// the bus to a berth they had just left.
//
// *** WHY THIS EXISTS ***
// A handler collecting cash walks the aisle front to back. Every ordered view of
// a bus in the app today is ordered by seat CODE — DL1, DL2, DU1, SL1 — which is
// the order the ids were GENERATED in (lane by lane, see `BusLayout._regenerateIds`),
// not the order the berths are passed on foot. Following it means walking the
// whole left lane to the back, returning to the front for the right lane, and
// doing it twice more for the upper berths. Aisle order fixes that: row by row,
// front to back, sweeping across the bus inside each row.
//
// *** WHAT "ACROSS THE BUS" MEANS IN THIS GRID ***
// The layout is one flat 5-column grid (`SeatGridCols`) in which a bunk's upper
// and lower berths sit in ADJACENT COLUMNS of the same row rather than stacked:
//
//     col 0            col 1            col 2       col 3            col 4
//     single·upper     single·lower     aisle       double·upper     double·lower
//
// The renderer (`CombinedSeatGrid._row`, mirrored as data in
// `SeatGridPlacement.columns`) deliberately draws the doubles LOWER-then-UPPER,
// so the bus reads `U L | aisle | L U` with both lower berths toward the centre.
// Left to right on screen is therefore:
//
//     col 0  →  col 1  →  [col 2 upper, col 2 lower]  →  col 4  →  col 3
//     ─ left wall ─────────  centre bench  ───────────  right wall ─
//
// That sweep IS the walking order — left wall, across the aisle, right wall —
// and matching it exactly is not cosmetic. "Next outstanding" scrolls the canvas
// and highlights a tile; if the order disagreed with what is drawn, the
// highlight would jump backwards across the screen on some advances.
//
// Column 2 only carries berths on the back bench (`SeatCell.isBalconyAisle`),
// where it holds an upper + lower pair; on every other row it is the gap the
// handler is standing in.
//
// *** ONE ENTRY PER TILE, NOT PER BERTH ***
// A double sofa is two berths but ONE tile: one code, one fill, one glyph, one
// sheet. The Board draws it once and the handler stops at it once, so the walk
// visits it once. A shared double whose two occupants differ (one paid, one due)
// still matches the lens predicate as a single stop, and the sheet resolves the
// two people inside. Reserved / blocked berths stay in the walk too — they are
// physically there and drawn; whether to stop at one is the predicate's call.

import '../models/seat_layout.dart';
import '../models/seat_type.dart';

/// "Should the handler stop here?" — a lens supplies one of these.
///
/// Money lens: *this berth still owes money*. Boarding lens: *nobody has ticked
/// this berth in*. Assignment lens: *this berth is empty*. The predicate takes
/// the whole [SeatCell] rather than a seat id so a lens can also filter on
/// geometry (skip `reserved`, skip seaters, …) without a second lookup.
typedef BerthPredicate = bool Function(SeatCell cell);

/// Rank of a cell's slot in the left-to-right sweep across one row.
///
/// Mirrors `CombinedSeatGrid._row` / `_benchRow` exactly. Any column outside the
/// documented 5-column scheme cannot be drawn in a known place, so it sorts
/// after everything real, by column index, purely so the result stays
/// deterministic instead of depending on grid insertion order.
int _slotRank(SeatCell cell) {
  switch (cell.col) {
    case SeatGridCols.singleUpper: // col 0 — left wall
      return 0;
    case SeatGridCols.singleLower: // col 1 — left, toward the aisle
      return 1;
    case SeatGridCols.aisle: // col 2 — the back bench pair, upper first
      return cell.position == SeatPosition.lower ? 3 : 2;
    case SeatGridCols.doubleLower: // col 4 — right, toward the aisle
      return 4;
    case SeatGridCols.doubleUpper: // col 3 — right wall
      return 5;
    default:
      return 100 + cell.col;
  }
}

/// Upper before lower, matching `BusLayout._posRank` so a bunk pair is walked in
/// the same order the seat ids were numbered in.
int _posRank(SeatPosition? p) => switch (p) {
      SeatPosition.upper => 0,
      SeatPosition.lower => 1,
      null => 2,
    };

/// Sort comparator for the walk: row front-to-back, then the across-the-bus
/// sweep. Public so anything else that has to line up with the walk — a print
/// order, a manifest, a list of passengers keyed by cell — can reuse the one
/// definition rather than growing a second, slightly different one.
///
/// [_posRank] and the seat id are pure tie-breaks. Neither can bite on a
/// well-formed layout (a lane column always implies its position, and only the
/// aisle holds two cells at one coordinate — which [_slotRank] already
/// separates); they exist so a malformed grid still sorts to a stable order
/// instead of an arbitrary one.
int compareAisleOrder(SeatCell a, SeatCell b) {
  if (a.row != b.row) return a.row.compareTo(b.row);
  final bySlot = _slotRank(a).compareTo(_slotRank(b));
  if (bySlot != 0) return bySlot;
  final byPos = _posRank(a.position).compareTo(_posRank(b.position));
  if (byPos != 0) return byPos;
  return (a.seatId ?? '').compareTo(b.seatId ?? '');
}

/// Every drawable seat cell in [layout], in aisle-walking order.
///
/// Null or empty layout → an empty list, so a bus with no seat plan yet (spec
/// §13) needs no special-casing at the call site. The result is unmodifiable:
/// the walk is shared state on the Board and a caller that sorted it in place
/// would silently break every other reader.
List<SeatCell> aisleOrder(BusLayout? layout) {
  final cells = <SeatCell>[
    for (final c in layout?.grid ?? const <SeatCell>[])
      if (c.hasSeat) c,
  ]..sort(compareAisleOrder);
  return List<SeatCell>.unmodifiable(cells);
}

/// One bus's berths in walking order, with the seat-id index precomputed.
///
/// Build it once per layout and keep it: a 22-stop collection round asks for
/// "the next one" 22 times, and rebuilding the sort on each tap would re-walk
/// the whole grid for an answer that cannot have changed — the OCCUPANCY changes
/// during a round, the GEOMETRY does not.
class AisleWalk {
  /// The berths, front to back. Unmodifiable.
  final List<SeatCell> berths;

  final Map<String, int> _indexById;

  const AisleWalk._(this.berths, this._indexById);

  factory AisleWalk.of(BusLayout? layout) {
    final berths = aisleOrder(layout);
    final byId = <String, int>{};
    for (var i = 0; i < berths.length; i++) {
      final id = berths[i].seatId;
      if (id == null || id.isEmpty) continue;
      // First occurrence wins. Ids are unique in any layout the app generates;
      // if a hand-edited one ever repeats a code, the walk still has to resolve
      // "where am I" to exactly one place or the advance would loop.
      byId.putIfAbsent(id, () => i);
    }
    return AisleWalk._(berths, byId);
  }

  int get length => berths.length;
  bool get isEmpty => berths.isEmpty;
  bool get isNotEmpty => berths.isNotEmpty;

  /// Seat ids in walking order. Berths with no id are dropped — nothing in the
  /// app can key money, boarding or assignment to a berth that has no code.
  List<String> get seatIds => [
        for (final c in berths)
          if (c.seatId != null && c.seatId!.isNotEmpty) c.seatId!,
      ];

  /// How far along the walk [seatId] sits, or null when this bus has no such
  /// berth. This is the "you are here" number — use it to render progress
  /// ("berth 14 of 40") without a second scan.
  int? indexOf(String? seatId) => seatId == null ? null : _indexById[seatId];

  /// The cell for [seatId], or null when this bus has no such berth.
  SeatCell? berthFor(String? seatId) {
    final i = indexOf(seatId);
    return i == null ? null : berths[i];
  }

  /// Every berth the lens wants, in walking order — the whole remaining round.
  List<SeatCell> where(BerthPredicate matches) =>
      [for (final c in berths) if (matches(c)) c];

  /// How many berths still match. The summary strip's "14 જણ".
  int count(BerthPredicate matches) {
    var n = 0;
    for (final c in berths) {
      if (matches(c)) n++;
    }
    return n;
  }

  /// The frontmost matching berth — where a round starts.
  SeatCell? firstMatching(BerthPredicate matches) {
    for (final c in berths) {
      if (matches(c)) return c;
    }
    return null;
  }

  /// The next berth after [from] that [matches], walking toward the back.
  ///
  /// **[from] is never returned.** "Next" means next: a handler who taps the
  /// control twice without completing the action has to move on, not sit on the
  /// same berth. When the action IS completed the berth stops matching anyway,
  /// so the exclusion costs nothing on the normal path.
  ///
  /// **[wrap] defaults to true, and this is the deliberate choice the spec left
  /// open.** The promise in §4 is "nobody missed": a handler who starts at berth
  /// 20 — because someone flagged them down — must still be walked back to the
  /// three outstanding berths in front of them once they reach the rear. The
  /// round terminates on its own because completing each action clears its
  /// match, so the loop empties rather than spinning; when the last outstanding
  /// berth is cleared this returns null and the caller shows "round complete".
  /// Pass `wrap: false` for a strictly one-directional sweep that stops dead at
  /// the back of the bus.
  ///
  /// A [from] this bus does not have (null, empty, a code from another bus)
  /// means "no current berth" — the walk starts from the front and does not
  /// wrap, because there is nothing behind the first berth.
  ///
  /// Returns null when nothing else matches — including the case where the only
  /// match IS [from].
  SeatCell? next({
    String? from,
    required BerthPredicate matches,
    bool wrap = true,
  }) =>
      _step(from: from, matches: matches, wrap: wrap, delta: 1);

  /// The previous matching berth, walking toward the front. Same rules as
  /// [next]. Exists for the "I mis-tapped, go back one" affordance — a handler
  /// who has advanced past someone should not have to hunt the chart for them.
  SeatCell? previous({
    String? from,
    required BerthPredicate matches,
    bool wrap = true,
  }) =>
      _step(from: from, matches: matches, wrap: wrap, delta: -1);

  SeatCell? _step({
    required String? from,
    required BerthPredicate matches,
    required bool wrap,
    required int delta,
  }) {
    if (berths.isEmpty) return null;

    final start = indexOf(from);
    if (start == null) {
      // No anchor: scan inward from the end the caller is heading away from.
      final scan = delta > 0 ? berths : berths.reversed;
      for (final c in scan) {
        if (matches(c)) return c;
      }
      return null;
    }

    final n = berths.length;
    // n - 1 steps visits every OTHER berth exactly once, wrapped or not, which
    // is what makes "the origin is never returned" true by construction.
    for (var step = 1; step < n; step++) {
      var i = start + delta * step;
      if (wrap) {
        // Dart's % is never negative for a positive divisor, so this handles
        // the backward walk too.
        i %= n;
      } else if (i < 0 || i >= n) {
        return null;
      }
      final c = berths[i];
      if (matches(c)) return c;
    }
    return null;
  }
}

/// One-shot [AisleWalk.next] for callers that do not hold a walk.
///
/// Convenient for a single "jump to the next empty berth"; do NOT use it inside
/// an auto-advance loop, which should keep an [AisleWalk] instead of re-sorting
/// the grid on every tap.
SeatCell? nextInAisleOrder({
  required BusLayout? layout,
  required BerthPredicate matches,
  String? from,
  bool wrap = true,
}) =>
    AisleWalk.of(layout).next(from: from, matches: matches, wrap: wrap);
