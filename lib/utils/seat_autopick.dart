// Propose seats for a party, so the chart can OPEN already filled in.
//
// Pure Dart — no Flutter, no I/O, no wall clock, no randomness. Identical
// input always yields identical output, which matters more than it sounds:
// availability polls every 20 seconds, and a picker that wobbled between runs
// would make the chart look broken every time it refreshed.
//
// *** WHY THIS IS NOT SeatingEngine.propose ***
// The engine needs `List<Passenger>` — the whole roster — and the customer app
// deliberately never receives one. `passengers` has no anon SELECT policy,
// precisely so a stranger cannot read who is sitting where off a public tour.
// So this picker sees only what a customer legitimately has: the layout, the
// ANONYMISED per-seat availability, the leg, and the party's own answers.
//
// The server still re-validates every seat inside an advisory lock, so a stale
// or over-optimistic proposal loses cleanly instead of double-booking.

import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import 'chart_seat_availability.dart';
import 'chart_selection.dart';

/// One way of taking one cell: a whole double, half a double, or a single.
class _Option {
  final SeatCell cell;
  final int berths;
  final double price;

  const _Option({
    required this.cell,
    required this.berths,
    required this.price,
  });

  String get seatId => cell.seatId ?? '';
  int get row => cell.row;

  /// A lower berth is the one elders and anyone prone to motion sickness need.
  /// The gate deliberately does not ask about this — the picker just prefers
  /// it, so the benefit survives without spending a question on it.
  bool get isLower => cell.position == SeatPosition.lower;

  /// Lower BERTHS this option yields, for scoring. A whole lower double seats
  /// two people low, not one.
  int get lowerBerths => isLower ? berths : 0;
}

/// A completed packing for one bus.
class _Packing {
  final List<_Option> options;
  final int covered;
  final int rowSpan;
  final double price;

  const _Packing({
    required this.options,
    required this.covered,
    required this.rowSpan,
    required this.price,
  });

  int get lowerBerths =>
      options.fold<int>(0, (sum, o) => sum + o.lowerBerths);

  List<ChartPick> get picks => [
        for (final o in options) ChartPick(cell: o.cell, berths: o.berths),
      ];
}

/// Every way this party could take each cell on [bus], given who is free.
List<_Option> _optionsFor({
  required Bus bus,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required bool shareOk,
}) {
  final out = <_Option>[];
  for (final cell in bus.layout?.grid ?? const <SeatCell>[]) {
    if (!cell.hasSeat) continue;
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) continue;

    final free = freeBerths(
      cell: cell,
      occupancy: availability[SeatAvailability.keyFor(bus.id, seatId)],
      leg: leg,
    );
    if (free <= 0) continue;

    final capacity = berthsOfCell(cell);
    final perBerth =
        bus.berthPriceFor(cell.seatType!, cell.row) * Bus.tripFactor(leg);

    if (capacity == 2) {
      // A whole sofa is always offerable when both berths are free — it is the
      // only way a party that refuses to share can use a double at all.
      if (free >= 2) {
        out.add(_Option(cell: cell, berths: 2, price: perBerth * 2));
      }
      // Half a sofa means an unrelated stranger takes the other berth. The
      // gate asks about this in words now, and "no" means never propose it.
      if (shareOk) {
        out.add(_Option(cell: cell, berths: 1, price: perBerth));
      }
    } else {
      out.add(_Option(cell: cell, berths: 1, price: perBerth));
    }
  }

  // Deterministic base order. Every later sort is stable on top of this.
  out.sort((a, b) {
    final byRow = a.row.compareTo(b.row);
    if (byRow != 0) return byRow;
    final byCol = a.cell.col.compareTo(b.cell.col);
    if (byCol != 0) return byCol;
    return b.berths.compareTo(a.berths);
  });
  return out;
}

/// Fill [people] berths starting from [anchorRow], taking the nearest and best
/// seat each time.
_Packing? _packFrom({
  required List<_Option> options,
  required int people,
  required int anchorRow,
}) {
  final used = <String>{};
  final taken = <_Option>[];
  var covered = 0;

  while (covered < people) {
    final remaining = people - covered;
    _Option? best;

    for (final o in options) {
      if (used.contains(o.seatId)) continue;
      if (best == null || _better(o, best, remaining, anchorRow)) best = o;
    }
    if (best == null) break; // nothing left to take

    used.add(best.seatId);
    taken.add(best);
    covered += best.berths;
  }

  if (covered < people) return null;

  final rows = taken.map((o) => o.row).toList()..sort();
  return _Packing(
    options: taken,
    covered: covered,
    rowSpan: rows.isEmpty ? 0 : rows.last - rows.first,
    price: taken.fold<double>(0, (sum, o) => sum + o.price),
  );
}

