import '../models/trip_type.dart';

/// One occupant already holding a seat: which legs they travel ([trip]) and how
/// many berths of that seat they hold ([berths] — 1 for a single/half-double,
/// 2 for a whole double held solo).
typedef SeatLegHolder = ({TripType trip, int berths});

/// Whether a passenger travelling [activeTrip] can take [need] berths on a seat
/// of capacity [cap] that is already held by [occupants].
///
/// Capacity is tracked PER LEG: the seat holds [cap] berths on the outbound (GO)
/// leg and [cap] on the return (RET) leg INDEPENDENTLY. So a one-way occupant
/// fills only its own leg and leaves the other leg free — letting an
/// opposite-leg one-way rider reuse the SAME physical sofa (GO + RET on one
/// seat). A round-trip occupant fills both legs and blocks any reuse; two
/// same-leg riders on a Double Sofa still share its two berths as before.
///
/// Pure and side-effect free so the seat-assignment UI and tests share one
/// rule. Mirrors the per-leg model the seating engine uses for auto-fill.
bool seatHasLegRoom({
  required TripType activeTrip,
  required int need,
  required int cap,
  required List<SeatLegHolder> occupants,
}) {
  if (need <= 0) return false;
  var goUsed = 0;
  var retUsed = 0;
  for (final o in occupants) {
    if (o.trip.usesOutbound) goUsed += o.berths;
    if (o.trip.usesReturn) retUsed += o.berths;
  }
  final fitsGo = !activeTrip.usesOutbound || goUsed + need <= cap;
  final fitsRet = !activeTrip.usesReturn || retUsed + need <= cap;
  return fitsGo && fitsRet;
}
