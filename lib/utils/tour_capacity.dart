import 'dart:math' as math;

import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seating_engine.dart';

/// Sellable berths on [bus], and whether that number came from its real seat
/// grid or from the legacy `total_seats` column.
///
/// THE single definition of "how big is this bus", read by BOTH
/// [computeTourCapacity] and [computeActualCapacity] so those surfaces can never
/// disagree about the same bus again.
///
/// Why the fallback exists: cold start deliberately ships buses WITHOUT their
/// `layout` jsonb (~71% of bus bytes on a live probe), and a LOST layout leaves
/// exactly the same shape behind — an empty grid on a bus that really does have
/// seats. Every grid-derived count then reads 0. That is how the tour overview
/// came to show `0/0` for a 37-seat bus while the Requests screen — the one
/// surface that already carried this fallback — correctly showed `72/74` off the
/// identical tour.
///
/// The grid wins whenever it holds seats: it is the ONLY source that knows which
/// cells are RESERVED (held), and those berths are excluded from [sellable].
/// The legacy column knows nothing about holds, so in that branch every berth is
/// treated as sellable — an over-count is safer here than a false "full", which
/// is the failure this whole helper exists to prevent.
({int sellable, int reserved, bool fromGrid}) busBerths(Bus bus) {
  var sellable = 0;
  var reserved = 0;
  for (final cell in bus.layout?.grid ?? const <SeatCell>[]) {
    if (cell.seatId == null || cell.seatType == null) continue;
    final berths = cell.seatType == SeatType.doubleSofa ? 2 : 1;
    if (cell.reserved) {
      reserved += berths;
    } else {
      sellable += berths;
    }
  }
  if (sellable > 0 || reserved > 0) {
    return (sellable: sellable, reserved: reserved, fromGrid: true);
  }
  // No usable grid. Read the legacy column DIRECTLY rather than via
  // [Bus.totalSeats] — that getter prefers `layout.totalSeats`, which is 0 for
  // the present-but-empty-grid case and would defeat the fallback here.
  final legacy = bus.totalSeatsLegacy;
  return (sellable: legacy < 0 ? 0 : legacy, reserved: 0, fromGrid: false);
}

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

/// Free WHOLE tiles of one seat type, split by which legs are still open — so
/// the by-type breakdown can say "1 Double free round-trip · 2 more free going
/// only" and the agent instantly knows which request each open seat can take.
///
/// A tile falls in EXACTLY one bucket (a whole unit of the type must be free on
/// that leg — a Double Sofa needs BOTH berths free, so a half-taken double lands
/// in NO bucket, no fresh pair fits either way):
///  * [round]   — empty on BOTH legs → sellable as a fresh round-trip booking.
///  * [goOnly]  — empty going, held returning → fits an OUTBOUND-only rider.
///  * [retOnly] — empty returning, held going → fits a RETURN-only rider.
class SeatTypeFree {
  /// Tiles free on both legs — a fresh round-trip booking of this type fits.
  final int round;

  /// Tiles free on the outbound leg only (a return rider holds the seat coming
  /// back) — a go-only rider of this type can still take them.
  final int goOnly;

  /// Tiles free on the return leg only (an outbound rider holds the seat going)
  /// — a return-only rider of this type can still take them.
  final int retOnly;

  const SeatTypeFree({this.round = 0, this.goOnly = 0, this.retOnly = 0});

  /// Every fresh booking of this type the agent can still take, any leg.
  int get total => round + goOnly + retOnly;

  /// True when there's leg asymmetry worth surfacing (a one-way-only opening).
  bool get hasOneWay => goOnly > 0 || retOnly > 0;
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

  /// Leg-aware berths the engine actually PLACES — the busier leg per seat,
  /// `max(GO, RET)`, so two opposite one-way riders sharing one berth count
  /// once. Never exceeds [capacity]. Excludes held (reserved) seats.
  final int occupied;

