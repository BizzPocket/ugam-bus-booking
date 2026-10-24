import '../utils/seat_money_state.dart';
import 'collection.dart';
import 'expense.dart';
import 'income_entry.dart';
import 'bus_handover.dart';
import 'passenger.dart';
import 'trip_pnl.dart';

/// How logged expenses roll into bus bhadu / Malik settlement and P&L.
///
/// THE RULE (user-confirmed 2026-10-25, the owner's own formula sheet:
/// Kharch = A1 bus bhadu + A2 driver food + A3 other; diesel and advance are
/// paid OUT of A1): on a pakku-bhadu bus ([rentIncludesFuel]) the agreed rent
/// is the WHOLE bus cost. Diesel ([ExpenseCategory.fuel]) and owner advances
/// ([ExpenseCategory.busOwner]) paid on the trip are PART of that rent: they
/// never add to the trip cost, they only shrink what is still owed to the
/// owner. EVERY driver cost ([ExpenseCategory.driver] — pay or food) is extra,
/// ON TOP of the rent, like food, toll and everything else.
///
/// Rent 50,000 · diesel 35,000 · advance 5,000 · driver food 500 · other 500 →
///   bus cost 50,000 · owner still owed 50,000 − 35,000 − 5,000 = 10,000
///   · trip kharch 50,000 + 500 + 500 = 51,000.
///
/// (Superseded 2026-10-15 rule: driver pay was inside the rent. The owner
/// asked explicitly — "All driver cost extra".)
///
/// When the rent does NOT include fuel, diesel is on top too (folded into
/// [otherExpensesTotal]) and only advances reduce the owed rent.
///
/// [driverTotal] and the `driver` parameters stay for API stability and are
/// always 0 inside the rent now.
class BusExpenseRollup {
  const BusExpenseRollup({
    required this.fuelTotal,
    this.driverTotal = 0,
    required this.ownerAdvanceTotal,
    required this.otherExpensesTotal,
    required this.effectiveBusCost,
    required this.expensesTotal,
    required this.busMalikPayable,
  });

  /// Diesel paid INSIDE the rent (0 when the rent excludes fuel).
  final double fuelTotal;

  /// Driver pay paid INSIDE the rent (0 when the rent excludes fuel).
  final double driverTotal;
  final double ownerAdvanceTotal;

  /// Everything ON TOP of the rent (food, toll, …; plus diesel + driver when
  /// the rent excludes them).
  final double otherExpensesTotal;
  final double effectiveBusCost;
  final double expensesTotal;
  final double busMalikPayable;

  /// The one formula for "bus cost" — shared by the rollup, the per-bus
  /// summary getter and the ledger path so they can never drift apart.
  static double busCost({
    required double busRent,
    required double fuel,
    required double driver,
    required double ownerAdvance,
    required bool rentIncludesFuel,
  }) {
    final inside = rentIncludesFuel
        ? fuel + driver + ownerAdvance
        : ownerAdvance;
    return busRent > inside ? busRent : inside;
  }

  /// What the admin still owes the owner: rent − everything already paid
  /// toward it on the trip, floored at 0.
  static double malikPayable({
    required double busRent,
    required double fuel,
    required double driver,
    required double ownerAdvance,
    required bool rentIncludesFuel,
  }) {
    final paid = rentIncludesFuel
        ? fuel + driver + ownerAdvance
        : ownerAdvance;
    return (busRent - paid).clamp(0.0, double.infinity);
  }

  /// The same rule when the LEDGER is the authority on the ground total (it
  /// posts every expense row as one `expense.ground` figure) and the
  /// categorised rows only say how much of it was diesel / driver / advance.
  /// [fuel], [driver] and [ownerAdvance] are RAW category sums; on a bus whose
  /// rent excludes fuel, diesel + driver stay inside [ground] as on-top cost.
  ///
  /// Shared by the money board ([MoneyController.summaryForBus]) and Finance so
  /// the same trip prints the same profit on both.
  static BusExpenseRollup fromLedger({
    required double ground,
    required double busRent,
    required double fuel,
    required double driver,
    required double ownerAdvance,
    required bool rentIncludesFuel,
  }) {
    final f = rentIncludesFuel ? fuel : 0.0;
    // Driver cost is never inside the rent — it stays in [ground] as on-top.
    const d = 0.0;
    final other = (ground - f - d - ownerAdvance).clamp(0.0, double.infinity);
    final cost = busCost(
      busRent: busRent,
      fuel: f,
      driver: d,
      ownerAdvance: ownerAdvance,
      rentIncludesFuel: rentIncludesFuel,
    );
    return BusExpenseRollup(
      fuelTotal: f,
      driverTotal: d,
      ownerAdvanceTotal: ownerAdvance,
      otherExpensesTotal: other,
      effectiveBusCost: cost,
      expensesTotal: cost + other,
      busMalikPayable: malikPayable(
        busRent: busRent,
        fuel: f,
        driver: d,
        ownerAdvance: ownerAdvance,
        rentIncludesFuel: rentIncludesFuel,
      ),
    );
  }

