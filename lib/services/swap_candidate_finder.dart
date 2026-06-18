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

import 'package:easy_localization/easy_localization.dart';

import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import '../utils/seat_leg_capacity.dart';

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
  ///
  /// [sourceBusId] is the bus the mover currently sits on. When provided this is
  /// a deliberate MANUAL move by the agent, so protection relaxes:
  ///   * approved-priority occupants become displaceable (manual change is
  ///     always allowed — the priority lock only guards the AUTO engine);
  ///   * grouped occupants become displaceable when the move is SAME-bus
  ///     (`sourceBusId == destinationBus.id`) — everyone stays on this bus so the
  ///     group is never split. A CROSS-bus move still blocks grouped occupants
  ///     (the whole group must move together via the cascade path).
  /// When [sourceBusId] is null the legacy rule holds: grouped AND approved-
  /// priority occupants are both blocked.
  static SwapAssist find({
    required Passenger mover,
    required Bus destinationBus,
    required List<Passenger> passengers,
    String? sourceBusId,
    String? moverFromSeatId,
    SeatType? moverFromSeatType,
    int? moverFromBerths,
  }) {
    final sameBus = sourceBusId != null && sourceBusId == destinationBus.id;
    final manual = sourceBusId != null;
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

    // ── Mover's CURRENT holding on this bus (for physical-swap reasoning) ──
    // When [moverFromSeatId] is supplied and resolves on THIS bus, we know the
    // exact seat the mover sits on and how many berths they hold there. That
    // lets a candidate be offered on physical swap feasibility (same seat-class
    // + berth counts fit both ways — the same rule the drag-drop engine uses),
    // independent of whether the mover still has an outstanding request line. A
    // seated passenger whose request is already satisfied can then still swap
    // with any compatible allocated seat.
    //
    // For a CROSS-bus move the mover doesn't sit on THIS bus, so [moverFromSeatId]
    // can't resolve here. The caller instead passes the mover's source-seat CLASS
    // + berth count directly ([moverFromSeatType] / [moverFromBerths]) — all the
    // physical-swap rule needs — so a seated passenger can swap onto ANOTHER bus's
    // compatible allocated seat too. Absent both, need-based candidacy only.
    final _MoverHolding? moverHolding =
        (moverFromSeatType != null && (moverFromBerths ?? 0) > 0)
        ? _MoverHolding(seatType: moverFromSeatType, berths: moverFromBerths!)
        : _moverHoldingOn(
            mover: mover,
            busId: destinationBus.id,
            seatId: moverFromSeatId,
            cellById: cellById,
          );

    // What the mover still needs to place (their full request lines). We work
    // off requestLines because that is what the mover wants on this bus.
    final needs = _needSummary(mover.requestLines);

    // ── Berth occupancy on the destination bus, tracked PER LEG ──────────
    // The finder must mirror seatHasLegRoom: a one-way occupant fills only its
    // own leg, leaving the opposite leg free for a leg-disjoint rider on the
    // SAME physical seat. So instead of a flat berth count we record, per seat,
    // the (tripType, berths) of every occupant berth — then judge availability
    // for the MOVER's specific legs via [seatHasLegRoom].
    //
    // seatId -> list of (trip, berths-on-this-berth-entry). Each assignment row
    // is one berth held by that occupant on that leg-set.
    final legHoldersBySeat = <String, List<SeatLegHolder>>{};
    for (final p in passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId != destinationBus.id) continue;
        if (!cellById.containsKey(a.seatId)) continue;
        (legHoldersBySeat[a.seatId] ??= <SeatLegHolder>[])
            .add((trip: p.tripType, berths: 1));
      }
    }

    // ── (a) Free seats the mover could just take ─────────────────────────
    // Availability is judged from the MOVER's legs: a GO-only mover only needs
    // GO room, so a seat whose RET leg is taken (but GO free) is still takeable.
    final freeSeatIds = _freeSeatsFor(
      needs: needs,
      moverTrip: mover.tripType,
      cellById: cellById,
      legHoldersBySeat: legHoldersBySeat,
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
      // Blocked: a grouped occupant can't be split off cross-bus (the whole
      // group must move together); a SAME-bus manual rearrangement leaves the
      // group whole, so it's allowed. An approved-priority occupant is blocked
      // only for the AUTO engine (sourceBusId == null) — a deliberate manual
      // move always allows displacing them.
      final groupId = p.groupId;
      if (groupId != null && groupId.isNotEmpty && !sameBus) {
        if (blockedSeen.add(p.id)) {
          blocked.add(BlockedOccupant(
            passengerId: p.id,
            passengerName: _name(p),
            reason: 'in group $groupId',
          ));
        }
        continue;
      }
      if (p.isPriorityApproved && !manual) {
        if (blockedSeen.add(p.id)) {
          blocked.add(BlockedOccupant(
            passengerId: p.id,
            passengerName: _name(p),
            reason: 'approved priority',
          ));
        }
        continue;
      }

      // A candidate's held seat-type may satisfy a mover NEED (exact / type /
      // cross-fill — ranked and labelled by [_fitFor]). The occupant's own berth
      // count on this cell decides whether displacing them frees a WHOLE double
      // (both berths) or only one berth of a shared double.
      final occupantBerths = ownBerths['${p.id}|${row.seatId}'] ?? 1;
      final fit = _fitFor(
        needs: needs,
        cell: row.cell,
        occupantBerths: occupantBerths,
      );
      if (fit != null) {
        // A need match must STILL be a physically valid exchange when we know
        // where the mover sits: displacing this occupant must not strand their
        // berths on a seat too small for them — e.g. a single-seated mover that
        // "matches" a WHOLE-double occupant would, on swap, cram two berths onto
        // their single (an over-booked cell). Mirror the drag engine's capacity
        // gate. With no known holding (cross-bus) we can't check here; the
        // controller's swapSeats enforces the capacity guard as the backstop.
        final physicallyOk = moverHolding == null ||
            _physicallySwappable(
              holding: moverHolding,
              candidateCell: row.cell,
              candidateBerths: occupantBerths,
            );
        if (physicallyOk) {
          movable.add(SwapCandidate(
            passengerId: p.id,
            passengerName: _name(p),
            seatId: row.seatId,
            rank: fit.rank,
            reason: fit.reason,
          ));
        }
        continue;
      }
      // No request match — but a SEATED mover can still swap on physical
      // feasibility: same seat-class and berth loads that fit both seats. This
      // is what lets the agent swap with any compatible allocated seat even when
      // their own request is already satisfied. Ranks below every need match.
      if (_physicallySwappable(
        holding: moverHolding,
        candidateCell: row.cell,
        candidateBerths: occupantBerths,
      )) {
        movable.add(SwapCandidate(
          passengerId: p.id,
          passengerName: _name(p),
          seatId: row.seatId,
          rank: _kSwapOnlyRank,
          reason:
              '${tr('swap_reason.swap_seats')}: ${seatTypeLabel(row.cell.seatType!, row.cell.position)}',
        ));
      }
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
  /// row-major-then-seatId order.
  ///
  /// Availability is judged PER LEG from the MOVER's perspective via
  /// [seatHasLegRoom]: a one-way mover only needs room on its own leg, so a
  /// Double Sofa whose OTHER leg is occupied (e.g. a RET berth held by a RET-only
  /// rider) is still a clean whole-double take for a GO-only mover — leg-disjoint
  /// reuse of the same physical seat. A round-trip mover still needs BOTH legs
  /// free on the berths it takes.
  static List<String> _freeSeatsFor({
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
  static _Fit? _fitFor({
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
  static const int _kSwapOnlyRank = 5;

  static int _cap(SeatType? type) => type == SeatType.doubleSofa ? 2 : 1;

  static bool _isSleeper(SeatType? t) =>
      t == SeatType.singleSofa || t == SeatType.doubleSofa;

  /// Same seat-CLASS gate — a sleeper berth and a seater chair never interchange
  /// (mirrors the drag-drop engine's class gate).
  static bool _sameClass(SeatType? a, SeatType? b) =>
      (_isSleeper(a) && _isSleeper(b)) ||
      (a == SeatType.seater && b == SeatType.seater);

  /// The mover's current holding on [busId]/[seatId], or null when it can't be
  /// resolved on this bus (cross-bus move, or no seat supplied) — in which case
  /// physical-swap reasoning is skipped and only need-based matches are offered.
  static _MoverHolding? _moverHoldingOn({
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
  static bool _physicallySwappable({
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
