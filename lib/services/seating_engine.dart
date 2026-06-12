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
import '../models/trip_type.dart';

/// A tour leg. Capacity is tracked PER LEG so the same physical berth can be
/// reused across disjoint legs (an outbound-only passenger and a return-only
/// passenger can hold the SAME seat at once). A round-trip passenger needs the
/// berth on BOTH legs and therefore blocks any reuse.
enum TripLeg {
  go,
  ret;

  /// The legs a [tripType] actually occupies.
  static List<TripLeg> forTrip(TripType t) {
    final legs = <TripLeg>[];
    if (t.usesOutbound) legs.add(TripLeg.go);
    if (t.usesReturn) legs.add(TripLeg.ret);
    return legs;
  }
}

/// Why a particular berth was placed where it was. Every assignment the engine
/// proposes carries one of these so the plan is fully explainable.
class PlacementReason {
  /// The bus + seat the berth landed on.
  final String busId;
  final String seatId;

  /// The passenger who holds the berth.
  final String passengerId;

  /// One-line human-readable rationale, e.g. "group Patel — same bus",
  /// "approved priority — lower berth", "type match: Double Sofa Lower",
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
  /// An approved-priority passenger was seated, but no LOWER berth was
  /// available within any bus's lower-berth budget — they got an upper berth
  /// (or were placed without a lower-berth claim).
  priorityNoLowerBerth,

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

  /// A passenger could only be seated by SHARING a Double Sofa with an
  /// UNRELATED occupant (the other berth is held by someone who does NOT share
  /// the passenger's group), and no other compatible seat/leg was free. Two
  /// strangers must not be auto-paired on one sofa — the agent confirms the
  /// pairing (e.g. checks gender) before this berth can be granted.
  sharedDoubleNeedsReview,
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

  /// Per-seat GO vs RETURN occupancy across the whole plan.
  ///
  /// Because capacity is now LEG-AWARE (a berth has a GO slot and a RETURN
  /// slot), the same physical seat can be held by different passengers on
  /// different legs. This helper lets the UI render that: for every seat that
  /// holds at least one berth, it reports how many berths are occupied on the
  /// outbound (GO) leg vs the return (RETURN) leg, derived from each holder's
  /// [Passenger.tripType].
  ///
  /// Pass the SAME passenger list given to [SeatingEngine.propose]; passengers
  /// absent from the plan are ignored. Keyed by `"busId:seatId"`. A whole double
  /// held solo contributes 2 to its leg(s); a shared double contributes 1 per
  /// holder per leg.
  Map<String, SeatLegOccupancy> legOccupancy(Iterable<Passenger> passengers) {
    final tripById = <String, TripType>{
      for (final p in passengers) p.id: p.tripType,
    };
    final out = <String, SeatLegOccupancy>{};
    for (final entry in assignmentsByPassenger.entries) {
      final trip = tripById[entry.key] ?? TripType.roundTrip;
      final usesGo = trip.usesOutbound;
      final usesReturn = trip.usesReturn;
      for (final a in entry.value) {
        final key = '${a.busId}:${a.seatId}';
        final cur = out[key] ?? const SeatLegOccupancy(go: 0, ret: 0);
        out[key] = SeatLegOccupancy(
          go: cur.go + (usesGo ? 1 : 0),
          ret: cur.ret + (usesReturn ? 1 : 0),
        );
      }
    }
    return out;
  }
}

/// How many berths of a single seat are occupied on each tour leg.
///
/// Exposed so the UI can show leg-aware reuse: a seat can read e.g. `go: 1,
/// ret: 1` from two DIFFERENT passengers (one outbound-only, one return-only)
/// sharing the same berth across disjoint legs.
class SeatLegOccupancy {
  /// Berths occupied on the outbound (GO) leg.
  final int go;

  /// Berths occupied on the return (RETURN) leg.
  final int ret;

  const SeatLegOccupancy({required this.go, required this.ret});

  @override
  String toString() => 'SeatLegOccupancy(go: $go, ret: $ret)';
}

/// Deterministic greedy seat-assignment engine.
///
/// Stateless; the single entry point is [propose]. All ordering is by stable
/// sort keys (ids, row indices, seat ids) — never by wall-clock time and never
/// random — so the same input always produces the same plan.
class SeatingEngine {
  const SeatingEngine._();

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
    //
    // Waitlisted passengers are intentionally HELD by the agent — the engine
    // must never seat them and never raise an exception for them (no phantom
    // overflowWaitlist for someone the agent already chose to defer). They
    // re-enter placement only once the agent takes them off the waitlist.
    final sorted = [
      for (final p in passengers)
        if (!p.isWaitlisted) p,
    ]..sort((a, b) => a.id.compareTo(b.id));

