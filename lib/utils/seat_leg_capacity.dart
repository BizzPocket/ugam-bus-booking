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

/// One occupant who would REMAIN on a seat after a swap: their identity, which
/// legs they travel ([trip]) and how many berths they hold there ([berths]).
typedef LegOccupant = ({String id, TripType trip, int berths});

/// Which remaining occupants a swap would over-book on a leg.
///
/// When a passenger of [incomingTrip] (holding [incomingBerths] berths) is
/// swapped onto a seat of capacity [cap] where [remaining] occupants stay put,
/// returns the occupants who share the over-booked leg(s) — the ones who must
/// be moved off to make the seat leg-legal again. Empty when the placement
/// fits per [seatHasLegRoom].
///
/// This is the bug the swap path previously missed: a leg-shared single sofa
/// (a GO-only + a RET-only rider) is left holding a one-way rider AND a
/// round-trip rider after a swap, double-booking the shared leg. The physical
/// berth-count guard can't see it because every berth count is still 1.
///
/// A PHYSICAL over-book — [incomingBerths] alone exceeds [cap] (e.g. a whole
/// double landing on a single) — returns empty: no occupant can be bumped to
/// fix it, so the controller's capacity backstop owns that case.
List<LegOccupant> legOverbookedOccupants({
  required TripType incomingTrip,
  required int incomingBerths,
  required int cap,
  required List<LegOccupant> remaining,
}) {
  if (incomingBerths <= 0 || incomingBerths > cap) return const [];
  var goUsed = 0;
  var retUsed = 0;
  for (final o in remaining) {
    if (o.trip.usesOutbound) goUsed += o.berths;
    if (o.trip.usesReturn) retUsed += o.berths;
  }
  final goOver = incomingTrip.usesOutbound && goUsed + incomingBerths > cap;
  final retOver = incomingTrip.usesReturn && retUsed + incomingBerths > cap;
  if (!goOver && !retOver) return const [];
  return [
    for (final o in remaining)
      if ((goOver && o.trip.usesOutbound) || (retOver && o.trip.usesReturn)) o,
  ];
}
