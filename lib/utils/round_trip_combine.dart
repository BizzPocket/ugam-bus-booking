// Booking-form helper: a customer who requests the SAME seat type for GO-only
// AND for RETURN-only is physically asking for ONE seat that serves BOTH legs —
// a round trip — but the form stored it as two separate one-way lines (e.g.
// "double sofa GO ×1" + "double sofa RET ×1"). That split over-counts their
// party size and reads as two seats. These pure helpers detect the pattern and
// fold each opposite-leg pair into a single round-trip line.
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// True when [lines] contains a same-(seatType, position) pair of ONE-WAY lines
/// on OPPOSITE legs — a GO-only line AND a RET-only line of the same type and
/// berth position. Each such pair is one physical seat across both legs, so the
/// booking form offers to combine them into a round trip.
bool hasCombinableRoundTripPairs(List<RequestLine> lines) {
  final byKey = <String, ({int go, int ret})>{};
  for (final l in lines) {
    final k = _key(l);
    final cur = byKey[k] ?? (go: 0, ret: 0);
    byKey[k] = switch (l.leg) {
      TripType.outboundOnly => (go: cur.go + l.qty, ret: cur.ret),
      TripType.returnOnly => (go: cur.go, ret: cur.ret + l.qty),
      TripType.roundTrip => cur,
    };
  }
  return byKey.values.any((v) => v.go > 0 && v.ret > 0);
}

/// Fold each same-(seatType, position) GO-only + RET-only pair into ONE
/// round-trip line: `min(go, ret)` units combine into round-trip (the same seat
/// on both legs), any leftover one-way units stay one-way, and round-trip lines
/// pass through. Same-type/position lines are merged by leg. Pure + order-stable
/// (groups appear in first-seen order). A booking with no opposite-leg pair is
/// returned equivalently (only same-key lines coalesce).
List<RequestLine> combineRoundTripPairs(List<RequestLine> lines) {
  // Preserve first-seen key order.
  final order = <String>[];
  final groups = <String, List<RequestLine>>{};
  for (final l in lines) {
    final k = _key(l);
    if (!groups.containsKey(k)) order.add(k);
    (groups[k] ??= <RequestLine>[]).add(l);
  }

  final out = <RequestLine>[];
  for (final k in order) {
    final group = groups[k]!;
    final proto = group.first;
    var go = 0, ret = 0, rt = 0;
    for (final l in group) {
      switch (l.leg) {
        case TripType.outboundOnly:
          go += l.qty;
        case TripType.returnOnly:
          ret += l.qty;
        case TripType.roundTrip:
          rt += l.qty;
      }
    }
    final combined = go < ret ? go : ret; // min → becomes round-trip
    final rtQty = rt + combined;
    final goQty = go - combined;
    final retQty = ret - combined;

    RequestLine line(int qty, TripType leg) => RequestLine(
          seatType: proto.seatType,
          position: proto.position,
          qty: qty,
          leg: leg,
        );
    if (rtQty > 0) out.add(line(rtQty, TripType.roundTrip));
    if (goQty > 0) out.add(line(goQty, TripType.outboundOnly));
    if (retQty > 0) out.add(line(retQty, TripType.returnOnly));
  }
  return out;
}

/// The coarse trip-type summary of [lines] (mirrors the booking form): round-trip
/// if any line is round-trip or the legs are mixed, else the shared one-leg value.
TripType summaryTripTypeOf(List<RequestLine> lines) {
  if (lines.isEmpty) return TripType.roundTrip;
  if (lines.any((l) => l.leg == TripType.roundTrip)) return TripType.roundTrip;
  final legs = lines.map((l) => l.leg).toSet();
  return legs.length == 1 ? legs.first : TripType.roundTrip;
}

/// Per-type UNIT counts (qty sums) after any transform, for the aggregate
/// double/single/seater fields carried alongside the lines.
({int doubleSofa, int singleSofa, int seater}) unitCountsOf(
  List<RequestLine> lines,
) {
  var d = 0, s = 0, st = 0;
  for (final l in lines) {
    switch (l.seatType) {
      case SeatType.doubleSofa:
        d += l.qty;
      case SeatType.singleSofa:
        s += l.qty;
      case SeatType.seater:
        st += l.qty;
    }
  }
  return (doubleSofa: d, singleSofa: s, seater: st);
}

String _key(RequestLine l) => '${l.seatType.name}|${l.position?.name ?? '-'}';
