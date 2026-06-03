// Pure-Dart seating engine for Ugam Booking.
//
// NO Flutter imports, NO I/O, no wall-clock time, no randomness. Given a set of
// buses and passengers it returns a [SeatingPlan]: per-passenger proposed
// [SeatAssignment]s plus a list of [SeatingException]s for anything that cannot
// be placed under the hard rules. Identical input always yields identical
// output (only stable sort keys are used).
//
// The engine mirrors the seat-matching semantics already used by the UI
// (`tour_seat_assignment_screen.dart`): a doubleSofa cell physically seats two
// people (= two berths / two SeatAssignment entries on the same seatId); two
// single berths can cross-fill ONE doubleSofa request line; seater has a null
// position; sofa = singleSofa | doubleSofa.
//
// See docs/superpowers/specs/2026-06-03-smart-seat-assignment-design.md §5.

import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';

/// Why a particular berth was placed where it was. Every assignment the engine
/// proposes carries one of these so the plan is fully explainable.
class PlacementReason {
  /// The bus + seat the berth landed on.
  final String busId;
  final String seatId;

  /// The passenger who holds the berth.
  final String passengerId;

  /// One-line human-readable rationale, e.g. "group Patel — same bus",
  /// "approved priority — front sofa", "type match: Double Sofa Lower",
  /// "cross-fill: single berth toward a Double Sofa line", or "locked".
  final String reason;

  const PlacementReason({
    required this.busId,
    required this.seatId,
    required this.passengerId,
    required this.reason,
  });

  @override
  String toString() =>
      'PlacementReason($passengerId @ $busId:$seatId — $reason)';
}

/// The kind of problem a [SeatingException] describes. Each maps to a card the
/// agent resolves by hand; the engine never guesses past a hard rule.
enum SeatingExceptionType {
  /// An approved-priority passenger was seated, but no FRONT sofa seat was
  /// available within any bus's front-seat budget — they got a seat further
  /// back (or a non-front sofa).
  priorityNoFrontSeat,

  /// A group could not be placed entirely on a single bus (no bus has enough
  /// matching free berths for the whole group).
  groupWontFit,

  /// A request line could not be satisfied because no compatible seat
  /// type/position (including valid cross-fill) was free anywhere.
  seatTypeUnavailable,

  /// There was simply not enough capacity left for this passenger — they
  /// overflow onto the waitlist.
  overflowWaitlist,

  /// A coupled double-sofa's two berths could not be kept together, or a
  /// locked pair was broken by surrounding state.
  brokenPair,
}

/// A single thing the agent must decide. Plain-language, stable, deterministic.
class SeatingException {
  final SeatingExceptionType type;

  /// The passenger this exception is about. Null only for bus-level issues.
  final String? passengerId;

  /// The group this exception is about, when relevant (e.g. [groupWontFit]).
  final String? groupId;

  /// The request line that could not be honored, when relevant.
  final RequestLine? requestLine;

  /// One-line human-readable explanation.
  final String message;

  const SeatingException({
    required this.type,
    this.passengerId,
    this.groupId,
    this.requestLine,
    required this.message,
  });

  @override
  String toString() => 'SeatingException(${type.name}'
      '${passengerId != null ? ' p=$passengerId' : ''}'
      '${groupId != null ? ' g=$groupId' : ''}: $message)';
}

/// The full output of [SeatingEngine.propose].
///
/// [assignmentsByPassenger] holds, for every passenger that has at least one
/// proposed berth, the COMPLETE list of [SeatAssignment]s it should hold —
/// including any pre-existing locked entries, preserved verbatim. Passengers
/// with no placement at all are simply absent from the map (see [exceptions]).
class SeatingPlan {
  /// passengerId -> full proposed assignment list (locked entries preserved).
  final Map<String, List<SeatAssignment>> assignmentsByPassenger;

  /// Everything the agent must decide. Ordered deterministically.
  final List<SeatingException> exceptions;

  /// One reason per proposed berth, in placement order. Stable.
  final List<PlacementReason> reasons;

  const SeatingPlan({
    required this.assignmentsByPassenger,
    required this.exceptions,
    required this.reasons,
  });

  /// Convenience: the proposed assignments for one passenger (empty if none).
  List<SeatAssignment> forPassenger(String passengerId) =>
      assignmentsByPassenger[passengerId] ?? const <SeatAssignment>[];

  /// Convenience: every proposed assignment across all passengers, flattened.
  List<SeatAssignment> get allAssignments => [
        for (final list in assignmentsByPassenger.values) ...list,
      ];
}

/// Deterministic greedy seat-assignment engine.
///
/// Stateless; the single entry point is [propose]. All ordering is by stable
/// sort keys (ids, row indices, seat ids) — never by wall-clock time and never
/// random — so the same input always produces the same plan.
class SeatingEngine {
  const SeatingEngine._();

