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
  });

  /// Net cash the bus should hand over (collections minus expenses).
  double get expectedHandover => collected - expensesTotal;

  /// Still-owed handover (expected minus what was actually handed over).
  double get outstandingHandover => expectedHandover - handedOver;

  factory BusMoneySummary.compute({
    required String busId,
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
  }) {
    final busCollections = collections.where((c) => c.busId == busId);
    final busExpenses = expenses.where((e) => e.busId == busId);
    final busHandovers = handovers.where((h) => h.busId == busId);

    return BusMoneySummary(
      busId: busId,
      collected: busCollections.fold(0.0, (sum, c) => sum + c.netCollected),
      expensesTotal: busExpenses.fold(0.0, (sum, e) => sum + e.amount),
      handedOver: busHandovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      toReturnTotal:
          busCollections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      toCollectTotal:
          busCollections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}

/// Aggregated money figures across an entire tour (all buses).
class TourMoneySummary {
  final double totalCollected;
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
  });

  /// Net cash for the tour (collections minus expenses).
  double get totalNet => totalCollected - totalExpenses;

  /// Still-owed handover across the whole tour.
  double get totalOutstandingHandover => totalNet - totalHandedOver;

  factory TourMoneySummary.compute({
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
  }) {
    return TourMoneySummary(
      totalCollected:
          collections.fold(0.0, (sum, c) => sum + c.netCollected),
      totalExpenses: expenses.fold(0.0, (sum, e) => sum + e.amount),
      totalHandedOver:
          handovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      totalToReturn:
          collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
