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
import '../models/request_band.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

part 'seating_engine_types.dart';
part 'seating_engine_pending.dart';
part 'seating_engine_state.dart';

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
    // journeyDone riders have FINISHED travelling. They are off the bus, so the
    // engine must never re-seat them or raise an exception for them; otherwise a
    // completed GO leg resurfaces them as pending demand and a "needs decision".
    //
    // Excluded from DEMAND is not the same as "their berths are free" — see the
    // retained-berth seed below. `completeOutboundLeg` frees a retired rider's
    // seats, but a per-seat leg cancellation deliberately does NOT: a round-trip
    // rider whose return is struck keeps the GO berth they actually rode.
    final sorted = [
      for (final p in passengers)
        if (!p.isWaitlisted && !p.journeyDone) p,
    ]..sort((a, b) => a.id.compareTo(b.id));

    // Riders excluded above who STILL HOLD berths. Their seats are history, not
    // vacancy: the berth is spoken for on the leg they rode it, and only the
    // OTHER leg is resellable.
    final retainedHolders = [
      for (final p in passengers)
        if (p.journeyDone && p.assignedSeats.isNotEmpty) p,
    ]..sort((a, b) => a.id.compareTo(b.id));

    // ── 0. Seed reserved + locked ─────────────────────────────────────────
    // Reserved seats are marked occupied so nothing auto-fills them.
    state.seedReserved();
    // Locked assignments are preserved verbatim and their berths reserved.
    //
    // The leg a locked berth blocks now lives per request LINE, so we recover it
    // by matching each locked seat to one of the passenger's request lines of
    // the SAME seat type (each line consumed once). A locked berth on a cell
    // type the passenger has no matching line for (e.g. legacy data) falls back
    // to the coarse [Passenger.derivedTripType] summary — never the removed-
    // meaning per-passenger `tripType`.
    for (final p in sorted) {
      // Mutable remaining-leg buckets per (seatType) so two locked berths of the
      // same type consume two distinct lines in order.
      final legBuckets = _LockedLegResolver(p);
      for (final a in p.assignedSeats) {
        if (!a.locked) continue;
        final cell = state.cellFor(a.busId, a.seatId);
        final legs = legBuckets.legsFor(cell?.seatType);
        state.seedLocked(p.id, a, legs, groupId: p.groupId);
        reasons.add(PlacementReason(
          busId: a.busId,
          seatId: a.seatId,
          passengerId: p.id,
          reason: 'locked',
        ));
      }
    }

    // Seed the berths retired riders still hold, so nothing is placed on top of
    // them. Seeded like a locked berth (same primitive) but WITHOUT recording a
    // PlacementReason: the engine did not place these and must not claim them.
    //
    // The seed is leg-scoped, which is the whole point. A rider who rode GO and
    // had their return struck holds a berth stamped `outboundOnly`, so only the
    // GO half of that tile is consumed and the RETURN half stays sellable —
    // exactly the "cancel the return, resell the seat home" flow. Without this
    // the berth read as wholly free and the engine would re-let it on BOTH legs,
    // seating a stranger on top of someone the chart still shows.
    for (final p in retainedHolders) {
      final legBuckets = _LockedLegResolver(p);
      for (final a in p.assignedSeats) {
        final cell = state.cellFor(a.busId, a.seatId);
        // Prefer the berth's OWN stamped leg; fall back to the request-line
        // queue only for legacy berths that never recorded one.
        final legs = a.leg != null
            ? TripLeg.forTrip(a.leg!)
            : legBuckets.legsFor(cell?.seatType);
        state.seedLocked(p.id, a, legs, groupId: p.groupId);
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
        final orderedMembers = _membersPriorityFirst(members);
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
    final orderMembers = _membersPriorityFirst(members);
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
        // by a stranger-double on this bus → this member needs review. The
        // blocking leg is read PER LINE (leg lives on the request line now), so
        // a one-leg line is only blocked by a stranger-double on its own leg.
        final blocked = pending.any((l) =>
            l.remaining > 0 &&
            ((l.seatType == SeatType.singleSofa &&
                    strict.hasBlockedShareDoubleOnBus(
                        bus.id, l.tripLegs, m.groupId,
                        position: l.position)) ||
                (l.seatType == SeatType.doubleSofa &&
                    strict.hasBlockedShareDoubleOnBus(
                        bus.id, l.tripLegs, m.groupId))));
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
    // Leg-aware capacity: this LINE only consumes the leg(s) it travels
    // (outbound-only = GO, return-only = RETURN, round-trip = BOTH). The leg now
    // lives on the request LINE, not the whole passenger, so a single passenger
    // can hold a round-trip line and a one-leg line at once. A berth is takeable
    // only when free on EVERY leg in [legs], so a disjoint-leg line can reuse a
    // berth a one-way line already holds.
    final legs = line.tripLegs;

    switch (line.seatType) {
      case SeatType.seater:
        final cell = state.takeFreeCell(
          busId,
          type: SeatType.seater,
          position: null,
          lowerOnly: false,
          legs: legs,
          band: line.band,
        );
        if (cell == null) return null;
        state.assign(passenger.id, busId, cell.seatId!, legs: legs);
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
          band: line.band,
          guardLowerReserve: !priority,
          preferLower: preferLower,
        );
        if (single != null) {
          state.assign(passenger.id, busId, single.seatId!, legs: legs);
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
          band: line.band,
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
          band: line.band,
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
          // Both berths: assign then record, twice (same order as before).
          for (var berth = 0; berth < 2; berth++) {
            state.assign(passenger.id, busId, whole.seatId!,
                groupId: reqGroup, legs: legs);
            reasons.add(PlacementReason(
              busId: busId,
              seatId: whole.seatId!,
              passengerId: passenger.id,
              reason: wholeReason,
            ));
          }
          return 1;
        }
        // Cross-fill: two single berths (single sofas or half-doubles) satisfy
        // ONE doubleSofa line. The double line's position only gates the WHOLE
        // double claim above; for cross-fill the substitute singles' positions
        // are irrelevant (a Double Sofa is one bench seating two), so we pass
        // position: null — mirroring the UI's cross-fill drain.
        SeatCell? takeCrossFillBerth() =>
            state.takeFreeCell(
              busId,
              type: SeatType.singleSofa,
              position: null,
              lowerOnly: requireLower,
              legs: legs,
              band: line.band,
              guardLowerReserve: !priority,
              preferLower: preferLower,
            ) ??
            state.takeHalfDouble(busId,
                position: null,
                lowerOnly: requireLower,
                legs: legs,
                band: line.band,
                requesterGroupId: reqGroup,
                guardLowerReserve: !priority,
                preferLower: preferLower,
                allowStrangerShare: allowStrangerShare);
        final first = takeCrossFillBerth();
        if (first == null) return null;
        final second = takeCrossFillBerth();
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
        for (final berth in [first, second]) {
          reasons.add(PlacementReason(
            busId: busId,
            seatId: berth.seatId!,
            passengerId: passenger.id,
            reason: _sofaReason(
              reasonTag,
              priority: priority,
              lower: state.isLowerSofa(busId, berth.seatId!),
              detail: 'cross-fill: 2 singles satisfy a Double Sofa line',
            ),
          ));
        }
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
    // Leg-aware, PER LINE: capacity is "free" only on the leg(s) THE LINE
    // travels (the leg now lives on the request line, not the passenger). A
    // berth whose sole free slot is on a leg this line does not use is not
    // capacity for it. With this view, overflowWaitlist fires only when there is
    // genuinely zero berth-leg the line could occupy anywhere; otherwise a
    // compatible-but-wrong-type seat exists → seatTypeUnavailable.
    final reqGroup = passenger.groupId;
    for (final line in pending) {
      if (line.remaining <= 0) continue;
      final legs = line.tripLegs;
      final anyFreeCapacity =
          state.buses.any((b) => state.freeBerths(b.id, legs) > 0);
      final rl = RequestLine(
        seatType: line.seatType,
        position: line.position,
        qty: line.remaining,
        leg: line.leg,
      );
      // STRANGER-SHARE: this line could ONLY be seated by sharing a Double Sofa
      // whose other berth an unrelated passenger already holds on an OVERLAPPING
      // leg (a single line takes one such berth; a double line would cross-fill
      // onto one). The engine refuses to auto-pair strangers, so surface it for
      // the agent to broker rather than as a generic seat/overflow miss.
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
}