  /// How many of a bus's lowest rows count as "front" for priority seating.
  /// Front rows are the LOW row indices (see [BusLayout]). A bus's front-seat
  /// budget is every sofa berth in rows `0..frontRowCount-1`.
  static const int frontRowCount = 2;

  /// Produce a full seating plan for [buses] + [passengers].
  ///
  /// Honors every hard rule and the ordered goals from the design spec.
  static SeatingPlan propose({
    required List<Bus> buses,
    required List<Passenger> passengers,
  }) {
    final state = _PlanState(buses);
    final reasons = <PlacementReason>[];
    final exceptions = <SeatingException>[];

    // ── Stable ordering of passengers ─────────────────────────────────────
    // Sort by id so every downstream "largest first" / "in order" step is
    // reproducible regardless of the caller's list order.
    final sorted = [...passengers]..sort((a, b) => a.id.compareTo(b.id));

    // ── 0. Seed reserved + locked ─────────────────────────────────────────
    // Reserved seats are marked occupied so nothing auto-fills them.
    state.seedReserved();
    // Locked assignments are preserved verbatim and their berths reserved.
    for (final p in sorted) {
      for (final a in p.assignedSeats) {
        if (!a.locked) continue;
        state.seedLocked(p.id, a);
        reasons.add(PlacementReason(
          busId: a.busId,
          seatId: a.seatId,
          passengerId: p.id,
          reason: 'locked',
        ));
      }
    }

    // ── Build the work list of "pending lines" per passenger ──────────────
    // Locked berths already satisfy part of a passenger's request, so we
    // subtract them before deciding what still needs placing.
    final pendingByPassenger = <String, List<_PendingLine>>{};
    for (final p in sorted) {
      pendingByPassenger[p.id] = _buildPendingLines(p, state);
    }

    // ── Partition into groups and individuals ─────────────────────────────
    final groups = <String, List<Passenger>>{};
    final individuals = <Passenger>[];
    for (final p in sorted) {
      final gid = p.groupId;
      if (gid != null && gid.isNotEmpty) {
        (groups[gid] ??= <Passenger>[]).add(p);
      } else {
        individuals.add(p);
      }
    }

    // Reserve front-sofa budget for approved-priority INDIVIDUALS (placed in
    // step 2) so a NON-priority group in step 1 cannot grab the front rows
    // first. This makes goal 1 (priority → front) dominate goal 2 (group
    // adjacency) deterministically. Each priority individual decrements the
    // reserve once placed. Priority GROUP members claim the front inside their
    // own group placement (requireFront pass) so they are not counted here.
    state.frontSofaReserve = individuals
        .where((p) => p.isPriorityApproved)
        .fold(0, (s, p) => s + _sofaBerths(pendingByPassenger[p.id]!));

    // ── 1. Place groups (largest first, then by groupId for stability) ────
    final groupEntries = groups.entries.toList()
      ..sort((a, b) {
        final byBerths = _groupBerths(b.value, pendingByPassenger)
            .compareTo(_groupBerths(a.value, pendingByPassenger));
        if (byBerths != 0) return byBerths;
        return a.key.compareTo(b.key);
      });

    for (final entry in groupEntries) {
      _placeGroup(
        groupId: entry.key,
        members: entry.value,
        pendingByPassenger: pendingByPassenger,
        state: state,
        reasons: reasons,
        exceptions: exceptions,
      );
    }

    // ── 2. Approved-priority individuals → front sofa, spread across buses ─
    final priorityIndividuals = individuals
        .where((p) => p.isPriorityApproved)
        .toList(); // already id-sorted from `sorted`
    for (final p in priorityIndividuals) {
      // This priority individual is being placed now, so release the front
      // budget we were holding for them before they claim it.
      final remaining =
          state.frontSofaReserve - _sofaBerths(pendingByPassenger[p.id]!);
      state.frontSofaReserve = remaining < 0 ? 0 : remaining;
      _placeIndividual(
        passenger: p,
        pending: pendingByPassenger[p.id]!,
        state: state,
        reasons: reasons,
        exceptions: exceptions,
        priority: true,
      );
    }
    // No priority individuals remain to protect; drop any residual reserve so
    // step 3 fills freely.
    state.frontSofaReserve = 0;

    // ── 3. Remaining individuals by best-fit type match ───────────────────
    final normalIndividuals =
        individuals.where((p) => !p.isPriorityApproved).toList();
    for (final p in normalIndividuals) {
      _placeIndividual(
        passenger: p,
        pending: pendingByPassenger[p.id]!,
        state: state,
        reasons: reasons,
        exceptions: exceptions,
        priority: false,
      );
    }

    return SeatingPlan(
      assignmentsByPassenger: state.assignmentsByPassenger,
      exceptions: exceptions,
      reasons: reasons,
    );
  }

