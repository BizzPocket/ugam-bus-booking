/// Shared, pure source of truth for "what's still pending for a passenger" and
/// "how many berths can they take on this cell".
///
/// This consolidates the algorithm that was triplicated across the auto seating
/// engine (`_buildPendingLines` / `_drain` / `_drainDoubleCrossFill`), the
/// manual seat-assignment screen (`_pendingLines` / `_drainPending` /
/// `_berthsForFreeCell`), and the leg-aware pieces in [seatHasLegRoom].
///
/// It is PURE (no Flutter, no engine state). Two design choices keep it a true
/// single source of truth while preserving the engine's existing behaviour:
///
///   * The own-cell double-completion case (a passenger holding ONE berth of a
///     Double Sofa whose partner berth is still free, plus a matching pending
///     `doubleSofa` line) is the case the manual screen historically MISSED.
///     The engine satisfies it by MUTATING its private plan state
///     (`tryClaimPartnerBerth` + `assign`). Because this module cannot mutate
///     either caller's world, it instead RETURNS a side-effect-free description
///     of each completion as a [PendingClaim] and asks the caller — via the
///     [canClaimPartnerBerth] callback — whether the partner berth is actually
///     claimable. The engine answers leg-aware against its plan state; the
///     manual screen answers via a [seatHasLegRoom] check. The algorithm /
///     phase ORDER is identical for both.
///
///   * Cell type/position lookup is supplied by [SeatFitContext] so the module
///     never needs to know how either caller stores its layout.
library;

import '../models/seat_type.dart';
import '../models/trip_type.dart';
import 'seat_leg_capacity.dart';

/// Pure read-only adapter to look up a cell's type + position from
/// (busId, seatId). Holds NO leg/capacity state. The engine builds it from its
/// plan state; the manual screen builds it from the tour layout.
class SeatFitContext {
  final SeatType? Function(String busId, String seatId) cellTypeAt;
  final SeatPosition? Function(String busId, String seatId) cellPositionAt;

  const SeatFitContext({
    required this.cellTypeAt,
    required this.cellPositionAt,
  });
}

/// One of a passenger's request lines (decoupled from the Passenger model).
class PendingLineInput {
  final SeatType seatType;
  final SeatPosition? position;
  final int qty;

