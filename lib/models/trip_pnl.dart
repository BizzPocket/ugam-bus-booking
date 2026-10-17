/// THE profit & loss of a trip (or a bus, or a set of trips) — the one place
/// the two profit figures are defined.
///
/// Every admin money surface shows BOTH, and they are deliberately different
/// questions:
///
///  * [tripProfit] — "what does this trip make?" Fares BILLED for the seats
///    held + extra income − every cost. The primary figure.
///  * [cashSoFar] — "where does the money stand right now?" Money actually
///    RECEIVED (handler cash + online UPI, net of refunds) + extra income −
///    every cost. The secondary figure.
///
/// Before this existed the dashboard, the money board and the Trip P&L
/// headlined the billed figure while Settings and the Finance report headlined
/// the cash one — both under the word "profit" — so a card said profit and the
/// screen behind it said loss. Both pipelines ([MoneyController] for the loaded
/// trip, [FinanceController] for every trip) now build one of these and every
/// surface reads its two getters, so the formulas cannot drift again.
///
/// The inputs, and the rules that keep them single-counted:
///  * [billed] — the ledger's `revenue.fare` (finance_bus_summary.billed_minor)
///    wherever the ledger can be read; live seat fares only when it cannot.
///    Both pipelines read the same ledger lines, so they agree by construction.
///  * [cash] — handler cash only (`cash.handler`, [Collection.netCash]).
///  * [online] — UPI money that reached the organiser's gateway
///    (`bank.gateway`, [Collection.amountOnline]). A rupee is cash OR online,
///    never both (069), so [received] counts each exactly once.
///  * [income] — cabin / gallery / other; adds to BOTH figures.
///  * [costs] — every trip cost under the pakku-bhadu rule
///    ([BusExpenseRollup]): the rent is the whole bus cost and diesel, driver
///    and owner advances only shrink what the owner is still owed.
///  * Handovers move cash between handler and admin; they are neither income
///    nor cost and never appear here.
class TripPnl {
  const TripPnl({
    this.billed = 0,
    this.cash = 0,
    this.online = 0,
    this.income = 0,
    this.costs = 0,
  });

  final double billed;
  final double cash;
  final double online;
  final double income;
  final double costs;

  static const zero = TripPnl();

  /// Everything riders have actually paid, however it arrived.
  double get received => cash + online;

  /// Primary: billed fares + extra income − all costs.
  double get tripProfit => billed + income - costs;

  /// Secondary: money received + extra income − all costs.
  double get cashSoFar => received + income - costs;

  /// True when nothing at all has been billed, received, earned or spent.
  bool get isEmpty =>
      billed.abs() < 0.005 &&
      received.abs() < 0.005 &&
      income.abs() < 0.005 &&
      costs.abs() < 0.005;

  TripPnl operator +(TripPnl o) => TripPnl(
        billed: billed + o.billed,
        cash: cash + o.cash,
        online: online + o.online,
        income: income + o.income,
        costs: costs + o.costs,
      );

  static TripPnl sum(Iterable<TripPnl> parts) =>
      parts.fold(zero, (acc, p) => acc + p);

  TripPnl copyWith({
    double? billed,
    double? cash,
    double? online,
    double? income,
    double? costs,
  }) =>
      TripPnl(
        billed: billed ?? this.billed,
        cash: cash ?? this.cash,
        online: online ?? this.online,
        income: income ?? this.income,
        costs: costs ?? this.costs,
      );

  @override
  bool operator ==(Object other) =>
      other is TripPnl &&
      other.billed == billed &&
      other.cash == cash &&
      other.online == online &&
      other.income == income &&
      other.costs == costs;

  @override
  int get hashCode => Object.hash(billed, cash, online, income, costs);

  @override
  String toString() => 'TripPnl(billed: $billed, cash: $cash, online: $online, '
      'income: $income, costs: $costs → tripProfit: $tripProfit, '
      'cashSoFar: $cashSoFar)';
}
