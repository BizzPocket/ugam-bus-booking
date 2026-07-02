import 'dart:math' as math;

import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seating_engine.dart';

/// Leg-aware capacity for ONE bus, read from the same engine plan as
/// [TourCapacity]. Lets a per-bus row show the honest two-leg split
/// (`Go 28/40 · Ret 24/40`) instead of a single merged fraction that hides
/// which leg is fuller. [goOccupied]/[retOccupied] are already clamped to
/// [capacity] by [computeTourCapacity].
class BusCapacity {
  /// Bus id this snapshot belongs to (matches [tour.buses[i].id]).
  final String busId;

  /// Physical berths on this bus (a Double Sofa = 2).
  final int capacity;

  /// Berths placed on the outbound (GO) leg of this bus.
  final int goOccupied;

  /// Berths placed on the return (RETURN) leg of this bus.
  final int retOccupied;

  const BusCapacity({
    required this.busId,
    required this.capacity,
    required this.goOccupied,
    required this.retOccupied,
  });

  /// Busier leg — the berths physically tied up at the peak of the journey.
  int get occupied => math.max(goOccupied, retOccupied);

  /// Berths empty on BOTH legs — sellable as a full round-trip.
  int get free => (capacity - occupied).clamp(0, capacity);

  /// Seats with a free outbound slot (`capacity − goOccupied`).
  int get goFree => (capacity - goOccupied).clamp(0, capacity);

  /// Seats with a free return slot (`capacity − retOccupied`).
  int get retFree => (capacity - retOccupied).clamp(0, capacity);

  /// True when both legs carry the same load — render a single bar, not two.
  bool get symmetric => goOccupied == retOccupied;
}

/// Honest, single-source capacity snapshot for a tour, derived from the SAME
/// deterministic [SeatingEngine] that auto-assign uses.
///
/// This exists to kill the old "patchwork" bug where the Requests capacity
/// banner re-derived `free = capacity − demand` on its own — counting every
/// non-waitlisted passenger's berths as if the engine could seat them, even
/// when it could NOT (a stranger-only Double Sofa half, a leg-blocked single, a
/// seater request with only sofas free). That made the bus read "FULL" while a
/// seat sat physically empty. Routing the banner through the engine's actual
/// plan makes "free" mean *genuinely empty* and surfaces the blocked riders as
/// "needs your decision" instead of hiding them inside a false FULL.
class TourCapacity {
  /// Total physical berths across every bus (a Double Sofa = 2).
  final int capacity;

  /// Leg-aware berths the engine actually PLACES — the busier leg per bus,
  /// `max(GO, RET)`, so two opposite one-way riders sharing one berth count
  /// once. Never exceeds [capacity].
  final int occupied;

  /// Genuinely empty berths the engine leaves free on BOTH legs — seats the
  /// agent can still sell as a full round-trip: `capacity − occupied`.
  final int free;

  /// Berths the plan places on the outbound (GO) leg, summed across buses.
  final int goOccupied;

  /// Berths the plan places on the return (RETURN) leg, summed across buses.
  final int retOccupied;

  /// Seats the plan leaves empty on the outbound leg ONLY (occupied returning).
  /// Per-bus `max(0, goFree − retFree)`, summed. A round-trip can't take these,
  /// but an outbound-only rider can. Derived from the SAME plan as [free], so it
  /// never disagrees with the chart the way the old raw-demand reclaim did.
  final int goOnlyFree;

  /// Seats the plan leaves empty on the return leg ONLY (occupied outbound).
  /// Per-bus `max(0, retFree − goFree)`, summed. Fillable by a return-only rider.
  final int retOnlyFree;

  /// Distinct passengers the engine could NOT auto-seat under the hard rules
  /// (stranger-share double, no matching seat type, leg-blocked, overflow).
  /// These are the riders that need the agent's decision — NOT a silent "full".
  final int needsDecision;

  /// Physical berth capacity per seat type (a Double Sofa cell = 2 berths).
  /// Only types the tour's buses actually have appear here.
  final Map<SeatType, int> capByType;