  // ── Group placement ─────────────────────────────────────────────────────

  /// Place an entire group onto ONE bus (hard rule 2). If no single bus can
  /// hold the whole group's still-pending berths, raises [groupWontFit] and
  /// places nothing (groups are all-or-nothing on a bus).
  static void _placeGroup({
    required String groupId,
    required List<Passenger> members,
    required Map<String, List<_PendingLine>> pendingByPassenger,
    required _PlanState state,
    required List<PlacementReason> reasons,
    required List<SeatingException> exceptions,
  }) {
    // ── Hard rule 2: the whole group sits on ONE bus ──────────────────────
    // Any LOCKED berth a member already holds ANCHORS the group to that bus —
    // the group must be placed there, not on whichever bus is currently
    // tightest. If members are anchored to MORE than one bus the group is
    // already split and can never satisfy hard rule 2: surface it as a broken
    // pair rather than emitting a silently-split "clean" plan.
    final anchorBuses = <String>{
      for (final m in members)
        for (final a in m.assignedSeats)
          if (a.locked) a.busId,
    };
    if (anchorBuses.length > 1) {
      exceptions.add(SeatingException(
        type: SeatingExceptionType.brokenPair,
        groupId: groupId,
        message:
            'Group $groupId is locked across multiple buses '
            '(${(anchorBuses.toList()..sort()).join(', ')}) and cannot sit '
            'together on one bus.',
      ));
      return;
    }

    // Total berths the whole group still needs.
    final needsBerths = _groupBerths(members, pendingByPassenger);
    if (needsBerths == 0) return; // fully satisfied by locked seats already.

    final wantsFront = members.any((m) => m.isPriorityApproved);

    // Candidate buses, deterministically ordered: prefer one that can hold the
    // group AND (if priority) has front budget; among those, prefer the bus
    // with the FEWEST free berths that still fits (tight pack → balance), then
    // by bus id. We trial-place onto a snapshot to know whether the whole group
    // actually fits under the cross-fill rules, not just by berth count.
    // When the group is anchored by a locked member, the ONLY candidate is the
    // anchor bus — the rest of the group joins it or the group won't fit.
    final ordered = (anchorBuses.length == 1
        ? state.buses.where((b) => b.id == anchorBuses.first).toList()
        : [...state.buses])
      ..sort((a, b) {
        final fa = state.freeBerths(a.id);
        final fb = state.freeBerths(b.id);
        if (fa != fb) return fa.compareTo(fb); // tightest first
        return a.id.compareTo(b.id);
      });

    // First pass honoring the front preference, then a fallback ignoring it.
    for (final requireFront in wantsFront ? [true, false] : [false]) {
      for (final bus in ordered) {
        final trial = state.fork();
        final trialReasons = <PlacementReason>[];
        var ok = true;
        // Place priority members first so they claim the front budget.
        final orderedMembers = [...members]
          ..sort((a, b) {
            final pa = a.isPriorityApproved ? 0 : 1;
            final pb = b.isPriorityApproved ? 0 : 1;
            if (pa != pb) return pa.compareTo(pb);
            return a.id.compareTo(b.id);
          });
        for (final m in orderedMembers) {
          final pending = _clonePending(pendingByPassenger[m.id]!);
          final placed = _placeOnBus(
            passenger: m,
            pending: pending,
            busId: bus.id,
            state: trial,
            reasons: trialReasons,
            priority: m.isPriorityApproved,
            requireFront: requireFront && m.isPriorityApproved,
            groupLabel: groupId,
          );
          if (!placed) {
            ok = false;
            break;
          }
        }
        if (ok) {
          // Commit the trial.
          state.adopt(trial);
          reasons.addAll(trialReasons);
          for (final m in members) {
            // Group members are now fully placed: clear their pending.
            pendingByPassenger[m.id] = const [];
          }
          // If the group wanted front but we only fit ignoring front budget,
          // flag the priority members that didn't get a front sofa.
          if (wantsFront && !requireFront) {
            for (final m in members.where((m) => m.isPriorityApproved)) {
              if (!state.hasFrontSofa(m.id)) {
                exceptions.add(SeatingException(
                  type: SeatingExceptionType.priorityNoFrontSeat,
                  passengerId: m.id,
                  groupId: groupId,
                  message:
                      'Approved-priority ${_name(m)} is in group $groupId but '
                      'no front sofa seat was free on the group\'s bus.',
                ));
              }
            }
          }
          return;
        }
      }
    }

    // No bus could hold the whole group.
    exceptions.add(SeatingException(
      type: SeatingExceptionType.groupWontFit,
      groupId: groupId,
      message: 'Group $groupId ($needsBerths berths across '
          '${members.length} bookings) does not fit on any single bus.',
    ));
  }

