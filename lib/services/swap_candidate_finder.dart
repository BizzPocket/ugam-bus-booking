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

part 'swap_candidate_finder_fit.dart';

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
}
