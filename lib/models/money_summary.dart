import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'bus_handover.dart';
import 'passenger.dart';

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

  /// Extra income logged against this bus (cabin / gallery / other) — cash the
  /// handler takes in OUTSIDE passenger fares. It adds to what they hold and
  /// must hand over, and to both profit figures.
  final double income;

  /// The bus owner's rent, already folded into [expensesTotal]. Kept as a
  /// discrete figure so it can be surfaced as its own ledger row. The HANDLER
  /// settles the owner directly out of the cash they collect, so rent is a real
  /// deduction from what they hand over — it sits INSIDE the handover
  /// expectation (see [expectedHandover]), never added back.
  final double busRent;

  const BusMoneySummary({
    required this.busId,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toReturnTotal,
    required this.toCollectTotal,
    this.revenueBilled = 0,
    this.income = 0,
    this.busRent = 0,
  });

  /// Net cash the bus should hand over: collections + extra income − ALL costs
  /// (every expense in [expensesTotal], the bus owner's rent INCLUDED — the
  /// handler settles the owner out of the cash they collect). This is exactly
  /// the cash profit [netCollected]: the handler hands over what's left after
  /// every cost, so the settlement figure and the P&L net are the SAME number
  /// on every screen.
  double get expectedHandover => netCollected;

  /// Still-owed handover (expected minus what was actually handed over).
  double get outstandingHandover => expectedHandover - handedOver;

  /// TRUE profit/loss for the bus: fares billed + extra income − (rent +
  /// expenses). Reflects the trip's real result even before every passenger
  /// has paid.
  double get netBilled => revenueBilled + income - expensesTotal;

  /// CASH profit/loss so far: money actually collected + extra income − (rent +
  /// expenses). Equal to [expectedHandover] — the handler hands over exactly the
  /// net cash they hold once every cost (the owner's rent included) is paid.
  double get netCollected => collected + income - expensesTotal;

  /// [passengers] + [dueForSeat] make to-collect the TRUE money still owed, not
  /// just the recorded shortfalls: a seated rider with NO collection row on this
  /// bus still owes their full seat fare, so admin no longer reads "to collect 0"
  /// while the handler shows the full billed revenue. Mirrors
  /// [HandlerBusMoney.compute] exactly (seat-AGNOSTIC: a rider with ANY row on
  /// this bus is already covered by the recorded shortfall, so they are skipped
  /// regardless of which seat that row names) so admin and handler can never
  /// disagree. When [dueForSeat] is null (e.g. the handler's own call, which does
  /// its own seated-uncollected pass) to-collect stays the recorded shortfalls
  /// alone — no double-count.
  factory BusMoneySummary.compute({
    required String busId,
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    List<IncomeEntry> incomes = const [],
    double busRent = 0,
    double revenueBilled = 0,
    Iterable<Passenger> passengers = const [],
    double Function(Passenger passenger, String seatId)? dueForSeat,
  }) {
    final busCollections = collections.where((c) => c.busId == busId);
    final busExpenses = expenses.where((e) => e.busId == busId);
    final busHandovers = handovers.where((h) => h.busId == busId);
    final busIncomes = incomes.where((i) => i.busId == busId);

    // Recorded shortfalls on existing collection rows …
    var toCollect = busCollections.fold(
      0.0,
      (sum, c) => sum + c.stillToCollect,
    );
    // … plus seated riders nobody has opened a collection for yet, at their full
    // seat fare. Keyed by passenger id (seat-agnostic): a rider with ANY row on
    // this bus is already in the shortfall sum above, so skip them here.
    if (dueForSeat != null) {
      final collectedPassengerIds = busCollections
          .map((c) => c.passengerId)
          .toSet();
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
    }

    return BusMoneySummary(
      busId: busId,
      collected: busCollections.fold(0.0, (sum, c) => sum + c.netCollected),
      income: busIncomes.fold(0.0, (sum, i) => sum + i.amount),
      busRent: busRent,
      revenueBilled: revenueBilled,
      // The bus owner's rent is the single source of truth (not a DB expense
      // row), so it is added to the expense rows here rather than counted twice.
      expensesTotal:
          busExpenses.fold(0.0, (sum, e) => sum + e.amount) + busRent,
      handedOver: busHandovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      toReturnTotal: busCollections.fold(
        0.0,
        (sum, c) => sum + c.changeToReturn,
      ),
      toCollectTotal: toCollect,
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

  /// Extra income (cabin / gallery / other) across this handler's buses.
  final double income;

  /// Bus owner rent across this handler's buses, already inside [expensesTotal].
  /// The handler settles the owners, so it is part of what's deducted from the
  /// handover expectation, not added back.
  final double busRent;

  const HandlerMoneySummary({
    required this.handlerPassengerId,
    required this.busIds,
    required this.revenueBilled,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toCollectTotal,
    required this.toReturnTotal,
    this.income = 0,
    this.busRent = 0,
  });

  double get netBilled => revenueBilled + income - expensesTotal;
  double get netCollected => collected + income - expensesTotal;

  /// Cash this handler should hand over: collections + income − ALL costs (their
  /// ground expenses AND the owner's rent they settle). Equal to [netCollected]
  /// — the cash they hold once every cost is paid.
  double get expectedHandover => netCollected;
  double get outstandingHandover => expectedHandover - handedOver;

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
      income: buses.fold(0.0, (s, b) => s + b.income),
      busRent: buses.fold(0.0, (s, b) => s + b.busRent),
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

  /// Total extra income (cabin / gallery / other) across every bus on the tour.
  final double totalIncome;

  /// Total bus owner rent across the tour, already inside [totalExpenses]. The
  /// handlers settle the owners, so it is part of what's deducted from the
  /// handover expectation, not added back.
  final double totalBusRent;

  const TourMoneySummary({
    required this.totalCollected,
    required this.totalExpenses,
    required this.totalHandedOver,
    required this.totalToReturn,
    required this.totalToCollect,
    this.totalRevenueBilled = 0,
    this.totalIncome = 0,
    this.totalBusRent = 0,
  });

  /// Net cash for the tour (collections + extra income − expenses).
  double get totalNet => totalCollected + totalIncome - totalExpenses;

  /// TRUE profit/loss for the tour: fares billed + extra income − (rents +
  /// expenses).
  double get totalNetBilled => totalRevenueBilled + totalIncome - totalExpenses;

  /// Cash the handlers should hand over across the tour: collections + income −
  /// ALL costs (ground expenses AND the owner rents they settle). Equal to
  /// [totalNet] — the settlement figure and the tour's cash profit are one and
  /// the same number on every screen.
  double get totalExpectedHandover => totalNet;

  /// Still-owed handover across the whole tour.
  double get totalOutstandingHandover =>
      totalExpectedHandover - totalHandedOver;

  /// [toCollectTotal] overrides the recorded-shortfall sum with the caller's
  /// per-bus roll-up (which also counts seated-but-uncollected riders), so the
  /// tour total and the per-bus [BusMoneySummary.toCollectTotal] figures always
  /// agree. When null, to-collect falls back to the recorded shortfalls alone.
  factory TourMoneySummary.compute({
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    List<IncomeEntry> incomes = const [],
    double busRentsTotal = 0,
    double totalRevenueBilled = 0,
    double? toCollectTotal,
  }) {
    return TourMoneySummary(
      totalCollected: collections.fold(0.0, (sum, c) => sum + c.netCollected),
      totalIncome: incomes.fold(0.0, (sum, i) => sum + i.amount),
      totalBusRent: busRentsTotal,
      totalRevenueBilled: totalRevenueBilled,
      // Bus owner rents are the single source of truth (not DB expense rows),
      // so they are folded into the expense total here rather than double-counted.
      totalExpenses:
          expenses.fold(0.0, (sum, e) => sum + e.amount) + busRentsTotal,
      totalHandedOver: handovers.fold(
        0.0,
        (sum, h) => sum + h.handedOverAmount,
      ),
      totalToReturn: collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          toCollectTotal ??
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
