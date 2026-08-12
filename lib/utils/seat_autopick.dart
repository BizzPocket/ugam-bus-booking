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
import 'party_fit.dart';

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

  /// The picks this packing represents, each stamped with the leg of the
  /// bucket that produced it.
  List<ChartPick> picksFor(TripType leg) => [
        for (final o in options)
          ChartPick(cell: o.cell, berths: o.berths, leg: leg),
      ];
}

/// Every way this party could take each cell on [bus], given who is free.
List<_Option> _optionsFor({
  required Bus bus,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required bool shareOk,
  required Set<String> claimed,
}) {
  final out = <_Option>[];
  for (final cell in bus.layout?.grid ?? const <SeatCell>[]) {
    if (!cell.hasSeat) continue;
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) continue;
    // An earlier leg's pass already took this berth. One tile, one person —
    // even though disjoint legs could physically share it.
    if (claimed.contains(SeatAvailability.keyFor(bus.id, seatId))) continue;

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
  required Set<String> claimed,
}) {
  if (people <= 0) return null;
  final options = _optionsFor(
    bus: bus,
    availability: availability,
    leg: leg,
    shareOk: shareOk,
    claimed: claimed,
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

/// What the picker managed to do, and what it could not.
///
/// *** WHY THIS IS NOT JUST A LIST ***
/// The old signature returned a bare list and signalled "no room" by returning
/// it empty. That cannot express the ordinary mixed-party outcome where the
/// outbound leg fits and the return leg does not: the go picks are real, the
/// customer should keep them, and the gap belongs in a sentence on the summary
/// bar naming the leg that is short.
class AutoPickResult {
  final List<ChartBusSelection> selections;

  /// Berths the picker could NOT place, per bucket. An absent key means that
  /// bucket was fully seated.
  final Map<TripType, int> shortfall;

  const AutoPickResult({
    this.selections = const [],
    this.shortfall = const {},
  });

  bool get isEmpty => selections.isEmpty;
  bool get hasShortfall => shortfall.isNotEmpty;
}

/// Propose seats for a party, one LEG BUCKET at a time.
///
/// Buckets are filled in [PartyIntent.activeLegs] order — round-trip first,
/// because its berth must be free on BOTH legs and therefore has the fewest
/// candidates. Letting a one-way pass take those cells first would strand it.
///
/// A cell taken by one pass is invisible to the next. Disjoint legs could in
/// principle share a berth (an outbound-only and a return-only passenger; see
/// `seating_engine.dart`), but the customer picker deliberately never does:
/// one tile is always one person. That keeps the chart honest across the two
/// leg tabs and keeps the claim payload free of duplicate seat ids, which the
/// server's uniqueness handling was never written for.
AutoPickResult autoPick({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required PartyIntent intent,
}) {
  if (intent.people <= 0 || buses.isEmpty) return const AutoPickResult();

  // Keyed exactly as availability is, so a seat id shared between two buses
  // cannot collide.
  final claimed = <String>{};
  final byBus = <String, List<ChartPick>>{};
  final shortfall = <TripType, int>{};

  for (final leg in intent.activeLegs) {
    final want = intent.countFor(leg);
    final placed = _pickOneLeg(
      buses: buses,
      availability: availability,
      leg: leg,
      people: want,
      shareOk: intent.shareOk,
      claimed: claimed,
    );

    var covered = 0;
    for (final selection in placed) {
      for (final pick in selection.picks) {
        claimed.add(SeatAvailability.keyFor(selection.bus.id, pick.seatId));
        covered += pick.berths;
        (byBus[selection.bus.id] ??= []).add(pick);
      }
    }
    if (covered < want) shortfall[leg] = want - covered;
  }

  // Rebuilt in bus tab order so the chart's tabs and the checkout list agree.
  final selections = <ChartBusSelection>[
    for (final bus in buses)
      if (byBus[bus.id] != null)
        ChartBusSelection(bus: bus, picks: byBus[bus.id]!),
  ];

  return AutoPickResult(selections: selections, shortfall: shortfall);
}

/// One bucket's worth of picking.
///
/// Returns whatever it could place. Partial is allowed HERE, unlike the old
/// all-or-nothing whole-party version, because the caller reports the gap per
/// leg rather than throwing every other leg's picks away with it.
List<ChartBusSelection> _pickOneLeg({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
  required bool shareOk,
  required Set<String> claimed,
}) {
  if (people <= 0) return const [];

  // ── 1. Whole bucket on ONE bus, in tab order ─────────────────────────────
  for (final bus in buses) {
    final packing = _packBus(
      bus: bus,
      availability: availability,
      leg: leg,
      people: people,
      shareOk: shareOk,
      claimed: claimed,
    );
    if (packing != null) {
      return [ChartBusSelection(bus: bus, picks: packing.picksFor(leg))];
    }
  }

  // ── 2. Split, only because nothing else fits ─────────────────────────────
  final out = <ChartBusSelection>[];
  // A local copy: seats taken during THIS bucket's split must also be hidden
  // from the buses considered after them.
  final used = <String>{...claimed};
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
        claimed: used,
      );
      if (packing == null) continue;
      final picks = packing.picksFor(leg);
      out.add(ChartBusSelection(bus: bus, picks: picks));
      for (final p in picks) {
        used.add(SeatAvailability.keyFor(bus.id, p.seatId));
      }
      remaining -= packing.covered;
      break;
    }
  }

  return out;
}
