// Pure-Dart group-cascade planner for Ugam Booking.
//
// NO Flutter imports, NO I/O, no wall-clock time, no randomness. When the agent
// moves one member of a cross-booking group, the WHOLE group has to move with
// them (hard rule: a group sits together on ONE bus). This planner answers two
// questions deterministically:
//   1. WHICH passengers must move together (the mover plus every group sibling).
//   2. WHETHER the destination bus can actually hold the whole group's requests
//      (capacity + seat-type compatibility, including cross-fill), and if not,
//      a plain-language reason the agent can read.
//
// An ungrouped mover (groupId == null/empty) is a group of one: it "fits" when
// the destination bus can hold that single passenger's own request lines.
//
// The fit decision is delegated to [SeatingEngine.propose] run against a
// single-bus snapshot, so it mirrors EXACTLY what the engine/applier would do
// when the move is actually applied — including the cross-fill rule (two single
// berths satisfy one Double Sofa line) and the deck-flexibility of a whole
// double (an opposite-deck whole double can serve a deck-specific double need).
// A parallel hand-rolled capacity model would inevitably diverge from the
// engine; mirroring the engine keeps "fits?" and "apply" in lock-step.
//
// See docs/superpowers/specs/2026-06-03-smart-seat-assignment-design.md.

import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import 'seating_engine.dart';

/// The cascade outcome for moving [mover] (and any group siblings) onto a bus.
class GroupMovePlan {
  /// Every passenger that must move together, INCLUDING the mover.
  /// Deterministically ordered (by passengerId).
  final List<String> memberPassengerIds;

  /// True when the destination bus has the free capacity AND seat types for the
  /// whole group's outstanding requests.
  final bool destinationFits;

  /// Null when [destinationFits]; otherwise a one-line reason it does not fit.
  final String? blockedReason;

  const GroupMovePlan({
    required this.memberPassengerIds,
    required this.destinationFits,
    this.blockedReason,
  });
}

/// Stateless group-cascade planner. Single entry point is [planMove].
class GroupCascade {
  const GroupCascade._();

