import 'dart:developer' as dev;

import 'package:get/get.dart';

import '../models/tour_finance.dart';
import '../models/tour_status.dart';
import '../services/supabase_service.dart';
import 'tour_controller.dart';

/// Cross-tour Profit & Loss data source.
///
/// Where [MoneyController] holds the money rows for a SINGLE tour, this loads
/// the realised revenue & expense totals for EVERY tour the agent owns, so the
/// finance report can show profit/loss across the whole history of completed
/// trips. The tours themselves (titles, dates, status, passenger/bus counts)
/// are read straight from the already-loaded [TourController]; only the per-tour
/// money sums are fetched here.
///
/// Aggregation runs client-side: we page through `collections` and `expenses`
/// (both RLS-scoped to the owner's tours) and fold them into per-tour maps.
/// Paging past the [SyncService] 500-row cap keeps the totals correct once an
/// agent has run enough trips to exceed it.
class FinanceController extends GetxController {
  final isLoading = false.obs;
  final loadFailed = false.obs;
  final loadedOnce = false.obs;

  // Net cash collected (received − refunded) and total expenses, keyed by
  // tour id. Plain maps — the screen rebuilds off [isLoading]/[loadedOnce]
  // and the reactive [TourController.tours] list, not off these.
  final Map<String, double> _revenueByTour = {};
  final Map<String, double> _expensesByTour = {};

  TourController get _tours => Get.find<TourController>();

  static const int _pageSize = 1000;

  /// Loads once. Safe to call from every screen that needs finance data —
  /// it no-ops while already loading or after a first successful load.
  Future<void> ensureLoaded() async {
    if (loadedOnce.value || isLoading.value) return;
    await load();
  }

  Future<void> reload() => load();

  Future<void> load() async {
    if (isLoading.value) return;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final revenue = <String, double>{};
      final expenses = <String, double>{};

      await _pageThrough(
        table: 'collections',
        columns: 'tour_id, amount_received, amount_refunded',
        onRow: (row) {
          final tid = row['tour_id'] as String?;
          if (tid == null) return;
          final received = (row['amount_received'] as num?)?.toDouble() ?? 0;
          final refunded = (row['amount_refunded'] as num?)?.toDouble() ?? 0;
          revenue[tid] = (revenue[tid] ?? 0) + (received - refunded);
        },
      );
      await _pageThrough(
        table: 'expenses',
        columns: 'tour_id, amount',
        onRow: (row) {
          final tid = row['tour_id'] as String?;
          if (tid == null) return;
          final amount = (row['amount'] as num?)?.toDouble() ?? 0;
          expenses[tid] = (expenses[tid] ?? 0) + amount;
        },
      );

      _revenueByTour
        ..clear()
        ..addAll(revenue);
      _expensesByTour
        ..clear()
        ..addAll(expenses);
      loadedOnce.value = true;
    } catch (e, st) {
      dev.log('finance load failed: $e\n$st', name: 'FinanceController');
      loadFailed.value = true;
    } finally {
      isLoading.value = false;
    }
  }

  /// Pages through [table] in [_pageSize] chunks (ordered by id for a stable
  /// window) until a short page signals the end, invoking [onRow] per row.
  Future<void> _pageThrough({
    required String table,
    required String columns,
    required void Function(Map<String, dynamic> row) onRow,
  }) async {
    final client = SupabaseService.instance.client;
    var from = 0;
    while (true) {
      final rows = await client
          .from(table)
          .select(columns)
          .order('id', ascending: true)
          .range(from, from + _pageSize - 1) as List;
      for (final r in rows) {
        onRow(Map<String, dynamic>.from(r as Map));
      }
      if (rows.length < _pageSize) break;
      from += _pageSize;
    }
  }

  // ── Reports ───────────────────────────────────────────────

  /// Per-tour P&L for [period], newest trip first. [completedOnly] limits the
  /// report to finished tours (realised P&L); pass false to include in-progress
  /// tours' running figures too.
  List<TourFinance> financesFor(
    FinancePeriod period, {
    bool completedOnly = true,
  }) {
    final now = DateTime.now();
    final out = <TourFinance>[];
    for (final tour in _tours.tours) {
      if (completedOnly && tour.status != TourStatus.completed) continue;
      final tf = TourFinance.from(
        tour,
        _revenueByTour[tour.id] ?? 0,
        _expensesByTour[tour.id] ?? 0,
      );
      if (!_inPeriod(tf.date, period, now)) continue;
      out.add(tf);
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  FinanceTotals totalsFor(FinancePeriod period, {bool completedOnly = true}) =>
      FinanceTotals.from(financesFor(period, completedOnly: completedOnly));

  /// Lifetime realised net across all completed tours — for the Settings card.
  double get lifetimeNet =>
      totalsFor(FinancePeriod.allTime).net;

  bool _inPeriod(DateTime date, FinancePeriod period, DateTime now) {
    switch (period) {
      case FinancePeriod.thisMonth:
        return date.year == now.year && date.month == now.month;
      case FinancePeriod.thisYear:
        return date.year == now.year;
      case FinancePeriod.allTime:
        return true;
    }
  }
}