  /// Genuinely empty berths the engine leaves free on BOTH legs — seats the
  /// agent can still sell as a full round-trip: `capacity − occupied`.
  final int free;

  /// Berths the plan places on the outbound (GO) leg, summed across buses.
  final int goOccupied;

  /// Berths the plan places on the return (RETURN) leg, summed across buses.
  final int retOccupied;

  /// Seats the plan leaves empty on the outbound leg ONLY (occupied returning).
  /// Per-seat `max(0, goFree − retFree)`, summed. A round-trip can't take these,
  /// but an outbound-only rider can. Derived from the SAME plan as [free], so it
  /// never disagrees with the chart the way the old raw-demand reclaim did.
  final int goOnlyFree;

  /// Seats the plan leaves empty on the return leg ONLY (occupied outbound).
  /// Per-seat `max(0, retFree − goFree)`, summed. Fillable by a return-only rider.
  final int retOnlyFree;

  /// The riders the engine could NOT auto-seat under the hard rules
  /// (stranger-share double, no matching seat type, leg-blocked, overflow),
  /// minus any overflow rider already held on the waitlist.
  ///
  /// Carried on the snapshot rather than recomputed by
  /// [seatingDecisionExceptions] so the "Needs your decision" SCREEN and the
  /// badge COUNT come from one memoized engine run instead of two identical
  /// ones. See [needsDecision].
  final List<SeatingException> decisions;

  /// Physical TILE capacity per seat type — one tile of that type = 1 unit (a
  /// Double Sofa cell is ONE tile that seats a pair, NOT two berths), matching
  /// the demand summary's "a Double Sofa counts as ONE unit". Only types the
  /// tour's buses actually have appear here.
  final Map<SeatType, int> capByType;

