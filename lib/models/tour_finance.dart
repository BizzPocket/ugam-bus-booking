import 'tour.dart';
import 'tour_status.dart';
import 'trip_pnl.dart';

/// Profit & loss for ONE tour, rolled up across every bus.
///
/// Pure value object — no Flutter/GetX deps. The figures live in [pnl], the
/// same [TripPnl] the trip's own money board builds, so this row prints the
/// SAME two numbers as the dashboard hero, the board card and the Trip P&L:
/// [tripProfit] (billed basis, the headline) and [cashSoFar] (money received).
/// Handovers are deliberately excluded: they move cash between handler and
/// admin, they are not income or cost.
class TourFinance {
  final String tourId;
  final String title;
  final String route;
  final DateTime date;
  final bool isCompleted;
  final int passengers;
  final int buses;
  final TripPnl pnl;

  const TourFinance({
    required this.tourId,
    required this.title,
    required this.route,
    required this.date,
    required this.isCompleted,
    required this.passengers,
    required this.buses,
    this.pnl = TripPnl.zero,
  });

  /// Fares billed for the seats held.
  double get billed => pnl.billed;

  /// Money actually received from riders (handler cash + online UPI).
  double get revenue => pnl.received;

  /// Every trip cost (rent under the pakku-bhadu rule + on-top expenses).
  double get expenses => pnl.costs;

  /// Extra income (cabin / gallery / other) — adds to both figures.
  double get income => pnl.income;

  /// Primary: [TripPnl.tripProfit].
  double get tripProfit => pnl.tripProfit;

  /// Secondary: [TripPnl.cashSoFar].
  double get cashSoFar => pnl.cashSoFar;

  bool get isProfit => tripProfit >= 0;

  /// Builds a [TourFinance] from a loaded [Tour] plus its [TripPnl]. Uses
  /// [Tour.returnDate] (falling back to departure) as the date a trip's money
  /// is "booked", so a multi-day trip lands in the period it ended.
  ///
  /// [busCount] overrides `tour.buses.length` when the roster is not loaded —
  /// an archived tour arrives from cold start with an EMPTY bus list, which is
  /// "not fetched", not "no buses".
  factory TourFinance.from(Tour tour, TripPnl pnl, {int? busCount}) {
    return TourFinance(
      tourId: tour.id,
      title: tour.title,
      route: tour.route,
      date: tour.returnDate ?? tour.departureDate,
      isCompleted: tour.status == TourStatus.completed,
      passengers: tour.passengerCount,
      buses: tour.buses.isNotEmpty ? tour.buses.length : (busCount ?? 0),
      pnl: pnl,
    );
  }
}

/// Aggregate P&L across a set of [TourFinance] rows (one period's worth).
///
/// Pure value object: feed it the already-filtered list and read its getters.
/// Its [pnl] is the plain sum of the rows' — so the period's two totals are
/// exactly the sums of the two figures printed on its rows.
class FinanceTotals {
  final TripPnl pnl;
  final int tourCount;
  final TourFinance? best;
  final TourFinance? worst;

  const FinanceTotals({
    required this.pnl,
    required this.tourCount,
    required this.best,
    required this.worst,
  });

  double get billed => pnl.billed;
  double get revenue => pnl.received;
  double get expenses => pnl.costs;
  double get income => pnl.income;
  double get tripProfit => pnl.tripProfit;
  double get cashSoFar => pnl.cashSoFar;
  bool get isProfit => tripProfit >= 0;
  double get avgTripProfit => tourCount == 0 ? 0 : tripProfit / tourCount;

  static const empty = FinanceTotals(
    pnl: TripPnl.zero,
    tourCount: 0,
    best: null,
    worst: null,
  );

  factory FinanceTotals.from(List<TourFinance> tours) {
    if (tours.isEmpty) return empty;
    TourFinance? best;
    TourFinance? worst;
    for (final t in tours) {
      if (best == null || t.tripProfit > best.tripProfit) best = t;
      if (worst == null || t.tripProfit < worst.tripProfit) worst = t;
    }
    return FinanceTotals(
      pnl: TripPnl.sum(tours.map((t) => t.pnl)),
      tourCount: tours.length,
      best: best,
      worst: worst,
    );
  }
}

/// The period a [FinanceController] report is scoped to. Filtering is done on
/// the [TourFinance.date] (trip end date).
enum FinancePeriod { thisMonth, thisYear, allTime }
