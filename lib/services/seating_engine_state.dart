part of 'seating_engine.dart';

// Per-bus and whole-plan mutable seat state used by [SeatingEngine].

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
        int posRank(SeatPosition? p) => switch (p) {
              SeatPosition.upper => 0,
              SeatPosition.lower => 1,
              null => 2,
            };
        final pa = posRank(a.position);
        final pb = posRank(b.position);
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
    // Preserve the locked entry exactly (including locked:true). Stamp the leg
    // from the passed [legs] only when the entry has none recorded yet.
    list.add(a.leg == null ? a.copyWith(leg: TripLeg.tripTypeOf(legs)) : a);
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
    RequestBand? band,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    final wholeNeeded = type == SeatType.doubleSofa ? 2 : 1;
    // When preferring lower berths, sweep lower cells first, then the rest.
    // Otherwise a single sweep with no lower-berth gate.
    for (final lowerPass in preferLower ? [true, false] : [false]) {
      for (final c in bs._orderedSeats()) {
        if (c.seatType != type) continue;
        // Paid-band bind: a rider who bought rows 1-4 may only be placed there.
        if (band != null && !band.covers(c.row)) continue;
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
  /// [SeatingExceptionType.sharedDoubleNeedsReview] instead.
  SeatCell? takeHalfDouble(
    String busId, {
    required SeatPosition? position,
    required bool lowerOnly,
    required List<TripLeg> legs,
    String? requesterGroupId,
    bool guardLowerReserve = false,
    bool preferLower = false,
    bool allowStrangerShare = false,
    RequestBand? band,
  }) {
    final bs = _busStates[busId];
    if (bs == null) return null;
    for (final lowerPass in preferLower ? [true, false] : [false]) {
      for (final c in bs._orderedSeats()) {
        if (c.seatType != SeatType.doubleSofa) continue;
        if (band != null && !band.covers(c.row)) continue;
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
    list.add(SeatAssignment(
        busId: busId, seatId: seatId, leg: TripLeg.tripTypeOf(legs)));
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