  /// GENUINELY-empty berths per seat type, read from the SAME engine plan as
  /// [free] — `typeCap − max(goPlaced, retPlaced)` clamped to `[0, cap]`. This
  /// replaces the old per-type `capacity − requested-demand` math that could go
  /// NEGATIVE (e.g. "Single Sofa −2") and disagree with the engine headline:
  /// over-demand surfaces as [needsDecision], never as a phantom negative free.
  final Map<SeatType, int> freeByType;

  /// Per-bus leg-aware capacity, keyed by bus id — the SAME plan as the tour
  /// totals, so a per-bus row can show `Go x/n · Ret y/n` without re-deriving
  /// its own count. Empty when the tour has no buses.
  final Map<String, BusCapacity> byBus;

  const TourCapacity({
    required this.capacity,
    required this.occupied,
    required this.free,
    required this.goOccupied,
    required this.retOccupied,
    required this.goOnlyFree,
    required this.retOnlyFree,
    required this.needsDecision,
    required this.capByType,
    required this.freeByType,
    required this.byBus,
  });

  /// Tour-wide seats with a free OUTBOUND slot — `capacity − goOccupied`.
  /// Mirror of [returnSeatsFree] for the GO leg.
  int get goSeatsFree => (capacity - goOccupied).clamp(0, capacity);

  /// True when both legs carry the same total load — the two-leg meter can
  /// collapse to a single bar (no return leg, or perfectly symmetric demand).
  bool get legsSymmetric => goOccupied == retOccupied;

  /// Berths with a free RETURN slot across every bus — the seats an agent can
  /// still sell as a return-only ticket once the GO leg is done: `capacity −
  /// retOccupied`. Exact for a single-bus tour; a safe total across buses.
  int get returnSeatsFree => (capacity - retOccupied).clamp(0, capacity);

  /// True when the tour has at least one bus with seats to reason about.
  bool get hasBuses => capacity > 0;

  /// Invariant the old banner violated: if a seat is free, the bus is NOT full.
  bool get isFull => hasBuses && free == 0;
}