  const PendingLineInput({
    required this.seatType,
    this.position,
    required this.qty,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingLineInput &&
          other.seatType == seatType &&
          other.position == position &&
          other.qty == qty;

  @override
  int get hashCode => Object.hash(seatType, position, qty);

  @override
  String toString() =>
      'PendingLineInput($seatType, $position, qty: $qty)';
}

/// ONE already-held berth for the subject passenger (locked or just-assigned).
/// The module groups these by `<busId>:<seatId>` to know whole-vs-half double.
class HeldBerth {
  final String busId;
  final String seatId;

  const HeldBerth({required this.busId, required this.seatId});
}

/// A side-effect-free DESCRIPTION of an own-cell double completion the algorithm
/// decided on. The module never mutates anything; the caller replays this in
/// its own world (engine: tryClaimPartnerBerth + assign; manual: nothing to
/// mutate — the claim has already drained the pending math).
class PendingClaim {
  final String busId;
  final String seatId;

  const PendingClaim({required this.busId, required this.seatId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingClaim && other.busId == busId && other.seatId == seatId;

  @override
  int get hashCode => Object.hash(busId, seatId);

  @override
  String toString() => 'PendingClaim($busId:$seatId)';
}

/// Output of [computePendingLines]: the still-unsatisfied request lines
/// (`qty > 0`) AND the own-cell completions the caller should apply.
class PendingResult {
  final List<PendingLineInput> remaining;
  final List<PendingClaim> ownCellClaims;

  const PendingResult({
    required this.remaining,
    required this.ownCellClaims,
  });
}

/// Mutable working copy of a pending line used internally while draining.
class _Line {
  final SeatType seatType;
  final SeatPosition? position;
  int remaining;

  _Line(this.seatType, this.position, this.remaining);
}

class _CellGroup {
  final String busId;
  final String seatId;
  int berths = 0;
  _CellGroup(this.busId, this.seatId);
}

/// THE single drainer. Seeds pending from [requestLines], groups [heldBerths] by
/// physical cell, then runs the EXACT phase order of the auto engine:
///
///   1. singleSofa held berth → drain one singleSofa line (position-matched),
///      else bucket a leftover single.
///   2. seater held berth → drain one seater line (position-matched).
///   3. doubleSofa WHOLE (2+ held on the cell) → drain one doubleSofa line
///      (position-matched), else drain two singleSofa lines.
///   3B. doubleSofa HALF (1 held on the cell) → try own-cell completion:
///       drain a doubleSofa line via cross-fill (position-ignored) AND ask
///       [canClaimPartnerBerth]; on success emit a [PendingClaim]; else drain a
///       singleSofa line; else bucket a leftover single.
///   4. cross-fill: pairs of leftover singles each drain ONE doubleSofa line
///      (position-ignored).
///
/// Pure: never mutates its arguments.
PendingResult computePendingLines({
  required List<PendingLineInput> requestLines,
  required List<HeldBerth> heldBerths,
  required SeatFitContext ctx,
  required bool Function(PendingClaim claim) canClaimPartnerBerth,
}) {
  final pending = [
    for (final l in requestLines) _Line(l.seatType, l.position, l.qty),
  ];

  // Group held berths by physical cell (preserve insertion order).
  final groups = <String, _CellGroup>{};
  for (final h in heldBerths) {
    final key = '${h.busId}:${h.seatId}';
    groups.putIfAbsent(key, () => _CellGroup(h.busId, h.seatId)).berths++;
  }

  final claims = <PendingClaim>[];
  var leftoverSingleBerths = 0;

  for (final g in groups.values) {
    final cellType = ctx.cellTypeAt(g.busId, g.seatId);
    if (cellType == null) continue;
    final cellPos = ctx.cellPositionAt(g.busId, g.seatId);

    switch (cellType) {
      case SeatType.singleSofa:
        for (var i = 0; i < g.berths; i++) {
          if (!_drain(pending, [SeatType.singleSofa], cellPos)) {
            leftoverSingleBerths++;
          }
        }
        break;
      case SeatType.seater:
        for (var i = 0; i < g.berths; i++) {
          _drain(pending, [SeatType.seater], cellPos);
        }
        break;
      case SeatType.doubleSofa:
        if (g.berths >= 2) {
          if (!_drain(pending, [SeatType.doubleSofa], cellPos)) {
            _drain(pending, [SeatType.singleSofa], cellPos);
            _drain(pending, [SeatType.singleSofa], cellPos);
          }
        } else {
          // ONE held berth on a double cell. First try to complete this
          // passenger's OWN double cell: if a matching pending doubleSofa line
          // exists and the cell's partner berth is still claimable, claim it
          // here (no stranded berth, no reallocation elsewhere). The double
          // line's position only gates which WHOLE double you claim, so a
          // position-agnostic cross-fill match is correct for completing an
          // already-held cell. Otherwise fall back to draining a single line,
          // else bucket as a leftover single.
          //
          // ORDER MATTERS: mirror the engine exactly. The engine decrements the
          // doubleSofa line FIRST, then checks tryClaimPartnerBerth; on success
          // it keeps the decrement and assigns. We replicate: tentatively drain
          // the double line, ask the caller; if the caller refuses, restore the
          // decrement and fall through to the single-line drain.
          final idx = pending.indexWhere(
            (l) => l.seatType == SeatType.doubleSofa && l.remaining > 0,
          );
          var completed = false;
          if (idx >= 0) {
            pending[idx].remaining -= 1;
            final claim = PendingClaim(busId: g.busId, seatId: g.seatId);
            if (canClaimPartnerBerth(claim)) {
              claims.add(claim);
              completed = true;
            } else {
              // Restore: the partner berth could not be claimed.
              pending[idx].remaining += 1;
            }
          }
          if (!completed) {
            if (!_drain(pending, [SeatType.singleSofa], cellPos)) {
              leftoverSingleBerths++;
            }
          }
        }
        break;
    }
  }

  // Cross-fill: 2 leftover single berths drain ONE doubleSofa line. Position is
  // irrelevant (two singles make a Double Sofa regardless of upper/lower).
  var pairs = leftoverSingleBerths ~/ 2;
  while (pairs > 0 && _drainDoubleCrossFill(pending)) {
    pairs--;
  }

  return PendingResult(
    remaining: [
      for (final l in pending)
        if (l.remaining > 0)
          PendingLineInput(
            seatType: l.seatType,
            position: l.position,
            qty: l.remaining,
          ),
    ],
    ownCellClaims: claims,
  );
}

/// Given the drained [remaining] lines from [computePendingLines], return how
/// many berths the passenger may claim on a (free OR occupied) cell.
///
/// Implements the engine's type/position matching matrix:
///   * doubleSofa cell: a matching doubleSofa line → 2 berths; otherwise
///     position-matched singleSofa lines cross-fill (2 → 2 berths, 1 → 1);
///   * singleSofa cell: a position-matched singleSofa line → 1 berth; otherwise
///     a (position-agnostic) doubleSofa line lets a single sit on half a double
///     → 1 berth;
///   * seater cell: a position-matched seater line → 1 berth.
///
/// The result is THEN gated through [seatHasLegRoom] with [activeTrip], [cap]
/// and [occupants]. For a genuinely free cell [occupants] is empty (the leg
/// check is trivially satisfied); for an occupied cell the caller passes the
/// real holders. This unifies the free-cell and occupied-cell paths into ONE
/// rule and closes the asymmetry where free cells skipped the leg check.
int berthsForFreeCell({
  required List<PendingLineInput> remaining,
  required SeatType cellType,
  required SeatPosition? cellPosition,
  required TripType activeTrip,
  required int cap,
  required List<SeatLegHolder> occupants,
}) {
  bool positionOk(PendingLineInput l) =>
      l.position == null || l.position == cellPosition;

  final need = _typeMatchBerths(remaining, cellType, cellPosition, positionOk);
  if (need == 0) return 0;

  final ok = seatHasLegRoom(
    activeTrip: activeTrip,
    need: need,
    cap: cap,
    occupants: occupants,
  );
  return ok ? need : 0;
}

/// Pure type/position matching matrix (no leg awareness). Mirrors the manual
/// screen's `_berthsForFreeCell` body, but with the position bug fixed: a
/// singleSofa cell only cross-fills a doubleSofa line when its position permits
/// (position-agnostic doubleSofa lines, which is what the engine's cross-fill
/// uses, always match).
int _typeMatchBerths(
  List<PendingLineInput> remaining,
  SeatType cellType,
  SeatPosition? cellPosition,
  bool Function(PendingLineInput) positionOk,
) {
  switch (cellType) {
    case SeatType.doubleSofa:
      final hasDoubleLine = remaining.any(
        (l) =>
            l.seatType == SeatType.doubleSofa && positionOk(l) && l.qty > 0,
      );
      if (hasDoubleLine) return 2;
      final singleRemaining = remaining
          .where(
            (l) =>
                l.seatType == SeatType.singleSofa &&
                positionOk(l) &&
                l.qty > 0,
          )
          .fold<int>(0, (sum, l) => sum + l.qty);
      if (singleRemaining >= 2) return 2;
      if (singleRemaining == 1) return 1;
      return 0;
    case SeatType.singleSofa:
      final hasSingleLine = remaining.any(
        (l) =>
            l.seatType == SeatType.singleSofa && positionOk(l) && l.qty > 0,
      );
      if (hasSingleLine) return 1;
      // A single may sit on half a double. The double line's position tags the
      // WHOLE double cell it would otherwise claim, not which single berths may
      // substitute — so this match is position-agnostic, exactly as the engine
      // treats cross-fill.
      final hasDoubleLine = remaining.any(
        (l) => l.seatType == SeatType.doubleSofa && l.qty > 0,
      );
      if (hasDoubleLine) return 1;
      return 0;
    case SeatType.seater:
      final hasMatch = remaining.any(
        (l) => l.seatType == SeatType.seater && positionOk(l) && l.qty > 0,
      );
      return hasMatch ? 1 : 0;
  }
}

/// Decrement the first pending line whose `seatType` ∈ [tryTypes] (checked in
/// order) AND whose position matches [cellPos] (null line position matches any).
/// Stable by index. Returns true when something was decremented.
bool _drain(List<_Line> pending, List<SeatType> tryTypes, SeatPosition? cellPos) {
  for (final t in tryTypes) {
    final idx = pending.indexWhere(
      (l) =>
          l.seatType == t &&
          (l.position == null || l.position == cellPos) &&
          l.remaining > 0,
    );
    if (idx >= 0) {
      pending[idx].remaining -= 1;
      return true;
    }
  }
  return false;
}

/// Drain ONE pending doubleSofa line via cross-fill, IGNORING its position.
bool _drainDoubleCrossFill(List<_Line> pending) {
  final idx = pending.indexWhere(
    (l) => l.seatType == SeatType.doubleSofa && l.remaining > 0,
  );
  if (idx < 0) return false;
  pending[idx].remaining -= 1;
  return true;
}
