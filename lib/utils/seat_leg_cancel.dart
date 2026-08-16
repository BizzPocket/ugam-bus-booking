// Pure-Dart per-seat leg cancellation. NO Flutter imports, NO I/O, no
// wall-clock time, no randomness — identical input always yields identical
// output.
//
// The counterpart to `seat_leg_resolver.dart`: that one STAMPS each held berth
// with the leg it satisfies, this one STRIKES one leg from one held seat.

import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// Which legs of [seatId] the agent may strike for [p] right now — the single
/// gate behind every "cancel this leg" action, so the seat chart and the Board
/// can never disagree about what is offerable.
///
/// A leg is offerable only when the rider ACTUALLY HOLDS a berth on this seat
/// that travels it. Reading the per-berth leg (not the rider's coarse trip type)
/// is what keeps a party honest: a round-trip rider whose GO berth is this seat
/// and whose RET berth is elsewhere must not be offered "cancel the return" from
/// here — that return lives on another tile.
///
/// [goLegCompleted] splits the two directions in time, because they are
/// opposites rather than a pair:
/// - the RETURN can be struck only AFTER the outbound is done — that is the
///   "they rode out, they are not riding home" case, and before departure the
///   right action is an ordinary cancel, not a leg strike;
/// - the OUTBOUND can be struck only BEFORE it is done. Once the bus has gone
///   you cannot un-ride it; the rider was either on it or marked absent.
({bool go, bool ret}) cancellableSeatLegs(
  Passenger p, {
  required String busId,
  required String seatId,
  required bool goLegCompleted,
}) {
  final target = _baseSeat(seatId);
  var holdsGo = false;
  var holdsRet = false;
  for (final a in p.assignedSeats) {
    if (a.busId != busId || _baseSeat(a.seatId) != target) continue;
    final leg = a.leg ?? p.effectiveTripType;
    if (leg.usesOutbound) holdsGo = true;
    if (leg.usesReturn) holdsRet = true;
  }
  return (go: holdsGo && !goLegCompleted, ret: holdsRet && goLegCompleted);
}

/// Strike ONE leg from ONE seat a passenger holds.
///
/// [strike] is the leg being cancelled — [TripType.returnOnly] for "they rode
/// out but are not riding home", [TripType.outboundOnly] for "they are not
/// riding out but will ride home". [TripType.roundTrip] is not a leg and throws.
///
/// *** WHY THIS IS PER SEAT AND NOT PER PASSENGER ***
/// A party holds several berths — say a whole Double Sofa plus a Single. When
/// one member of that party goes home separately, only THEIR berth loses its
/// return; the rest of the party still rides home on the seats they booked. The
/// old whole-rider cancel had no way to express that, so it cleared every berth
/// the rider held and the entire party vanished off the chart.
///
/// *** WHY THE GO BERTH SURVIVES ***
/// Each berth is re-stamped rather than deleted:
///
/// - a `roundTrip` berth becomes the SURVIVING one-way leg. It stays on the
///   chart, still held, still priced — it just stops consuming the struck leg,
///   so the other half of that tile becomes sellable. This is the case that
///   used to wipe the chart.
/// - a berth already held for the struck leg alone is REMOVED: there is nothing
///   left of it once that leg is gone.
/// - a berth held for the surviving leg alone is untouched — there was no
///   travel on the struck leg to cancel.
///
/// Request lines follow the berths, so demand, capacity and the live fare all
/// stay in step (a demoted berth is charged one leg by `amountDueForSeat`).
///
/// Returns `null` when nothing of the rider survives — no berths AND no request
/// lines — meaning the caller should remove them outright. That is what happens
/// to a return-only rider whose return is struck: they never rode any leg.
/// Returns the passenger UNCHANGED when [seatId] holds no berth of theirs that
/// travels the struck leg, so a mis-aimed tap is a no-op rather than a wipe.
Passenger? cancelSeatLegTransform(
  Passenger p, {
  required String busId,
  required String seatId,
  required TripType strike,
  required SeatType? Function(String busId, String seatId) cellTypeAt,
}) {
  if (strike == TripType.roundTrip) {
    throw ArgumentError.value(
      strike,
      'strike',
      'roundTrip is not a leg — pass outboundOnly (cancel GO) or returnOnly '
          '(cancel RET)',
    );
  }
  final survivor = strike == TripType.returnOnly
      ? TripType.outboundOnly
      : TripType.returnOnly;

  // A seat id can carry a '#' berth suffix; the CELL is the part before it.
  final targetSeat = _baseSeat(seatId);

  // ── 1. Rewrite the berths on the tapped seat ────────────────────────────
  final newSeats = <SeatAssignment>[];
  var demotedBerths = 0; // roundTrip berths that lost the struck leg
  var droppedBerths = 0; // struck-leg-only berths that went away entirely
  for (final a in p.assignedSeats) {
    final isTarget = a.busId == busId && _baseSeat(a.seatId) == targetSeat;
    if (!isTarget) {
      newSeats.add(a);
      continue;
    }
    // No recorded leg (a hand-placed berth) falls back to the rider's coarse
    // leg, the same fallback `legForSeat` and the pricing path already use.
    final leg = a.leg ?? p.effectiveTripType;
    if (leg == TripType.roundTrip) {
      demotedBerths++;
      newSeats.add(a.copyWith(leg: survivor));
    } else if (leg == strike) {
      droppedBerths++;
      // dropped: not carried into newSeats
    } else {
      newSeats.add(a);
    }
  }

  // Nothing on this seat travelled the struck leg — a no-op, not a wipe.
  if (demotedBerths == 0 && droppedBerths == 0) return p;

  // ── 2. Rewrite the request lines to match ───────────────────────────────
  final cellType = cellTypeAt(busId, targetSeat);
  final newLines = cellType == null
      ? List<RequestLine>.from(p.requestLines)
      : _rewriteLines(
          lines: p.requestLines,
          cellType: cellType,
          strike: strike,
          survivor: survivor,
          demotedBerths: demotedBerths,
          droppedBerths: droppedBerths,
        );

  // ── 3. Nothing left of them at all? Caller removes the rider. ───────────
  if (newSeats.isEmpty && newLines.isEmpty) return null;

  // ── 4. Re-derive the coarse leg + the finished flag ─────────────────────
  final rebuilt = p.copyWith(requestLines: newLines, assignedSeats: newSeats);
  // Striking the RETURN is only offered once the GO leg is over, so a rider
  // with no return travel left has finished their journey. Striking the GO leg
  // leaves the ride home ahead of them, so it never retires anyone.
  //
  // `journeyDone` means "has finished travelling" and NOT "holds no seat" — the
  // berths above deliberately survive. `SeatingEngine.propose` seeds the berths
  // a retired rider still holds so nothing is placed on top of them.
  final finished = strike == TripType.returnOnly &&
      !newLines.any((l) => l.leg.usesReturn) &&
      !newSeats.any((a) => (a.leg ?? rebuilt.effectiveTripType).usesReturn);

  return rebuilt.copyWith(
    tripType: rebuilt.derivedTripType,
    journeyDone: p.journeyDone || finished,
  );
}