  static BusExpenseRollup fromExpenses({
    required Iterable<Expense> busExpenses,
    required double busRent,
    required bool rentIncludesFuel,
  }) {
    var fuel = 0.0;
    var driver = 0.0;
    var ownerAdvance = 0.0;
    var other = 0.0;
    for (final e in busExpenses) {
      switch (e.category) {
        case ExpenseCategory.fuel:
          fuel += e.amount;
        case ExpenseCategory.busOwner:
          ownerAdvance += e.amount;
        default:
          // Includes ExpenseCategory.driver: every driver cost is on top.
          other += e.amount;
      }
    }

    if (!rentIncludesFuel) {
      other += fuel;
      fuel = 0;
    }

    final effectiveBusCost = busCost(
      busRent: busRent,
      fuel: fuel,
      driver: driver,
      ownerAdvance: ownerAdvance,
      rentIncludesFuel: rentIncludesFuel,
    );

    return BusExpenseRollup(
      fuelTotal: fuel,
      driverTotal: driver,
      ownerAdvanceTotal: ownerAdvance,
      otherExpensesTotal: other,
      effectiveBusCost: effectiveBusCost,
      expensesTotal: effectiveBusCost + other,
      busMalikPayable: malikPayable(
        busRent: busRent,
        fuel: fuel,
        driver: driver,
        ownerAdvance: ownerAdvance,
        rentIncludesFuel: rentIncludesFuel,
      ),
    );
  }
}

/// Aggregated money figures for a single bus on a tour.
///
/// Pure value object — compute it once from raw model lists and read its
/// derived getters in the UI. No Flutter/GetX dependencies.
class BusMoneySummary {
  final String busId;

  /// Handler CASH on this bus ([Collection.netCash] / the ledger's
  /// `cash.handler`). Drives the handover, so it never includes [online].
  final double collected;

  /// UPI money paid against this bus's collection rows
  /// ([Collection.amountOnline]) — received by the organiser, never held by
  /// the handler. Counted in [pnl]'s received, never in the handover.
  final double online;

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

  /// Agreed bus bhadu / rent (A1). Folded into [expensesTotal] via
  /// [BusExpenseRollup], not double-counted as a separate expense row.
  final double busRent;

  /// Diesel paid inside the rent (0 when the rent excludes fuel).
  final double fuelTotal;

  /// Driver pay paid inside the rent (0 when the rent excludes fuel).
  final double driverTotal;
  final double ownerAdvanceTotal;
  final double otherExpensesTotal;
  final double busMalikPayable;
  final bool rentIncludesFuel;

  /// How much of [collected] was paid by riders who NO LONGER hold a seat on
  /// this bus — they were unseated, or moved to another bus.
  final double detachedCash;

  const BusMoneySummary({
    required this.busId,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toReturnTotal,
    required this.toCollectTotal,
    this.online = 0,
    this.revenueBilled = 0,
    this.income = 0,
    this.busRent = 0,
    this.fuelTotal = 0,
    this.driverTotal = 0,
    this.ownerAdvanceTotal = 0,
    this.otherExpensesTotal = 0,
    this.busMalikPayable = 0,
    this.rentIncludesFuel = true,
    this.detachedCash = 0,
  });

  /// Contract cost (bhadu) used in P&L — at least the agreed rent, or diesel
  /// + driver + advances when those exceed it on a pakku-bhadu bus.
  double get effectiveBusCost => BusExpenseRollup.busCost(
    busRent: busRent,
    fuel: fuelTotal,
    driver: driverTotal,
    ownerAdvance: ownerAdvanceTotal,
    rentIncludesFuel: rentIncludesFuel,
  );

  /// Cash the handler pays on the trip (diesel, driver, advances, food, toll,
  /// …) — EVERY expense row, whether or not it sits inside the rent.
  double get groundExpenses =>
      fuelTotal + driverTotal + ownerAdvanceTotal + otherExpensesTotal;

