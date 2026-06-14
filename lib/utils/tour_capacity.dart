import 'dart:math' as math;

import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seating_engine.dart';

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

  /// Genuinely empty berths the engine leaves free: `capacity − occupied`.
  final int free;

  /// Distinct passengers the engine could NOT auto-seat under the hard rules
  /// (stranger-share double, no matching seat type, leg-blocked, overflow).
  /// These are the riders that need the agent's decision — NOT a silent "full".
  final int needsDecision;

  const TourCapacity({
    required this.capacity,
    required this.occupied,
    required this.free,
    required this.needsDecision,
  });

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
  final tripById = <String, TripType>{
    for (final p in tour.passengers) p.id: p.tripType,
  };
  final go = <String, int>{};
  final ret = <String, int>{};
  plan.assignmentsByPassenger.forEach((passengerId, seats) {
    final trip = tripById[passengerId] ?? TripType.roundTrip;
    for (final a in seats) {
      if (trip.usesOutbound) go[a.busId] = (go[a.busId] ?? 0) + 1;
      if (trip.usesReturn) ret[a.busId] = (ret[a.busId] ?? 0) + 1;
    }
  });
  final busIds = <String>{...go.keys, ...ret.keys};
  var occupied = 0;
  for (final id in busIds) {
    occupied += math.max(go[id] ?? 0, ret[id] ?? 0);
  }
  occupied = occupied.clamp(0, capacity);

  final needsDecision = plan.exceptions
      .map((e) => e.passengerId)
      .whereType<String>()
      .toSet()
      .length;

  return TourCapacity(
    capacity: capacity,
    occupied: occupied,
    free: (capacity - occupied).clamp(0, capacity),
    needsDecision: needsDecision,
  );
}
