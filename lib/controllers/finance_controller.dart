import 'dart:developer' as dev;

import 'package:get/get.dart';

import '../models/tour_finance.dart';
import '../models/tour_status.dart';
import '../services/ledger_money_source.dart';
import 'tour_controller.dart';

/// Cross-tour Profit & Loss data source.
///
/// Where [MoneyController] holds the money rows for a SINGLE tour, this loads
/// ledger bus rollups for EVERY tour the agent owns, so the finance report can
/// show profit/loss across the whole history of trips. Tour metadata comes from
/// [TourController]; money totals come from `finance_bus_summary`.
class FinanceController extends GetxController {
  FinanceController({LedgerMoneySource? ledgerSource})
      : _ledgerSource = ledgerSource ?? LedgerMoneySource();

  final LedgerMoneySource _ledgerSource;

  final isLoading = false.obs;
  final loadFailed = false.obs;
  final loadedOnce = false.obs;

  // Net cash collected and total expenses, keyed by tour id.
  final Map<String, double> _revenueByTour = {};
  final Map<String, double> _expensesByTour = {};
  final Map<String, double> _incomeByTour = {};

  Future<void>? _loadInFlight;
  int _loadGeneration = 0;

  TourController get _tours => Get.find<TourController>();

  Future<void> ensureLoaded() async {
    if (loadedOnce.value) return;
    if (_loadInFlight != null) return _loadInFlight!;
    await load();
  }

  Future<void> reload() => load();

  void markStale() {
    if (!loadedOnce.value && !isLoading.value) return;
    _stale = true;
  }

  bool _stale = false;

  Future<void> refreshIfStale() async {
    if (!loadedOnce.value) return ensureLoaded();
    if (!_stale || isLoading.value) {
      if (_stale && _loadInFlight != null) return _loadInFlight!;
      return;
    }
    await load();
  }

  Future<void> load() async {
    if (_loadInFlight != null) return _loadInFlight!;
    final future = _loadBody();
    _loadInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_loadInFlight, future)) {
        _loadInFlight = null;
      }
    }
  }

  Future<void> _loadBody() async {
    final gen = ++_loadGeneration;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final revenue = <String, double>{};
      final expenses = <String, double>{};
      final income = <String, double>{};

      final rollups = await _ledgerSource.fetchAllBusRollups();
      if (gen != _loadGeneration) return;
      for (final r in rollups) {
        final tid = r.tourId;
        if (tid.isEmpty) continue;
        revenue[tid] = (revenue[tid] ?? 0) + r.collected;
        expenses[tid] = (expenses[tid] ?? 0) + r.expensesTotal;
        income[tid] = (income[tid] ?? 0) + r.income;
      }

      _revenueByTour
        ..clear()
        ..addAll(revenue);
      _expensesByTour
        ..clear()
        ..addAll(expenses);
      _incomeByTour
        ..clear()
        ..addAll(income);
      loadedOnce.value = true;
      _stale = false;
    } catch (e, st) {
      if (gen != _loadGeneration) return;
      dev.log('finance load failed: $e\n$st', name: 'FinanceController');
      loadFailed.value = true;
    } finally {
      if (gen == _loadGeneration) isLoading.value = false;
    }
  }

  /// Per-tour P&L for [period], newest trip first.
  ///
  /// Counts EVERY tour by default — a running trip's figures are real money
  /// that has already moved, and gating the report on the manual "Mark
  /// completed" tap meant an agent mid-season saw a ₹0 card and an empty report
  /// no matter how much they had collected. [TourFinance.isCompleted] carries
  /// the distinction so the UI can still separate realised from running P&L.
  /// Pass [completedOnly] to get the realised-only view.
  List<TourFinance> financesFor(
    FinancePeriod period, {
    bool completedOnly = false,
  }) {
    final now = DateTime.now();
    final out = <TourFinance>[];
    for (final tour in _tours.tours) {
      if (completedOnly && tour.status != TourStatus.completed) continue;
      final tf = TourFinance.from(
        tour,
        _revenueByTour[tour.id] ?? 0,
        _expensesByTour[tour.id] ?? 0,
        income: _incomeByTour[tour.id] ?? 0,
      );
      if (!_inPeriod(tf.date, period, now)) continue;
      out.add(tf);
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  FinanceTotals totalsFor(FinancePeriod period, {bool completedOnly = false}) =>
      FinanceTotals.from(financesFor(period, completedOnly: completedOnly));

  double get lifetimeNet => totalsFor(FinancePeriod.allTime).net;

  double get lifetimeRealisedNet =>
      totalsFor(FinancePeriod.allTime, completedOnly: true).net;

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
