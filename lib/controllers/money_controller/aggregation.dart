part of '../money_controller.dart';

/// Pure read-side summaries over the held rows + ledger rollups.
mixin _MoneyAggregation on _MoneyControllerBase {
  // ── Aggregation ───────────────────────────────────────────

  /// Per-bus owner rent (`Bus.busPrice`) for the loaded tour, keyed by bus id.
  /// The rent is auto-counted as a `busOwner` expense in the summaries (single
  /// source of truth — never a DB expense row). Resolves from the loaded tour's
  /// buses via [TourController]; guards for a missing tour / not-registered
  /// controller by treating every rent as 0, so it never throws.
  Map<String, double> _busRents() {
    final buses = _loadedTour()?.buses;
    if (buses == null) return const {};
    return {for (final b in buses) b.id: b.busPrice};
  }

  /// How many of the tour's buses have no owner rent recorded — see
  /// [TourMoneySummary.busesMissingRent] for why it matters. Reads the tour's
  /// own bus list (not the ledger roll-ups) so both aggregation paths agree,
  /// and so a bus the ledger has no rows for yet is still checked.
  ///
  /// An unresolvable fleet yields an empty map and therefore 0 — "unknown",
  /// never a false accusation, matching [_busRents]'s own guard.
  int _busesMissingRent() =>
      _busRents().values.where((rent) => rent <= 0).length;

  /// Per-bus BILLED revenue — the sum of fares owed by every passenger seated
  /// on the bus (via [Bus.amountDueFor], which is already bus-scoped and trip-
  /// factor aware). This is ACCRUAL revenue: what the trip earns regardless of
  /// how much cash has been collected, so the P&L can show a "true" profit.
  /// Keyed by bus id; guards a missing tour / unregistered controller with 0.
  Map<String, double> _billedRevenues() {
    final tour = _loadedTour();
    if (tour == null) return const {};
    return {
      for (final b in tour.buses)
        b.id: tour.passengers.fold(0.0, (sum, p) => sum + b.amountDueFor(p)),
    };
  }

  /// Bus objects for the loaded tour, keyed by bus id — the source of each bus's
  /// per-seat fare ([Bus.amountDueForSeat]) so to-collect can price seated riders
  /// who have no collection row yet. Same guards as [_busRents] (missing tour /
  /// unregistered controller → empty).
  Map<String, Bus> _busById() {
    final buses = _loadedTour()?.buses;
    if (buses == null) return const {};
    return {for (final b in buses) b.id: b};
  }

  /// The loaded tour's passengers, or empty when the tour/controller is missing.
  List<Passenger> _tourPassengers() => _loadedTour()?.passengers ?? const [];

  /// This bus's still-owed / still-owed-back, priced seat by seat against the
  /// LIVE fare — the same [busSeatAr] walk the collection roster,
  /// [BusMoneySummary.compute] and the handler all use.
  ///
  /// The ledger cannot answer this. `ar.rider` lines are passenger-scoped and
  /// carry no `bus_id` (063's header says so explicitly), so the old code
  /// reconstructed a per-bus figure by apportioning each rider's TOUR-WIDE
  /// `finance_rider_balance` across their buses by billed share. Two things went
  /// wrong with that. A fraction of one rider's balance landed on a bus whose own
  /// seat was square — the "₹449 to return" with nobody in the To-return filter.
  /// And the posted fare it divides up goes stale whenever a bus is re-priced,
  /// because nothing re-posted it (migration 092 fixes that half).
  ///
  /// Cash, billed revenue, expenses and handovers still come from the ledger
  /// rollup: those are posted facts, not derivations, and the ledger is the
  /// better source for them.
  ///
  /// Falls back to the rollup's own figures when the bus cannot be priced —
  /// a bus the tour no longer lists has no [Bus] to read a fare from.
  ({double toCollect, double toReturn})? _seatArForBus(String busId) {
    final bus = _busById()[busId];
    if (bus == null) return null;
    return busSeatAr(
      busId: busId,
      passengers: _tourPassengers(),
      collections: collections,
      dueForSeat: bus.amountDueForSeat,
    );
  }

  BusMoneySummary summaryForBus(String busId) {
    final bus = _busById()[busId];
    final rent = bus?.busPrice ?? _busRents()[busId] ?? 0;
    final includesFuel = bus?.rentIncludesFuel ?? true;

    BusMoneySummary computed() => BusMoneySummary.compute(
      busId: busId,
      collections: collections.toList(),
      expenses: expenses.toList(),
      handovers: handovers.toList(),
      incomes: incomes.toList(),
      busRent: rent,
      rentIncludesFuel: includesFuel,
      revenueBilled: _billedRevenues()[busId] ?? 0,
      passengers: _tourPassengers(),
      dueForSeat: bus?.amountDueForSeat,
    );

    if (_ledgerReady) {
      final rollup = _ledgerByBus[busId];
      if (rollup != null) {
        final ar =
            _seatArForBus(busId) ??
            (toCollect: rollup.toCollect, toReturn: rollup.toReturn);
        final base = computed();
        final busRent = rent > 0 ? rent : rollup.rent;
        // The LEDGER is the authority on how much was spent on the ground (it
        // posts every expense row as one `expense.ground` figure); the
        // categorised legacy rows only say how much of that was diesel / driver
        // / owner advance, which the pakku-bhadu rule absorbs into the rent
        // (see [BusExpenseRollup]; on a non-pakku bus `base` already moved
        // diesel + driver into `other`, so only advances absorb). Keep the
        // ledger's ground total — dropping it zeroed the expenses of a bus the
        // tour no longer lists (no Bus, no rows) while `orphanExpenses` still
        // read the ledger, so the trip total came out BELOW its own orphan.
        //
        // Owner payable applies the same rule. The ledger's `payable.owner`
        // only ever carries the rent accrual (072), never the diesel / driver /
        // advances paid along the way, so preferring it showed the full rent
        // as "remaining" on every ledgered bus. Finance runs this SAME helper.
        final r = BusExpenseRollup.fromLedger(
          ground: rollup.groundExpenses,
          busRent: busRent,
          fuel: base.fuelTotal,
          driver: base.driverTotal,
          ownerAdvance: base.ownerAdvanceTotal,
          rentIncludesFuel: includesFuel,
        );
        return base.copyWith(
          collected: rollup.collected,
          revenueBilled: rollup.billed,
          handedOver: rollup.handedOver,
          toReturnTotal: ar.toReturn,
          toCollectTotal: ar.toCollect,
          income: rollup.income,
          busRent: busRent,
          fuelTotal: r.fuelTotal,
          driverTotal: r.driverTotal,
          ownerAdvanceTotal: r.ownerAdvanceTotal,
          otherExpensesTotal: r.otherExpensesTotal,
          busMalikPayable: r.busMalikPayable,
          expensesTotal: r.expensesTotal,
        );
      }
      // Ledger loaded but holding no lines for this bus — fall through to the
      // legacy recompute below.
      //
      // An empty answer is NOT proof the bus has no money. The write-through
      // triggers (062) may not be deployed, or the backfill (058) never run, in
      // which case the ledger is simply blank while the legacy tables — already
      // fetched, sitting in the obs lists right here — hold the real cash. This
      // used to return hard zeros, which is what rendered a ₹0 Profit & Loss
      // for a tour with money on it, and worse than an obviously-broken board:
      // rent still came through from the in-memory tour, so the trip read as a
      // clean rent-sized LOSS rather than as a failure.
      //
      // When the bus genuinely has nothing, the legacy compute returns the same
      // zeros (plus rent and billed revenue), so falling back is never worse
      // than the figure it replaces.
    }
    return computed();
  }

  TourMoneySummary tourSummary() {
    if (_ledgerReady) {
      final busById = _busById();
      final knownIds = busById.keys.toSet();
      // Buses the LEDGER carries money for that the tour no longer lists. Their
      // cash is real and must stay inside the trip total — dropping it (which
      // is what iterating `busById.keys` alone did) makes money silently vanish
      // from the books with nothing on screen to explain the gap. They are
      // summed in below AND broken out as `orphan*` so the arithmetic still
      // reconciles, exactly as the legacy path does.
      //
      // Only meaningful when we actually resolved a fleet: an empty `busById`
      // means the tour/controller wasn't available, NOT that the tour has no
      // buses, so every ledger bus would look orphaned.
      final orphanIds = knownIds.isEmpty
          ? const <String>[]
          : [
              for (final id in _ledgerByBus.keys)
                if (!knownIds.contains(id)) id,
            ];
      final ids = knownIds.isEmpty
          ? _ledgerByBus.keys.toList()
          : [...knownIds, ...orphanIds];
      final buses = summariesForBuses(ids);
      var toCollect = 0.0;
      var toReturn = 0.0;
      for (final s in buses) {
        toCollect += s.toCollectTotal;
        toReturn += s.toReturnTotal;
      }
      // A rider seated on NO bus is deliberately not added here. To-collect is
      // now priced from the seats someone actually holds ([busSeatAr]), and an
      // unseated rider holds none — so they are billed nothing and owe nothing.
      // Cash they already paid does not vanish: it stays in `collected` and is
      // called out separately as [TourMoneySummary.totalDetachedCash] below.
      // The old ledger-AR reading counted them, which is how a rider who had
      // been unseated kept generating a refund the roster could not explain.

      var orphanCollected = 0.0;
      var orphanExpenses = 0.0;
      var orphanIncome = 0.0;
      for (final id in orphanIds) {
        final r = _ledgerByBus[id]!;
        orphanCollected += r.collected;
        orphanExpenses += r.expensesTotal;
        orphanIncome += r.income;
      }

      return TourMoneySummary(
        totalCollected: buses.fold(0.0, (s, b) => s + b.collected),
        totalRevenueBilled: buses.fold(0.0, (s, b) => s + b.revenueBilled),
        totalExpenses: buses.fold(0.0, (s, b) => s + b.expensesTotal),
        totalHandedOver: buses.fold(0.0, (s, b) => s + b.handedOver),
        totalToReturn: toReturn,
        totalToCollect: toCollect,
        totalIncome: buses.fold(0.0, (s, b) => s + b.income),
        totalBusRent: buses.fold(0.0, (s, b) => s + b.busRent),
        // Not `totalExpenses − totalBusRent`: diesel / driver / advances absorbed
        // into a pakku rent would vanish from the handover expectation.
        groundExpensesTotal: buses.fold<double>(
          0.0,
          (s, b) => s + b.groundExpenses,
        ),
        busesMissingRent: _busesMissingRent(),
        orphanCollected: orphanCollected,
        orphanExpenses: orphanExpenses,
        orphanIncome: orphanIncome,
        totalDetachedCash: _detachedCash(
          collections,
          (p) => p.assignedSeats.isNotEmpty,
        ),
      );
    }

    // Roll to-collect up from the per-bus summaries so the tour total counts
    // seated-but-uncollected riders exactly the same way each bus row does —
    // admin, handler and tour totals then all agree. Fall back to the recorded
    // shortfalls (null override) when no tour/buses are resolvable.
    final busById = _busById();
    // One pass over the per-bus summaries feeds BOTH overrides — computing them
    // separately would walk every bus twice, and leaving either out lets the
    // trip total drift from the rows printed beneath it.
    final perBus = busById.isEmpty
        ? null
        : summariesForBuses(busById.keys).toList();
    final expensesFromBuses = perBus?.fold<double>(
      0,
      (sum, s) => sum + s.expensesTotal,
    );

    return TourMoneySummary.compute(
      collections: collections.toList(),
      expenses: expenses.toList(),
      handovers: handovers.toList(),
      incomes: incomes.toList(),
      totalExpensesOverride: expensesFromBuses,
      // Only claim to know the fleet when we actually resolved one. An empty
      // busById here means the tour/controller wasn't resolvable, NOT that the
      // tour has no buses — passing an empty set then would flag every single
      // row as orphaned.
      knownBusIds: busById.isEmpty ? null : busById.keys.toSet(),
      busRentsTotal: _busRents().values.fold(0.0, (sum, r) => sum + r),
      busesMissingRent: _busesMissingRent(),
      totalRevenueBilled: _billedRevenues().values.fold(
        0.0,
        (sum, r) => sum + r,
      ),
      toCollectTotal: perBus?.fold<double>(
        0,
        (sum, s) => sum + s.toCollectTotal,
      ),
      toReturnTotal: perBus?.fold<double>(
        0,
        (sum, s) => sum + s.toReturnTotal,
      ),
      // Trip level: only a rider seated on NO bus at all is stranded here — one
      // merely moved between buses is still on the trip and still counted once.
      detachedCashTotal: _detachedCash(
        collections,
        (p) => p.assignedSeats.isNotEmpty,
      ),
    );
  }

  /// Cash from payers that [isStillSeated] rejects — the shared engine behind
  /// [BusMoneySummary.detachedCash] at the handler and tour levels, where the
  /// "still seated" test spans several buses and so can't be answered per bus.
  ///
  /// Returns 0 when the tour's roster isn't resolvable: with nobody to check
  /// against, every row would look detached, and a false "₹X is stranded" alarm
  /// is worse than staying quiet.
  double _detachedCash(
    Iterable<Collection> rows,
    bool Function(Passenger p) isStillSeated,
  ) {
    final passengers = _tourPassengers();
    if (passengers.isEmpty) return 0;
    final seated = <String>{
      for (final p in passengers)
        if (isStillSeated(p)) p.id,
    };
    return rows
        .where((c) => !seated.contains(c.passengerId))
        .fold(0.0, (sum, c) => sum + c.netCollected);
  }

  /// Read-only summaries for every bus id in [busIds], in the order given.
  /// Pure aggregation over the currently held rows — no fetch. Used by the
  /// tour money board to render one row per bus without each row recomputing
  /// the same `where` scans against the shared lists.
  List<BusMoneySummary> summariesForBuses(Iterable<String> busIds) => [
        for (final id in busIds) summaryForBus(id),
      ];

  /// Per-handler money rollups for the loaded tour. A handler runs whole buses
  /// ([Bus.handlerPassengerId]), so each handler's P&L is the sum of their
  /// buses' [BusMoneySummary]s. Buses with no handler fall into a single
  /// null-keyed bucket (kept LAST) so unassigned buses are never dropped.
  /// First-seen handler order is preserved for a stable UI.
  List<HandlerMoneySummary> handlerSummaries() {
    final tour = _loadedTour();
    if (tour == null) return const [];

    final handlerByBus = {
      for (final b in tour.buses) b.id: b.handlerPassengerId,
    };
    final summaries = summariesForBuses(tour.buses.map((b) => b.id));

    final order = <String?>[];
    final grouped = <String?, List<BusMoneySummary>>{};
    for (final s in summaries) {
      final h = handlerByBus[s.busId];
      if (!grouped.containsKey(h)) {
        grouped[h] = [];
        order.add(h);
      }
      grouped[h]!.add(s);
    }
    // Non-null handlers first (in first-seen order), unassigned bucket last.
    final ordered = [
      ...order.where((h) => h != null),
      ...order.where((h) => h == null),
    ];
    return [
      for (final h in ordered)
        HandlerMoneySummary.fromBuses(
          h,
          grouped[h]!,
          // Scoped to THIS handler's fleet: a rider moved between two buses
          // the same handler runs never left their care, so they are not
          // stranded cash here even though each bus sees them as detached.
          detachedCash: _detachedCash(
            collections.where(
              (c) => grouped[h]!.any((s) => s.busId == c.busId),
            ),
            (p) => p.assignedSeats.any(
              (a) => grouped[h]!.any((s) => s.busId == a.busId),
            ),
          ),
        ),
    ];
  }

  /// Classifies a bus's money state for the board's attention ring. Pure
  /// read-only derivation from a [BusMoneySummary]:
  ///   * [BusMoneyState.actionNeeded] — handler still owes a handover
  ///     (outstanding > 0) OR a passenger shortfall is still to be collected.
  ///   * [BusMoneyState.settled] — money has moved (collected or handed over)
  ///     and nothing is outstanding / to collect / to return.
  ///   * [BusMoneyState.neutral] — nothing has happened on this bus yet.
  /// A small epsilon absorbs floating-point dust so a fully-square bus never
  /// reads as action-needed.
  BusMoneyState stateForBusSummary(BusMoneySummary s) {
    const eps = 0.005;
    final outstanding = s.outstandingHandover > eps;
    final toCollect = s.toCollectTotal > eps;
    final toReturn = s.toReturnTotal > eps;
    // Real money still owed: billed revenue not yet collected (catches seated
    // riders billed but uncollected, whether or not a shortfall row exists).
    final revenueOutstanding = (s.revenueBilled - s.collected) > eps;
    // Cash taken in doesn't cover the trip's costs (the owner's rent included —
    // the ADMIN pays that out of the handover), so the bus is running at a loss.
    // Reads off the cash net, NOT the handover: the handover figure is
    // rent-free by design, so it would never surface this.
    final cannotCoverRent = s.netCollected < -eps;
    if (outstanding || toCollect || revenueOutstanding || cannotCoverRent) {
      return BusMoneyState.actionNeeded;
    }

    final hasActivity = s.collected > eps || s.handedOver > eps;
    if (hasActivity && !toReturn) return BusMoneyState.settled;
    return BusMoneyState.neutral;
  }
}
