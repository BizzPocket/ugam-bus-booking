// What an ANONYMOUS customer can truthfully be told about a tour, derived from
// the two SECURITY DEFINER RPCs they are allowed to call. Pure Dart — no
// Flutter, no I/O — so it is directly testable.
//
// WHY THIS EXISTS: `Tour.buses` is always EMPTY on the customer side. `buses`
// has no anon SELECT policy (owner-only, which is exactly why `chart_tour_buses`
// exists), so every field the public tour page derived from it was dead:
//
//   * `tour.totalBusSeats` was always 0, so the "N seats left" chip could never
//     fire and every customer saw the generic "open for requests" instead;
//   * the bus card (AC / seat count / boarding point) never rendered;
//   * `tour.pricePerSeat` is 0 whenever the agent prices per bus or per band,
//     which is the normal case — so the page showed no price at all.
//
// The data was never missing, only unreachable from the model. This module
// reaches it through `chart_tour_buses` + `chart_seat_availability` and folds
// it into one value the UI can render without knowing any of the above.

import '../models/bus_details.dart';
import '../models/trip_type.dart';
import 'chart_seat_availability.dart';

/// The public, anonymised state of a tour's inventory.
class TourPublicSummary {
  /// Buses the server is willing to show a customer. Already stripped of
  /// driver/owner phones and the owner rent by `chart_tour_buses`, so these are
  /// safe to render wholesale.
  final List<Bus> buses;

  /// Cheapest claimable berth across every bus, for a round-trip rider. Null
  /// when nothing is priced yet — render NOTHING in that case, never "₹0".
  final double? fromPrice;

  /// Berths that physically exist and are offered (reserved seats excluded).
  final int berthsTotal;

  /// Berths a round-trip rider could still claim right now.
  final int berthsFree;

  /// True once the RPCs have answered. Distinguishes "no buses yet" from "we
  /// haven't asked" so the UI can hold its shape instead of flashing a
  /// sold-out state during the first frame.
  final bool loaded;

  const TourPublicSummary({
    this.buses = const [],
    this.fromPrice,
    this.berthsTotal = 0,
    this.berthsFree = 0,
    this.loaded = false,
  });

  /// Pre-answer state.
  static const TourPublicSummary pending = TourPublicSummary();

  /// Answered, but the tour has nothing to sell yet.
  static const TourPublicSummary none = TourPublicSummary(loaded: true);

  bool get hasBuses => buses.isNotEmpty;

  /// Every offered berth is gone. Only meaningful once [berthsTotal] is known —
  /// a tour with no buses is NOT sold out, it simply hasn't opened.
  bool get isSoldOut => loaded && berthsTotal > 0 && berthsFree <= 0;

  /// Whether a real seat count can be shown. Guards the UI from rendering
  /// "0 seats left" for a tour whose buses the agent hasn't added yet.
  bool get hasSeatCount => loaded && berthsTotal > 0;
}

/// Fold the two anon RPC payloads into one [TourPublicSummary].
///
/// Availability is counted for [TripType.roundTrip] deliberately: that limits
/// each berth by its BUSIER leg (`capacity - max(usedGo, usedRet)`), so the
/// number quoted is one a round-trip rider can actually book. Counting a single
/// leg would advertise seats that vanish at checkout — and merging the two legs
/// into an average would produce the fractional "half seat" figure this app
/// deliberately never shows a customer.
TourPublicSummary summariseTourForPublic({
  required List<Bus> buses,
  required Map<String, SeatAvailability> availability,
}) {
  if (buses.isEmpty) return TourPublicSummary.none;

  var total = 0;
  var free = 0;
  double? cheapest;

  for (final bus in buses) {
    final price = bus.fromBerthPrice(TripType.roundTrip);
    if (price != null && (cheapest == null || price < cheapest)) {
      cheapest = price;
    }

    final layout = bus.layout;
    if (layout == null) continue;
    for (final cell in layout.grid) {
      if (!cell.hasSeat || cell.reserved) continue;
      total += berthsOfCell(cell);
      free += freeBerths(
        cell: cell,
        occupancy: availability[SeatAvailability.keyFor(bus.id, cell.seatId!)],
        leg: TripType.roundTrip,
      );
    }
  }

  return TourPublicSummary(
    buses: buses,
    fromPrice: cheapest,
    berthsTotal: total,
    berthsFree: free,
    loaded: true,
  );
}
