import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// Which seat tile to draw. The ONE decision, extracted from [SeatChartTile] so
/// it is pure and unit-testable, and every chart renders the same seat for the
/// same occupancy.
enum SeatRenderKind {
  anonymous,
  free,
  held,
  booked,
  halfDouble,
  shared,
  legShare,
  quad,
}

/// The resolved render decision for a single seat cell: the [kind] plus the
/// occupant slots each tile needs, so the widget is a pure renderer.
class SeatRender {
  final SeatRenderKind kind;
  final List<Passenger> occ;
  final Passenger? primary;
  final Passenger? go;
  final Passenger? ret;
  final Passenger? sharedA;
  final Passenger? sharedB;

  /// [SeatRenderKind.quad] only: the up-to-two riders on the GO (outbound) row
  /// and the up-to-two on the RET (return) row of a double sofa. A round-trip
  /// rider holds both legs of their berth, so they appear in BOTH rows.
  final List<Passenger> quadGo;
  final List<Passenger> quadRet;

  final int extra;

  const SeatRender({
    required this.kind,
    this.occ = const [],
    this.primary,
    this.go,
    this.ret,
    this.sharedA,
    this.sharedB,
    this.quadGo = const [],
    this.quadRet = const [],
    this.extra = 0,
  });
}

/// The leg a render decision charges an occupant to, for the seat [seatId] they
/// hold here: the per-seat [SeatAssignment.leg] via [Passenger.legForSeat],
/// falling back to the coarse [Passenger.tripType] for legacy / unstamped seats.
/// Per-seat so a mixed same-type request (a GO-only and a RET-only seat in one
/// booking) resolves each cell to its own leg instead of the round-trip summary.
TripType _legOf(Passenger p, String? seatId) =>
    seatId == null ? p.tripType : p.legForSeat(seatId);

/// Occupants deduped by id, preserving order. A whole double held solo arrives
/// as the same passenger twice (two assignments on one seatId); collapsing to
/// unique ids makes it render as ONE name, while a genuine shared sofa (two
/// different people) keeps both. Matches [SeatChartTile]'s `_occ`.
List<Passenger> _dedupe(List<Passenger> occupants) {
  if (occupants.length < 2) return occupants;
  final seen = <String>{};
  final out = <Passenger>[];
  for (final p in occupants) {
    if (seen.add(p.id)) out.add(p);
  }
  return out;
}

