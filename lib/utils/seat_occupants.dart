import '../models/passenger.dart';

/// The passengers holding one seat, resolved by leg.
///
/// A single seat can be LEG-SHARED: an `outboundOnly` passenger (the GO leg)
/// and a separate `returnOnly` passenger (the RETURN leg) can both hold the
/// same seatId on disjoint legs. A `roundTrip` passenger holds BOTH legs
/// exclusively (so [go] and [ret] are the same person). A whole Double Sofa
/// held solo by one passenger (two assignment entries on the SAME seatId)
/// still resolves to a single occupant.
///
/// This is the public promotion of the private `_SeatOccupants` struct that
/// lived in `handler_bus_chart_screen.dart` — identical go/ret/isLegShared/
/// sole/all semantics, so handler behaviour is byte-for-byte preserved. It is
/// the IDENTITY view over the same assignment truth that
/// `SeatingPlan.legOccupancy` reads for COUNTS; the two are complementary.
class SeatOccupancy {
  /// The GO-leg occupant (outboundOnly or roundTrip), if any.
  final Passenger? go;

  /// The RETURN-leg occupant (returnOnly or roundTrip), if any.
  final Passenger? ret;

  const SeatOccupancy({this.go, this.ret});

  bool get isEmpty => go == null && ret == null;

  /// True when GO and RETURN are two DIFFERENT people sharing the seat across
  /// legs (an outbound-only + a return-only) — the leg-shared case.
  bool get isLegShared => go != null && ret != null && go!.id != ret!.id;

  /// The single passenger when the seat is held by one person (a round-trip,
  /// or a lone one-way leg); null when leg-shared or empty.
  Passenger? get sole {
    if (isEmpty) return null;
    if (isLegShared) return null;
    return go ?? ret;
  }

  /// Every DISTINCT passenger on this seat, GO first. This is the bug-fix
  /// surface: the tap handler must hand over THIS list, not just `.first`,
  /// so a shared double shows BOTH people exactly as the tile renders them.
  List<Passenger> get all {
    final out = <Passenger>[];
    if (go != null) out.add(go!);
    if (ret != null && (go == null || ret!.id != go!.id)) out.add(ret!);
    return out;
  }
}

/// THE shared seat→occupant resolver. Builds the leg-aware occupants for
/// EVERY seat on [busId] in a single O(passengers × assignedSeats) pass,
/// keyed by seatId.
///
/// "First passenger wins per leg" ordering is preserved via [Map.putIfAbsent]
/// over the passenger iteration order — a verbatim port of the handler's
/// reference `_occupantsBySeatForBus`. The leg partition uses
/// [TripType.usesOutbound]/[TripType.usesReturn] exactly as
/// `SeatingPlan.legOccupancy` does, so identity resolution stays consistent
/// with the count/capacity brain.
Map<String, SeatOccupancy> seatOccupantsForBus(
  Iterable<Passenger> passengers,
  String busId,
) {
  final go = <String, Passenger>{};
  final ret = <String, Passenger>{};
  for (final p in passengers) {
    for (final a in p.assignedSeats) {
      if (a.busId != busId) continue;
      if (p.tripType.usesOutbound) go.putIfAbsent(a.seatId, () => p);
      if (p.tripType.usesReturn) ret.putIfAbsent(a.seatId, () => p);
    }
  }
  final out = <String, SeatOccupancy>{};
  for (final seatId in {...go.keys, ...ret.keys}) {
    out[seatId] = SeatOccupancy(go: go[seatId], ret: ret[seatId]);
  }
  return out;
}

/// Flat distinct-occupant list per seat for callers that only render names.
/// Returns `occ.all` per seat — the de-duped, GO-first, leg-aware list that
/// replaces the flat `Map<String, List<Passenger>>` maps built ad-hoc by the
/// read-only Charts screen.
Map<String, List<Passenger>> occupantListForBus(
  Iterable<Passenger> passengers,
  String busId,
) => {
  for (final e in seatOccupantsForBus(passengers, busId).entries)
    e.key: e.value.all,
};
