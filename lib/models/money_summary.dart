import '../utils/seat_money_state.dart';
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
  /// discrete figure so it can be surfaced as its own ledger row.
  ///
  /// ADMIN-ONLY: the ADMIN settles the bus owner, not the handler, so rent is
  /// NOT deducted from what the handler hands over — it is added back out of
  /// [expectedHandover] and never shown on any handler surface. It stays a real
  /// cost of the trip, so it remains inside [netCollected] / [netBilled].
  final double busRent;

  /// How much of [collected] was paid by riders who NO LONGER hold a seat on
  /// this bus — they were unseated, or moved to another bus.
  ///
  /// Cash is tracked by `bus_id` (it stays with whoever physically took it),
  /// while [revenueBilled] is recomputed from who is seated RIGHT NOW. So when
  /// seating changes after money was taken, the two drift apart and the bus
  /// reads "collected more than it billed" with no visible reason. This is
  /// exactly that gap, surfaced so the figure is never a mystery.
  ///
  /// DISPLAY ONLY: it is already inside [collected] and is NOT subtracted from
  /// any net — the handler really does hold this cash and still has to account
  /// for it. Zero when no passenger list was supplied (we can't tell who is
  /// seated, so we never guess).
  final double detachedCash;

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
    this.detachedCash = 0,
  });

  /// Expenses the HANDLER pays on the ground (fuel, driver, food, …) — every
  /// expense except the bus owner's rent, which the admin settles.
  double get groundExpenses => expensesTotal - busRent;

  /// Net cash the bus should hand over: collections + extra income − the
  /// handler's GROUND costs only. The bus owner's rent is the admin's to pay,
  /// so it is NOT deducted here — the handler hands over the full cash they
  /// hold after their own ground spending, and the admin settles the owner from
  /// that. This is why it differs from the cash profit [netCollected] by exactly
  /// [busRent].
  double get expectedHandover => collected + income - groundExpenses;

  /// Still-owed handover (expected minus what was actually handed over).
  double get outstandingHandover => expectedHandover - handedOver;

  /// TRUE profit/loss for the bus: fares billed + extra income − (rent +
  /// expenses). Reflects the trip's real result even before every passenger
  /// has paid.
  double get netBilled => revenueBilled + income - expensesTotal;

  /// CASH profit/loss so far: money actually collected + extra income − (rent +
  /// expenses). What the admin is left with AFTER paying the owner out of the
  /// handler's handover — [expectedHandover] minus [busRent].
  double get netCollected => collected + income - expensesTotal;

  /// [passengers] + [dueForSeat] make to-collect / to-return the TRUE money
  /// still owed and still owed BACK: every seated rider is priced at their LIVE
  /// seat fare and measured against the row actually resolved for that seat, via
  /// the shared [busSeatAr]. So a rider with no collection row yet owes their
  /// full fare (admin no longer reads "to collect 0" while the handler shows the
  /// full billed revenue), and a rider whose bus was re-priced after they paid
  /// shows the real difference rather than a snapshot of the old fare.
  ///
  /// EVERY surface now shares that one walk — this factory, the collection
  /// roster, [HandlerBusMoney.compute] (which routes straight through here), and
  /// `MoneyController.summaryForBus` on BOTH its ledger and legacy paths. Admin,
  /// handler and the tour totals therefore cannot disagree, and a header figure
  /// is always the sum of the rows printed beneath it.
  ///
  /// This deliberately does NOT read `finance_rider_balance`. That view is
  /// passenger-scoped over posted `ar.rider` lines, so a per-bus figure had to be
  /// reconstructed by apportioning each rider's tour-wide balance across their
  /// buses — which lands a fraction of one rider's balance on a bus whose own
  /// seat is square, and inherits any drift between the ledger's posted fare and
  /// the current one. Check 7 in supabase/diagnostics/finance_audit_checks.sql
  /// measures that drift; migration 092 stops it accumulating.
  ///
  /// When [dueForSeat] is null no seat can be priced, so both figures fall back
  /// to the rows' own recorded shortfalls — see the note at the call site.
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

    // What every seated rider still owes / is still owed, priced seat by seat
    // against the LIVE fare — the same walk the collection roster renders, so a
    // header total is always the sum of the lines below it. See [busSeatAr].
    //
    // Without a fare resolver we cannot price a seat at all, so the figures fall
    // back to the recorded shortfalls on the rows themselves. That reads
    // `amount_due` — a SNAPSHOT of the fare at the moment the cash was taken —
    // so it goes stale the instant a bus is re-priced. It is the weaker answer
    // and is used only when the caller genuinely has no bus to price against
    // (an orphaned bus the tour no longer lists).
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

    // Cash on this bus whose payer holds no seat here any more (see
    // [detachedCash]). Only derivable when the caller supplied the roster —
    // with no passengers to check against, EVERY row would look detached, so
    // the figure stays 0 (unknown) rather than raising a false alarm.
    final seatedHere = <String>{
      for (final p in passengers)
        if (p.assignedSeats.any((a) => a.busId == busId)) p.id,
    };
    // netCash, not netCollected: a UPI advance lands in the organiser's bank,
    // never in the handler's pocket. `collected` drives inHand, outstanding and
    // the pre-filled handover amount, and the ledger's own collected_minor
    // (finance_bus_summary, 063) counts only cash.handler receipts — so using
    // the rider-side figure here asks the handler to hand over money they were
    // never given, and leaves outstanding permanently short by the online take.
    final detachedCash = passengers.isEmpty
        ? 0.0
        : busCollections
              .where((c) => !seatedHere.contains(c.passengerId))
              .fold(0.0, (sum, c) => sum + c.netCash);

    return BusMoneySummary(
      busId: busId,
      collected: busCollections.fold(0.0, (sum, c) => sum + c.netCash),
      detachedCash: detachedCash,
      income: busIncomes.fold(0.0, (sum, i) => sum + i.amount),
      busRent: busRent,
      revenueBilled: revenueBilled,
      // The bus owner's rent is the single source of truth (not a DB expense
      // row), so it is added to the expense rows here rather than counted twice.
      expensesTotal:
          busExpenses.fold(0.0, (sum, e) => sum + e.amount) + busRent,
      handedOver: busHandovers.fold(0.0, (sum, h) => sum + h.handedOverAmount),
      toReturnTotal: toReturn,
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
  /// ADMIN-ONLY: the admin settles the owners, so it is added back out of the
  /// handover expectation and never shown to the handler.
  final double busRent;

  /// Cash this handler holds for riders who sit on NONE of their buses — the
  /// handler-level reading of [BusMoneySummary.detachedCash]. A rider shuffled
  /// between two buses the SAME handler runs is NOT detached here (the cash and
  /// the rider both stayed with this handler), which is why the caller supplies
  /// it instead of [fromBuses] summing the per-bus figures. Display only — it is
  /// already inside [collected] and changes no net.
  final double detachedCash;

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
    this.detachedCash = 0,
  });

  double get netBilled => revenueBilled + income - expensesTotal;
  double get netCollected => collected + income - expensesTotal;

  /// Ground expenses this handler pays (everything except the owners' rent).
  double get groundExpenses => expensesTotal - busRent;

  /// Cash this handler should hand over: collections + income − their GROUND
  /// expenses only. The owners' rent is the admin's to settle, so it is not
  /// deducted here (differs from [netCollected] by exactly [busRent]).
  double get expectedHandover => collected + income - groundExpenses;
  double get outstandingHandover => expectedHandover - handedOver;

  /// Roll a set of per-bus summaries up into one handler total.
  ///
  /// [detachedCash] must be supplied by the caller (which can see the roster
  /// across the handler's whole fleet); summing the per-bus figures here would
  /// over-report a rider merely moved from one of this handler's buses to
  /// another. Defaults to 0 — "unknown", never a false alarm.
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

  /// Total bus owner rent across the tour, already inside [totalExpenses].
  /// ADMIN-ONLY: the admin settles the owners, so it is added back out of the
  /// handover expectation and never shown to a handler.
  final double totalBusRent;

  /// Cash held across the tour for riders seated on NO bus at all — the
  /// trip-level reading of [BusMoneySummary.detachedCash]. A rider moved from
  /// one bus to another is NOT counted (they are still on the trip), so this is
  /// supplied by the caller rather than summed from the per-bus figures.
  /// Display only — already inside [totalCollected] and changes no net.
  final double totalDetachedCash;

  /// Money on rows whose `bus_id` is NOT one of the tour's current buses.
  ///
  /// The money board draws one row per bus in `tour.buses` and computes those
  /// rows from that same list, but these trip totals fold EVERY row carrying
  /// the tour id. So a row pointing at a bus that is no longer on the tour is
  /// counted here while appearing on no bus row — the per-bus figures silently
  /// stop adding up to the total above them, with nothing on screen explaining
  /// the gap.
  ///
  /// These stay INSIDE the totals (the money is real and must never quietly
  /// vanish from the trip's books); they are broken out purely so the UI can
  /// show the remainder and make the arithmetic reconcile. All zero when the
  /// caller supplied no bus list — with nothing to check against, every row
  /// would look orphaned.
  final double orphanExpenses;
  final double orphanCollected;
  final double orphanIncome;

  /// How many of the tour's buses have NO owner rent recorded (`bus_price` is
  /// 0). The column is `not null default 0`, so "nobody entered the rent" and
  /// "this bus is free" are the same value — and the codebase already reads
  /// `> 0` as "a real rent" (migration 072, `bus_money_screen.dart:249`,
  /// `add_bus_screen.dart:168`). This follows that convention.
  ///
  /// It matters because rent is the single largest cost of a trip and it is
  /// folded into [totalExpenses] straight from `Bus.busPrice`. A bus missing
  /// its rent therefore contributes its full billed fares to
  /// [totalNetBilled] as pure profit, so the headline reads confidently green
  /// while a whole cost line is absent. Surfaced so the UI can say the P&L is
  /// incomplete rather than quietly overstating it.
  ///
  /// 0 when the caller supplied no per-bus rents (fleet unresolvable) — the
  /// same "unknown, never a false alarm" rule [totalDetachedCash] and the
  /// orphan figures follow.
  final int busesMissingRent;

  /// True when at least one bus on the tour has no rent recorded, which means
  /// [totalNetBilled] is overstated by those buses' unentered rents.
  bool get hasUnrecordedRent => busesMissingRent > 0;

  /// True when any money at all sits on a bus the tour no longer lists.
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
    this.totalRevenueBilled = 0,
    this.totalIncome = 0,
    this.totalBusRent = 0,
    this.totalDetachedCash = 0,
    this.orphanExpenses = 0,
    this.orphanCollected = 0,
    this.orphanIncome = 0,
    this.busesMissingRent = 0,
  });

  /// Net cash for the tour (collections + extra income − expenses).
  double get totalNet => totalCollected + totalIncome - totalExpenses;

  /// TRUE profit/loss for the tour: fares billed + extra income − (rents +
  /// expenses).
  double get totalNetBilled => totalRevenueBilled + totalIncome - totalExpenses;

  /// Ground expenses across the tour (everything except the owners' rents).
  double get totalGroundExpenses => totalExpenses - totalBusRent;

  /// Cash the handlers should hand over across the tour: collections + income −
  /// their GROUND expenses only. The owners' rents are the admin's to settle, so
  /// they are not deducted here — [totalNet] is what's left AFTER the admin pays
  /// them out of this handover.
  double get totalExpectedHandover =>
      totalCollected + totalIncome - totalGroundExpenses;

  /// Still-owed handover across the whole tour.
  double get totalOutstandingHandover =>
      totalExpectedHandover - totalHandedOver;

  /// [toCollectTotal] / [toReturnTotal] override the recorded-shortfall sums
  /// with the caller's per-bus roll-up, so the trip total and the per-bus
  /// [BusMoneySummary] figures printed under it always agree.
  ///
  /// BOTH must be overridable. Only to-collect was, so the per-bus rows priced
  /// every seat live while the total above them still summed `Collection.balance`
  /// — the `amount_due` SNAPSHOT — for to-return. The rows and their own total
  /// disagreed the moment a bus was re-priced after money was taken, which is
  /// the same drift, one level up, as the one the per-bus figures had.
  ///
  /// When null they fall back to the recorded shortfalls alone.
  ///
  /// [knownBusIds] are the buses the tour currently lists. Supply them to have
  /// money on any OTHER bus broken out as [orphanExpenses] / [orphanCollected] /
  /// [orphanIncome] (still counted in the totals — see those fields). Omit them
  /// and the orphan figures stay 0.
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
  }) {
    // Null (not supplied) → no orphan detection at all. An EMPTY set is a real
    // answer ("this tour has no buses"), so it still classifies.
    double orphanExpenses = 0;
    double orphanCollected = 0;
    double orphanIncome = 0;
    if (knownBusIds != null) {
      orphanExpenses = expenses
          .where((e) => !knownBusIds.contains(e.busId))
          .fold(0.0, (sum, e) => sum + e.amount);
      // netCash for the same reason as the per-bus rollup above: this folds
      // into the tour's cash position, not the riders'.
      orphanCollected = collections
          .where((c) => !knownBusIds.contains(c.busId))
          .fold(0.0, (sum, c) => sum + c.netCash);
      orphanIncome = incomes
          .where((i) => !knownBusIds.contains(i.busId))
          .fold(0.0, (sum, i) => sum + i.amount);
    }

    return TourMoneySummary(
      orphanExpenses: orphanExpenses,
      orphanCollected: orphanCollected,
      orphanIncome: orphanIncome,
      busesMissingRent: busesMissingRent,
      // netCash, consistent with orphanCollected above and the per-bus rollup
      // at :169/:173. This was left as netCollected when amount_online was
      // introduced, so the tour total silently included UPI money the handler
      // never held — the exact figure the split existed to separate, still
      // wrong at the tour level while every per-bus figure was right.
      totalCollected: collections.fold(0.0, (sum, c) => sum + c.netCash),
      totalDetachedCash: detachedCashTotal,
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
      totalToReturn:
          toReturnTotal ??
          collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          toCollectTotal ??
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
