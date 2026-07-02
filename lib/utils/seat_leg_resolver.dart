// Pure-Dart per-seat trip-leg resolver. NO Flutter imports, NO I/O, no
// wall-clock time, no randomness — identical input always yields identical
// output (request order is the only sort key).
//
// Generalizes the seating engine's `_LockedLegResolver` into a reusable
// function so plan-time and persist-time legs agree: given a passenger's
// request lines and the berths they actually hold, stamp each held berth with
// the trip leg of the line it satisfies.

import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// Stamp each assigned seat with the trip leg of the request line it satisfies.
/// Type-matched in request order; a doubleSofa cell cross-fills from leftover
/// singleSofa legs (two singles satisfy a double); any seat with no matching
/// line falls back to the coarse derived leg. Pure + order-stable. Mirrors the
/// engine's _LockedLegResolver so plan-time and persist-time legs agree.
List<SeatAssignment> resolveAssignmentLegs({
  required List<RequestLine> requestLines,
  required List<SeatAssignment> assigned,
  required SeatType? Function(String busId, String seatId) cellTypeAt,
}) {
  // fallback = derived: lines empty -> roundTrip; one distinct leg -> it;
  // mixed -> roundTrip.
  final fallback = _derivedLeg(requestLines);

  // byType: SeatType -> queue of per-berth legs still unconsumed. A doubleSofa
  // line contributes 2 berths of its leg (a double cell seats two); everything
  // else contributes 1 per qty.
  final byType = <SeatType, List<TripType>>{};
  for (final l in requestLines) {
    final berths = l.qty * (l.seatType == SeatType.doubleSofa ? 2 : 1);
    final q = byType.putIfAbsent(l.seatType, () => <TripType>[]);
    for (var i = 0; i < berths; i++) {
      q.add(l.leg);
    }
  }

  final out = <SeatAssignment>[];
  for (final a in assigned) {
    final type = cellTypeAt(a.busId, a.seatId);
    TripType chosen = fallback;
    if (type != null) {
      final q = byType[type];
      if (q != null && q.isNotEmpty) {
        chosen = q.removeAt(0);
      } else if (type == SeatType.doubleSofa) {
        // doubleSofa berth with no double line left → cross-fill from singles.
        final s = byType[SeatType.singleSofa];
        if (s != null && s.isNotEmpty) chosen = s.removeAt(0);
      }
    }
    out.add(SeatAssignment(
      busId: a.busId,
      seatId: a.seatId,
      locked: a.locked,
      leg: chosen,
    ));
  }
  return out;
}

/// The coarse leg a passenger's lines collapse to: no lines -> round-trip; a
/// single distinct leg -> that leg; mixed legs -> round-trip.
TripType _derivedLeg(List<RequestLine> lines) {
  if (lines.isEmpty) return TripType.roundTrip;
  final first = lines.first.leg;
  for (final l in lines) {
    if (l.leg != first) return TripType.roundTrip;
  }
  return first;
}
