import 'money_summary.dart';
import '../utils/ledger_money.dart';

/// One bus (or tour-level orphan bucket when [busId] is null) as returned by
/// `public.finance_bus_summary`. Amounts are already in rupees.
class LedgerBusRollup {
  final String tourId;
  final String? busId;
  final double outstandingHandover;
  final double billed;
  final double income;
  final double groundExpenses;
  final double rent;
  final double ownerUnpaid;
  final double collected;
  final double handedOver;
  final double toCollect;
  final double toReturn;

  const LedgerBusRollup({
    required this.tourId,
    required this.busId,
    required this.outstandingHandover,
    required this.billed,
    required this.income,
    required this.groundExpenses,
    required this.rent,
    this.ownerUnpaid = 0,
    required this.collected,
    required this.handedOver,
    required this.toCollect,
    required this.toReturn,
  });

  double get expensesTotal => groundExpenses + rent;

  factory LedgerBusRollup.fromMap(Map<String, dynamic> map) {
    int minor(String key) {
      final v = map[key];
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.round();
      return int.tryParse('$v') ?? 0;
    }

    return LedgerBusRollup(
      tourId: map['tour_id'] as String? ?? '',
      busId: map['bus_id'] as String?,
      outstandingHandover: minorToRupees(minor('outstanding_handover_minor')),
      billed: minorToRupees(minor('billed_minor')),
      income: minorToRupees(minor('income_minor')),
      groundExpenses: minorToRupees(minor('ground_expenses_minor')),
      rent: minorToRupees(minor('rent_minor')),
      ownerUnpaid: minorToRupees(minor('owner_unpaid_minor')),
      collected: minorToRupees(minor('collected_minor')),
      handedOver: minorToRupees(minor('handed_over_minor')),
      toCollect: minorToRupees(minor('to_collect_minor')),
      toReturn: minorToRupees(minor('to_return_minor')),
    );
  }

  /// Maps into the UI's existing [BusMoneySummary] shape so screens do not
  /// fork display formulas. [BusMoneySummary.outstandingHandover] is derived
  /// (`expected − handed`); when the ledger is consistent it matches
  /// [outstandingHandover].
  BusMoneySummary toBusMoneySummary() {
    final id = busId;
    if (id == null || id.isEmpty) {
      throw StateError('toBusMoneySummary requires a non-null busId');
    }
    return BusMoneySummary(
      busId: id,
      collected: collected,
      revenueBilled: billed,
      expensesTotal: expensesTotal,
      handedOver: handedOver,
      toReturnTotal: toReturn,
      toCollectTotal: toCollect,
      income: income,
      busRent: rent,
    );
  }
}
