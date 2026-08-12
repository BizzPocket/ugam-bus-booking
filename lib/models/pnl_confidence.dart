import 'money_summary.dart';
import 'tour_status.dart';

/// Whether a trip's BILLED profit headline is describing an outcome or a
/// forecast — and whether its cost side is even complete.
///
/// The billed net ([TourMoneySummary.totalNetBilled]) accrues the instant a
/// seat is assigned, so a trip that has not departed and has collected nothing
/// still produces a large positive number. Rendered as a green "trip is in
/// profit" that reads as money earned, when it is really "money the seat chart
/// says we would earn, minus whatever costs happen to be entered so far".
///
/// Pure value object — no Flutter/GetX deps — so all three surfaces that
/// headline the billed net (trip P&L hero, money-board entry card, dashboard
/// trip hero) apply one rule instead of three copies of a condition.
class PnlConfidence {
  /// The trip has not concluded AND not one rupee has been collected, so the
  /// billed net is derived purely from seat assignments. It is a projection of
  /// what the trip would earn, not a result it achieved.
  ///
  /// Collections are the gate rather than departure alone because the moment
  /// cash starts moving the agent has a real cash figure sitting beside the
  /// billed one, and the two together stop being misleading.
  final bool isProjected;

  /// At least one bus has no owner rent recorded, so a whole cost line is
  /// missing and the billed net is overstated by it. Orthogonal to
  /// [isProjected] — this stays true on a completed, fully collected trip.
  final bool costsIncomplete;

  const PnlConfidence({
    required this.isProjected,
    required this.costsIncomplete,
  });

  /// True when the headline must not be presented as a settled result — either
  /// because it is a forecast, or because its costs are incomplete.
  bool get isProvisional => isProjected || costsIncomplete;

  factory PnlConfidence.of(TourMoneySummary summary, TourStatus status) {
    // Same 0.005 epsilon the rest of the money layer compares rupees with, so
    // a rounding crumb never counts as "cash has been collected".
    final nothingCollected = summary.totalCollected.abs() <= 0.005;
    return PnlConfidence(
      isProjected: status.isActive && nothingCollected,
      costsIncomplete: summary.hasUnrecordedRent,
    );
  }
}
