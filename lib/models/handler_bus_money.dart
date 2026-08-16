import 'bus_handover.dart';
import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'money_summary.dart';
import 'passenger.dart';

/// Per-bus money totals for the HANDLER's "in hand" view.
///
/// Built on [BusMoneySummary] — the single source of truth the admin's money
/// board uses — so the handler and admin can NEVER disagree on what was
/// collected OR on what must be handed over.
///
/// The bus owner's rent is ADMIN-ONLY: the admin settles the owner out of what
/// the handler hands over, so rent never appears on — nor is deducted by — any
/// handler figure. [spent] is the handler's own ground expenses (driver, fuel,
/// food, …) and [inHand] is the cash left after those, which is exactly what
/// they hand to the admin — and exactly the admin's
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

  /// Total of every expense logged against this bus — the handler's own ground
  /// costs (driver, fuel, food, …). The bus owner's rent is admin-only and is
  /// never part of this figure.
  final double spent;

  /// Total extra income (cabin / gallery / other cash taken in outside fares).
  final double income;

  /// Cash already handed to the admin for this bus — the sum of this bus's
  /// [BusHandover.handedOverAmount] rows, whoever recorded them. Mirrors
  /// [BusMoneySummary.handedOver] so the two surfaces cannot drift.
  final double handedOver;

  const HandlerBusMoney({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    this.handedOver = 0,
  });

  /// Net cash this bus generated for the admin — collected + extra income taken
  /// in, less the handler's ground expenses. This is the GROSS figure the
  /// handler is accountable for, and is exactly the admin's
  /// [BusMoneySummary.expectedHandover] for the same bus. It deliberately does
  /// NOT move when cash is handed over: the invariant
  /// `admin.expectedHandover == handler.inHand` is asserted in
  /// `cross_system_invariants_test` and must keep holding.
  double get inHand => collected + income - spent;

  /// What the handler STILL owes the admin — [inHand] less what has already
  /// been handed over. This is the figure that must fall to zero once they
  /// settle; before handovers existed the handler's screen read the full
  /// [inHand] forever, even after the cash had physically changed hands.
  /// Mirrors [BusMoneySummary.outstandingHandover].
  double get outstanding => inHand - handedOver;

  /// True once this bus is settled — nothing material left to hand over.
  /// Uses the shared money epsilon so sub-rupee dust never leaves a bus
  /// looking unsettled.
  bool get isSettled => outstanding.abs() <= Collection.kMoneyEpsilon;

  /// [dueForSeat] resolves a seated rider's fare for one seat (the bus's
  /// `amountDueForSeat`); injected so this stays decoupled from the heavy Bus
  /// seat-layout model and is trivially unit-testable.
  factory HandlerBusMoney.compute({
    required String busId,
    required Iterable<Passenger> passengers,
    required List<Collection> collections,
    required List<Expense> expenses,
    List<IncomeEntry> incomes = const [],
    List<BusHandover> handovers = const [],
    required double Function(Passenger passenger, String seatId) dueForSeat,
  }) {
    // EVERY figure comes from the shared BusMoneySummary — including to-collect
    // and to-return, which used to be finished off by a bespoke second pass
    // right here. Handing the roster and the fare resolver straight down means
    // both sides walk the same seats through the same `busSeatAr`, so the
    // handler's "still to collect" is the admin's by construction rather than by
    // two implementations agreeing to stay in step.
    //
    // Rent is kept OUT of this base (`busRent: 0`) so `expensesTotal` stays the
    // handler's ground expenses only — the owner's rent is the admin's cost and
    // is deliberately invisible on every handler figure.
    final base = BusMoneySummary.compute(
      busId: busId,
      collections: collections,
      expenses: expenses,
      handovers: handovers,
      incomes: incomes,
      busRent: 0,
      passengers: passengers,
      dueForSeat: dueForSeat,
    );

    return HandlerBusMoney(
      collected: base.collected,
      toReturn: base.toReturnTotal,
      toCollect: base.toCollectTotal,
      spent: base.expensesTotal, // busRent: 0 → logged ground expenses only
      income: base.income,
      handedOver: base.handedOver,
    );
  }
}
