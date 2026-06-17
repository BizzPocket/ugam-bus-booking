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

  /// Swap the FULL contents of a paired Double Sofa with the full contents of
  /// another OCCUPIED double — two couples (or a couple and a solo whole-double
  /// holder) exchange sofas. Both seats are cap-2, so the exchange is always
  /// capacity- and leg-safe in either direction.
  swapPair,

  /// A paired Double Sofa dropped onto a SINGLE seat (free or single-occupant).
  /// The agent chooses WHICH sharer peels onto the single; the other keeps the
  /// double. Drives the screen's "which passenger moves?" picker.
  splitPairChoice,

  /// A paired Double Sofa MERGED into an already-occupied double whose existing
  /// occupants ride DISJOINT legs — e.g. two GO-only riders sit there and the
  /// incoming pair is two RET-only riders, so all four share one double across
  /// the trip (2 berths × 2 legs = 4 berth-legs). Both source sharers move onto
  /// the target double; the target's occupants stay put.
  fillPairInto,

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

  /// A paired source (or a 2-occupant non-double) has no legal home here — e.g.
  /// a pair dropped on a single already shared by two, or a leg-reused single
  /// lifted as a unit.
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
  factory SeatDropDecision.swapPair() =>
      const SeatDropDecision._(SeatDropAction.swapPair);
  factory SeatDropDecision.splitPairChoice() =>
      const SeatDropDecision._(SeatDropAction.splitPairChoice);
  factory SeatDropDecision.fillPairInto() =>
      const SeatDropDecision._(SeatDropAction.fillPairInto);
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
///
/// Decided per-CELL conservatively: a passenger who requested ANY double keeps
/// ALL their whole doubles intact, so a genuine double is never split even when
/// they also happen to hold a second (surplus) one. Only a passenger who
/// requested NO double at all — yet sits on a whole double — is parking singles
/// there and may peel a berth off.
bool _moverIsSubstituteDouble(SeatOccupant mover) =>
    mover.berthsHere >= 2 && mover.requestedDoubleQty == 0;

int _cap(SeatType? type) => type == SeatType.doubleSofa ? 2 : 1;

/// Whether an incoming [pair] (two 1-berth sharers) can MERGE onto a Double Sofa
/// already holding [existing] occupants without exceeding the cap-2 limit on
/// EITHER leg — i.e. the pair rides legs the existing occupants leave free. The
/// canonical fit is two GO-only riders already seated + a two-RET-only pair
/// incoming: GO 2/2, RET 2/2, all four share one double across the trip.
bool _pairFitsLegDisjoint(
  List<SeatOccupant> pair,
  List<SeatOccupant> existing,
) {
  int goOf(List<SeatOccupant> os) =>
      os.where((o) => o.trip.usesOutbound).fold(0, (s, o) => s + o.berthsHere);
  int retOf(List<SeatOccupant> os) =>
      os.where((o) => o.trip.usesReturn).fold(0, (s, o) => s + o.berthsHere);
  return goOf(existing) + goOf(pair) <= 2 && retOf(existing) + retOf(pair) <= 2;
}

/// Whether swapping the FULL contents of two seats is capacity-safe in BOTH
/// directions: each seat must absorb the OTHER's occupants without exceeding its
/// cap on either leg. Generalises the always-safe double↔double pair swap to
/// mixed sizes — e.g. relocating a single-sofa leg-share onto an occupied single
/// by exchanging occupants, which is leg-safe because each cap-1 seat ends up
/// with at most one rider per leg.
bool _contentsSwapLegSafe(
  DropCell from,
  DropCell target,
  List<SeatOccupant> fromOccupants,
  List<SeatOccupant> targetOccupants,
) {
  bool fits(List<SeatOccupant> incoming, int cap) {
    final go = incoming
        .where((o) => o.trip.usesOutbound)
        .fold(0, (s, o) => s + o.berthsHere);
    final ret = incoming
        .where((o) => o.trip.usesReturn)
        .fold(0, (s, o) => s + o.berthsHere);
    return go <= cap && ret <= cap;
  }

  return fits(fromOccupants, _cap(target.seatType)) &&
      fits(targetOccupants, _cap(from.seatType));
}

