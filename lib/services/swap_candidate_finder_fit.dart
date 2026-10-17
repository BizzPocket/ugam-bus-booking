part of 'swap_candidate_finder.dart';

// Compatibility & ranking helpers for [SwapCandidateFinder]: the mover's need
// summary, free-seat filtering, the fit ladder and cell ordering. Moved
// verbatim out of the class as library-private top-level members — the
// unqualified call sites in [SwapCandidateFinder.find] are unchanged.

// ── Compatibility & ranking ───────────────────────────────────────────────

/// Summary of what the mover needs, by seat type. Position-aware for sofas
/// (a lower-double need can't be served by an upper-double exact match), but
/// a null position need matches either deck.
_NeedSummary _needSummary(List<dynamic> requestLines) {
  var needsSeater = false;
  var needsSingleUpper = false;
  var needsSingleLower = false;
  var needsSingleAny = false;
  var needsDoubleUpper = false;
  var needsDoubleLower = false;
  var needsDoubleAny = false;
  for (final l in requestLines) {
    final seatType = l.seatType as SeatType;
    final position = l.position as SeatPosition?;
    switch (seatType) {
      case SeatType.seater:
        needsSeater = true;
        break;
      case SeatType.singleSofa:
        if (position == SeatPosition.upper) {
          needsSingleUpper = true;
        } else if (position == SeatPosition.lower) {
          needsSingleLower = true;
        } else {
          needsSingleAny = true;
        }
        break;
      case SeatType.doubleSofa:
        if (position == SeatPosition.upper) {
          needsDoubleUpper = true;
        } else if (position == SeatPosition.lower) {
          needsDoubleLower = true;
        } else {
          needsDoubleAny = true;
        }
        break;
    }
  }
  return _NeedSummary(
    seater: needsSeater,
    singleUpper: needsSingleUpper,
    singleLower: needsSingleLower,
    singleAny: needsSingleAny,
    doubleUpper: needsDoubleUpper,
    doubleLower: needsDoubleLower,
    doubleAny: needsDoubleAny,
  );
}

/// Free (unoccupied) compatible cells the mover could take outright, in
/// row-major-then-seatId order.
///
/// Availability is judged PER LEG from the MOVER's perspective via
/// [seatHasLegRoom]: a one-way mover only needs room on its own leg, so a
/// Double Sofa whose OTHER leg is occupied (e.g. a RET berth held by a RET-only
/// rider) is still a clean whole-double take for a GO-only mover — leg-disjoint
/// reuse of the same physical seat. A round-trip mover still needs BOTH legs
/// free on the berths it takes.
List<String> _freeSeatsFor({
  required _NeedSummary needs,
  required TripType moverTrip,
  required Map<String, SeatCell> cellById,
  required Map<String, List<SeatLegHolder>> legHoldersBySeat,
}) {
  final cells = cellById.values.toList()..sort(_cellOrder);
  final out = <String>[];
  for (final c in cells) {
    final cap = c.seatType == SeatType.doubleSofa ? 2 : 1;
    final occ = legHoldersBySeat[c.seatId] ?? const <SeatLegHolder>[];
    // Can the mover take a WHOLE cell (both berths on a double, the single on
    // a single/seater)? And can it take at LEAST one berth? Both judged on the
    // mover's own legs only.
    final wholeFree =
        seatHasLegRoom(activeTrip: moverTrip, need: cap, cap: cap, occupants: occ);
    final anyFree =
        seatHasLegRoom(activeTrip: moverTrip, need: 1, cap: cap, occupants: occ);
    if (!anyFree) continue;
    if (needs.acceptsFreeCell(c, wholeFree: wholeFree, anyFree: anyFree)) {
      out.add(c.seatId!);
    }
  }
  return out;
}