  // ── Individual placement ────────────────────────────────────────────────

  /// Place one ungrouped passenger. Tries buses in a deterministic order; an
  /// individual MAY span buses only across separate request lines, but in
  /// practice we keep a passenger together by trying each bus whole first, then
  /// falling back to best-fit across buses for whatever remains.
  static void _placeIndividual({
    required Passenger passenger,
    required List<_PendingLine> pending,
    required _PlanState state,
    required List<PlacementReason> reasons,
    required List<SeatingException> exceptions,
    required bool priority,
  }) {
    if (_remaining(pending) == 0) return;

    // Bus order: for priority, prefer buses with free FRONT sofa budget first
    // (spread priority across buses — goal 1), else balance by emptiest /
    // tightest. We use "most front budget remaining" so priority spreads out
    // rather than stacking on one bus.
    final ordered = [...state.buses]
      ..sort((a, b) {
        if (priority) {
          final fa = state.freeFrontSofa(a.id);
          final fb = state.freeFrontSofa(b.id);
          if (fa != fb) return fb.compareTo(fa); // most front budget first
        }
        // Balance fill: prefer the emptiest bus (most free berths).
        final ea = state.freeBerths(a.id);
        final eb = state.freeBerths(b.id);
        if (ea != eb) return eb.compareTo(ea);
        return a.id.compareTo(b.id);
      });

    for (final bus in ordered) {
      if (_remaining(pending) == 0) break;
      _placeOnBus(
        passenger: passenger,
        pending: pending,
        busId: bus.id,
        state: state,
        reasons: reasons,
        priority: priority,
        requireFront: false,
        groupLabel: null,
      );
    }

    // Whatever could not be placed becomes an exception.
    _raiseRemainingExceptions(
      passenger: passenger,
      pending: pending,
      state: state,
      exceptions: exceptions,
      priority: priority,
    );
  }

  /// Try to place as many of [passenger]'s [pending] berths as possible on a
  /// single [busId]. Mutates [pending] (decrementing satisfied lines) and the
  /// [state]. Returns true when EVERY pending line for this passenger is fully
  /// satisfied after this call (used by group all-or-nothing logic).
  ///
  /// When [requireFront] is set, sofa berths are only taken from front rows
  /// (rows < [frontRowCount]); used while a priority member is claiming the
  /// front budget on a chosen bus.
  static bool _placeOnBus({
    required Passenger passenger,
    required List<_PendingLine> pending,
    required String busId,
    required _PlanState state,
    required List<PlacementReason> reasons,
    required bool priority,
    required bool requireFront,
    required String? groupLabel,
  }) {
    // Process lines in a stable order: sofas before seaters, doubles before
    // singles (so doubleSofa lines claim whole doubles before singles get
    // scattered), upper before lower, then larger qty first.
    final order = List<int>.generate(pending.length, (i) => i)
      ..sort((ia, ib) {
        final la = pending[ia];
        final lb = pending[ib];
        final ka = _lineSortKey(la);
        final kb = _lineSortKey(lb);
        if (ka != kb) return ka.compareTo(kb);
        return ia.compareTo(ib); // stable by original index
      });

    for (final idx in order) {
      var line = pending[idx];
      while (line.remaining > 0) {
        final placed = _placeOneBerth(
          passenger: passenger,
          line: line,
          busId: busId,
          state: state,
          reasons: reasons,
          priority: priority,
          requireFront: requireFront,
          groupLabel: groupLabel,
        );
        if (placed == null) break; // nothing compatible free on this bus
        line = line.copyDecrementedBy(placed);
        pending[idx] = line;
      }
    }

    return _remaining(pending) == 0;
  }