  /// Net cash the bus should hand over: collections + extra income − ground
  /// costs. Bus bhadu is settled by the admin with the owner, not deducted here.
  double get expectedHandover => collected + income - groundExpenses;

  double get outstandingHandover => expectedHandover - handedOver;

  /// This bus's two profit figures — see [TripPnl], the one formula.
  TripPnl get pnl => TripPnl(
        billed: revenueBilled,
        cash: collected,
        online: online,
        income: income,
        costs: expensesTotal,
      );

  /// Trip profit (billed basis) — [TripPnl.tripProfit].
  double get netBilled => pnl.tripProfit;

  /// Cash so far (cash + online received) — [TripPnl.cashSoFar].
  double get netCollected => pnl.cashSoFar;

  BusMoneySummary copyWith({
    double? collected,
    double? online,
    double? revenueBilled,
    double? expensesTotal,
    double? handedOver,
    double? toReturnTotal,
    double? toCollectTotal,
    double? income,
    double? busRent,
    double? fuelTotal,
    double? driverTotal,
    double? ownerAdvanceTotal,
    double? otherExpensesTotal,
    double? busMalikPayable,
    bool? rentIncludesFuel,
    double? detachedCash,
  }) {
    return BusMoneySummary(
      busId: busId,
      collected: collected ?? this.collected,
      online: online ?? this.online,
      revenueBilled: revenueBilled ?? this.revenueBilled,
      expensesTotal: expensesTotal ?? this.expensesTotal,
      handedOver: handedOver ?? this.handedOver,
      toReturnTotal: toReturnTotal ?? this.toReturnTotal,
      toCollectTotal: toCollectTotal ?? this.toCollectTotal,
      income: income ?? this.income,
      busRent: busRent ?? this.busRent,
      fuelTotal: fuelTotal ?? this.fuelTotal,
      driverTotal: driverTotal ?? this.driverTotal,
      ownerAdvanceTotal: ownerAdvanceTotal ?? this.ownerAdvanceTotal,
      otherExpensesTotal: otherExpensesTotal ?? this.otherExpensesTotal,
      busMalikPayable: busMalikPayable ?? this.busMalikPayable,
      rentIncludesFuel: rentIncludesFuel ?? this.rentIncludesFuel,
      detachedCash: detachedCash ?? this.detachedCash,
    );
  }

  factory BusMoneySummary.compute({
    required String busId,
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    List<IncomeEntry> incomes = const [],
    double busRent = 0,
    bool rentIncludesFuel = true,
    double revenueBilled = 0,
    Iterable<Passenger> passengers = const [],
    double Function(Passenger passenger, String seatId)? dueForSeat,
  }) {
    final busCollections = collections.where((c) => c.busId == busId);
    final busExpenses = expenses.where((e) => e.busId == busId);
    final busHandovers = handovers.where((h) => h.busId == busId);
    final busIncomes = incomes.where((i) => i.busId == busId);

    final rollup = BusExpenseRollup.fromExpenses(
      busExpenses: busExpenses,
      busRent: busRent,
      rentIncludesFuel: rentIncludesFuel,
    );

    final double toCollect;
    final double toReturn;
    if (dueForSeat != null) {
      final ar = busSeatAr(
        busId: busId,
        passengers: passengers,
        collections: collections,
        dueForSeat: dueForSeat,
      );
      toCollect = ar.toCollect;
      toReturn = ar.toReturn;
    } else {
      toCollect = busCollections.fold(0.0, (sum, c) => sum + c.stillToCollect);
      toReturn = busCollections.fold(0.0, (sum, c) => sum + c.changeToReturn);
    }

    final seatedHere = <String>{
      for (final p in passengers)
        if (p.assignedSeats.any((a) => a.busId == busId)) p.id,
    };
    final detachedCash = passengers.isEmpty
        ? 0.0
        : busCollections
              .where((c) => !seatedHere.contains(c.passengerId))
              .fold(0.0, (sum, c) => sum + c.netCash);

    return BusMoneySummary(
      busId: busId,
      collected: busCollections.fold(0.0, (sum, c) => sum + c.netCash),
      online: busCollections.fold(0.0, (sum, c) => sum + c.amountOnline),
      detachedCash: detachedCash,
      income: busIncomes.fold(0.0, (sum, i) => sum + i.amount),
      busRent: busRent,
      rentIncludesFuel: rentIncludesFuel,
      fuelTotal: rollup.fuelTotal,
      driverTotal: rollup.driverTotal,
      ownerAdvanceTotal: rollup.ownerAdvanceTotal,
      otherExpensesTotal: rollup.otherExpensesTotal,
      busMalikPayable: rollup.busMalikPayable,
      revenueBilled: revenueBilled,
      expensesTotal: rollup.expensesTotal,
      handedOver: busHandovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      toReturnTotal: toReturn,
      toCollectTotal: toCollect,
    );
  }
}

