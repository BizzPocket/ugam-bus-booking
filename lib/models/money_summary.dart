import 'collection.dart';
import 'expense.dart';
import 'bus_handover.dart';

/// Aggregated money figures for a single bus on a tour.
///
/// Pure value object — compute it once from raw model lists and read its
/// derived getters in the UI. No Flutter/GetX dependencies.
class BusMoneySummary {
  final String busId;
  final double collected;

  /// Total fares BILLED to passengers seated on this bus (what they owe for
  /// their seats, whether collected yet or not). The accrual revenue — drives
  /// the "true" profit/loss figure, independent of how much cash is in hand.
  final double revenueBilled;
  final double expensesTotal;
  final double handedOver;
  final double toReturnTotal;
  final double toCollectTotal;

  const BusMoneySummary({
    required this.busId,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toReturnTotal,
    required this.toCollectTotal,
    this.revenueBilled = 0,
  });

  /// Net cash the bus should hand over (collections minus expenses).
  double get expectedHandover => collected - expensesTotal;

  /// Still-owed handover (expected minus what was actually handed over).
  double get outstandingHandover => expectedHandover - handedOver;

  /// TRUE profit/loss for the bus: fares billed − (rent + expenses). Reflects
  /// the trip's real result even before every passenger has paid.
  double get netBilled => revenueBilled - expensesTotal;

  /// CASH profit/loss so far: money actually collected − (rent + expenses).
  /// Same figure as [expectedHandover]; named for the P&L view.
  double get netCollected => collected - expensesTotal;

  factory BusMoneySummary.compute({
    required String busId,
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    double busRent = 0,
    double revenueBilled = 0,
  }) {
    final busCollections = collections.where((c) => c.busId == busId);
    final busExpenses = expenses.where((e) => e.busId == busId);
    final busHandovers = handovers.where((h) => h.busId == busId);

    return BusMoneySummary(
      busId: busId,
      collected: busCollections.fold(0.0, (sum, c) => sum + c.netCollected),
      revenueBilled: revenueBilled,
      // The bus owner's rent is the single source of truth (not a DB expense
      // row), so it is added to the expense rows here rather than counted twice.
      expensesTotal:
          busExpenses.fold(0.0, (sum, e) => sum + e.amount) + busRent,
      handedOver: busHandovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      toReturnTotal:
          busCollections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      toCollectTotal:
          busCollections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}

/// Aggregated money figures for ONE handler across all the buses they run on a
/// tour (a handler manages whole buses via [Bus.handlerPassengerId], so a
/// handler's P&L is simply the sum of their buses' [BusMoneySummary]s).
///
/// [handlerPassengerId] is null for the bucket of buses that have no handler
/// assigned yet, so unassigned buses are never silently dropped from the trip
/// total.
class HandlerMoneySummary {
  final String? handlerPassengerId;
  final List<String> busIds;
  final double revenueBilled;
  final double collected;
  final double expensesTotal;
  final double handedOver;
  final double toCollectTotal;
  final double toReturnTotal;

  const HandlerMoneySummary({
    required this.handlerPassengerId,
    required this.busIds,
    required this.revenueBilled,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toCollectTotal,
    required this.toReturnTotal,
  });

  double get netBilled => revenueBilled - expensesTotal;
  double get netCollected => collected - expensesTotal;
  double get outstandingHandover => netCollected - handedOver;

  /// Roll a set of per-bus summaries up into one handler total.
  factory HandlerMoneySummary.fromBuses(
    String? handlerPassengerId,
    List<BusMoneySummary> buses,
  ) {
    return HandlerMoneySummary(
      handlerPassengerId: handlerPassengerId,
      busIds: [for (final b in buses) b.busId],
      revenueBilled: buses.fold(0.0, (s, b) => s + b.revenueBilled),
      collected: buses.fold(0.0, (s, b) => s + b.collected),
      expensesTotal: buses.fold(0.0, (s, b) => s + b.expensesTotal),
      handedOver: buses.fold(0.0, (s, b) => s + b.handedOver),
      toCollectTotal: buses.fold(0.0, (s, b) => s + b.toCollectTotal),
      toReturnTotal: buses.fold(0.0, (s, b) => s + b.toReturnTotal),
    );
  }
}

/// Aggregated money figures across an entire tour (all buses).
class TourMoneySummary {
  final double totalCollected;

  /// Total fares billed across every bus on the tour (accrual revenue).
  final double totalRevenueBilled;
  final double totalExpenses;
  final double totalHandedOver;
  final double totalToReturn;
  final double totalToCollect;

  const TourMoneySummary({
    required this.totalCollected,
    required this.totalExpenses,
    required this.totalHandedOver,
    required this.totalToReturn,
    required this.totalToCollect,
    this.totalRevenueBilled = 0,
  });

  /// Net cash for the tour (collections minus expenses).
  double get totalNet => totalCollected - totalExpenses;

  /// TRUE profit/loss for the tour: fares billed − (rents + expenses).
  double get totalNetBilled => totalRevenueBilled - totalExpenses;

  /// Still-owed handover across the whole tour.
  double get totalOutstandingHandover => totalNet - totalHandedOver;

  factory TourMoneySummary.compute({
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    double busRentsTotal = 0,
    double totalRevenueBilled = 0,
  }) {
    return TourMoneySummary(
      totalCollected:
          collections.fold(0.0, (sum, c) => sum + c.netCollected),
      totalRevenueBilled: totalRevenueBilled,
      // Bus owner rents are the single source of truth (not DB expense rows),
      // so they are folded into the expense total here rather than double-counted.
      totalExpenses:
          expenses.fold(0.0, (sum, e) => sum + e.amount) + busRentsTotal,
      totalHandedOver:
          handovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      totalToReturn:
          collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