/// Resolve which seat tile to draw for [cell] given its (berth-accurate)
/// [occupants]. Pure: no BuildContext, no widgets. Reproduces the exact decision
/// [SeatChartTile] made inline, so the extraction is behaviour-preserving.
SeatRender resolveSeatRender({
  required SeatCell cell,
  required List<Passenger> occupants,
  bool markHalfDouble = false,
  bool anonymous = false,
}) {
  // PRIVACY: the customer chart shows only WHERE seats are, never WHO — every
  // other branch is skipped.
  if (anonymous) return const SeatRender(kind: SeatRenderKind.anonymous);

  final occ = _dedupe(occupants);
  final isDouble = cell.seatType == SeatType.doubleSofa;

  // Leg reuse: the FIRST outbound-only (GO) + FIRST return-only (RET) holder
  // share one physical seat across disjoint legs. Tolerant of a stray extra.
  Passenger? go;
  Passenger? ret;
  if (occ.length >= 2) {
    for (final p in occ) {
      final leg = _legOf(p, cell.seatId);
      if (leg == TripType.outboundOnly) {
        go ??= p;
      } else if (leg == TripType.returnOnly) {
        ret ??= p;
      }
    }
    if (go == null || ret == null) {
      go = null;
      ret = null;
    }
  }
  final legShare = go != null && ret != null;

  // Free berths still bookable on a double, leg-aware: a double has two berths
  // PER LEG, so a free half exists whenever EITHER leg has an unused berth —
  // e.g. the whole sofa booked on RET (r=2) but only one rider on GO (g=1)
  // still leaves a free GO berth. An earlier max(g,r) collapsed both legs and
  // hid that half. Only meaningful when berth-accurate (markHalfDouble);
  // leg-deduped charts can't count berths so they never split.
  //
  // Now that the leg-row grid below claims every double whose two legs carry
  // DIFFERENT riders, this only settles the leftover case: riders who ride both
  // legs, i.e. is a lone round-trip occupant sitting on one berth (half) or on
  // the whole sofa (booked). A partly-free leg row is deliberately NOT carved
  // up any more — see the grid's note.
  var hasFreeHalf = false;
  if (markHalfDouble && isDouble) {
    var g = 0, r = 0;
    for (final p in occupants) {
      switch (_legOf(p, cell.seatId)) {
        case TripType.outboundOnly:
          g++;
        case TripType.returnOnly:
          r++;
        case TripType.roundTrip:
          g++;
          r++;
      }
    }
    hasFreeHalf = (2 - g) >= 1 || (2 - r) >= 1;
  }

  final extra = isDouble && occ.length > 2 ? occ.length - 2 : 0;

  // Reached only for a double whose two legs carry the SAME riders (the grid
  // below took every other double), so this is the "two-plus people sharing the
  // sofa for the whole trip" tile: names stacked, no leg split to draw.
  final isShared = isDouble && occ.length > 1 && !legShare;
  // A double with ONE distinct occupant that still has a free berth renders as
  // a half (occupant + empty half), not a full booked tile. Also only reached
  // for a both-legs rider now — a one-leg occupant is drawn on their own leg
  // row by the grid below, which is what shows their free opposite leg.
  final isHalfDouble = markHalfDouble && isDouble && occ.length == 1 && hasFreeHalf;

  // A double sofa is two berths, each reusable across legs, so up to FOUR
  // distinct riders can share it. Draw them as a GO row over a RET row instead
  // of two names + a "+N" badge that hid the rest. A round-trip rider holds
  // both legs of their berth, so they appear in both rows.
  //
  // This leg-row grid is the ONE geometry for a double, at EVERY occupancy —
  // not just the 3-4 rider case it was introduced for. When the two legs carry
  // different riders, the smaller paths used to each invent their own picture
  // and both misread the sofa:
  //   * a GO + RET pair with a berth to spare fell to `legShareHalf`, which
  //     quartered BOTH riders (the leg pair crammed into the left column, one
  //     merged empty berth down the right) — so a rider holding a whole leg
  //     row looked like they held a quarter of the sofa;
  //   * two SAME-leg riders fell to `shared`, stacked over the WHOLE tile, so
  //     the opposite leg — completely free — read as fully booked.
  // Keying on "do the legs differ" (rather than a headcount) keeps the genuine
  // stacked cases stacked: two round-trip sharers, or a lone round-trip rider,
  // ride BOTH legs, so there is no leg split to draw and printing each name on
  // both rows would only duplicate it.
  if (isDouble && occ.isNotEmpty) {
    final qgo = occ.where((p) => _legOf(p, cell.seatId).usesOutbound).toList();
    final qret = occ.where((p) => _legOf(p, cell.seatId).usesReturn).toList();
    final sameOnBothLegs = qgo.length == qret.length &&
        qgo.every((p) => qret.any((q) => q.id == p.id));
    if (!sameOnBothLegs) {
      final goRow = qgo.length > 2 ? qgo.sublist(0, 2) : qgo;
      final retRow = qret.length > 2 ? qret.sublist(0, 2) : qret;
      // Each leg row only seats two. A rider beyond that (an OVER-BOOKED leg —
      // 3+ on GO or RET, e.g. two round-trip holders + a one-way squeezed in)
      // has no slot in either row; count everyone NOT drawn so the "+N" badge
      // surfaces them instead of vanishing. occ.length > 4 alone missed this,
      // because the overflow can sit on one leg while the other has room.
      final shownIds = <String>{
        for (final p in goRow) p.id,
        for (final p in retRow) p.id,
      };
      final hidden = occ.where((p) => !shownIds.contains(p.id)).length;
      return SeatRender(
        kind: SeatRenderKind.quad,
        occ: occ,
        quadGo: goRow,
        quadRet: retRow,
        extra: hidden,
      );
    }
  }

  // Only a SINGLE sofa reaches here: on a double, a GO-only + a RET-only rider
  // put different riders on the two legs, so the leg-row grid above already
  // claimed it. A single berth has no berths to lay out side-by-side, so the
  // GO-over-RET stack IS its whole tile.
  if (legShare) {
    return SeatRender(
      kind: SeatRenderKind.legShare,
      occ: occ,
      go: go,
      ret: ret,
      extra: extra,
    );
  }
  if (isShared) {
    return SeatRender(
      kind: SeatRenderKind.shared,
      occ: occ,
      sharedA: occ[0],
      sharedB: occ[1],
      extra: extra,
    );
  }
  if (isHalfDouble) {
    return SeatRender(
        kind: SeatRenderKind.halfDouble, occ: occ, primary: occ.first);
  }
  if (occ.isNotEmpty) {
    return SeatRender(kind: SeatRenderKind.booked, occ: occ, primary: occ.first);
  }
  if (cell.reserved) {
    return const SeatRender(kind: SeatRenderKind.held);
  }
  return const SeatRender(kind: SeatRenderKind.free);
}
