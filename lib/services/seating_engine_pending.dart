part of 'seating_engine.dart';

// Pending-line bookkeeping for [SeatingEngine]: the mutable request-line
// view, locked-berth leg recovery, and the pure helpers that drain, count
// and order pending lines. Moved verbatim out of the engine class (as
// library-private top-level functions) — call sites are unchanged.

// ── Internal mutable state ──────────────────────────────────────────────────

/// A pending request line during planning (a mutable view of [RequestLine]).
///
/// Carries the originating line's [leg] so placement is PER-LINE leg-aware: a
/// round-trip line occupies BOTH legs of its physical berth, while a one-leg
/// line occupies only its leg and leaves the other leg of that seat bookable by
/// an opposite-leg rider.
class _PendingLine {
  final SeatType seatType;
  final SeatPosition? position;
  final int remaining;

  /// Which legs of the tour this line travels (round-trip = both, one-way =
  /// just that leg). Defaults to round-trip so existing callers / tests that do
  /// not set it keep the old whole-seat behavior.
  final TripType leg;

  /// The band this line was SOLD in, when the customer paid for one.
  ///
  /// A rider who paid for rows 1-4 bought a seat in those rows; placing them
  /// outside it takes the higher fare and delivers the cheaper seat. Null for
  /// every line that was never priced — legacy requests and one-leg waitlist
  /// riders — and those stay placeable anywhere.
  final RequestBand? band;

  const _PendingLine({
    required this.seatType,
    this.position,
    required this.remaining,
    this.leg = TripType.roundTrip,
    this.band,
  });

  /// The concrete [TripLeg]s this line occupies on its physical berth.
  List<TripLeg> get tripLegs => TripLeg.forTrip(leg);

  _PendingLine copyDecrementedBy(int n) => _PendingLine(
        seatType: seatType,
        position: position,
        remaining: (remaining - n).clamp(0, remaining),
        leg: leg,
        band: band,
      );
}

class _LockedCell {
  final String busId;
  final String seatId;
  int berths = 0;
  _LockedCell(this.busId, this.seatId);
}

/// Recovers the LEG a locked berth blocks by matching it to one of the
/// passenger's request lines of the same seat type. The per-line leg replaced
/// the per-passenger leg, so a locked seat must inherit the leg of the line it
/// fulfils — not a coarse whole-passenger value. Each request line's legs are
/// handed out in qty order so two locked berths of one type pick up two
/// distinct lines. When no matching line remains (legacy / over-locked data)
/// it falls back to the coarse [Passenger.derivedTripType] summary.
class _LockedLegResolver {
  final TripType _fallback;

  /// seatType -> queue of per-berth legs still unconsumed (a doubleSofa line
  /// contributes 2 berths of the same leg). doubleSofa cells also draw from the
  /// singleSofa queue (cross-fill: two singles satisfy a double) when no double
  /// line is left, mirroring the pending-line drain.
  final Map<SeatType, List<TripType>> _byType;

  _LockedLegResolver(Passenger p)
      : _fallback = p.derivedTripType,
        _byType = {} {
    for (final l in p.requestLines) {
      final berths =
          l.qty * (l.seatType == SeatType.doubleSofa ? 2 : 1);
      final q = _byType.putIfAbsent(l.seatType, () => <TripType>[]);
      for (var i = 0; i < berths; i++) {
        q.add(l.leg);
      }
    }
  }

  List<TripLeg> legsFor(SeatType? type) {
    if (type != null) {
      final q = _byType[type];
      if (q != null && q.isNotEmpty) return TripLeg.forTrip(q.removeAt(0));
      // doubleSofa berth with no double line left → cross-fill from singles.
      if (type == SeatType.doubleSofa) {
        final s = _byType[SeatType.singleSofa];
        if (s != null && s.isNotEmpty) return TripLeg.forTrip(s.removeAt(0));
      }
    }
    return TripLeg.forTrip(_fallback);
  }
}


// ── Helpers ───────────────────────────────────────────────────────────────

