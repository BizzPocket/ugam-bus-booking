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
  legShareHalf,
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

  // Free berths still bookable on a double, leg-aware: used = max(GO, RET).
  // Only meaningful when berth-accurate (markHalfDouble); leg-deduped charts
  // can't count berths so they never split.
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
    final used = g > r ? g : r;
    hasFreeHalf = (2 - used) >= 1;
  }

  final extra = isDouble && occ.length > 2 ? occ.length - 2 : 0;

  final isShared = isDouble && occ.length > 1 && !legShare;
  final isHalfDouble = markHalfDouble &&
      isDouble &&
      occ.length == 1 &&
      occupants.length == 1;

  // A double sofa is two berths, each reusable across legs, so up to FOUR
  // distinct riders can share it. Draw them as a GO row over a RET row instead
  // of two names + a "+N" badge that hid the rest. A round-trip rider holds
  // both legs of their berth, so they appear in both rows.
  if (isDouble && occ.length > 2) {
    final qgo = occ.where((p) => _legOf(p, cell.seatId).usesOutbound).toList();
    final qret = occ.where((p) => _legOf(p, cell.seatId).usesReturn).toList();
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

  if (legShare) {
    return SeatRender(
      kind: hasFreeHalf ? SeatRenderKind.legShareHalf : SeatRenderKind.legShare,
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
