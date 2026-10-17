part of '../money_controller.dart';

/// Cross-tour outstanding-handover snapshots for the dashboard (AL-3).
mixin _MoneySettlement on _MoneyAggregation {
  // ── Settlement snapshots (AL-3) ───────────────────────────

  /// Per-tour outstanding-handover totals for the dashboard's settlement alerts
  /// (AL-3), so tours OTHER than the currently-loaded one still surface. Filled
  /// by [loadSettlementSnapshots]; read via [outstandingHandoverFor].
  final settlementByTour = <String, double>{}.obs;

  /// Outstanding handover for [tourId]: the exact live value when it's the
  /// loaded tour, else the cached snapshot (null when not yet computed — the
  /// caller must treat null as "unknown", not "settled").
  double? outstandingHandoverFor(String tourId) {
    if (tourId == _loadedTourId) return tourSummary().totalOutstandingHandover;
    return settlementByTour[tourId];
  }

  /// Lightweight settlement pass for [tourIds]: fetch each tour's four money
  /// tables and cache its outstanding handover via the SAME
  /// [TourMoneySummary.compute] the board uses. Never touches the live obs
  /// lists; skips the loaded tour (already exact, read live), any tour whose
  /// snapshot is already cached (the dashboard's trigger re-runs whenever the
  /// tours list changes for ANY reason, so this keeps repeat calls a no-op
  /// instead of re-fetching four tables per tour on every unrelated update),
  /// and any failed read (left uncached so a later call can retry it).
  Future<void> loadSettlementSnapshots(Iterable<String> tourIds) async {
    if (_settlementInFlight != null) return _settlementInFlight!;
    final future = _loadSettlementSnapshotsBody(tourIds);
    _settlementInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_settlementInFlight, future)) {
        _settlementInFlight = null;
      }
    }
  }

  Future<void> _loadSettlementSnapshotsBody(Iterable<String> tourIds) async {
    final tourCtrl =
        Get.isRegistered<TourController>() ? Get.find<TourController>() : null;
    var changed = false;
    final pending = tourIds
        .where((id) => id != _loadedTourId && !settlementByTour.containsKey(id))
        .toList();

    // Parallel batches of 3 — sequential N tours on 2G stacks latency; unbounded
    // parallelism floods a weak radio. Three keeps the air moving without
    // saturating the sync retry budget.
    const batchSize = 3;
    for (var i = 0; i < pending.length; i += batchSize) {
      final chunk = pending.sublist(i, math.min(i + batchSize, pending.length));
      final results = await Future.wait(chunk.map((id) async {
        try {
          final rollups = await _ledgerSource.fetchBusRollups(id);
          return MapEntry(
            id,
            rollups.fold<double>(
              0,
              (sum, r) => sum + r.outstandingHandover,
            ),
          );
        } catch (e, st) {
          dev.log(
            'settlement ledger snapshot failed for $id: $e\n$st',
            name: 'MoneyController',
          );
        }

        final results = await _fetchMoneyTables(id);
        if (results.any((r) => r.failed)) return null;
        final tour = tourCtrl?.getTour(id);
        final busRentsTotal =
            tour == null ? 0.0 : tour.buses.fold<double>(0, (s, b) => s + b.busPrice);
        final totalRevenueBilled = tour == null
            ? 0.0
            : tour.buses.fold<double>(
                0,
                (s, b) =>
                    s + tour.passengers.fold<double>(0, (ps, p) => ps + b.amountDueFor(p)),
              );
        final summary = TourMoneySummary.compute(
          collections: results[0].rows.map(Collection.fromMap).toList(),
          expenses: results[1].rows.map(Expense.fromMap).toList(),
          handovers: results[2].rows.map(BusHandover.fromMap).toList(),
          incomes: results[3].rows.map(IncomeEntry.fromMap).toList(),
          busRentsTotal: busRentsTotal,
          totalRevenueBilled: totalRevenueBilled,
        );
        return MapEntry(id, summary.totalOutstandingHandover);
      }));

      for (final entry in results) {
        if (entry == null) continue;
        settlementByTour[entry.key] = entry.value;
        changed = true;
      }
    }
    if (changed) settlementByTour.refresh();
  }
}
