// Pure-Dart "swap assistant" brain for Ugam Booking.
//
// NO Flutter imports, NO I/O, no wall-clock time, no randomness. Given a
// passenger the agent wants to move onto a (possibly full) destination bus, it
// returns a [SwapAssist]: the free seats the mover could just take outright, the
// occupants who could actually be displaced (ranked best-fit first), and the
// occupants who are blocked from being displaced WITH a reason. The agent never
// has to hunt for who is movable — the brain hands them the short list.
//
// See docs/superpowers/specs/2026-06-03-smart-seat-assignment-design.md: groups
// stay on one bus and approved-priority passengers are protected, so neither can
// be silently bumped to make room.

import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';

/// One occupant of the destination bus the mover COULD displace (swap with).
class SwapCandidate {
  final String passengerId;
  final String passengerName;

  /// The seat (cell) this candidate holds on the destination bus that the
  /// mover could take. For a whole double sofa this is that double cell.
  final String seatId;

  /// 0 = best fit. Lower ranks first. Exact type match ranks above a merely
  /// cross-fill-compatible match.
  final int rank;

  /// One-line, human-readable rationale, e.g.
  /// "exact match: Double Sofa Lower" or
  /// "cross-fill: 2 single berths cover a Double Sofa".
  final String reason;

  const SwapCandidate({
    required this.passengerId,
    required this.passengerName,
    required this.seatId,
    required this.rank,
    required this.reason,
  });

  @override
  String toString() =>
      'SwapCandidate($passengerName @ $seatId rank=$rank — $reason)';
}

/// An occupant excluded from the movable list, with the reason why.
class BlockedOccupant {
  final String passengerId;
  final String passengerName;

  /// e.g. "in group Patel", "approved priority".
  final String reason;

  const BlockedOccupant({
    required this.passengerId,
    required this.passengerName,
    required this.reason,
  });

  @override
  String toString() => 'BlockedOccupant($passengerName — $reason)';
}

/// The full answer the agent gets when they want to move [mover] onto a bus.
class SwapAssist {
  /// Compatible FREE seats on the destination bus the mover could just take —
  /// no swap needed. seatIds, deterministically ordered.
  final List<String> freeSeatIds;

  /// Occupants who can actually be displaced, ranked best-fit first.
  final List<SwapCandidate> movable;

  /// Occupants who CANNOT be displaced (grouped / approved-priority), each with
  /// a reason. Deterministically ordered.
  final List<BlockedOccupant> blocked;

  const SwapAssist({
    required this.freeSeatIds,
    required this.movable,
    required this.blocked,
  });
}

/// Stateless swap-assistant. Single entry point is [find]. All ordering is by
/// stable keys (rank, then passengerId) so the same input always yields the
/// same answer.
class SwapCandidateFinder {
  const SwapCandidateFinder._();

