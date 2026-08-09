import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/seating_engine.dart';

/// A candidate half-double the agent can Approve-share onto: free berth-leg
/// capacity remains, but the cell already has an UNRELATED occupant on an
/// overlapping leg (the case [SeatingExceptionType.sharedDoubleNeedsReview]
/// describes).
({String busId, String seatId, TripType leg})? findStrangerShareSeat(
  Tour tour,
  Passenger passenger,
) {
  final legs = TripLeg.forTrip(passenger.derivedTripType);
  if (legs.isEmpty) return null;
  final reqGroup = passenger.groupId;

  for (final bus in tour.buses) {
    final grid = bus.layout?.grid;
    if (grid == null) continue;
    for (final cell in grid) {
      if (cell.seatType != SeatType.doubleSofa) continue;
      final seatId = cell.seatId;
      if (seatId == null || seatId.isEmpty) continue;

      final holders = <Passenger>[];
      for (final p in tour.passengers) {
        if (p.id == passenger.id) continue;
        if (p.assignedSeats
            .any((a) => a.busId == bus.id && a.seatId == seatId)) {
          holders.add(p);
        }
      }
      if (holders.isEmpty) continue;

      // Same-group holders are not a stranger-share case.
      final related = reqGroup != null &&
          holders.every((h) => h.groupId != null && h.groupId == reqGroup);
      if (related) continue;

      // Must overlap in time with at least one holder (disjoint legs are fine
      // to auto-share — the engine already places those without review).
      final overlaps = holders.any((h) {
        final hLegs = TripLeg.forTrip(h.derivedTripType);
        return hLegs.any(legs.contains);
      });
      if (!overlaps) continue;

      // Count berth holds per leg on this cell (each assignment entry = 1).
      var goTaken = 0;
      var retTaken = 0;
      for (final h in holders) {
        for (final a in h.assignedSeats) {
          if (a.busId != bus.id || a.seatId != seatId) continue;
          final trip = a.leg ?? h.derivedTripType;
          if (trip.usesOutbound) goTaken++;
          if (trip.usesReturn) retTaken++;
        }
      }
      goTaken = goTaken.clamp(0, 2);
      retTaken = retTaken.clamp(0, 2);

      final needGo = legs.contains(TripLeg.go);
      final needRet = legs.contains(TripLeg.ret);
      if (needGo && goTaken >= 2) continue;
      if (needRet && retTaken >= 2) continue;

      return (
        busId: bus.id,
        seatId: seatId,
        leg: TripLeg.tripTypeOf(legs),
      );
    }
  }
  return null;
}