/// Compute the [TourCapacity] for [tour] by running the deterministic engine on
/// its current buses + passengers and reading the resulting plan. Pure and
/// side-effect free (no persistence) — safe to call from a widget build.
TourCapacity computeTourCapacity(Tour tour) {
  final capacity = tour.totalBusSeats;
  final plan = SeatingEngine.propose(
    buses: tour.buses,
    passengers: tour.passengers,
  );

  // Leg-aware occupancy per bus from the PLAN's placements: each physical berth
  // offers one GO slot + one RET slot, so the honest load is the busier leg.
  //
  // The leg now lives PER REQUEST LINE, not on the passenger, so a single
  // request can mix legs. A [SeatAssignment] carries no leg, so we gate each
  // placed seat against the passenger's per-line GO/RET berth quotas
  // ([Passenger.goBerths]/[Passenger.retBerths]): the first `goBerths` placed
  // seats load GO, the first `retBerths` load RET. Exact when a passenger's
  // seats sit on one bus (the engine keeps them together), a safe upper bound
  // otherwise — and identical to the old whole-passenger gate for a
  // single-leg request.
  final passengerById = <String, Passenger>{
    for (final p in tour.passengers) p.id: p,
  };
  final go = <String, int>{};
  final ret = <String, int>{};
  plan.assignmentsByPassenger.forEach((passengerId, seats) {
    final p = passengerById[passengerId];
    final goQuota = p?.goBerths ?? seats.length;
    final retQuota = p?.retBerths ?? seats.length;
    var i = 0;
    for (final a in seats) {
      if (i < goQuota) go[a.busId] = (go[a.busId] ?? 0) + 1;
      if (i < retQuota) ret[a.busId] = (ret[a.busId] ?? 0) + 1;
      i++;
    }
  });
  // Per-bus capacity so leg-free is bounded by the seats that bus actually has —
  // a seat free outbound on bus A can't offset a seat over-full on bus B.
  final busCap = <String, int>{for (final b in tour.buses) b.id: b.totalSeats};

  // Seat-type lookup keyed "busId:seatId", plus per-type berth capacity (a
  // Double Sofa cell physically seats two → contributes 2 berths). Built from
  // the same grids the engine plans on, so per-type free below reads the PLAN.
  final typeBySeat = <String, SeatType>{};
  final capByType = <SeatType, int>{};
  for (final b in tour.buses) {
    for (final cell in b.layout?.grid ?? const []) {
      final sid = cell.seatId;
      final st = cell.seatType;
      if (sid == null || st == null) continue;
      typeBySeat['${b.id}:$sid'] = st;
      capByType[st] = (capByType[st] ?? 0) + (st == SeatType.doubleSofa ? 2 : 1);
    }
  }
  // Per-type berth-legs the engine actually PLACES (each assignment = 1 berth,
  // a whole double = two entries on the same seatId). Gated PER SEAT by the leg
  // of the matching request line via [Passenger.legForSeatType] — the leg now
  // lives per line, so a mixed request charges each placed seat to its own type's
  // leg rather than the whole-passenger trip. Round-trip is unchanged.
  final goByType = <SeatType, int>{};
  final retByType = <SeatType, int>{};
  plan.assignmentsByPassenger.forEach((passengerId, seats) {
    final p = passengerById[passengerId];
    for (final a in seats) {
      final st = typeBySeat['${a.busId}:${a.seatId}'];
      if (st == null) continue;
      final leg = a.leg ?? (p?.legForSeatType(st) ?? TripType.roundTrip);
      if (leg.usesOutbound) goByType[st] = (goByType[st] ?? 0) + 1;
      if (leg.usesReturn) retByType[st] = (retByType[st] ?? 0) + 1;
    }
  });
  final freeByType = <SeatType, int>{
    for (final st in capByType.keys)
      st: (capByType[st]! -
              math.max(goByType[st] ?? 0, retByType[st] ?? 0))
          .clamp(0, capByType[st]!)
          .toInt(),
  };

  var occupied = 0;
  var goOccupied = 0;
  var retOccupied = 0;
  var goOnlyFree = 0;
  var retOnlyFree = 0;
  final byBus = <String, BusCapacity>{};
  for (final id in busCap.keys) {
    final cap = busCap[id] ?? 0;
    final g = (go[id] ?? 0).clamp(0, cap);
    final r = (ret[id] ?? 0).clamp(0, cap);
    occupied += math.max(g, r);
    goOccupied += g;
    retOccupied += r;
    final goFree = cap - g;
    final retFree = cap - r;
    // The leg with MORE free room carries the one-way-only surplus; the overlap
    // (min) is the fully-empty seats already counted in [free].
    goOnlyFree += math.max(0, goFree - retFree);
    retOnlyFree += math.max(0, retFree - goFree);
    byBus[id] = BusCapacity(
      busId: id,
      capacity: cap,
      goOccupied: g,
      retOccupied: r,
    );
  }
  occupied = occupied.clamp(0, capacity);

  final needsDecision = _decisionFilter(plan, tour).length;

  return TourCapacity(
    capacity: capacity,
    occupied: occupied,
    free: (capacity - occupied).clamp(0, capacity),
    goOccupied: goOccupied,
    retOccupied: retOccupied,
    goOnlyFree: goOnlyFree,
    retOnlyFree: retOnlyFree,
    needsDecision: needsDecision,
    capByType: capByType,
    freeByType: freeByType,
    byBus: byBus,
  );
}

/// The live, non-mutating list of seating exceptions that genuinely still need
/// the agent's decision: the engine's exceptions MINUS overflow riders the agent
/// has already HELD on the waitlist (a held rider isn't a pending decision).
///
/// SINGLE SOURCE for both the "Needs your decision" screen (one card per entry)
/// and the [TourCapacity.needsDecision] badge, so the count and the list can
/// never disagree. Pure — runs the engine but persists nothing.
List<SeatingException> seatingDecisionExceptions(Tour tour) {
  final plan = SeatingEngine.propose(
    buses: tour.buses,
    passengers: tour.passengers,
  );
  return _decisionFilter(plan, tour);
}

/// Drop overflow exceptions whose passenger is already waitlisted — shared by
/// [seatingDecisionExceptions] and [computeTourCapacity] so both apply the
/// IDENTICAL rule.
List<SeatingException> _decisionFilter(SeatingPlan plan, Tour tour) {
  return plan.exceptions.where((ex) {
    if (ex.type != SeatingExceptionType.overflowWaitlist) return true;
    final held = tour.passengers
        .any((p) => p.id == ex.passengerId && p.isWaitlisted);
    return !held;
  }).toList();
}
