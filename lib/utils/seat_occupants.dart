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

/// EVERY distinct rider on each seat of [busId], keyed by seatId, in stable
/// GO-first order (outbound + round-trip riders first, then return-only).
///
/// Unlike [seatOccupantsForBus] — which keeps ONE holder per leg so the tile
/// can draw its GO/RET split — this keeps ALL of them. A Double Sofa is two
/// berths, and each berth may be reused across legs, so one sofa can legally
/// seat up to FOUR distinct one-way riders (two outbound + two return). The
/// older `SeatOccupancy.all` (one GO + one RET) silently dropped the second
/// same-leg rider, so a sofa booked by two return-only riders showed only one
/// of them on every read-only chart, its tap sheet, and the chart PDF. This is
/// the single source those surfaces share, so the full set surfaces everywhere.
///
/// De-duped by passenger id: a whole double held solo by one round-trip rider
/// (two assignment entries on the same seatId) collapses to a single entry, and
/// a rider listed twice on one seat counts once.
Map<String, List<Passenger>> occupantListForBus(
  Iterable<Passenger> passengers,
  String busId,
) {
  // Partition by leg exactly as [seatOccupantsForBus] does (so GO-first
  // ordering matches the tile), but accumulate the FULL list per leg instead of
  // keeping only the first. A round-trip rider uses both legs; bucket them with
  // GO so they are never counted on both sides.
  final go = <String, List<Passenger>>{};
  final ret = <String, List<Passenger>>{};
  for (final p in passengers) {
    final seenSeats = <String>{}; // one seat counts a rider once, not per berth
    for (final a in p.assignedSeats) {
      if (a.busId != busId) continue;
      if (!seenSeats.add(a.seatId)) continue;
      if (p.tripType.usesOutbound) {
        (go[a.seatId] ??= <Passenger>[]).add(p);
      } else if (p.tripType.usesReturn) {
        (ret[a.seatId] ??= <Passenger>[]).add(p);
      }
    }
  }
  final out = <String, List<Passenger>>{};
  for (final seatId in {...go.keys, ...ret.keys}) {
    final list = <Passenger>[];
    final ids = <String>{};
    for (final p in [...?go[seatId], ...?ret[seatId]]) {
      if (ids.add(p.id)) list.add(p);
    }
    out[seatId] = list;
  }
  return out;
}