  /// GENUINELY-empty WHOLE tiles per seat type, split by open leg — read from
  /// the SAME engine plan as [free]. A tile counts as free on a leg ONLY when
  /// ZERO berths are placed on it that leg (a whole unit must fit — a Double
  /// Sofa needs BOTH berths free), so a half-occupied double is NOT a free
  /// double. Counted in tiles/units (a double = 1), so it agrees with the demand
  /// line and never over-reports bookable doubles the way the old berth-based
  /// `typeCap − max(goPlaced, retPlaced)` did. See [SeatTypeFree] for the
  /// round / go-only / return-only split the by-type breakdown renders.
  final Map<SeatType, SeatTypeFree> freeByType;

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
    required this.decisions,
    required this.capByType,
    required this.freeByType,
    required this.byBus,
  });

  /// How many riders need the agent's decision — NOT a silent "full".
  int get needsDecision => decisions.length;

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
  final plan = SeatingEngine.propose(
    buses: tour.buses,
    passengers: tour.passengers,
  );

  final passengerById = <String, Passenger>{
    for (final p in tour.passengers) p.id: p,
  };

  // Seat-type lookup keyed "busId:seatId", plus per-type TILE capacity — one
  // physical tile of that type = 1 unit (a Double Sofa cell is ONE tile that
  // seats a pair, NOT two berths), matching the "a Double Sofa counts as ONE
  // unit" convention the demand summary uses. Built from the same grids the
  // engine plans on, so per-type free below reads the PLAN.
  //
  // RESERVED cells are HELD, never sellable — the engine never auto-fills them.
  // They are excluded from [typeBySeat]/[capByType] (and every free/occupied
  // bucket below), and their berths are subtracted from [capacity], so a held
  // seat can never read as free sellable capacity.
  final typeBySeat = <String, SeatType>{};
  final capByType = <SeatType, int>{};
  for (final b in tour.buses) {
    for (final cell in b.layout?.grid ?? const []) {
      final sid = cell.seatId;
      final st = cell.seatType;
      if (sid == null || st == null || cell.reserved) continue;
      typeBySeat['${b.id}:$sid'] = st;
      capByType[st] = (capByType[st] ?? 0) + 1;
    }
  }
  // Sellable capacity through the SHARED [busBerths] definition — grid berths
  // minus held cells where a grid exists, the legacy column where it does not.
  // Identical arithmetic to the old `totalBusSeats − reservedBerths`, now stated
  // once so [computeActualCapacity] cannot drift from it.
  final capacity =
      tour.buses.fold<int>(0, (sum, b) => sum + busBerths(b).sellable);
  // Berth-legs the plan PLACES on each physical tile, split by leg. A whole
  // double tile is two entries on one seatId, a half-open double just one.
  // Gated PER SEAT by the request line's leg via [Passenger.legForSeatType] —
  // the leg lives per line, so a mixed request charges each placed seat to its
  // own leg. Round-trip loads both legs.
  final goBySeat = <String, int>{};
  final retBySeat = <String, int>{};
  plan.assignmentsByPassenger.forEach((passengerId, seats) {
    final p = passengerById[passengerId];
    for (final a in seats) {
      final st = typeBySeat['${a.busId}:${a.seatId}'];
      if (st == null) continue;
      final leg = a.leg ?? (p?.legForSeatType(st) ?? TripType.roundTrip);
      final k = '${a.busId}:${a.seatId}';
      if (leg.usesOutbound) goBySeat[k] = (goBySeat[k] ?? 0) + 1;
      if (leg.usesReturn) retBySeat[k] = (retBySeat[k] ?? 0) + 1;
    }
  });
  // GENUINELY-empty WHOLE tiles per seat type, split by which legs are open —
  // the fresh bookings of that type the agent can still take. A tile is free on
  // a leg ONLY when ZERO berths are placed on it that leg (a whole unit must fit
  // — a Double Sofa needs BOTH berths free), so a half-occupied double (one half
  // taken) is free on NEITHER leg: a new pair can't sit there. Counted in tiles
  // (a double = 1 unit), agreeing with the demand line and the by-type row's own
  // intent ("match a Double Sofa request to a free double"). The go-only /
  // return-only buckets carry the one-way surplus per type, so the breakdown can
  // tell a round-trip opening from a going-/returning-only one at a glance.
  final roundByType = <SeatType, int>{for (final st in capByType.keys) st: 0};
  final goOnlyByType = <SeatType, int>{for (final st in capByType.keys) st: 0};
  final retOnlyByType = <SeatType, int>{for (final st in capByType.keys) st: 0};
  for (final b in tour.buses) {
    for (final cell in b.layout?.grid ?? const []) {
      final sid = cell.seatId;
      final st = cell.seatType;
      if (sid == null || st == null || cell.reserved) continue;
      final k = '${b.id}:$sid';
      final goOpen = (goBySeat[k] ?? 0) == 0;
      final retOpen = (retBySeat[k] ?? 0) == 0;
      if (goOpen && retOpen) {
        roundByType[st] = (roundByType[st] ?? 0) + 1;
      } else if (goOpen) {
        goOnlyByType[st] = (goOnlyByType[st] ?? 0) + 1;
      } else if (retOpen) {
        retOnlyByType[st] = (retOnlyByType[st] ?? 0) + 1;
      }
    }
  }
  final freeByType = <SeatType, SeatTypeFree>{
    for (final st in capByType.keys)
      st: SeatTypeFree(
        round: roundByType[st] ?? 0,
        goOnly: goOnlyByType[st] ?? 0,
        retOnly: retOnlyByType[st] ?? 0,
      ),
  };

  // Meter totals read from the SAME per-seat goBySeat/retBySeat map that drives
  // [freeByType] — so the headline "free" can never claim a round-trip seat that
  // the by-type breakdown counts as go-only/return-only. Each physical berth
  // offers one GO slot + one RET slot; a seat is round-trip-free only where BOTH
  // legs are open (min of the two), and the surplus on the roomier leg is the
  // one-way-only opening. Reserved (held) cells are skipped entirely.
  var occupied = 0;
  var goOccupied = 0;
  var retOccupied = 0;
  var free = 0;
  var goOnlyFree = 0;
  var retOnlyFree = 0;
  final busGo = <String, int>{};
  final busRet = <String, int>{};
  final busCapTotal = <String, int>{};
  for (final b in tour.buses) {
    for (final cell in b.layout?.grid ?? const []) {
      final sid = cell.seatId;
      final st = cell.seatType;
      if (sid == null || st == null || cell.reserved) continue;
      final int capBerths = st.berthsPerUnit.toInt();
      final k = '${b.id}:$sid';
      final placedGo = (goBySeat[k] ?? 0).clamp(0, capBerths).toInt();
      final placedRet = (retBySeat[k] ?? 0).clamp(0, capBerths).toInt();
      final gF = capBerths - placedGo;
      final rF = capBerths - placedRet;
      free += math.min(gF, rF);
      goOnlyFree += math.max(0, gF - rF);
      retOnlyFree += math.max(0, rF - gF);
      occupied += capBerths - math.min(gF, rF);
      goOccupied += placedGo;
      retOccupied += placedRet;
      busGo[b.id] = (busGo[b.id] ?? 0) + placedGo;
      busRet[b.id] = (busRet[b.id] ?? 0) + placedRet;
      busCapTotal[b.id] = (busCapTotal[b.id] ?? 0) + capBerths;
    }
  }
  // Per-bus leg-aware snapshot — every bus appears (0 when it has no sellable,
  // non-reserved seats), derived from the same per-seat loop as the tour totals.
  final byBus = <String, BusCapacity>{
    for (final b in tour.buses)
      b.id: BusCapacity(
        busId: b.id,
        capacity: busCapTotal[b.id] ?? 0,
        goOccupied: busGo[b.id] ?? 0,
        retOccupied: busRet[b.id] ?? 0,
      ),
  };

  // 2G cold-start: Phase 2 ships buses WITHOUT layout jsonb. Until Phase 3 /
  // ensureBusLayouts fills grids, the loops above see empty grids and would
  // report free=0 on a 40-seat bus — a false "full" on Home. Fall back to the
  // legacy total_seats column + assigned seat entries for those buses only.
  //
  // Gated on [busBerths.fromGrid] rather than `b.layout != null`: a layout that
  // is present but carries an EMPTY grid strands the bus in exactly the same
  // place, and the old null-check skipped the rescue for it.
  for (final b in tour.buses) {
    final berths = busBerths(b);
    if (berths.fromGrid) continue;
    final capBerths = berths.sellable;
    if (capBerths <= 0) continue;
    var placed = 0;
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == b.id) placed++;
      }
    }
    placed = placed.clamp(0, capBerths);
    free += capBerths - placed;
    occupied += placed;
    goOccupied += placed;
    retOccupied += placed;
    busCapTotal[b.id] = capBerths;
    byBus[b.id] = BusCapacity(
      busId: b.id,
      capacity: capBerths,
      goOccupied: placed,
      retOccupied: placed,
    );
  }

  occupied = occupied.clamp(0, capacity);
  free = free.clamp(0, capacity);

  final decisions = _decisionFilter(plan, tour);

  return TourCapacity(
    capacity: capacity,
    occupied: occupied,
    free: free.clamp(0, capacity),
    goOccupied: goOccupied,
    retOccupied: retOccupied,
    goOnlyFree: goOnlyFree,
    retOnlyFree: retOnlyFree,
    decisions: decisions,
    capByType: capByType,
    freeByType: freeByType,
    byBus: byBus,
  );
}