/// Aggregated money figures for ONE handler across all the buses they run on a
/// tour (a handler manages whole buses via [Bus.handlerPassengerId], so a
/// handler's P&L is simply the sum of their buses' [BusMoneySummary]s).
class HandlerMoneySummary {
  final String? handlerPassengerId;
  final List<String> busIds;
  final double revenueBilled;
  final double collected;
  final double online;
  final double expensesTotal;
  final double handedOver;
  final double toCollectTotal;
  final double toReturnTotal;
  final double income;
  final double busRent;
  final double detachedCash;

  /// Sum of each bus's [BusMoneySummary.groundExpenses].
  final double groundExpensesSum;

  const HandlerMoneySummary({
    required this.handlerPassengerId,
    required this.busIds,
    required this.revenueBilled,
    required this.collected,
    required this.expensesTotal,
    required this.handedOver,
    required this.toCollectTotal,
    required this.toReturnTotal,
    this.online = 0,
    this.income = 0,
    this.busRent = 0,
    this.detachedCash = 0,
    this.groundExpensesSum = 0,
  });

  /// This handler's buses' two profit figures — see [TripPnl].
  TripPnl get pnl => TripPnl(
        billed: revenueBilled,
        cash: collected,
        online: online,
        income: income,
        costs: expensesTotal,
      );
  double get netBilled => pnl.tripProfit;
  double get netCollected => pnl.cashSoFar;
  double get groundExpenses =>
      groundExpensesSum > 0 ? groundExpensesSum : expensesTotal - busRent;
  double get expectedHandover => collected + income - groundExpenses;
  double get outstandingHandover => expectedHandover - handedOver;

  factory HandlerMoneySummary.fromBuses(
    String? handlerPassengerId,
    List<BusMoneySummary> buses, {
    double detachedCash = 0,
  }) {
    return HandlerMoneySummary(
      handlerPassengerId: handlerPassengerId,
      busIds: [for (final b in buses) b.busId],
      detachedCash: detachedCash,
      revenueBilled: buses.fold(0.0, (s, b) => s + b.revenueBilled),
      collected: buses.fold(0.0, (s, b) => s + b.collected),
      online: buses.fold(0.0, (s, b) => s + b.online),
      income: buses.fold(0.0, (s, b) => s + b.income),
      busRent: buses.fold(0.0, (s, b) => s + b.busRent),
      groundExpensesSum: buses.fold(0.0, (s, b) => s + b.groundExpenses),
      expensesTotal: buses.fold(0.0, (s, b) => s + b.expensesTotal),
      handedOver: buses.fold(0.0, (s, b) => s + b.handedOver),
      toCollectTotal: buses.fold(0.0, (s, b) => s + b.toCollectTotal),
      toReturnTotal: buses.fold(0.0, (s, b) => s + b.toReturnTotal),
    );
  }
}

/// Aggregated money figures across an entire tour (all buses).
class TourMoneySummary {
  /// Handler CASH across the trip — drives the handover; excludes [totalOnline].
  final double totalCollected;

  /// UPI money the organiser received for this trip (the ledger's
  /// `bank.gateway`, or Σ [Collection.amountOnline] where that view is not
  /// deployed — see [LedgerMoneySource.fetchOnlineForTour]). Tour-level: a
  /// waitlisted rider's advance belongs to no bus, so this can exceed the sum
  /// of the per-bus [BusMoneySummary.online].
  final double totalOnline;
  final double totalRevenueBilled;
  final double totalExpenses;
  final double totalHandedOver;
  final double totalToReturn;
  final double totalToCollect;
  final double totalIncome;
  final double totalBusRent;
  final double totalDetachedCash;
  final double orphanExpenses;
  final double orphanCollected;
  final double orphanIncome;
  final int busesMissingRent;

  /// What the handlers actually spent on the ground (every expense row:
  /// diesel, owner advances, food, toll, …) — the Σ of each bus's
  /// [BusMoneySummary.groundExpenses]. Null on the old shape, where it was
  /// derivable as `totalExpenses − totalBusRent`; under the pakku-bhadu rule
  /// diesel / advances are absorbed INTO the rent inside [totalExpenses], so
  /// that subtraction would drop them and over-state the handover.
  final double? groundExpensesTotal;

