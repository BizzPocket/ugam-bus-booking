import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'money_summary.dart';
import 'passenger.dart';

/// Per-bus money totals for the HANDLER's "in hand" view.
///
/// Built on [BusMoneySummary] — the single source of truth the admin's money
/// board uses — so the handler and admin can NEVER disagree on what was
/// collected OR on what must be handed over. The handler settles the bus owner
/// directly out of the cash they collect, so the owner's rent ([rent]) is a
/// real deduction: [spent] is the handler's own ground expenses and [inHand] is
/// the net cash left after BOTH ground costs and rent — exactly the admin's
/// [BusMoneySummary.expectedHandover] for the same bus.
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
  /// costs only — the owner's rent is tracked separately in [rent]).
  final double spent;

  /// Total extra income (cabin / gallery / other cash taken in outside fares).
  final double income;

  /// The bus owner's rent the handler pays out of the cash they collect. Shown
  /// as its own deduction line so the handler can see why their in-hand drops.
  final double rent;

  const HandlerBusMoney({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    this.rent = 0,
  });

  /// Net cash the handler should be holding for this bus — collected + extra
  /// income taken in, less their ground expenses AND the owner's rent. This is
  /// what they hand over to the admin.
  double get inHand => collected + income - spent - rent;

  /// [dueForSeat] resolves a seated rider's fare for one seat (the bus's
  /// `amountDueForSeat`); injected so this stays decoupled from the heavy Bus
  /// seat-layout model and is trivially unit-testable.
  factory HandlerBusMoney.compute({
    required String busId,
    required Iterable<Passenger> passengers,
    required List<Collection> collections,
    required List<Expense> expenses,
    List<IncomeEntry> incomes = const [],
    double busRent = 0,
    required double Function(Passenger passenger, String seatId) dueForSeat,
  }) {
    // collected / toReturn / to-collect-shortfalls / income all come from the
    // shared, seat-agnostic BusMoneySummary. Rent is kept OUT of this base
    // (`busRent: 0`) so `expensesTotal` stays the handler's ground expenses
    // only; the owner's rent is carried separately on [rent] and deducted in
    // [inHand], so the handler sees ground costs and rent as distinct lines.
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
      rent: busRent,
    );
  }
}