/// ACTUAL, leg-aware occupancy of a tour read from persisted
/// [Passenger.assignedSeats] — the SAME real seats the seat GRID renders — NOT
/// the engine's would-fill plan.
///
/// Why it exists: [computeTourCapacity] runs [SeatingEngine.propose] and counts
/// what the engine WOULD place, so a bus reads "full" the moment there is enough
/// *demand* to fill it — even before anyone is actually seated. That is the right
/// question for the capacity-shortfall / "needs decision" banner ("can everyone
/// fit?"), but it made the tour-overview meters and the "full" dot disagree with
/// the grid, which shows only real assignments. This snapshot answers the OTHER
/// question — "who is actually placed?" — so the overview's fill ratios can never
/// claim a bus is full while its grid still has empty seats. Uses the same
/// leg-split convention as [Tour.occupiedBerthsFor] (`min(seatsOnBus, goBerths)`
/// / `retBerths` per passenger), so it agrees with every other actual-seat
/// surface in the app.
class ActualCapacity {
  /// Sellable berths across every bus (physical total minus reserved) — the SAME
  /// denominator [computeTourCapacity] uses, so only the numerator changes.
  final int capacity;

  /// Berths ACTUALLY assigned on the outbound (GO) leg, summed across buses.
  final int goOccupied;

