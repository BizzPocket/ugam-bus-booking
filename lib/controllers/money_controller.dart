import 'dart:async';
import 'dart:developer' as dev;

import 'package:get/get.dart';

import '../models/collection.dart';
import '../models/expense.dart';
import '../models/bus_handover.dart';
import '../models/money_summary.dart';
import '../services/sync_service.dart';
import '../utils/app_snackbar.dart';

/// Loads & persists the money tables (`collections`, `expenses`,
/// `bus_handovers`) for a single tour via [SyncService], and exposes
/// aggregation summaries built from the locally held rows.
///
/// CRUD follows the same shape as [TourController]: mutate local state
/// optimistically so the UI feels instant, await the server write, and on
/// failure pull fresh state from the server + surface the error.
///
/// RLS note: these three tables are NOT owner-scoped (no `owner_id`
/// column). Their policies validate via the tour-owner join, so we just
/// send the row's `toMap()` (which already carries `tour_id`/`bus_id`).
class MoneyController extends GetxController {
  final collections = <Collection>[].obs;
  final expenses = <Expense>[].obs;
  final handovers = <BusHandover>[].obs;
  final isLoading = false.obs;

  /// Which tour the lists currently hold data for. Used to scope cache
  /// keys and to know what to refetch on refresh.
  String? _loadedTourId;

  SyncService get _sync => Get.find<SyncService>();

  String _collectionsKey(String tourId) => 'collections_$tourId';
  String _expensesKey(String tourId) => 'expenses_$tourId';
  String _handoversKey(String tourId) => 'handovers_$tourId';

  // ── Load / refresh ────────────────────────────────────────

  Future<void> loadForTour(String tourId) async {
    _loadedTourId = tourId;
    isLoading.value = true;
    try {
      final results = await Future.wait([
        _sync.smartFetch(
          table: 'collections',
          cacheKey: _collectionsKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'expenses',
          cacheKey: _expensesKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
        _sync.smartFetch(
          table: 'bus_handovers',
          cacheKey: _handoversKey(tourId),
          filters: {'tour_id': tourId},
          orderBy: 'created_at',
        ),
      ]);

      collections.assignAll(results[0].map(Collection.fromMap).toList());
      expenses.assignAll(results[1].map(Expense.fromMap).toList());
      handovers.assignAll(results[2].map(BusHandover.fromMap).toList());
    } catch (e, st) {
      // Leave whatever we already hold in place — a transient fetch
      // failure shouldn't blank the money screen.
      dev.log(
        'loadForTour failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
    } finally {
      isLoading.value = false;
    }
  }

  /// Force a fresh fetch by invalidating the three per-tour cache keys
  /// before reloading.
  Future<void> refreshForTour(String tourId) async {
    await _sync.invalidateCache(_collectionsKey(tourId));
    await _sync.invalidateCache(_expensesKey(tourId));
    await _sync.invalidateCache(_handoversKey(tourId));
    await loadForTour(tourId);
  }

  // ── Collections ───────────────────────────────────────────

  Collection? collectionFor(String passengerId, String busId, String seatId) =>
      collections.firstWhereOrNull(
        (c) =>
            c.passengerId == passengerId &&
            c.busId == busId &&
            c.seatId == seatId,
      );

  Future<void> upsertCollection(Collection c) async {
    final idx = collections.indexWhere((e) => e.id == c.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      collections[idx] = c;
    } else {
      collections.add(c);
    }
    collections.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'collections',
          entityId: c.id,
          data: c.toMap(),
        );
      }
    } catch (e) {
      await refreshForTour(c.tourId);
      AppSnackBar.error('Could not save collection. $e', title: 'Save failed');
      rethrow;
    }
  }

  Future<void> deleteCollection(String id) async {
    final removed = collections.firstWhereOrNull((c) => c.id == id);
    collections.removeWhere((c) => c.id == id);
    try {
      await _sync.smartDelete(table: 'collections', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        'Could not delete collection. $e',
        title: 'Delete failed',
      );
      rethrow;
    }
  }

  // ── Expenses ──────────────────────────────────────────────

  Future<void> upsertExpense(Expense e) async {
    final idx = expenses.indexWhere((x) => x.id == e.id);
    final existedBefore = idx >= 0;

    if (existedBefore) {
      expenses[idx] = e;
    } else {
      expenses.add(e);
    }
    expenses.refresh();

    try {
      if (existedBefore) {
        await _sync.smartUpdate(
          table: 'expenses',
          entityId: e.id,
          data: e.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'expenses',
          entityId: e.id,
          data: e.toMap(),
        );
      }
    } catch (err) {
      await refreshForTour(e.tourId);
      AppSnackBar.error('Could not save expense. $err', title: 'Save failed');
      rethrow;
    }
  }

  Future<void> deleteExpense(String id) async {
    final removed = expenses.firstWhereOrNull((e) => e.id == id);
    expenses.removeWhere((e) => e.id == id);
    try {
      await _sync.smartDelete(table: 'expenses', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error('Could not delete expense. $e', title: 'Delete failed');
      rethrow;
    }
  }

  // ── Handovers ─────────────────────────────────────────────

  Future<void> recordHandover(BusHandover h) async {
    handovers.add(h);
    handovers.refresh();
    try {
      await _sync.smartInsert(
        table: 'bus_handovers',
        entityId: h.id,
        data: h.toMap(),
      );
    } catch (e) {
      await refreshForTour(h.tourId);
      AppSnackBar.error('Could not record handover. $e', title: 'Save failed');
      rethrow;
    }
  }

  Future<void> deleteHandover(String id) async {
    final removed = handovers.firstWhereOrNull((h) => h.id == id);
    handovers.removeWhere((h) => h.id == id);
    try {
      await _sync.smartDelete(table: 'bus_handovers', entityId: id);
    } catch (e) {
      await refreshForTour(removed?.tourId ?? _loadedTourId ?? '');
      AppSnackBar.error(
        'Could not delete handover. $e',
        title: 'Delete failed',
      );
      rethrow;
    }
  }

  // ── Aggregation ───────────────────────────────────────────

  BusMoneySummary summaryForBus(String busId) => BusMoneySummary.compute(
    busId: busId,
    collections: collections.toList(),
    expenses: expenses.toList(),
    handovers: handovers.toList(),
  );

  TourMoneySummary tourSummary() => TourMoneySummary.compute(
    collections: collections.toList(),
    expenses: expenses.toList(),
    handovers: handovers.toList(),
  );
}