  /// Attempt to satisfy ONE unit of [line] on [busId]. Returns how many berths
  /// of the line were consumed (1 normally; 1 for a doubleSofa line that took a
  /// whole double; or via cross-fill a single berth counts as a half toward a
  /// double line) or null if nothing compatible was free.
  ///
  /// Returns the number of REQUEST-LINE units consumed (always 1 on success),
  /// not the number of physical berths claimed.
  static int? _placeOneBerth({
    required Passenger passenger,
    required _PendingLine line,
    required String busId,
    required _PlanState state,
    required List<PlacementReason> reasons,
    required bool priority,
    required bool requireFront,
    required String? groupLabel,
  }) {
    final reasonTag = _reasonPrefix(priority, groupLabel);

    switch (line.seatType) {
      case SeatType.seater:
        final cell = state.takeFreeCell(
          busId,
          type: SeatType.seater,
          position: null,
          frontOnly: false,
        );
        if (cell == null) return null;
        state.assign(passenger.id, busId, cell.seatId!);
        reasons.add(PlacementReason(
          busId: busId,
          seatId: cell.seatId!,
          passengerId: passenger.id,
          reason: '$reasonTag type match: Seater',
        ));
        return 1;

      case SeatType.singleSofa:
        // Prefer an actual single-sofa cell; if none, take HALF of a free
        // double (a single may sit on one berth of a double sofa).
        // Non-priority placements honor the front-sofa reserve so approved
        // priority passengers keep first claim on the front rows (goal 1 over
        // goal 2).
        final single = state.takeFreeCell(
          busId,
          type: SeatType.singleSofa,
          position: line.position,
          frontOnly: requireFront,
          guardFrontReserve: !priority,
        );
        if (single != null) {
          state.assign(passenger.id, busId, single.seatId!);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: single.seatId!,
            passengerId: passenger.id,
            reason:
                '$reasonTag type match: ${seatTypeLabel(SeatType.singleSofa, single.position)}',
          ));
          return 1;
        }
        final halfDouble = state.takeHalfDouble(
          busId,
          position: line.position,
          frontOnly: requireFront,
          guardFrontReserve: !priority,
        );
        if (halfDouble != null) {
          state.assign(passenger.id, busId, halfDouble.seatId!);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: halfDouble.seatId!,
            passengerId: passenger.id,
            reason: '$reasonTag single on half of a Double Sofa',
          ));
          return 1;
        }
        return null;

      case SeatType.doubleSofa:
        // Prefer a whole free double (both berths to this passenger).
        final whole = state.takeFreeCell(
          busId,
          type: SeatType.doubleSofa,
          position: line.position,
          frontOnly: requireFront,
          guardFrontReserve: !priority,
        );
        if (whole != null) {
          // A doubleSofa cell = two berths held by one passenger. One reason
          // entry per berth so every assignment maps to a rationale.
          final wholeReason =
              '$reasonTag type match: ${seatTypeLabel(SeatType.doubleSofa, whole.position)} (whole)';
          state.assign(passenger.id, busId, whole.seatId!);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: whole.seatId!,
            passengerId: passenger.id,
            reason: wholeReason,
          ));
          state.assign(passenger.id, busId, whole.seatId!);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: whole.seatId!,
            passengerId: passenger.id,
            reason: wholeReason,
          ));
          return 1;
        }
        // Cross-fill: two single berths (single sofas or half-doubles) satisfy
        // ONE doubleSofa line. The double line's position only gates the WHOLE
        // double claim above; for cross-fill the substitute singles' positions
        // are irrelevant (a Double Sofa is one bench seating two), so we pass
        // position: null — mirroring the UI's cross-fill drain.
        final first = state.takeFreeCell(
              busId,
              type: SeatType.singleSofa,
              position: null,
              frontOnly: requireFront,
              guardFrontReserve: !priority,
            ) ??
            state.takeHalfDouble(busId,
                position: null,
                frontOnly: requireFront,
                guardFrontReserve: !priority);
        if (first == null) return null;
        final second = state.takeFreeCell(
              busId,
              type: SeatType.singleSofa,
              position: null,
              frontOnly: requireFront,
              guardFrontReserve: !priority,
            ) ??
            state.takeHalfDouble(busId,
                position: null,
                frontOnly: requireFront,
                guardFrontReserve: !priority);
        if (second == null) {
          // Only one single available — can't satisfy a double line by
          // cross-fill. Release the first so we don't strand it.
          state.release(busId, first.seatId!);
          return null;
        }
        state.assign(passenger.id, busId, first.seatId!);
        state.assign(passenger.id, busId, second.seatId!);
        reasons.add(PlacementReason(
          busId: busId,
          seatId: first.seatId!,
          passengerId: passenger.id,
          reason: '$reasonTag cross-fill: 2 singles satisfy a Double Sofa line',
        ));
        reasons.add(PlacementReason(
          busId: busId,
          seatId: second.seatId!,
          passengerId: passenger.id,
          reason: '$reasonTag cross-fill: 2 singles satisfy a Double Sofa line',
        ));
        return 1;
    }
  }

  // ── Exception raising ─────────────────────────────────────────────────────

  static void _raiseRemainingExceptions({
    required Passenger passenger,
    required List<_PendingLine> pending,
    required _PlanState state,
    required List<SeatingException> exceptions,
    required bool priority,
  }) {
    final anyFreeCapacity = state.buses.any((b) => state.freeBerths(b.id) > 0);
    for (final line in pending) {
      if (line.remaining <= 0) continue;
      final rl = RequestLine(
        seatType: line.seatType,
        position: line.position,
        qty: line.remaining,
      );
      if (!anyFreeCapacity) {
        exceptions.add(SeatingException(
          type: SeatingExceptionType.overflowWaitlist,
          passengerId: passenger.id,
          requestLine: rl,
          message:
              '${_name(passenger)} could not be seated — no capacity left for '
              '${rl.label}. Waitlist.',
        ));
      } else {
        exceptions.add(SeatingException(
          type: SeatingExceptionType.seatTypeUnavailable,
          passengerId: passenger.id,
          requestLine: rl,
          message:
              'No matching ${seatTypeLabel(line.seatType, line.position)} seat '
              'free for ${_name(passenger)} (${rl.label}).',
        ));
      }
    }

    // A priority passenger who got seated but not in a front sofa.
    if (priority &&
        _remaining(pending) == 0 &&
        !state.hasFrontSofa(passenger.id)) {
      exceptions.add(SeatingException(
        type: SeatingExceptionType.priorityNoFrontSeat,
        passengerId: passenger.id,
        message:
            'Approved-priority ${_name(passenger)} was seated, but no front '
            'sofa seat was available.',
      ));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Build the still-pending request lines for a passenger after subtracting
  /// their LOCKED assignments (locked berths already satisfy part of a line).
  /// Mirrors the cross-fill draining in tour_seat_assignment_screen.dart.
  static List<_PendingLine> _buildPendingLines(
      Passenger p, _PlanState state) {
    final pending = [
      for (final l in p.requestLines)
        _PendingLine(
          seatType: l.seatType,
          position: l.position,
          remaining: l.qty,
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
            if (_drainDoubleCrossFill(pending) &&
                state.tryClaimPartnerBerth(g.busId, g.seatId)) {
              state.assign(p.id, g.busId, g.seatId);
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
  static bool _drainDoubleCrossFill(List<_PendingLine> pending) {
    final idx = pending.indexWhere(
        (l) => l.seatType == SeatType.doubleSofa && l.remaining > 0);
    if (idx < 0) return false;
    pending[idx] = pending[idx].copyDecrementedBy(1);
    return true;
  }

  static bool _drain(
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

  static List<_PendingLine> _clonePending(List<_PendingLine> src) => [
        for (final l in src)
          _PendingLine(
            seatType: l.seatType,
            position: l.position,
            remaining: l.remaining,
          ),
      ];

  static int _remaining(List<_PendingLine> pending) =>
      pending.fold(0, (s, l) => s + l.remaining);

  /// Count the SOFA berths a passenger's pending lines still need (doubleSofa
  /// = 2 berths, singleSofa = 1; seaters excluded). Used to size the
  /// front-sofa reserve for approved-priority demand.
  static int _sofaBerths(List<_PendingLine> pending) {
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

  static int _groupBerths(
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
  static int _lineSortKey(_PendingLine l) {
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

  static String _reasonPrefix(bool priority, String? groupLabel) {
    if (groupLabel != null) {
      return priority
          ? 'group $groupLabel (approved priority) —'
          : 'group $groupLabel —';
    }
    return priority ? 'approved priority —' : '';
  }

  static String _name(Passenger p) => p.name.isNotEmpty ? p.name : p.id;
}

// ── Internal mutable state ──────────────────────────────────────────────────

/// A pending request line during planning (a mutable view of [RequestLine]).
class _PendingLine {
  final SeatType seatType;
  final SeatPosition? position;
  final int remaining;

  const _PendingLine({
    required this.seatType,
    this.position,
    required this.remaining,
  });

  _PendingLine copyDecrementedBy(int n) => _PendingLine(
        seatType: seatType,
        position: position,
        remaining: (remaining - n).clamp(0, remaining),
      );
}

class _LockedCell {
  final String busId;
  final String seatId;
  int berths = 0;
  _LockedCell(this.busId, this.seatId);
}

/// Per-cell free-berth accounting for one bus, plus seat metadata.
class _BusState {
  final Bus bus;

  /// seatId -> the cell (so we can read type/position/row).
  final Map<String, SeatCell> cells;

  /// seatId -> berths still FREE on that cell. A doubleSofa starts at 2; every
  /// other seat at 1. Reserved cells start at 0.
  final Map<String, int> freeBerthsBySeat;

  _BusState(this.bus)
      : cells = {},
        freeBerthsBySeat = {} {
    final layout = bus.layout;
    if (layout == null) return;
    for (final c in layout.grid) {
      if (!c.hasSeat || c.seatId == null) continue;
      cells[c.seatId!] = c;
      final cap = c.seatType == SeatType.doubleSofa ? 2 : 1;
      freeBerthsBySeat[c.seatId!] = c.reserved ? 0 : cap;
    }
  }

  _BusState._clone(this.bus, this.cells, Map<String, int> free)
      : freeBerthsBySeat = Map<String, int>.from(free);

  _BusState fork() => _BusState._clone(bus, cells, freeBerthsBySeat);

  int get rows => bus.layout?.rows ?? 0;

  bool isFront(SeatCell c) => c.row < SeatingEngine.frontRowCount;

  bool isSofa(SeatType? t) =>
      t == SeatType.singleSofa || t == SeatType.doubleSofa;

  int get freeBerths =>
      freeBerthsBySeat.values.fold(0, (s, v) => s + v);

  /// Free sofa berths in the front rows — the priority budget.
  int get freeFrontSofa {
    var n = 0;
    for (final e in freeBerthsBySeat.entries) {
      if (e.value <= 0) continue;
      final c = cells[e.key]!;
      if (isSofa(c.seatType) && isFront(c)) n += e.value;
    }
    return n;
  }

  /// Seats ordered row-major (front first) then by seatId for stability.
  List<SeatCell> _orderedSeats() {
    final list = cells.values.toList()
      ..sort((a, b) {
        if (a.row != b.row) return a.row.compareTo(b.row);
        if (a.col != b.col) return a.col.compareTo(b.col);
        // upper before lower before null
        final pa = a.position == SeatPosition.upper
            ? 0
            : a.position == SeatPosition.lower
                ? 1
                : 2;
        final pb = b.position == SeatPosition.upper
            ? 0
            : b.position == SeatPosition.lower
                ? 1
                : 2;
        if (pa != pb) return pa.compareTo(pb);
        return (a.seatId ?? '').compareTo(b.seatId ?? '');
      });
    return list;
  }
}

/// The whole evolving plan: per-bus accounting + per-passenger assignments.
class _PlanState {
  final List<Bus> buses;
  final Map<String, _BusState> _busStates;
  final Map<String, List<SeatAssignment>> assignmentsByPassenger;

  /// passengerId -> set of "busId:seatId" cells where they sit on a FRONT sofa.
  final Map<String, bool> _hasFrontSofa;

  /// How many FRONT sofa berths (across all buses) must be kept free for
  /// still-unplaced approved-priority demand. Non-priority placements may only
  /// dip into front sofas once doing so would NOT drop global free front-sofa
  /// capacity below this reserve. Goal 1 (priority front) thus dominates goal 2
  /// (group adjacency) without any wall-clock/random input.
  int frontSofaReserve = 0;

  _PlanState(List<Bus> buses)
      : buses = (buses.toList()..sort((a, b) => a.id.compareTo(b.id))),
        _busStates = {
          for (final b in buses) b.id: _BusState(b),
        },
        assignmentsByPassenger = {},
        _hasFrontSofa = {};

  _PlanState._clone(
    this.buses,
    this._busStates,
    this.assignmentsByPassenger,
    this._hasFrontSofa,
  );

  /// A deep-enough copy for trial group placement: bus berth counts and
  /// assignment lists are cloned; immutable cell metadata is shared.
  _PlanState fork() {
    return _PlanState._clone(
      buses,
      {for (final e in _busStates.entries) e.key: e.value.fork()},
      {
        for (final e in assignmentsByPassenger.entries)
          e.key: List<SeatAssignment>.from(e.value)
      },
      Map<String, bool>.from(_hasFrontSofa),
    )..frontSofaReserve = frontSofaReserve;
  }

  /// Copy a committed trial's state back into this one.
  void adopt(_PlanState other) {
    _busStates
      ..clear()
      ..addAll(other._busStates);
    assignmentsByPassenger
      ..clear()
      ..addAll(other.assignmentsByPassenger);
    _hasFrontSofa
      ..clear()
      ..addAll(other._hasFrontSofa);
    frontSofaReserve = other.frontSofaReserve;
  }

  void seedReserved() {
    // Reserved cells already start at 0 free berths in _BusState; nothing else
    // to do — kept as an explicit step for readability / future hooks.
  }

  /// Seed a locked assignment: reserve its berth and record it verbatim.
  void seedLocked(String passengerId, SeatAssignment a) {
    final bs = _busStates[a.busId];
    final list = assignmentsByPassenger.putIfAbsent(passengerId, () => []);
    // Preserve the locked entry exactly (including locked:true).
    list.add(a);
    if (bs == null) return;
    final free = bs.freeBerthsBySeat[a.seatId];
    if (free != null && free > 0) {
      bs.freeBerthsBySeat[a.seatId] = free - 1;
    }
    final cell = bs.cells[a.seatId];
    if (cell != null && bs.isSofa(cell.seatType) && bs.isFront(cell)) {
      _hasFrontSofa[passengerId] = true;
    }
  }

  SeatCell? cellFor(String busId, String seatId) =>
      _busStates[busId]?.cells[seatId];

  int freeBerths(String busId) => _busStates[busId]?.freeBerths ?? 0;

  int freeFrontSofa(String busId) => _busStates[busId]?.freeFrontSofa ?? 0;

  /// Free FRONT sofa berths across every bus — the global priority budget.
  int get totalFreeFrontSofa =>
      _busStates.values.fold(0, (s, bs) => s + bs.freeFrontSofa);

  /// True when consuming ONE more front-sofa berth (for a non-priority
  /// placement) would NOT eat into the reserve held for approved-priority
  /// demand. A non-priority sofa take consults this before claiming a front
  /// cell, so priority passengers keep getting the front seats first.
  bool _frontTakeAllowed() => totalFreeFrontSofa - 1 >= frontSofaReserve;

  bool hasFrontSofa(String passengerId) =>
      _hasFrontSofa[passengerId] ?? false;

  /// Take a free cell of an exact [type] (+[position] when given) on [busId].
  /// When [frontOnly], only front-row cells qualify. Returns null if none.
  /// For a doubleSofa, "free" means BOTH berths are still free (a whole double).
  /// When [guardFrontReserve] is set (a NON-priority sofa placement), a FRONT
  /// sofa cell is skipped unless taking it would still leave enough free front
  /// sofas for outstanding approved-priority demand ([frontSofaReserve]).
  SeatCell? takeFreeCell(
    String busId, {
    required SeatType type,
    required SeatPosition? position,
    required bool frontOnly,
    bool guardFrontReserve = false,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    final wholeNeeded = type == SeatType.doubleSofa ? 2 : 1;
    for (final c in bs._orderedSeats()) {
      if (c.seatType != type) continue;
      if (position != null && c.position != position) continue;
      if (frontOnly && !bs.isFront(c)) continue;
      if (guardFrontReserve &&
          bs.isSofa(c.seatType) &&
          bs.isFront(c) &&
          !_frontTakeAllowed()) {
        continue;
      }
      final free = bs.freeBerthsBySeat[c.seatId] ?? 0;
      if (free >= wholeNeeded) {
        bs.freeBerthsBySeat[c.seatId!] = free - wholeNeeded;
        return c;
      }
    }
    return null;
  }

  /// Take ONE berth of a doubleSofa cell (a half-double) on [busId], matching
  /// [position] when given. Used for single-on-double and cross-fill.
  SeatCell? takeHalfDouble(
    String busId, {
    required SeatPosition? position,
    required bool frontOnly,
    bool guardFrontReserve = false,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    for (final c in bs._orderedSeats()) {
      if (c.seatType != SeatType.doubleSofa) continue;
      if (position != null && c.position != position) continue;
      if (frontOnly && !bs.isFront(c)) continue;
      if (guardFrontReserve && bs.isFront(c) && !_frontTakeAllowed()) {
        continue;
      }
      final free = bs.freeBerthsBySeat[c.seatId] ?? 0;
      if (free >= 1) {
        bs.freeBerthsBySeat[c.seatId!] = free - 1;
        return c;
      }
    }
    return null;
  }

  /// Record a placed berth for a passenger and update front-sofa tracking.
  void assign(String passengerId, String busId, String seatId) {
    final list = assignmentsByPassenger.putIfAbsent(passengerId, () => []);
    list.add(SeatAssignment(busId: busId, seatId: seatId));
    final cell = _busStates[busId]?.cells[seatId];
    final bs = _busStates[busId];
    if (cell != null && bs != null && bs.isSofa(cell.seatType) && bs.isFront(cell)) {
      _hasFrontSofa[passengerId] = true;
    }
  }

  /// Claim the remaining free berth of a specific (already-partly-occupied)
  /// double-sofa [seatId] on [busId]. Used to complete a half-locked own-cell
  /// double in place. Returns true if a free berth existed and was consumed.
  bool tryClaimPartnerBerth(String busId, String seatId) {
    final bs = _busStates[busId];
    if (bs == null) return false;
    final cell = bs.cells[seatId];
    if (cell == null || cell.seatType != SeatType.doubleSofa) return false;
    final free = bs.freeBerthsBySeat[seatId] ?? 0;
    if (free < 1) return false;
    bs.freeBerthsBySeat[seatId] = free - 1;
    return true;
  }

  /// Give back one free berth on a cell (used when a cross-fill aborts).
  void release(String busId, String seatId) {
    final bs = _busStates[busId];
    if (bs == null) return;
    final free = bs.freeBerthsBySeat[seatId] ?? 0;
    final cap = bs.cells[seatId]?.seatType == SeatType.doubleSofa ? 2 : 1;
    bs.freeBerthsBySeat[seatId] = (free + 1).clamp(0, cap);
  }
}
