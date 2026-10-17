part of '../money_controller.dart';

/// Optimistic writes: collections, expenses, incomes, handovers, and the
/// post-seat-move collection reconcile.
mixin _MoneyWrites on _MoneyLoad {
  // ── Collections ───────────────────────────────────────────

  /// The EXISTING collection row a tap on [seatId] must write into.
  ///
  /// Resolves through [collectionRowForSeat], not the strict
  /// (passenger, bus, seat) triple. Matching on the triple meant a rider who
  /// paid on one seat and later moved to another MISSED their own row, so the
  /// collect sheet opened blank and the save wrote a SECOND row — which 062's
  /// collections_ledger_sync posted to the ledger again, and both money engines
  /// fold per row. The admin board then showed double the cash in hand. Same
  /// hole, same fix, as the handler chart's `_collectionFor`.
  Collection? collectionFor(Passenger passenger, String busId, String seatId) =>
      collectionRowForSeat(
        passenger: passenger,
        busId: busId,
        seatId: seatId,
        collections: collections,
      );

  Future<void> upsertCollection(Collection c) => _upsertRow(
        collections,
        c,
        isRow: (e) => e.id == c.id,
        table: 'collections',
        entityId: c.id,
        data: c.toMap,
        tourId: c.tourId,
        errorKey: 'errors.save_collection',
        invalidatesFinance: true,
      );

  Future<void> deleteCollection(String id) => _deleteRow(
        collections,
        isRow: (c) => c.id == id,
        tourIdOf: (c) => c.tourId,
        table: 'collections',
        entityId: id,
        errorKey: 'errors.delete_collection',
        invalidatesFinance: true,
      );

  /// Re-attach this tour's collection rows to the seats their payers actually
  /// hold after a seat move, and report what that does to each payer's balance.
  ///
  /// A cross-bus move re-prices the passenger at the DESTINATION bus's bands
  /// while the cash they already handed over stays exactly as recorded, so each
  /// returned [SeatMoveMoneyDelta] says how much more to collect — or hand back
  /// when the new bus is cheaper. See [CollectionReconciler] for why the rows
  /// need re-homing at all.
  ///
  /// Never throws. The seat move this follows is already persisted and visible
  /// on the chart, so a money-write failure surfaces as an error toast plus a
  /// refetch rather than unwinding a placement the agent can see.
  ///
  /// [crossedBus] gates the on-demand read. A cross-bus move is rare and is the
  /// whole point of this method, so it is worth a round trip when the money
  /// tables are not loaded. A same-bus move only re-stamps a stale `seat_id`,
  /// which is not worth a fetch on every drag — it reconciles for free when the
  /// tour's rows happen to be loaded, and otherwise waits for the next write
  /// that touches this passenger's seats. Nothing reconciles on a
  /// collection-screen visit; this method has exactly one caller
  /// ([TourController] after a seat write), so a skipped pass stays skipped
  /// until the seats move again.
  Future<List<SeatMoveMoneyDelta>> reconcileAfterSeatMove({
    required Tour tour,
    required Iterable<String> passengerIds,
    required bool crossedBus,
  }) async {
    final ids = passengerIds.toSet();
    if (ids.isEmpty) return const [];

    final isLoadedTour = _loadedTourId == tour.id;
    if (!isLoadedTour && !crossedBus) return const [];

    final List<Collection> rows;
    if (isLoadedTour) {
      rows = collections.toList();
    } else {
      // The assign workspace never loads the money tables, so read this tour's
      // rows on demand rather than planning against an empty list — that would
      // silently skip the carry-over for exactly the screen where moves happen.
      final res = await _sync.smartFetch(
        table: 'collections',
        cacheKey: _collectionsKey(tour.id),
        select: SyncReadProjections.collectionsSelect,
        filters: {'tour_id': tour.id},
        orderBy: 'created_at',
      );
      if (res.failed) {
        // Offline, or the read failed. We now know NOTHING about this tour's
        // collections, so returning an empty plan is not "nothing to do" — it
        // is "we did not look". Staying silent here is what let a paid rider
        // cross buses and quietly keep the full destination fare outstanding
        // with their cash stranded on the old bus. Say so; the reconcile is
        // idempotent, so the next seat write (online) puts it right.
        AppSnackBar.warning(tr('money.reconcile_unavailable'));
        return const [];
      }
      rows = res.rows.map(Collection.fromMap).toList();
    }

    final plan = CollectionReconciler.plan(
      tour: tour,
      passengerIds: ids,
      collections: rows,
    );
    if (plan.isEmpty) return const [];

    try {
      for (final c in plan.updates) {
        await _sync.smartUpdate(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
        if (isLoadedTour) {
          final idx = collections.indexWhere((e) => e.id == c.id);
          if (idx >= 0) collections[idx] = c;
        }
      }
      if (isLoadedTour) collections.refresh();
    } catch (e) {
      await refreshForTour(tour.id);
      AppSnackBar.error(
        tr('errors.save_collection', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      return const [];
    }

    return plan.deltas;
  }

  // ── Expenses ──────────────────────────────────────────────

  Future<void> upsertExpense(Expense e) => _upsertRow(
        expenses,
        e,
        isRow: (x) => x.id == e.id,
        table: 'expenses',
        entityId: e.id,
        data: e.toMap,
        tourId: e.tourId,
        errorKey: 'errors.save_expense',
        invalidatesFinance: true,
      );

  Future<void> deleteExpense(String id) => _deleteRow(
        expenses,
        isRow: (e) => e.id == id,
        tourIdOf: (e) => e.tourId,
        table: 'expenses',
        entityId: id,
        errorKey: 'errors.delete_expense',
        invalidatesFinance: true,
      );

  // ── Incomes ───────────────────────────────────────────────
  // Extra cash taken in outside seat fares (cabin / gallery / other). The
  // HANDLER logs these on the ground through their own RPCs; these are the
  // ADMIN's equivalents, so a wrong or missing entry can be corrected from the
  // bus money screen instead of being permanently stuck at whatever the handler
  // typed. Same optimistic-then-confirm shape as [upsertExpense].

  Future<void> upsertIncome(IncomeEntry i) => _upsertRow(
        incomes,
        i,
        isRow: (x) => x.id == i.id,
        table: 'incomes',
        entityId: i.id,
        data: i.toMap,
        tourId: i.tourId,
        errorKey: 'errors.save_income',
        invalidatesFinance: true,
      );

  Future<void> deleteIncome(String id) => _deleteRow(
        incomes,
        isRow: (i) => i.id == id,
        tourIdOf: (i) => i.tourId,
        table: 'incomes',
        entityId: id,
        errorKey: 'errors.delete_income',
        invalidatesFinance: true,
      );

  // ── Handovers ─────────────────────────────────────────────
  // `invalidatesFinance: false` is deliberate: a handover only moves cash
  // from the handler's pocket to the admin. FinanceController reads revenue,
  // expenses and income per trip, none of which a handover changes, so there
  // is nothing stale to mark.

  /// Records a new handover or, when [h] carries an existing id, updates it —
  /// so a logged handover can be corrected after the fact (mirrors
  /// [upsertExpense]).
  Future<void> recordHandover(BusHandover h) => _upsertRow(
        handovers,
        h,
        isRow: (x) => x.id == h.id,
        table: 'bus_handovers',
        entityId: h.id,
        data: h.toMap,
        tourId: h.tourId,
        errorKey: 'errors.record_handover',
        invalidatesFinance: false,
      );

  Future<void> deleteHandover(String id) => _deleteRow(
        handovers,
        isRow: (h) => h.id == id,
        tourIdOf: (h) => h.tourId,
        table: 'bus_handovers',
        entityId: id,
        errorKey: 'errors.delete_handover',
        invalidatesFinance: false,
      );

  // ── Shared optimistic row plumbing ────────────────────────

  /// Replace-or-append [row] in [list] (one repaint), then UPDATE it on
  /// [table] when it already existed locally, else INSERT it. On success,
  /// optionally tells the cross-tour P&L it is stale. On failure: refetch the
  /// tour from the server, toast [errorKey], rethrow.
  Future<void> _upsertRow<T>(
    RxList<T> list,
    T row, {
    required bool Function(T) isRow,
    required String table,
    required String entityId,
    required Map<String, dynamic> Function() data,
    required String tourId,
    required String errorKey,
    required bool invalidatesFinance,
  }) async {
    final idx = list.indexWhere(isRow);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      list[idx] = row;
    } else {
      list.add(row);
    }
    list.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(table: table, entityId: entityId, data: data());
      } else {
        await _sync.smartInsert(table: table, entityId: entityId, data: data());
      }
      if (invalidatesFinance) _invalidateFinance();
    } catch (e) {
      await refreshForTour(tourId);
      AppSnackBar.error(
        tr(errorKey, namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      rethrow;
    }
  }

  /// Drop every row of [list] matching [isRow] locally, then delete
  /// [entityId] on [table]. On failure: refetch the tour the row belonged to
  /// (or the loaded tour), toast [errorKey], rethrow.
  Future<void> _deleteRow<T>(
    RxList<T> list, {
    required bool Function(T) isRow,
    required String Function(T) tourIdOf,
    required String table,
    required String entityId,
    required String errorKey,
    required bool invalidatesFinance,
  }) async {
    final removed = list.firstWhereOrNull(isRow);
    list.removeWhere(isRow);
    try {
      await _sync.smartDelete(table: table, entityId: entityId);
      if (invalidatesFinance) _invalidateFinance();
    } catch (e) {
      final tourId = removed == null ? null : tourIdOf(removed);
      await refreshForTour(tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        tr(errorKey, namedArgs: {'e': '$e'}),
        title: tr('errors.delete_failed'),
      );
      rethrow;
    }
  }
}