/// Build the still-pending request lines for a passenger after subtracting
/// their LOCKED assignments (locked berths already satisfy part of a line).
/// Mirrors the cross-fill draining in tour_seat_assignment_screen.dart.
List<_PendingLine> _buildPendingLines(
    Passenger p, _PlanState state) {
  final pending = [
    for (final l in p.requestLines)
      _PendingLine(
        seatType: l.seatType,
        position: l.position,
        remaining: l.qty,
        leg: l.leg,
        band: l.band,
      ),
  ];

  // Group locked berths by physical cell to know whole vs half double.
  final lockedGroups = <String, _LockedCell>{};
  for (final a in p.assignedSeats) {
    if (!a.locked) continue;
    final key = '${a.busId}:${a.seatId}';
    lockedGroups
        .putIfAbsent(key, () => _LockedCell(a.busId, a.seatId))
        .berths++;
  }

  var leftoverSingleBerths = 0;
  for (final g in lockedGroups.values) {
    final cell = state.cellFor(g.busId, g.seatId);
    if (cell == null) continue;
    switch (cell.seatType) {
      case SeatType.singleSofa:
        for (var i = 0; i < g.berths; i++) {
          if (!_drain(pending, [SeatType.singleSofa], cell.position)) {
            leftoverSingleBerths++;
          }
        }
        break;
      case SeatType.seater:
        for (var i = 0; i < g.berths; i++) {
          _drain(pending, [SeatType.seater], cell.position);
        }
        break;
      case SeatType.doubleSofa:
        if (g.berths >= 2) {
          if (!_drain(pending, [SeatType.doubleSofa], cell.position)) {
            _drain(pending, [SeatType.singleSofa], cell.position);
            _drain(pending, [SeatType.singleSofa], cell.position);
          }
        } else {
          // ONE locked berth on a double cell. First try to complete this
          // passenger's OWN double cell: if a matching pending doubleSofa
          // line exists and the cell's other berth is still free, claim that
          // berth here (2 entries on the same cell, no stranded berth, no
          // reallocation elsewhere). The double line's position only gates
          // which WHOLE double you claim, so a position-agnostic match is
          // fine for completing an already-locked cell. Otherwise fall back
          // to draining a single line, else bucket as a leftover single.
          // Claim the partner berth FIRST. Only when it actually succeeds do
          // we drain the doubleSofa line — otherwise the speculative
          // `_drainDoubleCrossFill` would consume the line and, on refusal,
          // never restore it (the old `&&` short-circuit bug), silently
          // marking the passenger satisfied while holding only one berth.
          final doubleLineIdx = pending.indexWhere((l) =>
              l.seatType == SeatType.doubleSofa && l.remaining > 0);
          final matchedDouble =
              doubleLineIdx >= 0 ? pending[doubleLineIdx] : null;
          if (matchedDouble != null &&
              state.tryClaimPartnerBerth(
                  g.busId, g.seatId, matchedDouble.tripLegs)) {
            // Complete this passenger's OWN half-locked double in place using
            // the LEG of the matched pending double line — not a coarse
            // whole-passenger value — so a one-leg line only blocks its leg.
            _drainDoubleCrossFill(pending);
            state.assign(p.id, g.busId, g.seatId,
                groupId: p.groupId, legs: matchedDouble.tripLegs);
          } else if (!_drain(pending, [SeatType.singleSofa], cell.position)) {
            leftoverSingleBerths++;
          }
        }
        break;
      case null:
        break;
    }
  }

  // Cross-fill: 2 leftover single berths drain ONE doubleSofa line. The
  // double line's position is irrelevant for cross-fill (two single berths
  // make a Double Sofa regardless of upper/lower), so match it directly.
  var pairs = leftoverSingleBerths ~/ 2;
  while (pairs > 0 && _drainDoubleCrossFill(pending)) {
    pairs--;
  }

  // Drop fully-satisfied lines.
  return pending.where((l) => l.remaining > 0).toList();
}