/// Fit of an occupant's held [cell] against the mover's [needs]. Returns null
/// when nothing the mover needs can be served by displacing that occupant.
///
/// [occupantBerths] is how many berths THIS occupant holds on [cell] (1 or, on
/// a whole double, 2). It matters because displacing an occupant only frees
/// the berths they personally hold: a SHARED half-double (1 berth) does not
/// free a whole double, so it can never be a clean whole-double match.
///
/// Ranking:
///   rank 0 — exact type AND deck match.
///   rank 1 — exact type, deck-agnostic need (mover stated no deck), so either
///            deck legitimately matches.
///   rank 1.5 (encoded as a labelled rank 1 variant) is avoided; instead the
///   wrong-deck case is a DISTINCT rank-2 "different deck" option so the agent
///   is never shown a deck-violating swap as a clean match.
///   rank 2 — cross-fill / different-deck options that need explanation.
_Fit? _fitFor({
  required _NeedSummary needs,
  required SeatCell cell,
  required int occupantBerths,
}) {
  switch (cell.seatType) {
    case SeatType.seater:
      if (needs.seater) {
        return _Fit(
          rank: 0,
          reason:
              '${tr('swap_reason.exact_match')}: ${seatTypeLabel(SeatType.seater, null)}',
        );
      }
      return null;
    case SeatType.singleSofa:
      final pos = cell.position;
      // Exact: the mover wants a single on this exact deck.
      if ((pos == SeatPosition.upper && needs.singleUpper) ||
          (pos == SeatPosition.lower && needs.singleLower)) {
        return _Fit(
          rank: 0,
          reason:
              '${tr('swap_reason.exact_match')}: ${seatTypeLabel(SeatType.singleSofa, pos)}',
        );
      }
      // Same type, mover stated NO deck preference → either deck is a clean
      // type match.
      if (needs.singleAny) {
        return _Fit(
          rank: 1,
          reason:
              '${tr('swap_reason.type_match')}: ${seatTypeLabel(SeatType.singleSofa, null)}',
        );
      }
      // The mover specified the OPPOSITE deck. The engine treats deck as a
      // hard gate, so this is NOT a clean match — surface it as a distinct,
      // clearly-labelled different-deck option.
      if ((pos == SeatPosition.lower && needs.singleUpper) ||
          (pos == SeatPosition.upper && needs.singleLower)) {
        final wanted =
            needs.singleUpper ? SeatPosition.upper : SeatPosition.lower;
        return _Fit(
          rank: 2,
          reason: '${tr('swap_reason.different_deck')}: '
              '${seatTypeLabel(SeatType.singleSofa, pos)} '
              '(${tr('swap_reason.you_wanted')} ${wanted.displayName})',
        );
      }
      // Cross-fill: a single berth toward a Double Sofa need.
      if (needs.doubleUpper || needs.doubleLower || needs.doubleAny) {
        return _Fit(
          rank: 2,
          reason: tr('swap_reason.cross_fill_single'),
        );
      }
      return null;
    case SeatType.doubleSofa:
      final pos = cell.position;
      final holdsWholeDouble = occupantBerths >= 2;
      // A clean whole-double swap is only possible when the occupant actually
      // holds BOTH berths. A shared half-double (1 berth) cannot satisfy a
      // whole-double need by displacing this one occupant.
      if (holdsWholeDouble) {
        if ((pos == SeatPosition.upper && needs.doubleUpper) ||
            (pos == SeatPosition.lower && needs.doubleLower)) {
          return _Fit(
            rank: 0,
            reason:
                '${tr('swap_reason.exact_match')}: ${seatTypeLabel(SeatType.doubleSofa, pos)}',
          );
        }
        // Mover stated NO deck preference → either deck is a clean type match.
        if (needs.doubleAny) {
          return _Fit(
            rank: 1,
            reason:
                '${tr('swap_reason.type_match')}: ${seatTypeLabel(SeatType.doubleSofa, null)}',
          );
        }
        // Mover specified the OPPOSITE deck — deck is a hard gate, so this is a
        // distinct different-deck option, not a clean match.
        if ((pos == SeatPosition.lower && needs.doubleUpper) ||
            (pos == SeatPosition.upper && needs.doubleLower)) {
          final wanted =
              needs.doubleUpper ? SeatPosition.upper : SeatPosition.lower;
          return _Fit(
            rank: 2,
            reason: '${tr('swap_reason.different_deck')}: '
                '${seatTypeLabel(SeatType.doubleSofa, pos)} '
                '(${tr('swap_reason.you_wanted')} ${wanted.displayName})',
          );
        }
      } else if (needs.doubleUpper || needs.doubleLower || needs.doubleAny) {
        // Occupant holds only ONE berth of a shared double. Displacing them
        // frees a single berth toward a Double Sofa need — a cross-fill, NOT a
        // whole-double match. The cell's other berth must be freed too for a
        // full double.
        return _Fit(
          rank: 2,
          reason: tr('swap_reason.cross_fill_single_other'),
        );
      }
      // Cross-fill the other way: a single need can sit on one berth of a
      // double the occupant holds.
      if (needs.singleUpper ||
          needs.singleLower ||
          needs.singleAny) {
        return _Fit(
          rank: 2,
          reason: tr('swap_reason.cross_fill_half'),
        );
      }
      return null;
    case null:
      return null;
  }
}

/// Rank for a physically-valid swap that matches no request line. Sits below
/// every need-based match (ranks 0–2) so useful swaps surface first.
const int _kSwapOnlyRank = 5;

int _cap(SeatType? type) => type == SeatType.doubleSofa ? 2 : 1;

bool _isSleeper(SeatType? t) =>
    t == SeatType.singleSofa || t == SeatType.doubleSofa;

/// Same seat-CLASS gate — a sleeper berth and a seater chair never interchange
/// (mirrors the drag-drop engine's class gate).
bool _sameClass(SeatType? a, SeatType? b) =>
    (_isSleeper(a) && _isSleeper(b)) ||
    (a == SeatType.seater && b == SeatType.seater);

