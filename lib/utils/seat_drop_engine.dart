import '../models/seat_type.dart';
import '../models/trip_type.dart';
import 'seat_leg_capacity.dart';

/// Pure decision engine for the manual seat-assignment drag-and-drop grid.
///
/// One home for every "what should this drop DO?" rule. The screen feeds it the
/// source/target cells plus the occupants on each, and gets back a single
/// [SeatDropDecision]. The same call drives BOTH the live drop-target highlight
/// while dragging and the action taken on release, so what the agent SEES is
/// exactly what a drop will DO. No Flutter, no controller, no I/O — fully unit
/// testable.
///
/// The four "smart" behaviours layered on top of plain move/swap:
///   * SHARED SOURCE (a Double Sofa held by TWO people) is now pickable and
///     moves BOTH occupants together onto a fully-free double ([moveBoth]).
///   * Dropping a single onto a HALF-FILLED double FILLS the free berth (share)
///     when it fits per-leg, else falls back to a [swap] ([fill]).
///   * A SUBSTITUTE whole-double — two single requests that were seated on one
///     double because singles ran out — can be SPLIT: drop it onto a free single
///     to peel ONE berth off ([splitToSingle]).
///   * A GENUINE whole-double (the passenger actually requested a double) stays
///     a unit: double→double only, never split ([SeatDropBlock.tooSmall]).

/// What a released drag should do.
enum SeatDropAction {
  /// Move the sole occupant (all their berths on the cell) onto a free target.
  move,

  /// Peel ONE berth off a substitute whole-double onto a free single seat. The
  /// other berth stays on the source double (freeing that half for someone).
  splitToSingle,

  /// Swap the sole occupant with the sole occupant of the target.
  swap,

  /// Add the single-berth mover to the free half of a half-filled double
  /// (sharing). Caller confirms the pairing before committing.
  fill,

  /// Move BOTH occupants of a shared double together onto a fully-free double.
  moveBoth,

  /// Drop is illegal — see [SeatDropDecision.block] for why.
  blocked,
}

/// Why a drop was rejected — drives the toast the agent sees.
enum SeatDropBlock {
  /// Dropped on its own source seat — a no-op.
  self,

  /// Target is not a real seat (aisle / empty gap).
  neutral,

  /// Sleeper berth ↔ seater chair never interchange.
  classMismatch,

  /// A whole-double (genuine, or any 2-berth load) won't fit the smaller target.
  tooSmall,

  /// Target is a reserved / held seat.
  held,

  /// Target is already shared by two people — a one-finger swap is ambiguous.
  sharedTargetAmbiguous,

  /// A shared source can only land on a fully-FREE double.
  sharedNeedsFreeDouble,

  /// Per-leg capacity leaves no room to share/move here.
  noLegRoom,
}

/// One occupant of a seat, with everything the engine needs to reason about
/// them. [berthsHere] is how many berths they hold on the cell in question.
/// [wholeDoublesHeld] / [requestedDoubleQty] are used only for the MOVER, to
/// tell a substitute whole-double (splittable) from a genuine one.
typedef SeatOccupant = ({
  String passengerId,
  TripType trip,
  int berthsHere,
  int wholeDoublesHeld,
  int requestedDoubleQty,
});

/// The verdict for a drop.
class SeatDropDecision {
  final SeatDropAction action;

  /// Set only when [action] is [SeatDropAction.blocked].
  final SeatDropBlock? block;

  /// Berths the action moves from the source (1 for [splitToSingle]/[fill],
  /// the mover's full load for [move]). Unused for swap/moveBoth/blocked.
  final int berths;

  const SeatDropDecision._(this.action, {this.block, this.berths = 0});

  factory SeatDropDecision.move(int berths) =>
      SeatDropDecision._(SeatDropAction.move, berths: berths);
  factory SeatDropDecision.splitToSingle() =>
      const SeatDropDecision._(SeatDropAction.splitToSingle, berths: 1);
  factory SeatDropDecision.swap() =>
      const SeatDropDecision._(SeatDropAction.swap);
  factory SeatDropDecision.fill() =>
      const SeatDropDecision._(SeatDropAction.fill, berths: 1);
  factory SeatDropDecision.moveBoth() =>
      const SeatDropDecision._(SeatDropAction.moveBoth);
  factory SeatDropDecision.blocked(SeatDropBlock reason) =>
      SeatDropDecision._(SeatDropAction.blocked, block: reason);

  bool get isValid => action != SeatDropAction.blocked;
}

/// Minimal view of a grid cell the engine needs — decoupled from `SeatCell` so
/// it stays a pure model with no widget/layout dependency.
typedef DropCell = ({
  String? seatId,
  SeatType? seatType,
  bool reserved,
});