  /// Plan the cascade move of [mover] (and its group) onto [destinationBus].
  ///
  /// Capacity is checked against the bus's CURRENTLY-FREE berths: a berth is
  /// free unless some passenger (other than a moving group member) already
  /// holds it. Moving members release their current seats on the destination
  /// bus, so those berths are counted as available to the group.
  static GroupMovePlan planMove({
    required Passenger mover,
    required Bus destinationBus,
    required List<Passenger> passengers,
  }) {
    // ── Resolve the group ────────────────────────────────────────────────
    final gid = mover.groupId;
    final List<Passenger> members;
    if (gid != null && gid.isNotEmpty) {
      members = passengers
          .where((p) => p.groupId == gid)
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      // The mover should always be part of its own group; guard against a
      // mover that isn't in the passenger list.
      if (!members.any((p) => p.id == mover.id)) {
        members.add(mover);
        members.sort((a, b) => a.id.compareTo(b.id));
      }
    } else {
      members = [mover];
    }
    final memberIds = members.map((p) => p.id).toList();
    final memberIdSet = memberIds.toSet();

    final layout = destinationBus.layout;
    if (layout == null) {
      return GroupMovePlan(
        memberPassengerIds: memberIds,
        destinationFits: false,
        blockedReason:
            '${destinationBus.name} has no seat layout, so it cannot hold the '
            'group.',
      );
    }

    // Cells the destination bus actually has (skip empty / aisle cells).
    final cellById = <String, SeatCell>{};
    for (final c in layout.grid) {
      final sid = c.seatId;
      if (sid != null && c.seatType != null) cellById[sid] = c;
    }

    // ── Build the trial passenger set for a single-bus snapshot ───────────
    // Group members: stripped of their current seat assignments so the engine
    // freely (re)places their request lines on the destination bus — this is
    // exactly what "moving members vacate their seats" means. We keep their
    // groupId so the engine's all-or-nothing group rule applies, and their
    // priority so front-seat semantics match the real apply.
    final trial = <Passenger>[
      for (final m in members)
        m.copyWith(assignedSeats: const <SeatAssignment>[]),
    ];

    // Berths taken by NON-moving passengers on the destination bus.
    final berthsTakenByOthers = <String, int>{};
    var occIdx = 0;
    for (final p in passengers) {
      if (memberIdSet.contains(p.id)) continue;
      final held = <SeatAssignment>[];
      for (final a in p.assignedSeats) {
        if (a.busId != destinationBus.id) continue;
        if (!cellById.containsKey(a.seatId)) continue;
        held.add(SeatAssignment(
          busId: destinationBus.id,
          seatId: a.seatId,
          locked: true,
        ));
        berthsTakenByOthers[a.seatId] =
            (berthsTakenByOthers[a.seatId] ?? 0) + 1;
      }
      if (held.isEmpty) continue;
      // Non-member occupants of the destination bus: seed their berths as LOCKED
      // synthetic passengers (no request lines) so the engine treats those exact
      // berths as taken. Locked seeding is per-berth, so a SHARED half-double
      // (one berth held) correctly leaves only the other berth free — something a
      // cell-level `reserved` flag could not express.
      trial.add(Passenger(
        id: '__occ_${occIdx++}__${p.id}',
        tourId: mover.tourId,
        name: '__occupant__',
        phone: '',
        requestLines: const [],
        assignedSeats: held,
      ));
    }

    // ── Mirror the engine: does the whole group fully place on THIS bus? ──
    final plan = SeatingEngine.propose(
      buses: [destinationBus],
      passengers: trial,
    );

    // The engine's verdict is authoritative. Group placement is all-or-nothing
    // (the engine commits NOTHING and raises groupWontFit when a group can't
    // fully fit), so a CAPACITY/TYPE exception about any member or the group
    // means "no fit". A priorityNoFrontSeat exception does NOT block the move —
    // the passenger WAS seated, just not on a front sofa, which is still a fit.
    final exceptionsForGroup = plan.exceptions.where((e) {
      if (e.type == SeatingExceptionType.priorityNoFrontSeat) return false;
      return (e.passengerId != null && memberIdSet.contains(e.passengerId)) ||
          (gid != null && gid.isNotEmpty && e.groupId == gid);
    });

    var anyShort = exceptionsForGroup.isNotEmpty;
    for (final m in members) {
      final needed = m.requestLines.fold<int>(
          0, (s, l) => s + l.qty * _berthsPerUnit(l.seatType));
      final placed = plan.forPassenger(m.id).length;
      if (placed < needed) anyShort = true;
    }

    if (!anyShort) {
      return GroupMovePlan(
        memberPassengerIds: memberIds,
        destinationFits: true,
      );
    }

    // ── Build a plain-language shortfall, by seat type ────────────────────
    // The engine commits nothing on an all-or-nothing group failure, so we can
    // not read the gap off proposed assignments. Instead derive it from FREE
    // capacity vs need, folding cross-fill exactly as the engine does (two free
    // single-capable berths satisfy one Double Sofa line; a whole double on
    // either deck satisfies any double need). This keeps the human message in
    // step with the engine-authoritative fit verdict.
    final shortfallText = 'short ${_shortfallText(
      members: members,
      cellById: cellById,
      berthsTakenByOthers: berthsTakenByOthers,
    )}';

    final label = (gid != null && gid.isNotEmpty)
        ? 'Group $gid (${members.length} bookings)'
        : _name(mover);
    return GroupMovePlan(
      memberPassengerIds: memberIds,
      destinationFits: false,
      blockedReason:
          '$label does not fit on ${destinationBus.name}: $shortfallText.',
    );
  }

  /// Physical berths one request-line unit of [type] consumes (a Double Sofa
  /// line is one bench seating two = 2 berths; everything else = 1).
  static int _berthsPerUnit(SeatType type) =>
      type == SeatType.doubleSofa ? 2 : 1;

  /// Human-readable shortfall by seat type, e.g. "1 Double Sofa, 2 Seater".
  ///
  /// Derived from FREE berths vs the group's need, allocating in the same order
  /// the engine uses so the gap mirrors a real apply:
  ///   1. whole double cells satisfy double lines (either deck — decks are
  ///      flexible for a whole double), then
  ///   2. cross-fill: two single-capable berths satisfy one double line, then
  ///   3. single lanes satisfy single lines, half-doubles fill the rest, then
  ///   4. seaters.
  static String _shortfallText({
    required List<Passenger> members,
    required Map<String, SeatCell> cellById,
    required Map<String, int> berthsTakenByOthers,
  }) {
    // Free pools on the snapshot: a cell's capacity minus reserved status and
    // minus berths already held by non-moving passengers.
    var freeSeater = 0;
    var freeSingle = 0;
    var wholeDoubles = 0; // double cells with BOTH berths free
    var halfDoubles = 0; // double cells with exactly ONE berth free
    for (final c in cellById.values) {
      if (c.reserved) continue;
      final cap = c.seatType == SeatType.doubleSofa ? 2 : 1;
      final free = cap - (berthsTakenByOthers[c.seatId] ?? 0);
      if (free <= 0) continue;
      switch (c.seatType) {
        case SeatType.seater:
          freeSeater += free;
          break;
        case SeatType.singleSofa:
          freeSingle += free;
          break;
        case SeatType.doubleSofa:
          if (free >= 2) {
            wholeDoubles += 1;
          } else {
            halfDoubles += 1;
          }
          break;
        case null:
          break;
      }
    }

    var needSeater = 0;
    var needSingle = 0;
    var needDouble = 0; // in Double Sofa LINES (each = a whole double bench)
    for (final m in members) {
      for (final l in m.requestLines) {
        switch (l.seatType) {
          case SeatType.seater:
            needSeater += l.qty;
            break;
          case SeatType.singleSofa:
            needSingle += l.qty;
            break;
          case SeatType.doubleSofa:
            needDouble += l.qty;
            break;
        }
      }
    }

    // 1. Whole doubles satisfy double lines first.
    final useWhole = needDouble < wholeDoubles ? needDouble : wholeDoubles;
    needDouble -= useWhole;
    wholeDoubles -= useWhole;
    // 2. Cross-fill remaining double lines from pairs of single-capable berths
    //    (free single lanes + leftover whole-double berths + half doubles).
    var crossFillBerths = freeSingle + wholeDoubles * 2 + halfDoubles;
    while (needDouble > 0 && crossFillBerths >= 2) {
      crossFillBerths -= 2;
      needDouble -= 1;
    }
    // 3. Singles draw from whatever single-capable berths remain.
    final useSingle = needSingle < crossFillBerths ? needSingle : crossFillBerths;
    needSingle -= useSingle;
    crossFillBerths -= useSingle;
    // 4. Seaters.
    final missSeater = needSeater - freeSeater;

    final parts = <String>[];
    if (needDouble > 0) parts.add('$needDouble ${SeatType.doubleSofa.displayName}');
    if (needSingle > 0) parts.add('$needSingle ${SeatType.singleSofa.displayName}');
    if (missSeater > 0) parts.add('$missSeater ${SeatType.seater.displayName}');
    return parts.isEmpty ? 'not enough room' : parts.join(', ');
  }

  static String _name(Passenger p) => p.name.isNotEmpty ? p.name : p.id;
}
