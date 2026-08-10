import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_leg_capacity.dart';

/// Leg-aware front door for every seat SWAP.
///
/// A plain berth-for-berth swap only checks PHYSICAL capacity (1 vs 2 berths),
/// so it happily lands a round-trip rider on a single sofa that a one-way rider
/// still shares — double-booking that leg ([legOverbookedOccupants]). Instead of
/// silently corrupting the chart (or rejecting with an error), this guard
/// detects the over-booked leg and ASKS the agent what to do with the one-leg
/// occupant who is in the way: move them off (back to the unseated pool, request
/// intact) and complete the swap, or cancel.
///
/// All swap call sites (the relocate tap-to-place flow, the drag engine's swap,
/// the split-pair flow, and the swap-assistant) route through [run] so the
/// behaviour is identical everywhere; the write itself stays in
/// [TourController.swapSeats], which performs the bump atomically.
class SeatSwapGuard {
  const SeatSwapGuard._();

  static TourController get _ctrl => Get.find<TourController>();

  /// Swap passenger A (on [seatAId]/[busAId]) with passenger B (on
  /// [seatBId]/[busBId]), prompting first when the exchange would over-book a
  /// shared leg on either seat. Returns once the swap is done or the agent
  /// cancels.
  static Future<void> run(
    BuildContext context, {
    required String tourId,
    required String busAId,
    required String passengerAId,
    required String seatAId,
    required String passengerBId,
    required String seatBId,
    required String busBId,
  }) async {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final byId = {for (final p in tour.passengers) p.id: p};
    final pA = byId[passengerAId];
    final pB = byId[passengerBId];
    if (pA == null || pB == null) return;

    // Seat A receives B's berths (B leaves seat B); seat B receives A's berths.
    final bumpA = _overbookedOn(
      tour,
      busId: busAId,
      seatId: seatAId,
      incoming: pB,
      incomingBerths: _berthsOn(pB, busBId, seatBId),
      leavingId: passengerAId,
    );
    final bumpB = _overbookedOn(
      tour,
      busId: busBId,
      seatId: seatBId,
      incoming: pA,
      incomingBerths: _berthsOn(pA, busAId, seatAId),
      leavingId: passengerBId,
    );

    final toBump = [
      for (final p in bumpA) (passengerId: p.id, busId: busAId, seatId: seatAId),
      for (final p in bumpB) (passengerId: p.id, busId: busBId, seatId: seatBId),
    ];

    if (toBump.isNotEmpty) {
      final names = {...bumpA, ...bumpB}.map((p) => p.displayName).join(', ');
      final confirmed = await UgamDialog.confirm(
        context,
        title: tr('seat_swap_conflict.title'),
        message: tr(
          'seat_swap_conflict.body',
          namedArgs: {'occupant': names},
        ),
        cancelLabel: tr('seat_swap_conflict.keep'),
        confirmLabel: tr('seat_swap_conflict.move_off'),
        destructive: true,
      );
      if (!confirmed) return;
    }

    await _ctrl.swapSeats(
      tourId: tourId,
      busId: busAId,
      passengerAId: passengerAId,
      seatAId: seatAId,
      passengerBId: passengerBId,
      seatBId: seatBId,
      busBId: busBId,
      bump: toBump,
    );
  }

  /// The occupants of [seatId]/[busId] who would be over-booked on a leg once
  /// [incoming] (holding [incomingBerths] berths) lands there and [leavingId]
  /// vacates. Empty when the swap is leg-legal.
  static List<Passenger> _overbookedOn(
    Tour tour, {
    required String busId,
    required String seatId,
    required Passenger incoming,
    required int incomingBerths,
    required String leavingId,
  }) {
    final cap = _capOf(tour, busId, seatId);
    final byId = {for (final p in tour.passengers) p.id: p};
    final remaining = <LegOccupant>[
      for (final p in tour.passengers)
        if (p.id != incoming.id && p.id != leavingId)
          if (_berthsOn(p, busId, seatId) > 0)
            (
              id: p.id,
              // Per-seat leg when it was stamped, else the rider's REAL coarse
              // leg. The raw [Passenger.tripType] column defaults to round-trip
              // and is never set for a request-mode booking, so a one-way rider
              // read as occupying BOTH legs and the guard reported an overbook
              // on a swap that was perfectly legal.
              trip: p.legForSeat(seatId, busId: busId),
              berths: _berthsOn(p, busId, seatId),
            ),
    ];
    final over = legOverbookedOccupants(
      incomingTrip: incoming.effectiveTripType,
      incomingBerths: incomingBerths,
      cap: cap,
      remaining: remaining,
    );
    return [for (final o in over) if (byId[o.id] != null) byId[o.id]!];
  }

  static int _berthsOn(Passenger p, String busId, String seatId) => p
      .assignedSeats
      .where((a) => a.busId == busId && a.seatId == seatId)
      .length;

  static int _capOf(Tour tour, String busId, String seatId) {
    final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
    for (final cl in bus?.layout?.grid ?? const <SeatCell>[]) {
      if (cl.seatId == seatId) {
        return cl.seatType == SeatType.doubleSofa ? 2 : 1;
      }
    }
    return 1;
  }
}