/// Whether a mover's 2-berth load on [fromCell] is a SUBSTITUTE double (two
/// single requests parked on a double because singles ran out) rather than a
/// genuine requested double. Only substitutes may be split onto singles.
bool _moverIsSubstituteDouble(SeatOccupant mover) =>
    mover.berthsHere >= 2 &&
    mover.wholeDoublesHeld > mover.requestedDoubleQty;

int _cap(SeatType? type) => type == SeatType.doubleSofa ? 2 : 1;

bool _isSleeper(SeatType? t) =>
    t == SeatType.singleSofa || t == SeatType.doubleSofa;

/// Decide what dropping the contents of [fromCell] onto [targetCell] should do.
///
/// [fromOccupants] are the occupants on the source cell (1 = a normal drag, 2 =
/// a shared double moving as a unit). [targetOccupants] are whoever already
/// holds the target cell (0 / 1 / 2).
SeatDropDecision decideSeatDrop({
  required DropCell fromCell,
  required DropCell targetCell,
  required List<SeatOccupant> fromOccupants,
  required List<SeatOccupant> targetOccupants,
}) {
  final targetSeatId = targetCell.seatId;
  if (targetSeatId == null) return SeatDropDecision.blocked(SeatDropBlock.neutral);
  if (targetSeatId == fromCell.seatId) {
    return SeatDropDecision.blocked(SeatDropBlock.self);
  }
  if (fromOccupants.isEmpty) {
    return SeatDropDecision.blocked(SeatDropBlock.neutral);
  }

  // Seat-class gate: a sleeper berth and a seater chair never interchange.
  final srcSleeper = _isSleeper(fromCell.seatType);
  final tgtSleeper = _isSleeper(targetCell.seatType);
  final srcSeater = fromCell.seatType == SeatType.seater;
  final tgtSeater = targetCell.seatType == SeatType.seater;
  if ((srcSleeper && tgtSeater) || (srcSeater && tgtSleeper)) {
    return SeatDropDecision.blocked(SeatDropBlock.classMismatch);
  }

  final tgtCap = _cap(targetCell.seatType);

  // ── SHARED SOURCE: two people on one sofa move together ──────────────────
  if (fromOccupants.length >= 2) {
    // The only legal home for a pair is a fully-free double with room on every
    // leg they travel. (They already coexisted on a cap-2 source, so an empty
    // cap-2 target always has room — the leg check is a belt-and-braces guard.)
    if (targetCell.seatType != SeatType.doubleSofa ||
        targetOccupants.isNotEmpty) {
      return SeatDropDecision.blocked(SeatDropBlock.sharedNeedsFreeDouble);
    }
    if (targetCell.reserved) return SeatDropDecision.blocked(SeatDropBlock.held);
    return SeatDropDecision.moveBoth();
  }

  // ── SINGLE SOURCE OCCUPANT ───────────────────────────────────────────────
  final mover = fromOccupants.first;
  final moverBerths = mover.berthsHere;

  // Free target.
  if (targetOccupants.isEmpty) {
    if (targetCell.reserved) return SeatDropDecision.blocked(SeatDropBlock.held);
    if (moverBerths <= tgtCap) return SeatDropDecision.move(moverBerths);
    // moverBerths (2) > tgtCap (1): a whole-double dropped onto a single.
    if (_moverIsSubstituteDouble(mover)) return SeatDropDecision.splitToSingle();
    return SeatDropDecision.blocked(SeatDropBlock.tooSmall);
  }

  // Target shared by two — ambiguous to swap into.
  if (targetOccupants.length >= 2) {
    return SeatDropDecision.blocked(SeatDropBlock.sharedTargetAmbiguous);
  }

  // Target held by exactly one person.
  final occ = targetOccupants.first;
  if (occ.passengerId == mover.passengerId) {
    return SeatDropDecision.blocked(SeatDropBlock.self);
  }

  final occBerthsHere = occ.berthsHere;

  // FILL: a single-berth mover slots in beside the occupant — sharing the free
  // half of a half-filled double, OR reusing a seat on the opposite (disjoint)
  // leg of a one-way occupant. Driven purely by the leg-aware capacity so a
  // one-way occupant who fills both berths on ONE leg still leaves the other
  // leg open. Falls back to a swap below when there is no leg room.
  if (moverBerths == 1) {
    final room = seatHasLegRoom(
      activeTrip: mover.trip,
      need: 1,
      cap: tgtCap,
      occupants: [(trip: occ.trip, berths: occBerthsHere)],
    );
    if (room) return SeatDropDecision.fill();
  }

  // SWAP — only when each side's berth load fits the other's cell, so we never
  // create a whole-double stranded on a single.
  final srcCap = _cap(fromCell.seatType);
  if (occBerthsHere > srcCap || moverBerths > tgtCap) {
    return SeatDropDecision.blocked(SeatDropBlock.tooSmall);
  }
  return SeatDropDecision.swap();
}