/// Move [demotedBerths] berths off the round-trip lines onto [survivor], and
/// delete [droppedBerths] berths' worth of [strike] lines, for berths held on a
/// [cellType] seat.
///
/// *** WHY A BERTH IS MATCHED TO MORE THAN ONE LINE TYPE ***
/// Berths are counted per person; request lines are counted in UNITS, and a
/// Double Sofa unit is two berths. The line that a double berth satisfies is
/// therefore not always a double line: a rider holding ONE berth of a SHARED
/// double booked a SINGLE sofa and was cross-filled onto the double cell (two
/// singles satisfy a double). Matching only on the cell's own type left that
/// rider's line untouched — the berth changed leg while the line still claimed
/// a round trip. So candidates are tried in the same order
/// [resolveAssignmentLegs] consumes them: the cell's own type first, then the
/// single-sofa cross-fill.
///
/// Berths convert to units with a FLOOR, and any remainder is simply left
/// alone. That is the conservative direction on both counts: an un-demoted unit
/// keeps claiming the struck leg and an un-dropped unit keeps claiming a berth,
/// so a remainder can only ever OVERSTATE demand. Overstating leaves a seat
/// looking owed; understating would resell a berth somebody is still sitting in.
List<RequestLine> _rewriteLines({
  required List<RequestLine> lines,
  required SeatType cellType,
  required TripType strike,
  required TripType survivor,
  required int demotedBerths,
  required int droppedBerths,
}) {
  var demoteBerths = demotedBerths;
  var dropBerths = droppedBerths;

  // Work on a mutable copy of the qty per line, in list order — the same order
  // `legForSeatType` and `resolveAssignmentLegs` consume lines in, so all three
  // agree about which line a given berth belongs to.
  final qty = [for (final l in lines) l.qty];
  final demoted = <RequestLine>[];

  for (final type in <SeatType>[
    cellType,
    if (cellType == SeatType.doubleSofa) SeatType.singleSofa,
  ]) {
    final unit = type.berthsPerUnit;

    // Drop first: a struck-leg line is pure loss, so spending it before
    // demoting keeps a round-trip line intact for as long as possible.
    for (var i = 0; i < lines.length && dropBerths >= unit; i++) {
      if (lines[i].seatType != type || lines[i].leg != strike) continue;
      final want = dropBerths ~/ unit;
      final take = qty[i] < want ? qty[i] : want;
      qty[i] -= take;
      dropBerths -= take * unit;
    }

    // Demote: split the round-trip line so only the struck units change leg. A
    // partially-demoted line becomes TWO lines (the untouched round-trip
    // remainder + the demoted survivor units), which is exactly what the
    // per-line leg exists to express.
    for (var i = 0; i < lines.length && demoteBerths >= unit; i++) {
      if (lines[i].seatType != type || lines[i].leg != TripType.roundTrip) {
        continue;
      }
      final want = demoteBerths ~/ unit;
      final take = qty[i] < want ? qty[i] : want;
      if (take == 0) continue;
      qty[i] -= take;
      demoteBerths -= take * unit;
      demoted.add(lines[i].copyWith(qty: take, leg: survivor));
    }
  }

  final out = <RequestLine>[
    for (var i = 0; i < lines.length; i++)
      if (qty[i] > 0) lines[i].copyWith(qty: qty[i]),
    ...demoted,
  ];
  return _mergeLines(out);
}

/// Fold lines that agree on (seatType, position, leg) into one, preserving
/// first-appearance order. A demote splits a line and the split half often
/// matches a line the rider already had; leaving both would double an entry in
/// every request summary the agent reads.
List<RequestLine> _mergeLines(List<RequestLine> lines) {
  final order = <String>[];
  final byKey = <String, RequestLine>{};
  for (final l in lines) {
    final key = '${l.seatType.name}|${l.position?.name ?? ''}|${l.leg.name}';
    final cur = byKey[key];
    if (cur == null) {
      order.add(key);
      byKey[key] = l;
    } else {
      byKey[key] = cur.copyWith(qty: cur.qty + l.qty);
    }
  }
  return [for (final k in order) byKey[k]!];
}

String _baseSeat(String seatId) => seatId.split('#').first;