  bool get hasUnrecordedRent => busesMissingRent > 0;

  bool get hasOrphanMoney =>
      orphanExpenses.abs() > 0.005 ||
      orphanCollected.abs() > 0.005 ||
      orphanIncome.abs() > 0.005;

  const TourMoneySummary({
    required this.totalCollected,
    required this.totalExpenses,
    required this.totalHandedOver,
    required this.totalToReturn,
    required this.totalToCollect,
    this.totalOnline = 0,
    this.totalRevenueBilled = 0,
    this.totalIncome = 0,
    this.totalBusRent = 0,
    this.totalDetachedCash = 0,
    this.orphanExpenses = 0,
    this.orphanCollected = 0,
    this.orphanIncome = 0,
    this.busesMissingRent = 0,
    this.groundExpensesTotal,
  });

  /// The trip's two profit figures — see [TripPnl], the one formula every
  /// money surface (and [FinanceController]'s row for this trip) reads.
  TripPnl get pnl => TripPnl(
        billed: totalRevenueBilled,
        cash: totalCollected,
        online: totalOnline,
        income: totalIncome,
        costs: totalExpenses,
      );

  /// Cash so far — [TripPnl.cashSoFar] (cash + online received).
  double get totalNet => pnl.cashSoFar;

  /// Trip profit — [TripPnl.tripProfit] (billed basis).
  double get totalNetBilled => pnl.tripProfit;
  double get totalGroundExpenses =>
      groundExpensesTotal ?? totalExpenses - totalBusRent;
  double get totalExpectedHandover =>
      totalCollected + totalIncome - totalGroundExpenses;
  double get totalOutstandingHandover =>
      totalExpectedHandover - totalHandedOver;

  factory TourMoneySummary.compute({
    required List<Collection> collections,
    required List<Expense> expenses,
    required List<BusHandover> handovers,
    List<IncomeEntry> incomes = const [],
    double busRentsTotal = 0,
    double totalRevenueBilled = 0,
    double? toCollectTotal,
    double? toReturnTotal,
    double detachedCashTotal = 0,
    Set<String>? knownBusIds,
    int busesMissingRent = 0,
    double? totalExpensesOverride,
    double? onlineTotal,
  }) {
    double orphanExpenses = 0;
    double orphanCollected = 0;
    double orphanIncome = 0;
    if (knownBusIds != null) {
      orphanExpenses = expenses
          .where((e) => !knownBusIds.contains(e.busId))
          .fold(0.0, (sum, e) => sum + e.amount);
      orphanCollected = collections
          .where((c) => !knownBusIds.contains(c.busId))
          .fold(0.0, (sum, c) => sum + c.netCash);
      orphanIncome = incomes
          .where((i) => !knownBusIds.contains(i.busId))
          .fold(0.0, (sum, i) => sum + i.amount);
    }

    final expenseRows = expenses.fold(0.0, (sum, e) => sum + e.amount);
    final legacyExpenses = expenseRows + busRentsTotal;

    return TourMoneySummary(
      orphanExpenses: orphanExpenses,
      orphanCollected: orphanCollected,
      orphanIncome: orphanIncome,
      busesMissingRent: busesMissingRent,
      totalCollected: collections.fold(0.0, (sum, c) => sum + c.netCash),
      totalOnline:
          onlineTotal ??
          collections.fold(0.0, (sum, c) => sum + c.amountOnline),
      totalDetachedCash: detachedCashTotal,
      totalIncome: incomes.fold(0.0, (sum, i) => sum + i.amount),
      totalBusRent: busRentsTotal,
      totalRevenueBilled: totalRevenueBilled,
      // [totalExpensesOverride] is the Σ of the KNOWN buses' expensesTotal, so
      // rows on a bus the tour no longer lists must be added back — they stay
      // inside the trip total (see [orphanExpenses]), never silently dropped.
      totalExpenses: totalExpensesOverride != null
          ? totalExpensesOverride + orphanExpenses
          : legacyExpenses,
      groundExpensesTotal: expenseRows,
      totalHandedOver: handovers.fold(
        0.0,
        (sum, h) => sum + h.handedOverAmount,
      ),
      totalToReturn:
          toReturnTotal ??
          collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          toCollectTotal ??
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