/// The mover's current holding on [busId]/[seatId], or null when it can't be
/// resolved on this bus (cross-bus move, or no seat supplied) — in which case
/// physical-swap reasoning is skipped and only need-based matches are offered.
_MoverHolding? _moverHoldingOn({
  required Passenger mover,
  required String busId,
  required String? seatId,
  required Map<String, SeatCell> cellById,
}) {
  if (seatId == null) return null;
  final cell = cellById[seatId];
  if (cell == null) return null;
  var berths = 0;
  for (final a in mover.assignedSeats) {
    if (a.busId == busId && a.seatId == seatId) berths++;
  }
  if (berths == 0) return null;
  return _MoverHolding(seatType: cell.seatType, berths: berths);
}

/// Whether the mover (given their current [holding]) could physically SWAP
/// with an occupant holding [candidateBerths] berths on [candidateCell]:
/// the two seats share a class AND each side's berth load fits the other's
/// cell capacity, so the swap never strands a whole-double on a single. Same
/// rule the drag-drop engine applies for a release-to-swap.
bool _physicallySwappable({
  required _MoverHolding? holding,
  required SeatCell candidateCell,
  required int candidateBerths,
}) {
  if (holding == null) return false;
  if (!_sameClass(holding.seatType, candidateCell.seatType)) return false;
  final moverCap = _cap(holding.seatType);
  final candidateCap = _cap(candidateCell.seatType);
  return holding.berths <= candidateCap && candidateBerths <= moverCap;
}

int _cellOrder(SeatCell a, SeatCell b) {
  if (a.row != b.row) return a.row.compareTo(b.row);
  if (a.col != b.col) return a.col.compareTo(b.col);
  final pa = _posRank(a.position);
  final pb = _posRank(b.position);
  if (pa != pb) return pa.compareTo(pb);
  return (a.seatId ?? '').compareTo(b.seatId ?? '');
}

int _posRank(SeatPosition? p) => switch (p) {
      SeatPosition.upper => 0,
      SeatPosition.lower => 1,
      null => 2,
    };

String _name(Passenger p) => p.name.isNotEmpty ? p.name : p.id;


class _OccupantRow {
  final Passenger passenger;
  final String seatId;
  final SeatCell cell;
  const _OccupantRow({
    required this.passenger,
    required this.seatId,
    required this.cell,
  });
}

class _Fit {
  final int rank;
  final String reason;
  const _Fit({required this.rank, required this.reason});
}

/// The mover's current seat CLASS plus how many berths they hold there — the
/// minimum needed to judge a physical swap against an occupant. Stored as the
/// bare [seatType] (not the full cell) so it can be built from a cross-bus
/// source seat the destination layout doesn't contain.
class _MoverHolding {
  final SeatType? seatType;
  final int berths;
  const _MoverHolding({required this.seatType, required this.berths});
}

/// Bucketed view of the mover's outstanding seat needs.
class _NeedSummary {
  final bool seater;
  final bool singleUpper;
  final bool singleLower;
  final bool singleAny;
  final bool doubleUpper;
  final bool doubleLower;
  final bool doubleAny;

  const _NeedSummary({
    required this.seater,
    required this.singleUpper,
    required this.singleLower,
    required this.singleAny,
    required this.doubleUpper,
    required this.doubleLower,
    required this.doubleAny,
  });

  bool get _wantsSingle => singleUpper || singleLower || singleAny;
  bool get _wantsDouble => doubleUpper || doubleLower || doubleAny;

  /// Whether a FREE [cell] can satisfy any mover need, given leg-aware
  /// availability for the MOVER's legs: [wholeFree] means the mover can take the
  /// cell's full capacity (both berths of a double), [anyFree] means at least one
  /// berth is takeable. These already account for leg-disjoint reuse — a one-way
  /// mover sees a leg whose opposite is occupied as free.
  bool acceptsFreeCell(
    SeatCell cell, {
    required bool wholeFree,
    required bool anyFree,
  }) {
    switch (cell.seatType) {
      case SeatType.seater:
        return seater && anyFree;
      case SeatType.singleSofa:
        if (!anyFree) return false;
        // A free single can serve a single need (any matching deck) or be a
        // cross-fill berth toward a double need.
        if (_wantsSingle) {
          final pos = cell.position;
          if (singleAny) return true;
          if (pos == SeatPosition.upper && singleUpper) return true;
          if (pos == SeatPosition.lower && singleLower) return true;
          // need has a deck preference that doesn't match this cell's deck:
          // only accept as cross-fill toward a double below.
        }
        return _wantsDouble; // cross-fill berth toward a Double Sofa line.
      case SeatType.doubleSofa:
        // A WHOLE-double need is served only when the mover can take BOTH berths
        // on its legs (leg-disjoint reuse already folded into [wholeFree]).
        if (wholeFree && _wantsDouble) {
          final pos = cell.position;
          if (doubleAny) return true;
          if (pos == SeatPosition.upper && doubleUpper) return true;
          if (pos == SeatPosition.lower && doubleLower) return true;
        }
        // A single berth of a double can host a single need (single-on-double)
        // as long as the mover has room for one berth on its legs.
        if (anyFree && _wantsSingle) return true;
        return false;
      case null:
        return false;
    }
  }
}