bool _isSleeper(SeatType? t) =>
    t == SeatType.singleSofa || t == SeatType.doubleSofa;

/// True when [occupants] is exactly a GO-only (outbound-only) + RET-only
/// (return-only) pair reusing ONE physical berth across disjoint legs — the
/// leg-share on a single sofa. Each holds a single berth on opposite legs, so
/// the pair can be lifted and relocated TOGETHER onto a free seat without ever
/// over-booking a leg. Used by both the drag-pickability gate and the engine so
/// the same definition drives "can lift" and "what the drop does".
bool isLegDisjointPair(List<SeatOccupant> occupants) {
  if (occupants.length != 2) return false;
  final a = occupants[0].trip;
  final b = occupants[1].trip;
  return (a == TripType.outboundOnly && b == TripType.returnOnly) ||
      (a == TripType.returnOnly && b == TripType.outboundOnly);
}

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
  // A reserved/held SOURCE seat can't be dragged off — the hold guards the
  // origin as well as the destination, so its occupant is never silently moved.
  if (fromCell.reserved) return SeatDropDecision.blocked(SeatDropBlock.held);

  // Seat-class gate: a sleeper berth and a seater chair never interchange.
  final srcSleeper = _isSleeper(fromCell.seatType);
  final tgtSleeper = _isSleeper(targetCell.seatType);
  final srcSeater = fromCell.seatType == SeatType.seater;
  final tgtSeater = targetCell.seatType == SeatType.seater;
  if ((srcSleeper && tgtSeater) || (srcSeater && tgtSleeper)) {
    return SeatDropDecision.blocked(SeatDropBlock.classMismatch);
  }

  // A reserved/held TARGET is off-limits no matter what sits on it — free,
  // occupied, single, or shared. Hoisted here so every downstream branch
  // (move / swap / fill / moveBoth / swapPair / splitPairChoice) is guarded
  // uniformly; the per-branch reserved checks below are now redundant.
  if (targetCell.reserved) return SeatDropDecision.blocked(SeatDropBlock.held);

  final tgtCap = _cap(targetCell.seatType);

  // ── SHARED SOURCE: a Double Sofa held by TWO occupants (a pair) ───────────
  if (fromOccupants.length >= 2) {
    // A cap-1 single reused across disjoint legs (one GO-only + one RET-only)
    // also surfaces two occupants. It is NOT a real double, so it can't fill /
    // swap / merge — but it CAN be lifted and relocated as a UNIT onto a fully
    // FREE compatible seat, carrying the whole GO+RET pairing across intact.
    // (The class gate above already rejected a seater target.)
    if (fromCell.seatType != SeatType.doubleSofa) {
      // Only a clean GO+RET leg-share lifts as a unit off a non-double seat.
      if (!isLegDisjointPair(fromOccupants)) {
        return SeatDropDecision.blocked(SeatDropBlock.sharedNeedsFreeDouble);
      }
      // Free target → relocate the whole GO+RET pairing intact.
      if (targetOccupants.isEmpty) return SeatDropDecision.moveBoth();
      // Occupied DOUBLE whose free legs still fit the pair → MERGE all of them
      // onto it (e.g. dropping onto the empty half of a half-filled double), the
      // same leg-disjoint share a double-sofa pair already gets.
      if (targetCell.seatType == SeatType.doubleSofa &&
          _pairFitsLegDisjoint(fromOccupants, targetOccupants)) {
        return SeatDropDecision.fillPairInto();
      }
      // Otherwise exchange the full contents when the swap is leg-safe in BOTH
      // directions — relocating the leg-share onto an occupied single, or onto a
      // double it can't merge into. This gives a single-sofa leg-share the same
      // "move/swap onto an occupied seat" reach as a double-sofa pair, so it is
      // never stranded just because no fully-free seat is left.
      if (_contentsSwapLegSafe(
          fromCell, targetCell, fromOccupants, targetOccupants)) {
        return SeatDropDecision.swapPair();
      }
      return SeatDropDecision.blocked(SeatDropBlock.sharedNeedsFreeDouble);
    }

    if (targetCell.seatType == SeatType.doubleSofa) {
      // Free double → move the whole pair across intact.
      if (targetOccupants.isEmpty) return SeatDropDecision.moveBoth();
      // Occupied double → if the incoming pair rides legs that are still FREE on
      // the target (e.g. two GO-only sit there and the pair is two RET-only),
      // MERGE all four onto the one double across the trip. Otherwise exchange
      // the full contents of the two sofas (the always-safe pair-for-pair swap).
      if (_pairFitsLegDisjoint(fromOccupants, targetOccupants)) {
        return SeatDropDecision.fillPairInto();
      }
      return SeatDropDecision.swapPair();
    }

    // Single target → the pair can't both sit here, but the agent may want to
    // peel ONE sharer onto it (the other keeps the double). Offer the choice
    // when the single holds at most one person; two occupants is too ambiguous.
    if (targetCell.seatType == SeatType.singleSofa &&
        targetOccupants.length < 2) {
      return SeatDropDecision.splitPairChoice();
    }

    return SeatDropDecision.blocked(SeatDropBlock.sharedNeedsFreeDouble);
  }

  // ── SINGLE SOURCE OCCUPANT ───────────────────────────────────────────────
  final mover = fromOccupants.first;
  final moverBerths = mover.berthsHere;

  // Free target.
  if (targetOccupants.isEmpty) {
    if (moverBerths <= tgtCap) return SeatDropDecision.move(moverBerths);
    // moverBerths (2) > tgtCap (1): a whole-double dropped onto a single.
    if (_moverIsSubstituteDouble(mover)) return SeatDropDecision.splitToSingle();
    return SeatDropDecision.blocked(SeatDropBlock.tooSmall);
  }

  // Target shared by two. A 1-berth mover may STILL fit if its leg is free —
  // e.g. dropping a GO-only rider onto a double whose two occupants are both
  // RET-only (the "4 berth-legs into one double" build step). Run the leg-aware
  // capacity over ALL target occupants before falling back to the ambiguity /
  // leg-room blocks. A multi-berth (whole-double) mover never shares, so it is
  // still ambiguous here.
  if (targetOccupants.length >= 2) {
    if (moverBerths == 1) {
      final room = seatHasLegRoom(
        activeTrip: mover.trip,
        need: 1,
        cap: tgtCap,
        occupants: [
          for (final o in targetOccupants) (trip: o.trip, berths: o.berthsHere),
        ],
      );
      if (room) return SeatDropDecision.fill();
      // A pure leg conflict — the mover's leg is full, not a size mismatch.
      return SeatDropDecision.blocked(SeatDropBlock.noLegRoom);
    }
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
    // No leg room on a cap-2 target where a fill was the intent (the free half
    // of a half-filled double is blocked by the mover's leg being full): report
    // the leg-specific reason rather than the tooSmall the swap fallback would
    // give. A cap-1 target was never shareable, so a full single legitimately
    // falls through to a swap below; and a genuine size mismatch (occupant holds
    // more berths than the source cell can take) likewise routes to tooSmall.
    final srcCapForFill = _cap(fromCell.seatType);
    if (tgtCap >= 2 && occBerthsHere <= srcCapForFill) {
      return SeatDropDecision.blocked(SeatDropBlock.noLegRoom);
    }
  }

  // SWAP — only when each side's berth load fits the other's cell, so we never
  // create a whole-double stranded on a single.
  final srcCap = _cap(fromCell.seatType);
  if (occBerthsHere > srcCap || moverBerths > tgtCap) {
    return SeatDropDecision.blocked(SeatDropBlock.tooSmall);
  }
  return SeatDropDecision.swap();
}
