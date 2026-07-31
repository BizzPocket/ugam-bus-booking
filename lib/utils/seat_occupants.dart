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
      // Bucket THIS berth by its OWN recorded leg so a passenger holding a
      // same-type one-way split (a GO-only seat + a RET-only seat) lands each
      // seat on its real leg; null = legacy row → fall back to the
      // passenger-level leg this resolver always used.
      final leg = a.leg ?? p.tripType;
      if (leg.usesOutbound) go.putIfAbsent(a.seatId, () => p);
      if (leg.usesReturn) ret.putIfAbsent(a.seatId, () => p);
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
    // One seat counts a rider once PER LEG, not per berth — but a same-type
    // one-way split puts the rider on different legs of DIFFERENT seats, so the
    // dedupe is keyed by (seatId, leg): a whole double held solo (two berths,
    // same leg, same seat) still collapses, while the rider's GO seat and RET
    // seat each surface on their own leg.
    final seen = <String>{};
    for (final a in p.assignedSeats) {
      if (a.busId != busId) continue;
      // This berth's OWN recorded leg; null = legacy row → fall back to the
      // passenger-level leg this resolver always used.
      final leg = a.leg ?? p.tripType;
      if (leg.usesOutbound) {
        if (seen.add('${a.seatId}|go')) (go[a.seatId] ??= <Passenger>[]).add(p);
      } else if (leg.usesReturn) {
        if (seen.add('${a.seatId}|ret')) {
          (ret[a.seatId] ??= <Passenger>[]).add(p);
        }
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

/// The journey leg a money-collection chooser is currently scoped to. A shared
/// sofa can carry different riders on each leg (an outbound-only + a return-only,
/// or a round-trip sharing with a one-way rider), so the handler collects from
/// one leg at a time: the GO riders while the bus is going out, the RETURN riders
/// once the outbound leg is done.
enum CollectLeg { go, ret }

/// The riders on a shared seat relevant to [leg] for money collection:
/// [CollectLeg.go] keeps everyone whose trip uses the outbound leg (round-trip +
/// outbound-only); [CollectLeg.ret] keeps everyone whose trip uses the return leg
/// (round-trip + return-only). A round-trip rider therefore appears under both.
/// Pass [seatId] wherever it is known: the leg is then read from the rider's
/// assignment for THAT berth ([Passenger.legForSeat]) instead of their overall
/// tripType, so a round-trip rider who holds this seat on the GO leg only —
/// their return berth being elsewhere — is not offered on its RETURN chooser.
/// Omitting it keeps the coarse trip-type behaviour for callers with no seat in
/// hand.
List<Passenger> occupantsForCollectLeg(
  List<Passenger> occupants,
  CollectLeg leg, {
  String? seatId,
  String? busId,
}) => occupants.where((p) {
      final l = seatId == null ? p.tripType : p.legForSeat(seatId, busId: busId);
      return leg == CollectLeg.go ? l.usesOutbound : l.usesReturn;
    }).toList();

/// Every rider who actually boards [busId] on [leg], deduped by passenger id in
/// roster order. This is the "who is on my bus today" roster — attendance,
/// head-counts, per-leg rosters.
///
/// The leg comes from the SEAT they hold on THIS bus (`SeatAssignment.leg`,
/// falling back to the rider's tripType for legacy rows), NEVER from the rider's
/// overall tripType. A round-trip rider whose GO berth is on this bus but whose
/// RET berth is on another bus must not appear on this bus's return roster —
/// the handler would stand waiting for someone riding a different bus home.
///
/// Distinct from [occupantsForCollectLeg], which filters an already-resolved
/// per-SEAT occupant list by the rider's trip type for the money chooser.
List<Passenger> ridersOnBusForLeg(
  Iterable<Passenger> passengers,
  String busId,
  CollectLeg leg,
) {
  final seen = <String>{};
  final out = <Passenger>[];
  for (final p in passengers) {
    final ridesThisLeg = p.assignedSeats.any((a) {
      if (a.busId != busId) return false;
      final seatLeg = a.leg ?? p.tripType;
      return leg == CollectLeg.go ? seatLeg.usesOutbound : seatLeg.usesReturn;
    });
    if (!ridesThisLeg) continue;
    if (seen.add(p.id)) out.add(p);
  }
  return out;
}

/// Whether a shared seat's roster differs across legs, so the chooser should
/// offer a GO/Return toggle. True only when riders exist on BOTH legs and the
/// two leg rosters aren't the same set — e.g. an outbound-only + a return-only,
/// or a round-trip sharing with a one-way rider. A double held by round-trip
/// riders (same people on both legs), or one leg held by same-leg one-way riders
/// (nobody on the other leg), needs no toggle.
bool seatHasLegSplit(List<Passenger> occupants, {String? seatId, String? busId}) {
  final go =
      occupantsForCollectLeg(occupants, CollectLeg.go,
              seatId: seatId, busId: busId)
          .map((p) => p.id)
          .toSet();
  final ret =
      occupantsForCollectLeg(occupants, CollectLeg.ret,
              seatId: seatId, busId: busId)
          .map((p) => p.id)
          .toSet();
  if (go.isEmpty || ret.isEmpty) return false;
  return !(go.length == ret.length && go.containsAll(ret));
}

/// The leg the chooser should open on. RETURN when the outbound leg is already
/// done [outboundDone] or no rider on this seat travels GO at all; otherwise GO
/// (the active leg while the bus is going out).
CollectLeg defaultCollectLeg(
  List<Passenger> occupants, {
  required bool outboundDone,
}) {
  final hasGo = occupants.any((p) => p.tripType.usesOutbound);
  if (outboundDone || !hasGo) return CollectLeg.ret;
  return CollectLeg.go;
}