  /// Compute the swap options for moving [mover] onto [destinationBus].
  ///
  /// [passengers] is the full passenger set (any tour). Only those currently
  /// holding a seat on [destinationBus] are considered as occupants; the mover
  /// itself is never listed as a candidate or blocked occupant.
  static SwapAssist find({
    required Passenger mover,
    required Bus destinationBus,
    required List<Passenger> passengers,
  }) {
    final layout = destinationBus.layout;
    if (layout == null) {
      return const SwapAssist(freeSeatIds: [], movable: [], blocked: []);
    }

    // ── Index the destination layout ─────────────────────────────────────
    final cellById = <String, SeatCell>{};
    for (final c in layout.grid) {
      final sid = c.seatId;
      if (sid != null && c.seatType != null) cellById[sid] = c;
    }

    // What the mover still needs to place (their full request lines). We work
    // off requestLines because that is what the mover wants on this bus.
    final needs = _needSummary(mover.requestLines);

    // ── Berth occupancy on the destination bus ───────────────────────────
    // seatId -> berths currently taken on that cell (1 for most; up to 2 for a
    // double sofa that is shared or wholly held). seatId -> set of occupant ids.
    final berthsTaken = <String, int>{};
    final occupantsBySeat = <String, Set<String>>{};
    for (final p in passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId != destinationBus.id) continue;
        if (!cellById.containsKey(a.seatId)) continue;
        berthsTaken[a.seatId] = (berthsTaken[a.seatId] ?? 0) + 1;
        (occupantsBySeat[a.seatId] ??= <String>{}).add(p.id);
      }
    }

    // ── (a) Free seats the mover could just take ─────────────────────────
    final freeSeatIds = _freeSeatsFor(
      needs: needs,
      cellById: cellById,
      berthsTaken: berthsTaken,
    );

    // ── (b)/(c) Walk occupants, split movable vs blocked ─────────────────
    // De-dupe: an occupant holding two berths on the same cell (whole double)
    // is considered once for that cell. We consider one candidate row per
    // (passenger, seatId) so a whole double surfaces a single swap target.
    final seenPassengerSeat = <String>{};
    final movable = <SwapCandidate>[];
    final blocked = <BlockedOccupant>[];
    final blockedSeen = <String>{};

    // How many berths each (passenger, seatId) pair holds — distinguishes a
    // WHOLE double (this passenger holds both berths) from a SHARED half-double
    // (this passenger holds one berth, someone else holds / could take the
    // other). Keyed "passengerId|seatId".
    final ownBerths = <String, int>{};
    for (final p in passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId != destinationBus.id) continue;
        if (!cellById.containsKey(a.seatId)) continue;
        final key = '${p.id}|${a.seatId}';
        ownBerths[key] = (ownBerths[key] ?? 0) + 1;
      }
    }

    // Stable order: by passengerId, then seatId.
    final occupantRows = <_OccupantRow>[];
    for (final p in passengers) {
      if (p.id == mover.id) continue;
      for (final a in p.assignedSeats) {
        if (a.busId != destinationBus.id) continue;
        final cell = cellById[a.seatId];
        if (cell == null) continue;
        final key = '${p.id}|${a.seatId}';
        if (!seenPassengerSeat.add(key)) continue;
        occupantRows.add(_OccupantRow(passenger: p, seatId: a.seatId, cell: cell));
      }
    }
    occupantRows.sort((x, y) {
      final byP = x.passenger.id.compareTo(y.passenger.id);
      if (byP != 0) return byP;
      return x.seatId.compareTo(y.seatId);
    });

    for (final row in occupantRows) {
      final p = row.passenger;
      // Blocked: grouped or approved-priority occupants cannot be displaced.
      final groupId = p.groupId;
      if (groupId != null && groupId.isNotEmpty) {
        if (blockedSeen.add(p.id)) {
          blocked.add(BlockedOccupant(
            passengerId: p.id,
            passengerName: _name(p),
            reason: 'in group $groupId',
          ));
        }
        continue;
      }
      if (p.isPriorityApproved) {
        if (blockedSeen.add(p.id)) {
          blocked.add(BlockedOccupant(
            passengerId: p.id,
            passengerName: _name(p),
            reason: 'approved priority',
          ));
        }
        continue;
      }

      // Movable only if their held seat-type can satisfy something the mover
      // needs (exact match, or cross-fill compatible). The occupant's own berth
      // count on this cell decides whether displacing them frees a WHOLE double
      // (both berths) or only one berth of a shared double.
      final occupantBerths = ownBerths['${p.id}|${row.seatId}'] ?? 1;
      final fit = _fitFor(
        needs: needs,
        cell: row.cell,
        occupantBerths: occupantBerths,
      );
      if (fit == null) continue;
      movable.add(SwapCandidate(
        passengerId: p.id,
        passengerName: _name(p),
        seatId: row.seatId,
        rank: fit.rank,
        reason: fit.reason,
      ));
    }

    // Deterministic ordering: by rank, then passengerId, then seatId.
    movable.sort((x, y) {
      if (x.rank != y.rank) return x.rank.compareTo(y.rank);
      final byP = x.passengerId.compareTo(y.passengerId);
      if (byP != 0) return byP;
      return x.seatId.compareTo(y.seatId);
    });
    blocked.sort((x, y) => x.passengerId.compareTo(y.passengerId));

    return SwapAssist(
      freeSeatIds: freeSeatIds,
      movable: movable,
      blocked: blocked,
    );
  }

  // ── Compatibility & ranking ───────────────────────────────────────────────

  /// Summary of what the mover needs, by seat type. Position-aware for sofas
  /// (a lower-double need can't be served by an upper-double exact match), but
  /// a null position need matches either deck.
  static _NeedSummary _needSummary(List<dynamic> requestLines) {
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
  /// row-major-then-seatId order. A double cell counts as free only when BOTH
  /// berths are free; otherwise its remaining berth is offered for a single/
  /// cross-fill need.
  static List<String> _freeSeatsFor({
    required _NeedSummary needs,
    required Map<String, SeatCell> cellById,
    required Map<String, int> berthsTaken,
  }) {
    final cells = cellById.values.toList()..sort(_cellOrder);
    final out = <String>[];
    for (final c in cells) {
      final cap = c.seatType == SeatType.doubleSofa ? 2 : 1;
      final free = cap - (berthsTaken[c.seatId] ?? 0);
      if (free <= 0) continue;
      if (needs.acceptsFreeCell(c, freeBerths: free)) {
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
  static _Fit? _fitFor({
    required _NeedSummary needs,
    required SeatCell cell,
    required int occupantBerths,
  }) {
    switch (cell.seatType) {
      case SeatType.seater:
        if (needs.seater) {
          return const _Fit(rank: 0, reason: 'exact match: Seater');
        }
        return null;
      case SeatType.singleSofa:
        final pos = cell.position;
        // Exact: the mover wants a single on this exact deck.
        if ((pos == SeatPosition.upper && needs.singleUpper) ||
            (pos == SeatPosition.lower && needs.singleLower)) {
          return _Fit(
            rank: 0,
            reason: 'exact match: ${seatTypeLabel(SeatType.singleSofa, pos)}',
          );
        }
        // Same type, mover stated NO deck preference → either deck is a clean
        // type match.
        if (needs.singleAny) {
          return const _Fit(rank: 1, reason: 'type match: Single Sofa');
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
            reason: 'different deck: ${seatTypeLabel(SeatType.singleSofa, pos)} '
                '(you wanted ${wanted.displayName})',
          );
        }
        // Cross-fill: a single berth toward a Double Sofa need.
        if (needs.doubleUpper || needs.doubleLower || needs.doubleAny) {
          return const _Fit(
            rank: 2,
            reason: 'cross-fill: a single berth toward a Double Sofa',
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
              reason: 'exact match: ${seatTypeLabel(SeatType.doubleSofa, pos)}',
            );
          }
          // Mover stated NO deck preference → either deck is a clean type match.
          if (needs.doubleAny) {
            return const _Fit(rank: 1, reason: 'type match: Double Sofa');
          }
          // Mover specified the OPPOSITE deck — deck is a hard gate, so this is a
          // distinct different-deck option, not a clean match.
          if ((pos == SeatPosition.lower && needs.doubleUpper) ||
              (pos == SeatPosition.upper && needs.doubleLower)) {
            final wanted =
                needs.doubleUpper ? SeatPosition.upper : SeatPosition.lower;
            return _Fit(
              rank: 2,
              reason:
                  'different deck: ${seatTypeLabel(SeatType.doubleSofa, pos)} '
                  '(you wanted ${wanted.displayName})',
            );
          }
        } else if (needs.doubleUpper || needs.doubleLower || needs.doubleAny) {
          // Occupant holds only ONE berth of a shared double. Displacing them
          // frees a single berth toward a Double Sofa need — a cross-fill, NOT a
          // whole-double match. The cell's other berth must be freed too for a
          // full double.
          return const _Fit(
            rank: 2,
            reason: 'cross-fill: a single berth toward a Double Sofa '
                '(other berth of this double must be freed too)',
          );
        }
        // Cross-fill the other way: a single need can sit on one berth of a
        // double the occupant holds.
        if (needs.singleUpper ||
            needs.singleLower ||
            needs.singleAny) {
          return const _Fit(
            rank: 2,
            reason: 'cross-fill: a single on half of a Double Sofa',
          );
        }
        return null;
      case null:
        return null;
    }
  }

  static int _cellOrder(SeatCell a, SeatCell b) {
    if (a.row != b.row) return a.row.compareTo(b.row);
    if (a.col != b.col) return a.col.compareTo(b.col);
    final pa = _posRank(a.position);
    final pb = _posRank(b.position);
    if (pa != pb) return pa.compareTo(pb);
    return (a.seatId ?? '').compareTo(b.seatId ?? '');
  }

  static int _posRank(SeatPosition? p) => switch (p) {
        SeatPosition.upper => 0,
        SeatPosition.lower => 1,
        null => 2,
      };

  static String _name(Passenger p) => p.name.isNotEmpty ? p.name : p.id;
}

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

  /// Whether a FREE [cell] (with [freeBerths] free) can satisfy any mover need.
  bool acceptsFreeCell(SeatCell cell, {required int freeBerths}) {
    switch (cell.seatType) {
      case SeatType.seater:
        return seater;
      case SeatType.singleSofa:
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
        // A WHOLE free double (both berths) serves a double need directly.
        if (freeBerths >= 2 && _wantsDouble) {
          final pos = cell.position;
          if (doubleAny) return true;
          if (pos == SeatPosition.upper && doubleUpper) return true;
          if (pos == SeatPosition.lower && doubleLower) return true;
        }
        // A single berth of a double can host a single need (single-on-double).
        if (freeBerths >= 1 && _wantsSingle) return true;
        return false;
      case null:
        return false;
    }
  }
}