  /// Berths ACTUALLY assigned on the return (RETURN) leg, summed across buses.
  final int retOccupied;

  /// Per-bus actual leg-aware occupancy, keyed by bus id — reuses [BusCapacity]
  /// (a plain capacity/go/ret holder) but populated from real assignments.
  final Map<String, BusCapacity> byBus;

  /// Per-bus GENUINELY-empty WHOLE tiles by seat type, split by open leg — read
  /// from the same real [Passenger.assignedSeats] as [byBus]. Keyed by bus id,
  /// then by [SeatType]; every seat type the bus HAS appears (all-zero when that
  /// type is fully taken). A tile is free on a leg only when ZERO berths are
  /// placed on it that leg (a Double Sofa needs BOTH berths free), counted in
  /// tiles (a double = 1 unit) so it matches the demand line. The per-seat leg
  /// comes from [SeatAssignment.leg], falling back to the holder's
  /// [Passenger.derivedTripType] for legacy rows with no recorded leg. See
  /// [SeatTypeFree] for the round / go-only / return-only split.
  final Map<String, Map<SeatType, SeatTypeFree>> freeByType;

  const ActualCapacity({
    required this.capacity,
    required this.goOccupied,
    required this.retOccupied,
    required this.byBus,
    required this.freeByType,
  });

  /// Busier leg — the berths physically tied up at the peak of the journey.
  int get occupied => math.max(goOccupied, retOccupied);

  /// Berths empty on BOTH legs — sellable as a full round-trip.
  int get free => (capacity - occupied).clamp(0, capacity);

  /// True when both legs carry the same load — the meter renders a single bar.
  bool get legsSymmetric => goOccupied == retOccupied;

  /// If a seat is actually free, the bus is NOT full.
  bool get isFull => capacity > 0 && free == 0;
}