/// Drain ONE pending doubleSofa line via cross-fill, IGNORING its position.
/// A Double Sofa is one bench seating two; its upper/lower tag only picks
/// which whole double CELL to claim, never which single berths may
/// substitute for it. Returns true when a doubleSofa line was decremented.
bool _drainDoubleCrossFill(List<_PendingLine> pending) {
  final idx = pending.indexWhere(
      (l) => l.seatType == SeatType.doubleSofa && l.remaining > 0);
  if (idx < 0) return false;
  pending[idx] = pending[idx].copyDecrementedBy(1);
  return true;
}

bool _drain(
    List<_PendingLine> pending, List<SeatType> tryTypes, SeatPosition? pos) {
  for (final t in tryTypes) {
    final idx = pending.indexWhere((l) =>
        l.seatType == t &&
        (l.position == null || l.position == pos) &&
        l.remaining > 0);
    if (idx >= 0) {
      pending[idx] = pending[idx].copyDecrementedBy(1);
      return true;
    }
  }
  return false;
}

List<_PendingLine> _clonePending(List<_PendingLine> src) => [
      for (final l in src)
        _PendingLine(
          seatType: l.seatType,
          position: l.position,
          remaining: l.remaining,
          leg: l.leg,
          band: l.band,
        ),
    ];

int _remaining(List<_PendingLine> pending) =>
    pending.fold(0, (s, l) => s + l.remaining);

/// Count the SOFA berths a passenger's pending lines still need (doubleSofa
/// = 2 berths, singleSofa = 1; seaters excluded). Used to size the
/// lower-sofa reserve for approved-priority demand.
int _sofaBerths(List<_PendingLine> pending) {
  var n = 0;
  for (final l in pending) {
    switch (l.seatType) {
      case SeatType.doubleSofa:
        n += l.remaining * 2;
        break;
      case SeatType.singleSofa:
        n += l.remaining;
        break;
      case SeatType.seater:
        break;
    }
  }
  return n;
}

/// A copy of [members] with approved-priority members first (so they claim the
/// lower-berth budget), then by passenger id for stability.
List<Passenger> _membersPriorityFirst(List<Passenger> members) =>
    [...members]
      ..sort((a, b) {
        final pa = a.isPriorityApproved ? 0 : 1;
        final pb = b.isPriorityApproved ? 0 : 1;
        if (pa != pb) return pa.compareTo(pb);
        return a.id.compareTo(b.id);
      });

int _groupBerths(
    List<Passenger> members, Map<String, List<_PendingLine>> pending) {
  var n = 0;
  for (final m in members) {
    for (final l in pending[m.id] ?? const <_PendingLine>[]) {
      // A doubleSofa line costs 2 berths; everything else 1.
      n += l.remaining * (l.seatType == SeatType.doubleSofa ? 2 : 1);
    }
  }
  return n;
}

/// Sort key for processing pending lines on a bus. Lower sorts first.
/// doubleSofa(0) < singleSofa(1) < seater(2); upper(0) before lower(1)
/// before null(2); larger qty first.
int _lineSortKey(_PendingLine l) {
  final typeRank = switch (l.seatType) {
    SeatType.doubleSofa => 0,
    SeatType.singleSofa => 1,
    SeatType.seater => 2,
  };
  final posRank = switch (l.position) {
    SeatPosition.upper => 0,
    SeatPosition.lower => 1,
    null => 2,
  };
  // Combine into a single comparable int. qty descending: subtract.
  return typeRank * 1000 + posRank * 100 + (99 - l.remaining.clamp(0, 99));
}

/// Build a sofa placement reason. When an approved-priority passenger lands
/// on a lower berth, the rationale reads "`prefix` lower berth"; otherwise it
/// keeps the type-match [detail].
String _sofaReason(
  String reasonTag, {
  required bool priority,
  required bool lower,
  required String detail,
}) {
  if (priority && lower) return '$reasonTag lower berth';
  return '$reasonTag $detail';
}

String _reasonPrefix(bool priority, String? groupLabel) {
  if (groupLabel != null) {
    return priority
        ? 'group $groupLabel (approved priority) —'
        : 'group $groupLabel —';
  }
  return priority ? 'approved priority —' : '';
}

String _name(Passenger p) => p.name.isNotEmpty ? p.name : p.id;