/// Is [a] a better next pick than [b], for a party still needing [remaining]?
bool _better(_Option a, _Option b, int remaining, int anchorRow) {
  // 1. Prefer an option that does not overshoot the party size. Buying a whole
  //    sofa for one person is sometimes unavoidable, never preferable.
  final aFits = a.berths <= remaining ? 0 : 1;
  final bFits = b.berths <= remaining ? 0 : 1;
  if (aFits != bFits) return aFits < bFits;

  // 2. Sit together. Distance from the anchor row beats everything below,
  //    including price — splitting a family to save money is the wrong trade.
  final aDist = (a.row - anchorRow).abs();
  final bDist = (b.row - anchorRow).abs();
  if (aDist != bDist) return aDist < bDist;

  // 3. Two people take a whole sofa rather than two singles across the aisle.
  final aPair = (remaining >= 2 && a.berths == 2) ? 0 : 1;
  final bPair = (remaining >= 2 && b.berths == 2) ? 0 : 1;
  if (aPair != bPair) return aPair < bPair;

  // 4. Lower berths.
  if (a.isLower != b.isLower) return a.isLower;

  // 5. Cheaper, as a tie-break only.
  if (a.price != b.price) return a.price < b.price;

  // 6. Seat id, purely so the result cannot wobble between identical runs.
  return a.seatId.compareTo(b.seatId) < 0;
}

/// Best packing of [people] onto one bus, or null when it cannot hold them.
_Packing? _packBus({
  required Bus bus,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  required bool shareOk,
}) {
  if (people <= 0) return null;
  final options = _optionsFor(
    bus: bus,
    availability: availability,
    leg: leg,
    shareOk: shareOk,
  );
  if (options.isEmpty) return null;

  final anchors = options.map((o) => o.row).toSet().toList()..sort();

  _Packing? best;
  for (final anchor in anchors) {
    final packing = _packFrom(
      options: options,
      people: people,
      anchorRow: anchor,
    );
    if (packing == null) continue;
    if (best == null || _betterPacking(packing, best)) best = packing;
  }
  return best;
}

bool _betterPacking(_Packing a, _Packing b) {
  // Overshoot first: paying for berths nobody sits in is the most visible way
  // to look wrong on the summary bar.
  if (a.covered != b.covered) return a.covered < b.covered;
  if (a.rowSpan != b.rowSpan) return a.rowSpan < b.rowSpan;
  if (a.lowerBerths != b.lowerBerths) return a.lowerBerths > b.lowerBerths;
  if (a.price != b.price) return a.price < b.price;
  return false;
}

/// Seats the whole party, or nothing at all.
///
/// Returns one [ChartBusSelection] per bus used — usually one. It only spans
/// buses when NO single bus can hold the party, and the caller is expected to
/// say so on the summary bar: discovering a split at the boarding point is the
/// failure this is designed to avoid.
///
/// An empty result means the party cannot be seated. A partial pick is never
/// returned, because silently under-booking a family of four is worse than
/// telling them plainly that there is not room.
List<ChartBusSelection> autoPick({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  bool shareOk = true,
}) {
  if (people <= 0 || buses.isEmpty) return const [];

  // ── 1. Whole party on ONE bus, in tab order ──────────────────────────────
  for (final bus in buses) {
    final packing = _packBus(
      bus: bus,
      availability: availability,
      leg: leg,
      people: people,
      shareOk: shareOk,
    );
    if (packing != null) {
      return [ChartBusSelection(bus: bus, picks: packing.picks)];
    }
  }

  // ── 2. Split, only because nothing else fits ─────────────────────────────
  final out = <ChartBusSelection>[];
  var remaining = people;

  for (final bus in buses) {
    if (remaining <= 0) break;
    // Take as much as this bus can carry, largest first, so the party lands in
    // as few buses as possible.
    for (var want = remaining; want >= 1; want--) {
      final packing = _packBus(
        bus: bus,
        availability: availability,
        leg: leg,
        people: want,
        shareOk: shareOk,
      );
      if (packing == null) continue;
      out.add(ChartBusSelection(bus: bus, picks: packing.picks));
      remaining -= packing.covered;
      break;
    }
  }

  // All or nothing.
  if (remaining > 0) return const [];
  return out;
}