/// Compute the [ActualCapacity] for [tour] from its persisted seat assignments.
/// Pure and side-effect free — safe to call from a widget build. Cheap: no
/// engine run, just two passes over the bus grids + passengers.
ActualCapacity computeActualCapacity(Tour tour) {
  // Sellable berths per bus (physical berths minus held/reserved cells) — the
  // SAME denominator [computeTourCapacity] derives, so switching a meter from the
  // engine plan to this changes only the OCCUPANCY, never the "/ n" total.
  // Denominator via the SHARED [busBerths] definition, so a bus whose layout
  // jsonb has not landed (or was lost) reports its legacy seat count instead of
  // 0 — the fix for the tour overview reading `0/0` on a 37-seat bus. Occupancy
  // below is read from [Passenger.assignedSeats] and never touched the grid, so
  // correcting the denominator is all that is needed here.
  final capByBus = <String, int>{};
  var capacityTotal = 0;
  for (final b in tour.buses) {
    final berths = busBerths(b).sellable;
    capByBus[b.id] = berths;
    capacityTotal += berths;
  }

  // Actual leg-aware berths placed per bus, from assignedSeats. Mirrors
  // [Tour.occupiedBerthsFor]: each passenger charges min(seatsOnThisBus, goBerths)
  // to GO and min(seatsOnThisBus, retBerths) to RET — exact when a passenger's
  // seats sit on one bus (the engine keeps them together), a safe bound otherwise.
  final goByBus = <String, int>{};
  final retByBus = <String, int>{};
  for (final p in tour.passengers) {
    final perBus = <String, int>{};
    for (final a in p.assignedSeats) {
      perBus[a.busId] = (perBus[a.busId] ?? 0) + 1;
    }
    perBus.forEach((busId, seatsOnBus) {
      goByBus[busId] = (goByBus[busId] ?? 0) + math.min(seatsOnBus, p.goBerths);
      retByBus[busId] = (retByBus[busId] ?? 0) + math.min(seatsOnBus, p.retBerths);
    });
  }

  final byBus = <String, BusCapacity>{
    for (final b in tour.buses)
      b.id: BusCapacity(
        busId: b.id,
        capacity: capByBus[b.id] ?? 0,
        goOccupied: (goByBus[b.id] ?? 0).clamp(0, capByBus[b.id] ?? 0),
        retOccupied: (retByBus[b.id] ?? 0).clamp(0, capByBus[b.id] ?? 0),
      ),
  };

  var go = 0, ret = 0;
  for (final bc in byBus.values) {
    go += bc.goOccupied;
    ret += bc.retOccupied;
  }

  // Per-SEAT leg occupancy from the real assignments — a tile-by-type breakdown
  // needs to know which leg each physical seat is taken on, so (unlike the berth
  // totals above) this reads each [SeatAssignment.leg], falling back to the
  // holder's [Passenger.derivedTripType] for legacy rows. A whole double held
  // solo is two entries on one seatId; a half-open double just one.
  final goBySeat = <String, int>{};
  final retBySeat = <String, int>{};
  for (final p in tour.passengers) {
    for (final a in p.assignedSeats) {
      final leg = a.leg ?? p.derivedTripType;
      final k = '${a.busId}:${a.seatId}';
      if (leg.usesOutbound) goBySeat[k] = (goBySeat[k] ?? 0) + 1;
      if (leg.usesReturn) retBySeat[k] = (retBySeat[k] ?? 0) + 1;
    }
  }

  // Bucket every non-reserved cell into round / go-only / return-only per type,
  // mirroring [computeTourCapacity]'s freeByType but from the actual seats. Every
  // seat type the bus HAS appears (all-zero when fully taken); the UI skips the
  // zero rows.
  final freeByType = <String, Map<SeatType, SeatTypeFree>>{};
  for (final b in tour.buses) {
    final present = <SeatType>{};
    final round = <SeatType, int>{};
    final goOnly = <SeatType, int>{};
    final retOnly = <SeatType, int>{};
    for (final cell in b.layout?.grid ?? const []) {
      final sid = cell.seatId;
      final st = cell.seatType;
      if (sid == null || st == null || cell.reserved) continue;
      present.add(st);
      final k = '${b.id}:$sid';
      final goOpen = (goBySeat[k] ?? 0) == 0;
      final retOpen = (retBySeat[k] ?? 0) == 0;
      if (goOpen && retOpen) {
        round[st] = (round[st] ?? 0) + 1;
      } else if (goOpen) {
        goOnly[st] = (goOnly[st] ?? 0) + 1;
      } else if (retOpen) {
        retOnly[st] = (retOnly[st] ?? 0) + 1;
      }
    }
    freeByType[b.id] = {
      for (final st in present)
        st: SeatTypeFree(
          round: round[st] ?? 0,
          goOnly: goOnly[st] ?? 0,
          retOnly: retOnly[st] ?? 0,
        ),
    };
  }

  return ActualCapacity(
    capacity: capacityTotal,
    goOccupied: go,
    retOccupied: ret,
    byBus: byBus,
    freeByType: freeByType,
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
