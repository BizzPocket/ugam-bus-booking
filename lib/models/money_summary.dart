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

  /// [passengers] + [dueForSeat] make to-collect the TRUE money still owed, not
  /// just the recorded shortfalls: a seated rider with NO collection row on this
  /// bus still owes their full seat fare, so admin no longer reads "to collect 0"
  /// while the handler shows the full billed revenue. Mirrors
  /// [HandlerBusMoney.compute] exactly (seat-AGNOSTIC: a rider with ANY row on
  /// this bus is already covered by the recorded shortfall, so they are skipped
  /// regardless of which seat that row names). When [dueForSeat] is null (e.g.
  /// the handler's own call, which does its own seated-uncollected pass)
  /// to-collect stays the recorded shortfalls alone — no double-count.
  ///
  /// SCOPE OF THAT AGREEMENT (audit finding F2). "Admin and handler can never
  /// disagree" holds for THIS path — both sides computing from the same rows
  /// with the same [dueForSeat]. It does NOT hold once the admin reads the
  /// LEDGER: `MoneyController.summaryForBus` then takes to-collect from
  /// `finance_rider_balance` (via `_arShareByBus`), which is the ledger's own
  /// arithmetic over posted `ar.rider` lines, while the handler still prices
  /// seated riders here from the live Dart fare. The two agree only while the
  /// ledger's fare formula and `Bus.amountDueForSeat` agree — which is what
  /// migration 070 exists to guarantee, and what check 7 in
  /// supabase/diagnostics/finance_audit_checks.sql verifies on live data.
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

  /// [toCollectTotal] overrides the recorded-shortfall sum with the caller's
  /// per-bus roll-up (which also counts seated-but-uncollected riders), so the
  /// tour total and the per-bus [BusMoneySummary.toCollectTotal] figures always
  /// agree. When null, to-collect falls back to the recorded shortfalls alone.
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
      totalToReturn: collections.fold(0.0, (sum, c) => sum + c.changeToReturn),
      totalToCollect:
          toCollectTotal ??
          collections.fold(0.0, (sum, c) => sum + c.stillToCollect),
    );
  }
}