    // ── 0. Seed reserved + locked ─────────────────────────────────────────
    // Reserved seats are marked occupied so nothing auto-fills them.
    state.seedReserved();
    // Locked assignments are preserved verbatim and their berths reserved.
    for (final p in sorted) {
      final legs = TripLeg.forTrip(p.tripType);
      for (final a in p.assignedSeats) {
        if (!a.locked) continue;
        state.seedLocked(p.id, a, legs, groupId: p.groupId);
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

    // Reserve lower-sofa budget for approved-priority INDIVIDUALS (placed in
    // step 2) so a NON-priority group in step 1 cannot grab the lower berths
    // first. This makes goal 1 (priority → lower berth) dominate goal 2 (group
    // adjacency) deterministically. Each priority individual decrements the
    // reserve once placed. Priority GROUP members claim a lower berth inside
    // their own group placement (requireLower pass) so they are not counted here.
    state.lowerSofaReserve = individuals
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

    // ── 2. Approved-priority individuals → lower berth, spread across buses ─
    final priorityIndividuals = individuals
        .where((p) => p.isPriorityApproved)
        .toList(); // already id-sorted from `sorted`
    for (final p in priorityIndividuals) {
      // This priority individual is being placed now, so release the lower-berth
      // budget we were holding for them before they claim it.
      final remaining =
          state.lowerSofaReserve - _sofaBerths(pendingByPassenger[p.id]!);
      state.lowerSofaReserve = remaining < 0 ? 0 : remaining;
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
    state.lowerSofaReserve = 0;

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

    final wantsLower = members.any((m) => m.isPriorityApproved);

    // Candidate buses, deterministically ordered: prefer one that can hold the
    // group AND (if priority) has lower-berth budget; among those, prefer the bus
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

    // First pass honoring the lower-berth preference, then a fallback ignoring it.
    for (final requireLower in wantsLower ? [true, false] : [false]) {
      for (final bus in ordered) {
        final trial = state.fork();
        final trialReasons = <PlacementReason>[];
        var ok = true;
        // Place priority members first so they claim the lower-berth budget.
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
            requireLower: requireLower && m.isPriorityApproved,
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
          // If the group wanted a lower berth but we only fit ignoring the
          // lower-berth budget, flag the priority members who got an upper berth.
          if (wantsLower && !requireLower) {
            for (final m in members.where((m) => m.isPriorityApproved)) {
              if (!state.hasLowerSofa(m.id)) {
                exceptions.add(SeatingException(
                  type: SeatingExceptionType.priorityNoLowerBerth,
                  passengerId: m.id,
                  groupId: groupId,
                  message:
                      'Approved-priority ${_name(m)} is in group $groupId but '
                      'no lower berth was free on the group\'s bus.',
                ));
              }
            }
          }
          return;
        }
      }
    }

    // No bus could hold the whole group under the hard rules.
    //
    // STRANGER-SHARE PARITY (locked rule): before declaring the group simply
    // "won't fit", check whether the ONLY obstacle was the stranger-share
    // refusal — i.e. the group WOULD fit on some candidate bus if its members
    // were allowed to share a Double Sofa with an unrelated occupant. If so, the
    // bus genuinely HAS room; the agent must broker the stranger pairing, so the
    // affected member(s) get [sharedDoubleNeedsReview] (exactly what an
    // UNGROUPED passenger in the same spot would get) instead of a misleading
    // groupWontFit that hides the brokerable berth. No berth is ever
    // auto-paired: the relaxed trial below is detection-only and is never
    // committed.
    final orderMembers = ([...members]
      ..sort((a, b) {
        final pa = a.isPriorityApproved ? 0 : 1;
        final pb = b.isPriorityApproved ? 0 : 1;
        if (pa != pb) return pa.compareTo(pb);
        return a.id.compareTo(b.id);
      }));
    for (final bus in ordered) {
      // Would the whole group fit on THIS bus if strangers could share doubles?
      final relaxed = state.fork();
      final discard = <PlacementReason>[];
      var fitsWithStrangers = true;
      for (final m in orderMembers) {
        final pending = _clonePending(pendingByPassenger[m.id]!);
        final placed = _placeOnBus(
          passenger: m,
          pending: pending,
          busId: bus.id,
          state: relaxed,
          reasons: discard,
          priority: m.isPriorityApproved,
          requireLower: false,
          groupLabel: groupId,
          allowStrangerShare: true,
        );
        if (!placed) {
          fitsWithStrangers = false;
          break;
        }
      }
      if (!fitsWithStrangers) continue;

      // The group fits ONLY when strangers may share → the sole obstacle is the
      // stranger-share rule. Replay a STRICT (rule-enforcing) trial on this bus
      // to find which members are blocked by a stranger-double, and surface them
      // for the agent to broker.
      final strict = state.fork();
      final strictDiscard = <PlacementReason>[];
      final affected = <Passenger>[];
      for (final m in orderMembers) {
        final pending = _clonePending(pendingByPassenger[m.id]!);
        _placeOnBus(
          passenger: m,
          pending: pending,
          busId: bus.id,
          state: strict,
          reasons: strictDiscard,
          priority: m.isPriorityApproved,
          requireLower: false,
          groupLabel: groupId,
        );
        // Lines that remain unplaced under the strict rule, blocked precisely
        // by a stranger-double on this bus → this member needs review.
        final legs = TripLeg.forTrip(m.tripType);
        final blocked = pending.any((l) =>
            l.remaining > 0 &&
            ((l.seatType == SeatType.singleSofa &&
                    strict.hasBlockedShareDoubleOnBus(bus.id, legs, m.groupId,
                        position: l.position)) ||
                (l.seatType == SeatType.doubleSofa &&
                    strict.hasBlockedShareDoubleOnBus(
                        bus.id, legs, m.groupId))));
        if (blocked) affected.add(m);
      }
      if (affected.isNotEmpty) {
        for (final m in affected) {
          exceptions.add(SeatingException(
            type: SeatingExceptionType.sharedDoubleNeedsReview,
            passengerId: m.id,
            groupId: groupId,
            message:
                '${_name(m)} (group $groupId) can only be seated by sharing a '
                'Double Sofa with another passenger — confirm the pairing.',
          ));
        }
        return;
      }
    }

    // Genuine capacity shortage (not a brokerable stranger-share): the group
    // does not fit on any single bus.
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

    // Bus order: PACK, don't balance. Fill the fullest bus that still has room
    // before opening the next one — the agent's flow: "pick one bus, seat the
    // unassigned people, and only move to the next bus once this one is full."
    // Buses with no room sort last. A priority passenger still takes a LOWER
    // berth *within* the chosen bus via the requireLower pass below (and, all
    // else equal, we prefer a bus that still has free lower-berth budget so
    // priority people aren't pushed onto an upper berth while a lower one sits
    // open on another bus).
    final ordered = [...state.buses]
      ..sort((a, b) {
        final ea = state.freeBerths(a.id);
        final eb = state.freeBerths(b.id);
        final aRoom = ea > 0;
        final bRoom = eb > 0;
        if (aRoom != bRoom) return aRoom ? -1 : 1; // buses with room first
        if (priority) {
          // Priority still seeks a LOWER berth — prefer the bus with the most
          // free lower-berth budget (spreads priority only as far as needed to
          // seat elders on a lower berth). The non-priority bulk skips this and
          // packs below.
          final fa = state.freeLowerSofa(a.id);
          final fb = state.freeLowerSofa(b.id);
          if (fa != fb) return fb.compareTo(fa); // most lower-berth budget first
        }
        if (ea != eb) return ea.compareTo(eb); // fewest free first = PACK
        return a.id.compareTo(b.id);
      });

    // Priority individuals get the SAME two-phase placement groups already use:
    // a HARD lower-only pass across all buses first, then a relaxed pass for
    // whatever remains. requireLower=true sets lowerOnly on both takeFreeCell
    // and takeHalfDouble, so the lower-berth preference spans the exact-type →
    // substitute fallback chain (a lower double satisfies a single line, two
    // lower singles satisfy a double line) before any upper berth is touched.
    // The soft preferLower still acts as a tie-breaker in the relaxed pass.
    // Non-priority passengers run the single relaxed pass only.
    for (final requireLower in priority ? [true, false] : [false]) {
      for (final bus in ordered) {
        if (_remaining(pending) == 0) break;
        _placeOnBus(
          passenger: passenger,
          pending: pending,
          busId: bus.id,
          state: state,
          reasons: reasons,
          priority: priority,
          requireLower: requireLower,
          groupLabel: null,
        );
      }
    }

    // ── FILL, NO EMPTY SEATS ──────────────────────────────────────────────
    // The balance/lower-ordered passes above may stop short while a compatible
    // berth-leg is still free on SOME bus (the early-break heuristics optimize
    // for balance, not exhaustion). Before we ever waitlist this passenger,
    // sweep EVERY bus once more with all preference gating dropped — plain
    // relaxed placement, hard rules still intact — so no one is left unplaced
    // while a compatible seat sits empty anywhere.
    _fillSweep(
      passenger: passenger,
      pending: pending,
      state: state,
      reasons: reasons,
    );

    // Whatever could not be placed becomes an exception.
    _raiseRemainingExceptions(
      passenger: passenger,
      pending: pending,
      state: state,
      exceptions: exceptions,
      priority: priority,
    );
  }

  /// Exhaustive last-resort fill for one passenger's still-[pending] lines.
  ///
  /// Iterates buses in stable id order and keeps re-attempting plain (no
  /// lower-berth gating, no lower-reserve guard) placement until a full sweep across all
  /// buses places nothing more. This guarantees Change 2's contract: a
  /// passenger is never waitlisted while ANY compatible free berth-leg remains
  /// anywhere — including cross-fill and the leg-reuse GO/RETURN slots. Hard
  /// rules (type/position match, capacity, reserved, locked) are still honored
  /// because it routes through the same [_placeOnBus] path.
  static void _fillSweep({
    required Passenger passenger,
    required List<_PendingLine> pending,
    required _PlanState state,
    required List<PlacementReason> reasons,
  }) {
    if (_remaining(pending) == 0) return;
    final busOrder = [...state.buses]..sort((a, b) => a.id.compareTo(b.id));
    var progressed = true;
    while (progressed && _remaining(pending) > 0) {
      progressed = false;
      for (final bus in busOrder) {
        if (_remaining(pending) == 0) break;
        final before = _remaining(pending);
        _placeOnBus(
          passenger: passenger,
          pending: pending,
          busId: bus.id,
          state: state,
          reasons: reasons,
          priority: false,
          requireLower: false,
          groupLabel: null,
        );
        if (_remaining(pending) < before) progressed = true;
      }
    }
  }

  /// Try to place as many of [passenger]'s [pending] berths as possible on a
  /// single [busId]. Mutates [pending] (decrementing satisfied lines) and the
  /// [state]. Returns true when EVERY pending line for this passenger is fully
  /// satisfied after this call (used by group all-or-nothing logic).
  ///
  /// When [requireLower] is set, sofa berths are only taken from lower-position
  /// cells; used while a priority member is claiming the lower-berth budget on a
  /// chosen bus.
  static bool _placeOnBus({
    required Passenger passenger,
    required List<_PendingLine> pending,
    required String busId,
    required _PlanState state,
    required List<PlacementReason> reasons,
    required bool priority,
    required bool requireLower,
    required String? groupLabel,
    bool allowStrangerShare = false,
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
          requireLower: requireLower,
          groupLabel: groupLabel,
          allowStrangerShare: allowStrangerShare,
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
    required bool requireLower,
    required String? groupLabel,
    bool allowStrangerShare = false,
  }) {
    final reasonTag = _reasonPrefix(priority, groupLabel);
    // The requester's group drives the stranger-share rule on doubles: a member
    // may auto-share only with another member of the SAME non-null group.
    final reqGroup = passenger.groupId;
    // A priority placement that is not ALREADY pinned to lower-only should still
    // prefer lower-berth sofas over upper ones, so an approved-priority passenger
    // lands on a lower berth whenever one is free.
    final preferLower = priority && !requireLower;
    // Leg-aware capacity: this passenger only consumes the leg(s) their
    // tripType travels (outbound-only = GO, return-only = RETURN, round-trip =
    // BOTH). A berth is takeable only when free on EVERY leg in [legs], so a
    // disjoint-leg passenger can reuse a berth a one-way passenger already holds.
    final legs = TripLeg.forTrip(passenger.tripType);

    switch (line.seatType) {
      case SeatType.seater:
        final cell = state.takeFreeCell(
          busId,
          type: SeatType.seater,
          position: null,
          lowerOnly: false,
          legs: legs,
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
        // Non-priority placements honor the lower-sofa reserve so approved
        // priority passengers keep first claim on the lower berths (goal 1 over
        // goal 2).
        final single = state.takeFreeCell(
          busId,
          type: SeatType.singleSofa,
          position: line.position,
          lowerOnly: requireLower,
          legs: legs,
          guardLowerReserve: !priority,
          preferLower: preferLower,
        );
        if (single != null) {
          state.assign(passenger.id, busId, single.seatId!);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: single.seatId!,
            passengerId: passenger.id,
            reason: _sofaReason(
              reasonTag,
              priority: priority,
              lower: state.isLowerSofa(busId, single.seatId!),
              detail:
                  'type match: ${seatTypeLabel(SeatType.singleSofa, single.position)}',
            ),
          ));
          return 1;
        }
        final halfDouble = state.takeHalfDouble(
          busId,
          position: line.position,
          lowerOnly: requireLower,
          legs: legs,
          requesterGroupId: reqGroup,
          guardLowerReserve: !priority,
          preferLower: preferLower,
          allowStrangerShare: allowStrangerShare,
        );
        if (halfDouble != null) {
          state.assign(passenger.id, busId, halfDouble.seatId!,
              groupId: reqGroup, legs: legs);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: halfDouble.seatId!,
            passengerId: passenger.id,
            reason: _sofaReason(
              reasonTag,
              priority: priority,
              lower: state.isLowerSofa(busId, halfDouble.seatId!),
              detail: 'single on half of a Double Sofa',
            ),
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
          lowerOnly: requireLower,
          legs: legs,
          guardLowerReserve: !priority,
          preferLower: preferLower,
        );
        if (whole != null) {
          // A doubleSofa cell = two berths held by one passenger. One reason
          // entry per berth so every assignment maps to a rationale.
          final wholeReason = _sofaReason(
            reasonTag,
            priority: priority,
            lower: state.isLowerSofa(busId, whole.seatId!),
            detail:
                'type match: ${seatTypeLabel(SeatType.doubleSofa, whole.position)} (whole)',
          );
          state.assign(passenger.id, busId, whole.seatId!,
              groupId: reqGroup, legs: legs);
          reasons.add(PlacementReason(
            busId: busId,
            seatId: whole.seatId!,
            passengerId: passenger.id,
            reason: wholeReason,
          ));
          state.assign(passenger.id, busId, whole.seatId!,
              groupId: reqGroup, legs: legs);
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
              lowerOnly: requireLower,
              legs: legs,
              guardLowerReserve: !priority,
              preferLower: preferLower,
            ) ??
            state.takeHalfDouble(busId,
                position: null,
                lowerOnly: requireLower,
                legs: legs,
                requesterGroupId: reqGroup,
                guardLowerReserve: !priority,
                preferLower: preferLower,
                allowStrangerShare: allowStrangerShare);
        if (first == null) return null;
        final second = state.takeFreeCell(
              busId,
              type: SeatType.singleSofa,
              position: null,
              lowerOnly: requireLower,
              legs: legs,
              guardLowerReserve: !priority,
              preferLower: preferLower,
            ) ??
            state.takeHalfDouble(busId,
                position: null,
                lowerOnly: requireLower,
                legs: legs,
                requesterGroupId: reqGroup,
                guardLowerReserve: !priority,
                preferLower: preferLower,
                allowStrangerShare: allowStrangerShare);
        if (second == null) {
          // Only one single available — can't satisfy a double line by
          // cross-fill. Release the first so we don't strand it.
          state.release(busId, first.seatId!, legs);
          return null;
        }
        state.assign(passenger.id, busId, first.seatId!,
            groupId: reqGroup, legs: legs);
        state.assign(passenger.id, busId, second.seatId!,
            groupId: reqGroup, legs: legs);
        reasons.add(PlacementReason(
          busId: busId,
          seatId: first.seatId!,
          passengerId: passenger.id,
          reason: _sofaReason(
            reasonTag,
            priority: priority,
            lower: state.isLowerSofa(busId, first.seatId!),
            detail: 'cross-fill: 2 singles satisfy a Double Sofa line',
          ),
        ));
        reasons.add(PlacementReason(
          busId: busId,
          seatId: second.seatId!,
          passengerId: passenger.id,
          reason: _sofaReason(
            reasonTag,
            priority: priority,
            lower: state.isLowerSofa(busId, second.seatId!),
            detail: 'cross-fill: 2 singles satisfy a Double Sofa line',
          ),
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
    // Leg-aware: capacity is "free" only on the leg(s) THIS passenger travels.
    // A berth whose sole free slot is on a leg this passenger does not use is
    // not capacity for them. With this view, overflowWaitlist fires only when
    // there is genuinely zero berth-leg they could occupy anywhere; otherwise a
    // compatible-but-wrong-type seat exists → seatTypeUnavailable.
    final legs = TripLeg.forTrip(passenger.tripType);
    final reqGroup = passenger.groupId;
    final anyFreeCapacity =
        state.buses.any((b) => state.freeBerths(b.id, legs) > 0);
    for (final line in pending) {
      if (line.remaining <= 0) continue;
      final rl = RequestLine(
        seatType: line.seatType,
        position: line.position,
        qty: line.remaining,
      );
      // STRANGER-SHARE: this passenger could ONLY be seated by sharing a Double
      // Sofa whose other berth an unrelated passenger already holds (a single
      // line takes one such berth; a double line would cross-fill onto one).
      // The engine refuses to auto-pair strangers, so surface it for the agent
      // to broker rather than as a generic seat/overflow miss.
      final blockedShare = (line.seatType == SeatType.singleSofa &&
              state.hasBlockedShareDouble(legs, reqGroup,
                  position: line.position)) ||
          (line.seatType == SeatType.doubleSofa &&
              state.hasBlockedShareDouble(legs, reqGroup));
      if (blockedShare) {
        exceptions.add(SeatingException(
          type: SeatingExceptionType.sharedDoubleNeedsReview,
          passengerId: passenger.id,
          groupId: reqGroup,
          requestLine: rl,
          message:
              '${_name(passenger)} can only be seated by sharing a Double Sofa '
              'with another passenger — confirm the pairing.',
        ));
      } else if (!anyFreeCapacity) {
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

    // A priority passenger who got seated but not on a lower berth.
    if (priority &&
        _remaining(pending) == 0 &&
        !state.hasLowerSofa(passenger.id)) {
      exceptions.add(SeatingException(
        type: SeatingExceptionType.priorityNoLowerBerth,
        passengerId: passenger.id,
        message:
            'Approved-priority ${_name(passenger)} was seated, but no lower '
            'berth was available.',
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
                state.tryClaimPartnerBerth(
                    g.busId, g.seatId, TripLeg.forTrip(p.tripType))) {
              state.assign(p.id, g.busId, g.seatId,
                  groupId: p.groupId, legs: TripLeg.forTrip(p.tripType));
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
  /// lower-sofa reserve for approved-priority demand.
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

  /// Build a sofa placement reason. When an approved-priority passenger lands
  /// on a lower berth, the rationale reads "`prefix` lower berth"; otherwise it
  /// keeps the type-match [detail].
  static String _sofaReason(
    String reasonTag, {
    required bool priority,
    required bool lower,
    required String detail,
  }) {
    if (priority && lower) return '$reasonTag lower berth';
    return '$reasonTag $detail';
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

/// One held berth on a doubleSofa cell, tagged with its holder's group and the
/// legs they travel. Drives the leg-aware stranger-share check: two holders only
/// "sit together" (and so only need agent review when unrelated) when their legs
/// OVERLAP — disjoint-leg holders reuse the cell without ever co-occupying it.
class _Occupant {
  final String? groupId;
  final List<TripLeg> legs;
  const _Occupant(this.groupId, this.legs);
}

/// Per-cell, PER-LEG free-berth accounting for one bus, plus seat metadata.
///
/// Capacity is leg-aware: every berth has a GO slot and a RETURN slot, tracked
/// independently. A round-trip passenger consumes a berth on BOTH legs; a
/// one-way passenger consumes it on only their leg. Because berths within a
/// cell are fungible, a simple per-leg free COUNT gives exactly the desired
/// reuse: a doubleSofa (2 berths) starts GO=2/RETURN=2 and can host, e.g., one
/// outbound-only + one return-only on the SAME berth while a second berth holds
/// a round-trip — never letting either leg-count go negative.
class _BusState {
  final Bus bus;

  /// seatId -> the cell (so we can read type/position/row).
  final Map<String, SeatCell> cells;

  /// seatId -> berths still FREE on the GO (outbound) leg. A doubleSofa starts
  /// at 2; every other seat at 1. Reserved cells start at 0.
  final Map<String, int> freeGoBySeat;

  /// seatId -> berths still FREE on the RETURN leg. Same capacities as GO.
  final Map<String, int> freeReturnBySeat;

  /// seatId -> every passenger berth currently held on that cell, recorded as
  /// (groupId, legs). A `null` group means an UNGROUPED holder. Used only for
  /// doubleSofa cells to enforce the stranger-share rule: a half-double berth
  /// may be granted to a requester only when the cell holds no UNRELATED holder
  /// on a leg the requester also travels. Two passengers on DISJOINT legs reuse
  /// the same cell without ever sitting together, so they never trigger review.
  final Map<String, List<_Occupant>> occupantGroupsBySeat;

  _BusState(this.bus)
      : cells = {},
        freeGoBySeat = {},
        freeReturnBySeat = {},
        occupantGroupsBySeat = {} {
    final layout = bus.layout;
    if (layout == null) return;
    for (final c in layout.grid) {
      if (!c.hasSeat || c.seatId == null) continue;
      cells[c.seatId!] = c;
      final cap = c.seatType == SeatType.doubleSofa ? 2 : 1;
      freeGoBySeat[c.seatId!] = c.reserved ? 0 : cap;
      freeReturnBySeat[c.seatId!] = c.reserved ? 0 : cap;
    }
  }

  _BusState._clone(this.bus, this.cells, Map<String, int> go,
      Map<String, int> ret, Map<String, List<_Occupant>> occ)
      : freeGoBySeat = Map<String, int>.from(go),
        freeReturnBySeat = Map<String, int>.from(ret),
        occupantGroupsBySeat = {
          for (final e in occ.entries) e.key: List<_Occupant>.from(e.value),
        };

  _BusState fork() => _BusState._clone(
      bus, cells, freeGoBySeat, freeReturnBySeat, occupantGroupsBySeat);

  /// The free-berth map for one [leg].
  Map<String, int> _legMap(TripLeg leg) =>
      leg == TripLeg.go ? freeGoBySeat : freeReturnBySeat;

  /// Berths on [seatId] free on EVERY leg in [legs] (the min across them) — the
  /// number a passenger needing exactly [legs] could still claim there.
  int freeForLegs(String seatId, List<TripLeg> legs) {
    if (legs.isEmpty) return 0;
    var min = 1 << 30;
    for (final leg in legs) {
      final f = _legMap(leg)[seatId] ?? 0;
      if (f < min) min = f;
    }
    return min;
  }

  /// Consume [n] berths of [seatId] on each leg in [legs].
  void consume(String seatId, List<TripLeg> legs, int n) {
    for (final leg in legs) {
      final m = _legMap(leg);
      m[seatId] = ((m[seatId] ?? 0) - n).clamp(0, 1 << 30);
    }
  }

  /// Give back [n] berths of [seatId] on each leg in [legs] (capped at cap).
  void giveBack(String seatId, List<TripLeg> legs, int n) {
    final cap = cells[seatId]?.seatType == SeatType.doubleSofa ? 2 : 1;
    for (final leg in legs) {
      final m = _legMap(leg);
      m[seatId] = ((m[seatId] ?? 0) + n).clamp(0, cap);
    }
  }

  /// Record that a passenger with [groupId] travelling [legs] now holds a berth
  /// on [seatId] (one entry per berth). Drives the stranger-share check below.
  void recordOccupant(String seatId, String? groupId, List<TripLeg> legs) {
    (occupantGroupsBySeat[seatId] ??= <_Occupant>[])
        .add(_Occupant(groupId, legs));
  }

  /// Drop the LAST recorded occupant entry for [seatId] (used when a tentative
  /// cross-fill berth is released so its occupancy record is undone too).
  void unrecordOccupant(String seatId) {
    final list = occupantGroupsBySeat[seatId];
    if (list != null && list.isNotEmpty) list.removeLast();
  }

  /// Whether a requester with [requesterGroupId] travelling [legs] may take a
  /// SHARED berth of the doubleSofa [seatId] WITHOUT agent review.
  ///
  /// The check is LEG-AWARE: two passengers only physically SIT TOGETHER when
  /// their legs OVERLAP. A holder whose legs are DISJOINT from the requester's
  /// (e.g. an outbound-only holder vs a return-only requester) is reusing the
  /// cell across separate legs and never co-occupies it, so it never triggers
  /// review. Among holders who DO overlap the requester's legs, the take is
  /// allowed only when every overlapping holder shares the requester's NON-NULL
  /// group (known-related). An ungrouped requester, or any overlapping
  /// ungrouped/other-group holder, makes the pair "strangers" → refused.
  bool canShareDouble(
      String seatId, String? requesterGroupId, List<TripLeg> legs) {
    final holders = occupantGroupsBySeat[seatId];
    if (holders == null || holders.isEmpty) return true; // empty cell.
    for (final h in holders) {
      // Only holders sharing a leg with the requester could sit beside them.
      final overlaps = h.legs.any(legs.contains);
      if (!overlaps) continue;
      // Same non-null group = known-related; anything else is a stranger.
      if (requesterGroupId == null ||
          requesterGroupId.isEmpty ||
          h.groupId != requesterGroupId) {
        return false;
      }
    }
    return true;
  }

  int get rows => bus.layout?.rows ?? 0;

  /// Whether [c] is a LOWER berth — the priority-preferred zone.
  ///
  /// Approved-priority (elderly / sick) passengers are seated on lower berths
  /// first so they need not climb to an upper berth. The lower/upper split is a
  /// sleeper-sofa concept: only sofa cells carry a [SeatPosition]; seaters have
  /// `null` position and are never "lower berths" for this purpose. The agent's
  /// `forward`/premium flag is unrelated to this rule (it drives pricing only).
  bool isLowerBerth(SeatCell c) =>
      isSofa(c.seatType) && c.position == SeatPosition.lower;

  bool isSofa(SeatType? t) =>
      t == SeatType.singleSofa || t == SeatType.doubleSofa;

  /// Free berths across the bus for a passenger needing exactly [legs]. With
  /// [legs] omitted this reports berths free on BOTH legs (the conservative
  /// "fully free" view used for balance ordering — leg-agnostic and stable).
  int freeBerths([List<TripLeg>? legs]) {
    final ls = legs ?? const [TripLeg.go, TripLeg.ret];
    var n = 0;
    for (final id in cells.keys) {
      n += freeForLegs(id, ls);
    }
    return n;
  }

  /// Free LOWER-berth sofa berths — the priority budget. Leg-aware as
  /// [freeBerths]; [legs] omitted means berths free on both legs.
  int freeLowerSofa([List<TripLeg>? legs]) {
    final ls = legs ?? const [TripLeg.go, TripLeg.ret];
    var n = 0;
    for (final e in cells.entries) {
      final c = e.value;
      if (!isSofa(c.seatType) || !isLowerBerth(c)) continue;
      n += freeForLegs(e.key, ls);
    }
    return n;
  }

  /// Seats ordered row-major (low row first) then by seatId for stability.
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

  /// passengerId -> whether they hold at least one LOWER-berth sofa.
  final Map<String, bool> _hasLowerSofa;

  /// How many LOWER-berth sofa berths (across all buses) must be kept free for
  /// still-unplaced approved-priority demand. Non-priority placements may only
  /// dip into lower berths once doing so would NOT drop global free lower-sofa
  /// capacity below this reserve. Goal 1 (priority → lower berth) thus dominates
  /// goal 2 (group adjacency) without any wall-clock/random input.
  int lowerSofaReserve = 0;

  _PlanState(List<Bus> buses)
      : buses = (buses.toList()..sort((a, b) => a.id.compareTo(b.id))),
        _busStates = {
          for (final b in buses) b.id: _BusState(b),
        },
        assignmentsByPassenger = {},
        _hasLowerSofa = {};

  _PlanState._clone(
    this.buses,
    this._busStates,
    this.assignmentsByPassenger,
    this._hasLowerSofa,
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
      Map<String, bool>.from(_hasLowerSofa),
    )..lowerSofaReserve = lowerSofaReserve;
  }

  /// Copy a committed trial's state back into this one.
  void adopt(_PlanState other) {
    _busStates
      ..clear()
      ..addAll(other._busStates);
    assignmentsByPassenger
      ..clear()
      ..addAll(other.assignmentsByPassenger);
    _hasLowerSofa
      ..clear()
      ..addAll(other._hasLowerSofa);
    lowerSofaReserve = other.lowerSofaReserve;
  }

  void seedReserved() {
    // Reserved cells already start at 0 free berths in _BusState; nothing else
    // to do — kept as an explicit step for readability / future hooks.
  }

  /// Seed a locked assignment: reserve its berth and record it verbatim.
  ///
  /// A locked berth only blocks the legs its passenger actually travels: a
  /// one-way locked passenger still leaves the OTHER leg of that berth free for
  /// reuse by a disjoint-leg passenger.
  void seedLocked(String passengerId, SeatAssignment a, List<TripLeg> legs,
      {String? groupId}) {
    final bs = _busStates[a.busId];
    final list = assignmentsByPassenger.putIfAbsent(passengerId, () => []);
    // Preserve the locked entry exactly (including locked:true).
    list.add(a);
    if (bs == null) return;
    if (bs.freeForLegs(a.seatId, legs) > 0) {
      bs.consume(a.seatId, legs, 1);
    }
    final cell = bs.cells[a.seatId];
    if (cell != null && cell.seatType == SeatType.doubleSofa) {
      // A locked double berth is an EXISTING occupant for the stranger-share
      // check — record its holder's group + legs so later half-double takes see
      // it (and disjoint-leg reuse still passes).
      bs.recordOccupant(a.seatId, groupId, legs);
    }
    if (cell != null && bs.isSofa(cell.seatType) && bs.isLowerBerth(cell)) {
      _hasLowerSofa[passengerId] = true;
    }
  }

  SeatCell? cellFor(String busId, String seatId) =>
      _busStates[busId]?.cells[seatId];

  /// Free berths on [busId] for a passenger needing exactly [legs] (omit for
  /// the conservative both-legs view used by balance ordering).
  int freeBerths(String busId, [List<TripLeg>? legs]) =>
      _busStates[busId]?.freeBerths(legs) ?? 0;

  int freeLowerSofa(String busId, [List<TripLeg>? legs]) =>
      _busStates[busId]?.freeLowerSofa(legs) ?? 0;

  /// Free LOWER-berth sofa berths across every bus for a passenger needing
  /// [legs] (omit for the conservative both-legs view that sizes
  /// [lowerSofaReserve]).
  int totalFreeLowerSofa([List<TripLeg>? legs]) =>
      _busStates.values.fold(0, (s, bs) => s + bs.freeLowerSofa(legs));

  /// True when consuming ONE more lower-berth sofa (for a non-priority
  /// placement needing [legs]) would NOT eat into the reserve held for
  /// approved-priority demand. The check is LEG-AWARE: it measures lower-sofa
  /// capacity on the leg(s) actually being taken, so a one-way passenger may
  /// still claim the free leg of a lower berth whose OTHER leg is occupied —
  /// that leg was never part of the priority reserve. A non-priority sofa take
  /// consults this before claiming a lower cell, so priority passengers keep
  /// getting the lower berths first on the legs that are genuinely contended.
  bool _lowerTakeAllowed(List<TripLeg> legs) =>
      totalFreeLowerSofa(legs) - 1 >= lowerSofaReserve;

  bool hasLowerSofa(String passengerId) =>
      _hasLowerSofa[passengerId] ?? false;

  /// True when [seatId] on [busId] is a LOWER-berth sofa cell (the
  /// priority-preferred zone) — used to phrase placement reasons.
  bool isLowerSofa(String busId, String seatId) {
    final bs = _busStates[busId];
    final cell = bs?.cells[seatId];
    if (bs == null || cell == null) return false;
    return bs.isSofa(cell.seatType) && bs.isLowerBerth(cell);
  }

  /// Take a free cell of an exact [type] (+[position] when given) on [busId].
  /// When [lowerOnly], only LOWER-berth cells qualify. Returns null if none.
  /// For a doubleSofa, "free" means BOTH berths are still free (a whole double).
  /// When [guardLowerReserve] is set (a NON-priority sofa placement), a LOWER
  /// berth is skipped unless taking it would still leave enough free lower
  /// berths for outstanding approved-priority demand ([lowerSofaReserve]).
  /// When [preferLower] is set (a priority placement that is NOT already
  /// [lowerOnly]), lower-berth cells are tried first and only then the rest —
  /// so an approved-priority passenger lands on a lower berth whenever one is
  /// free, falling back to an upper berth only if none is.
  SeatCell? takeFreeCell(
    String busId, {
    required SeatType type,
    required SeatPosition? position,
    required bool lowerOnly,
    required List<TripLeg> legs,
    bool guardLowerReserve = false,
    bool preferLower = false,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    final wholeNeeded = type == SeatType.doubleSofa ? 2 : 1;
    // When preferring lower berths, sweep lower cells first, then the rest.
    // Otherwise a single sweep with no lower-berth gate.
    for (final lowerPass in preferLower ? [true, false] : [false]) {
      for (final c in bs._orderedSeats()) {
        if (c.seatType != type) continue;
        if (position != null && c.position != position) continue;
        if (lowerOnly && !bs.isLowerBerth(c)) continue;
        if (preferLower && lowerPass && !bs.isLowerBerth(c)) continue;
        if (guardLowerReserve &&
            bs.isSofa(c.seatType) &&
            bs.isLowerBerth(c) &&
            !_lowerTakeAllowed(legs)) {
          continue;
        }
        // Leg-aware: the cell is takeable only if every leg this passenger
        // needs still has [wholeNeeded] berths free there.
        if (bs.freeForLegs(c.seatId!, legs) >= wholeNeeded) {
          bs.consume(c.seatId!, legs, wholeNeeded);
          return c;
        }
      }
    }
    return null;
  }

  /// Take ONE berth of a doubleSofa cell (a half-double) on [busId], matching
  /// [position] when given. Used for single-on-double and cross-fill.
  /// [preferLower] behaves as in [takeFreeCell]; [legs] gates leg-aware reuse.
  ///
  /// STRANGER-SHARE RULE: a half-double berth is granted only when the cell is
  /// EMPTY or every existing holder shares [requesterGroupId] (a non-null group
  /// = agent-tagged related). A cell whose other berth is held by an UNRELATED
  /// passenger is SKIPPED here — never auto-paired — so the caller can raise
  /// [SeatingExceptionType.sharedDoubleNeedsReview] instead. [sawBlockedShare]
  /// (when given) is set true if at least one candidate cell was skipped ONLY
  /// because of this rule, so the caller can distinguish "no double at all" from
  /// "a double exists but would pair strangers".
  SeatCell? takeHalfDouble(
    String busId, {
    required SeatPosition? position,
    required bool lowerOnly,
    required List<TripLeg> legs,
    String? requesterGroupId,
    bool guardLowerReserve = false,
    bool preferLower = false,
    bool allowStrangerShare = false,
    List<bool>? sawBlockedShare,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    for (final lowerPass in preferLower ? [true, false] : [false]) {
      for (final c in bs._orderedSeats()) {
        if (c.seatType != SeatType.doubleSofa) continue;
        if (position != null && c.position != position) continue;
        if (lowerOnly && !bs.isLowerBerth(c)) continue;
        if (preferLower && lowerPass && !bs.isLowerBerth(c)) continue;
        if (guardLowerReserve && bs.isLowerBerth(c) && !_lowerTakeAllowed(legs)) {
          continue;
        }
        if (bs.freeForLegs(c.seatId!, legs) >= 1) {
          // Hard rule: never auto-share a double with an UNRELATED occupant.
          // [allowStrangerShare] relaxes this for the DETECTION-ONLY trial in
          // _placeGroup that asks "would the group fit if strangers could
          // share?" — it is never used by a committed placement.
          if (!allowStrangerShare &&
              !bs.canShareDouble(c.seatId!, requesterGroupId, legs)) {
            if (sawBlockedShare != null && sawBlockedShare.isNotEmpty) {
              sawBlockedShare[0] = true;
            }
            continue;
          }
          bs.consume(c.seatId!, legs, 1);
          return c;
        }
      }
    }
    return null;
  }

  /// Record a placed berth for a passenger and update lower-sofa tracking.
  ///
  /// [groupId] is the placing passenger's group (null = ungrouped) and [legs]
  /// the legs they travel. For a doubleSofa cell both are recorded as the
  /// berth's occupant tag so the leg-aware stranger-share rule
  /// ([_BusState.canShareDouble]) can see who already holds the cell — and on
  /// which legs. Pass them for every placement so shared-double review stays
  /// exact and disjoint-leg reuse stays allowed.
  void assign(String passengerId, String busId, String seatId,
      {String? groupId, List<TripLeg> legs = const [TripLeg.go, TripLeg.ret]}) {
    final list = assignmentsByPassenger.putIfAbsent(passengerId, () => []);
    list.add(SeatAssignment(busId: busId, seatId: seatId));
    final cell = _busStates[busId]?.cells[seatId];
    final bs = _busStates[busId];
    if (cell != null && bs != null) {
      if (cell.seatType == SeatType.doubleSofa) {
        bs.recordOccupant(seatId, groupId, legs);
      }
      if (bs.isSofa(cell.seatType) && bs.isLowerBerth(cell)) {
        _hasLowerSofa[passengerId] = true;
      }
    }
  }

  /// Claim the remaining free berth of a specific (already-partly-occupied)
  /// double-sofa [seatId] on [busId], for a passenger needing [legs]. Used to
  /// complete a half-locked own-cell double in place. Returns true if a berth
  /// was free on every needed leg and was consumed.
  bool tryClaimPartnerBerth(String busId, String seatId, List<TripLeg> legs) {
    final bs = _busStates[busId];
    if (bs == null) return false;
    final cell = bs.cells[seatId];
    if (cell == null || cell.seatType != SeatType.doubleSofa) return false;
    if (bs.freeForLegs(seatId, legs) < 1) return false;
    bs.consume(seatId, legs, 1);
    return true;
  }

  /// Give back one berth on a cell on each leg in [legs] (cross-fill abort).
  void release(String busId, String seatId, List<TripLeg> legs) {
    final bs = _busStates[busId];
    if (bs == null) return;
    bs.giveBack(seatId, legs, 1);
  }

  /// True when, ANYWHERE across the buses, there is a doubleSofa cell with a
  /// berth still free on every leg in [legs] BUT whose existing occupant is
  /// UNRELATED to a requester with [requesterGroupId] — i.e. the only seat that
  /// could host this passenger is a stranger-shared double the engine refuses to
  /// auto-pair. When [position] is non-null it must match the cell's position
  /// (mirrors a positioned singleSofa line; a null position matches any double).
  /// This is exactly the capacity that [takeHalfDouble] skips for the rule, so
  /// it lets the exception layer report [sharedDoubleNeedsReview] rather than a
  /// generic seat-type/overflow message.
  bool hasBlockedShareDouble(
    List<TripLeg> legs,
    String? requesterGroupId, {
    SeatPosition? position,
  }) {
    for (final bs in _busStates.values) {
      if (_busHasBlockedShareDouble(bs, legs, requesterGroupId,
          position: position)) {
        return true;
      }
    }
    return false;
  }

  /// Same blocked-stranger-double test as [hasBlockedShareDouble] but scoped to
  /// a SINGLE bus [busId]. Used by group placement (a group must fit on ONE bus,
  /// so the relevant capacity is that one candidate bus, not the whole fleet).
  bool hasBlockedShareDoubleOnBus(
    String busId,
    List<TripLeg> legs,
    String? requesterGroupId, {
    SeatPosition? position,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return false;
    return _busHasBlockedShareDouble(bs, legs, requesterGroupId,
        position: position);
  }

  static bool _busHasBlockedShareDouble(
    _BusState bs,
    List<TripLeg> legs,
    String? requesterGroupId, {
    SeatPosition? position,
  }) {
    for (final c in bs.cells.values) {
      if (c.seatType != SeatType.doubleSofa) continue;
      if (position != null && c.position != position) continue;
      if (bs.freeForLegs(c.seatId!, legs) < 1) continue;
      if (!bs.canShareDouble(c.seatId!, requesterGroupId, legs)) return true;
    }
    return false;
  }
}
