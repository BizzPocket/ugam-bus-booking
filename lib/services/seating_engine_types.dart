part of 'seating_engine.dart';

// Public value types of the seating engine: legs, plan, reasons, exceptions.

/// A tour leg. Capacity is tracked PER LEG so the same physical berth can be
/// reused across disjoint legs (an outbound-only passenger and a return-only
/// passenger can hold the SAME seat at once). A round-trip passenger needs the
/// berth on BOTH legs and therefore blocks any reuse.
enum TripLeg {
  go,
  ret;

  /// The legs a [tripType] actually occupies.
  static List<TripLeg> forTrip(TripType t) {
    final legs = <TripLeg>[];
    if (t.usesOutbound) legs.add(TripLeg.go);
    if (t.usesReturn) legs.add(TripLeg.ret);
    return legs;
  }

  /// Inverse of [forTrip]: the [TripType] a set of held legs represents.
  static TripType tripTypeOf(List<TripLeg> legs) {
    final go = legs.contains(TripLeg.go);
    final ret = legs.contains(TripLeg.ret);
    if (go && ret) return TripType.roundTrip;
    if (go) return TripType.outboundOnly;
    if (ret) return TripType.returnOnly;
    return TripType.roundTrip;
  }
}

/// Why a particular berth was placed where it was. Every assignment the engine
/// proposes carries one of these so the plan is fully explainable.
class PlacementReason {
  /// The bus + seat the berth landed on.
  final String busId;
  final String seatId;

  /// The passenger who holds the berth.
  final String passengerId;

  /// One-line human-readable rationale, e.g. "group Patel — same bus",
  /// "approved priority — lower berth", "type match: Double Sofa Lower",
  /// "cross-fill: single berth toward a Double Sofa line", or "locked".
  final String reason;

  const PlacementReason({
    required this.busId,
    required this.seatId,
    required this.passengerId,
    required this.reason,
  });

  @override
  String toString() =>
      'PlacementReason($passengerId @ $busId:$seatId — $reason)';
}

/// The kind of problem a [SeatingException] describes. Each maps to a card the
/// agent resolves by hand; the engine never guesses past a hard rule.
enum SeatingExceptionType {
  /// An approved-priority passenger was seated, but no LOWER berth was
  /// available within any bus's lower-berth budget — they got an upper berth
  /// (or were placed without a lower-berth claim).
  priorityNoLowerBerth,

  /// A group could not be placed entirely on a single bus (no bus has enough
  /// matching free berths for the whole group).
  groupWontFit,

  /// A request line could not be satisfied because no compatible seat
  /// type/position (including valid cross-fill) was free anywhere.
  seatTypeUnavailable,

  /// There was simply not enough capacity left for this passenger — they
  /// overflow onto the waitlist.
  overflowWaitlist,

  /// A coupled double-sofa's two berths could not be kept together, or a
  /// locked pair was broken by surrounding state.
  brokenPair,

  /// A passenger could only be seated by SHARING a Double Sofa with an
  /// UNRELATED occupant (the other berth is held by someone who does NOT share
  /// the passenger's group), and no other compatible seat/leg was free. Two
  /// strangers must not be auto-paired on one sofa — the agent confirms the
  /// pairing (e.g. checks gender) before this berth can be granted.
  sharedDoubleNeedsReview,
}

/// A single thing the agent must decide. Plain-language, stable, deterministic.
class SeatingException {
  final SeatingExceptionType type;

  /// The passenger this exception is about. Null only for bus-level issues.
  final String? passengerId;

  /// The group this exception is about, when relevant (e.g. [groupWontFit]).
  final String? groupId;

  /// The request line that could not be honored, when relevant.
  final RequestLine? requestLine;

  /// One-line human-readable explanation.
  final String message;

  const SeatingException({
    required this.type,
    this.passengerId,
    this.groupId,
    this.requestLine,
    required this.message,
  });

  @override
  String toString() => 'SeatingException(${type.name}'
      '${passengerId != null ? ' p=$passengerId' : ''}'
      '${groupId != null ? ' g=$groupId' : ''}: $message)';
}

