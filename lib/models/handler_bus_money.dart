import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'money_summary.dart';
import 'passenger.dart';

/// Per-bus money totals for the HANDLER's "in hand" view.
///
/// Built on [BusMoneySummary] — the single source of truth the admin's money
/// board uses — so the handler and admin can NEVER disagree on what was
/// collected. The handler never settles the bus owner (the admin pays the owner
/// directly), so the owner's rent is excluded here entirely (`busRent: 0`):
/// [spent] is the handler's own ground expenses and [inHand] is the cash they
/// must hand over.
///
/// CRITICAL: cash is summed per COLLECTION ROW scoped to the bus — NEVER matched
/// to a rider's CURRENT seat. A rider who paid and later changed seats keeps
/// their collection row on the OLD seat; matching by current seat orphaned the
/// row, silently dropping the cash from [collected] and double-counting it back
/// into [toCollect]. See `test/models/handler_bus_money_test.dart`.
class HandlerBusMoney {
  final double collected;
  final double toReturn;
  final double toCollect;

  /// Total of every expense logged against this bus (the handler's own ground
  /// costs — the owner's rent is NOT included, the admin settles that).
  final double spent;

  /// Total extra income (cabin / gallery / other cash taken in outside fares).
  final double income;

  const HandlerBusMoney({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
  });

  /// Net cash the handler should be holding for this bus — collected + extra
  /// income taken in, less their ground expenses. This is what they hand over.
  double get inHand => collected + income - spent;

  /// [dueForSeat] resolves a seated rider's fare for one seat (the bus's
  /// `amountDueForSeat`); injected so this stays decoupled from the heavy Bus
  /// seat-layout model and is trivially unit-testable.
  factory HandlerBusMoney.compute({
    required String busId,
    required Iterable<Passenger> passengers,
    required List<Collection> collections,
    required List<Expense> expenses,
    List<IncomeEntry> incomes = const [],
    required double Function(Passenger passenger, String seatId) dueForSeat,
  }) {
    // collected / toReturn / to-collect-shortfalls / income all come from the
    // shared, seat-agnostic BusMoneySummary. Rent is the admin's to settle, so
    // it is 0 here — `expensesTotal` is then the handler's ground expenses only.
    final base = BusMoneySummary.compute(
      busId: busId,
      collections: collections,
      expenses: expenses,
      handovers: const [],
      incomes: incomes,
      busRent: 0,
    );

    // Seated riders nobody has opened a collection for yet still owe their full
    // fare. Keyed by passenger id (seat-AGNOSTIC): a rider with ANY collection
    // row on this bus is already accounted for by [base.toCollectTotal], so
    // they are skipped here regardless of which seat that row names.
    final collectedPassengerIds = collections
        .where((c) => c.busId == busId)
        .map((c) => c.passengerId)
        .toSet();
    var toCollect = base.toCollectTotal;
    for (final p in passengers) {
      if (collectedPassengerIds.contains(p.id)) continue;
      final seatIds = p.assignedSeats
          .where((a) => a.busId == busId)
          .map((a) => a.seatId)
          .toSet();
      for (final seatId in seatIds) {
        toCollect += dueForSeat(p, seatId);
      }
    }

    return HandlerBusMoney(
      collected: base.collected,
      toReturn: base.toReturnTotal,
      toCollect: toCollect,
      spent: base.expensesTotal, // busRent: 0 → logged ground expenses only
      income: base.income,
    );
  }
}
