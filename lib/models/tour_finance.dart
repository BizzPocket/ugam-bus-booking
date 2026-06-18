import 'tour.dart';
import 'tour_status.dart';

/// Realised profit & loss for ONE tour, rolled up across every bus.
///
/// Pure value object — no Flutter/GetX deps. [revenue] is the net cash
/// actually collected from passengers (received − refunded, the same figure
/// the per-tour money board calls "collected"); [income] is extra cash taken
/// in OUTSIDE passenger fares (cabin / gallery / other) — kept separate because
/// it is not a billed/intended fare; [expenses] is the sum of every logged
/// expense. [net] is the profit (or loss) the tour realised. Handovers are
/// deliberately excluded: they move cash between handler and admin, they are
/// not income or cost.
class TourFinance {
  final String tourId;
  final String title;
  final String route;
  final DateTime date;
  final bool isCompleted;
  final int passengers;
  final int buses;
  final double revenue;
  final double expenses;

  /// Extra income (cabin / gallery / other) realised on the tour — separate
  /// from billed passenger fares ([revenue]); it adds to [net].
  final double income;

  const TourFinance({
    required this.tourId,
    required this.title,
    required this.route,
    required this.date,
    required this.isCompleted,
    required this.passengers,
    required this.buses,
    required this.revenue,
    required this.expenses,
    this.income = 0,
  });

  double get net => revenue + income - expenses;
  bool get isProfit => net >= 0;

  /// Builds a [TourFinance] from a loaded [Tour] plus its pre-aggregated money
  /// figures. Uses [Tour.returnDate] (falling back to departure) as the date a
  /// trip's money is "booked", so a multi-day trip lands in the period it ended.
  factory TourFinance.from(
    Tour tour,
    double revenue,
    double expenses, {
    double income = 0,
  }) {
    return TourFinance(
      tourId: tour.id,
      title: tour.title,
      route: tour.route,
      date: tour.returnDate ?? tour.departureDate,
      isCompleted: tour.status == TourStatus.completed,
      passengers: tour.passengerCount,
      buses: tour.buses.length,
      revenue: revenue,
      expenses: expenses,
      income: income,
    );
  }
}

/// Aggregate P&L across a set of [TourFinance] rows (one period's worth).
///
/// Pure value object: feed it the already-filtered list and read its getters.
class FinanceTotals {
  final double revenue;
  final double expenses;

  /// Total extra income (cabin / gallery / other) across the period's tours —
  /// kept separate from [revenue]; adds to [net].
  final double income;
  final int tourCount;
  final TourFinance? best;
  final TourFinance? worst;

  const FinanceTotals({
    required this.revenue,
    required this.expenses,
    required this.tourCount,
    required this.best,
    required this.worst,
    this.income = 0,
  });

  double get net => revenue + income - expenses;
  bool get isProfit => net >= 0;
  double get avgNet => tourCount == 0 ? 0 : net / tourCount;

  static const empty = FinanceTotals(
    revenue: 0,
    expenses: 0,
    income: 0,
    tourCount: 0,
    best: null,
    worst: null,
  );

  factory FinanceTotals.from(List<TourFinance> tours) {
    if (tours.isEmpty) return empty;
    var revenue = 0.0;
    var expenses = 0.0;
    var income = 0.0;
    TourFinance? best;
    TourFinance? worst;
    for (final t in tours) {
      revenue += t.revenue;
      expenses += t.expenses;
      income += t.income;
      if (best == null || t.net > best.net) best = t;
      if (worst == null || t.net < worst.net) worst = t;
    }
    return FinanceTotals(
      revenue: revenue,
      expenses: expenses,
      income: income,
      tourCount: tours.length,
      best: best,
      worst: worst,
    );
  }
}

/// The period a [FinanceController] report is scoped to. Filtering is done on
/// the [TourFinance.date] (trip end date).
enum FinancePeriod { thisMonth, thisYear, allTime }