/// The full output of [SeatingEngine.propose].
///
/// [assignmentsByPassenger] holds, for every passenger that has at least one
/// proposed berth, the COMPLETE list of [SeatAssignment]s it should hold —
/// including any pre-existing locked entries, preserved verbatim. Passengers
/// with no placement at all are simply absent from the map (see [exceptions]).
class SeatingPlan {
  /// passengerId -> full proposed assignment list (locked entries preserved).
  final Map<String, List<SeatAssignment>> assignmentsByPassenger;

  /// Everything the agent must decide. Ordered deterministically.
  final List<SeatingException> exceptions;

  /// One reason per proposed berth, in placement order. Stable.
  final List<PlacementReason> reasons;

  const SeatingPlan({
    required this.assignmentsByPassenger,
    required this.exceptions,
    required this.reasons,
  });

  /// Convenience: the proposed assignments for one passenger (empty if none).
  List<SeatAssignment> forPassenger(String passengerId) =>
      assignmentsByPassenger[passengerId] ?? const <SeatAssignment>[];

  /// Convenience: every proposed assignment across all passengers, flattened.
  List<SeatAssignment> get allAssignments => [
        for (final list in assignmentsByPassenger.values) ...list,
      ];

  /// Per-seat GO vs RETURN occupancy across the whole plan.
  ///
  /// Because capacity is now LEG-AWARE (a berth has a GO slot and a RETURN
  /// slot), the same physical seat can be held by different passengers on
  /// different legs. This helper lets the UI render that: for every seat that
  /// holds at least one berth, it reports how many berths are occupied on the
  /// outbound (GO) leg vs the return (RETURN) leg, derived from each holder's
  /// coarse [Passenger.derivedTripType] summary.
  ///
  /// NOTE: per-seat legs are now honored. Each [SeatAssignment] carries the leg
  /// of the request line it satisfies, so a passenger that mixes a GO-only line
  /// with a RET-only line reports the correct leg on each of its seats. The
  /// [Passenger.derivedTripType] SUMMARY is used only as a fallback when a seat
  /// has no recorded leg (legacy data).
  ///
  /// Pass the SAME passenger list given to [SeatingEngine.propose]; passengers
  /// absent from the plan are ignored. Keyed by `"busId:seatId"`. A whole double
  /// held solo contributes 2 to its leg(s); a shared double contributes 1 per
  /// holder per leg.
  Map<String, SeatLegOccupancy> legOccupancy(Iterable<Passenger> passengers) {
    final tripById = <String, TripType>{
      for (final p in passengers) p.id: p.derivedTripType,
    };
    final out = <String, SeatLegOccupancy>{};
    for (final entry in assignmentsByPassenger.entries) {
      for (final a in entry.value) {
        // Per-seat leg first; fall back to the passenger summary for legacy
        // seats that carry no recorded leg.
        final trip = a.leg ?? (tripById[entry.key] ?? TripType.roundTrip);
        final usesGo = trip.usesOutbound;
        final usesReturn = trip.usesReturn;
        final key = '${a.busId}:${a.seatId}';
        final cur = out[key] ?? const SeatLegOccupancy(go: 0, ret: 0);
        out[key] = SeatLegOccupancy(
          go: cur.go + (usesGo ? 1 : 0),
          ret: cur.ret + (usesReturn ? 1 : 0),
        );
      }
    }
    return out;
  }
}

/// How many berths of a single seat are occupied on each tour leg.
///
/// Exposed so the UI can show leg-aware reuse: a seat can read e.g. `go: 1,
/// ret: 1` from two DIFFERENT passengers (one outbound-only, one return-only)
/// sharing the same berth across disjoint legs.
class SeatLegOccupancy {
  /// Berths occupied on the outbound (GO) leg.
  final int go;

  /// Berths occupied on the return (RETURN) leg.
  final int ret;

  const SeatLegOccupancy({required this.go, required this.ret});

  @override
  String toString() => 'SeatLegOccupancy(go: $go, ret: $ret)';
}
