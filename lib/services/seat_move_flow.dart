import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/seat_chart_tile.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../services/group_cascade.dart';
import '../services/seat_swap_guard.dart';
import '../services/swap_candidate_finder.dart';
import '../utils/passenger_display.dart';

part 'seat_move_flow_sheets.dart';

/// The one shared "move / swap a seated passenger" flow.
///
/// Destination-bus picker → swap assistant → move/swap, **including across
/// buses** (the source bus is passed in explicitly, so a passenger can be sent
/// to another bus's free seat or swapped with someone on it). Grouped movers
/// cascade their whole group via [GroupCascade]. All seating math lives in
/// [SwapCandidateFinder] / [GroupCascade]; the writes go through the cross-bus
/// [TourController.moveSeat] / [TourController.swapSeats].
///
/// Both the seat-detail screen and the unified Assign workspace call
/// [SeatMoveFlow.start] so the behaviour and sheets read identically.
class SeatMoveFlow {
  const SeatMoveFlow._();

  static TourController get _ctrl => Get.find<TourController>();

  /// Entry point. [sourceBusId] is the bus the mover currently sits on (where
  /// [fromSeatId] lives). A single-bus tour skips the picker.
  ///
  /// When [onRelocateToBus] is supplied, picking a destination bus DOES NOT open
  /// the auto swap-assistant; instead it calls back so the caller (the seat
  /// chart) can switch to that bus and let the agent tap the exact target seat
  /// by hand — tap a free seat to move, tap an occupied seat to swap/free. The
  /// callback receives the destination plus the mover's source identity so the
  /// chart can drive the cross-bus [TourController.moveSeat] / [swapSeats]
  /// itself. Without it, the legacy swap-assistant flow runs.
  static void start(
    BuildContext context, {
    required String tourId,
    required String sourceBusId,
    required Passenger mover,
    required String fromSeatId,
    void Function(
      Bus destination,
      Passenger mover,
      String sourceBusId,
      String fromSeatId,
    )? onRelocateToBus,
  }) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;
    final buses = tour.buses;
    if (buses.isEmpty) return;

    // Callers (e.g. the occupant action sheet) typically POP their own sheet
    // immediately before calling start, so [context] is already being torn
    // down. The destination picker still opens (the popped sheet is mid-exit
    // animation), but the swap assistant is launched LATER from the picker's
    // onPick — by then [context] is deactivated and opening a sheet against it
    // throws "deactivated widget's ancestor is unsafe", silently killing the
    // (cross-bus) move. Anchor the whole flow to the ROOT navigator's context,
    // which outlives every sheet we pop.
    final flowContext = Navigator.of(context, rootNavigator: true).context;

    void run(Bus destination) {
      if (onRelocateToBus != null) {
        onRelocateToBus(destination, mover, sourceBusId, fromSeatId);
        return;
      }
      _openSwapAssist(
        flowContext,
        tourId: tourId,
        sourceBusId: sourceBusId,
        mover: mover,
        fromSeatId: fromSeatId,
        destination: destination,
      );
    }

    if (buses.length == 1) {
      run(buses.first);
      return;
    }

    final c = UgamColors.of(flowContext);
    showModalBottomSheet<void>(
      context: flowContext,
      // Root navigator + safe area: escape the shell's nested tab Navigator so
      // the sheet paints above (not behind) the bottom dock nav. See
      // UgamSheet.show for the full rationale.
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _DestinationPickerSheet(
        mover: mover,
        buses: buses,
        currentBusId: sourceBusId,
        onPick: (b) {
          Navigator.of(sheetCtx).pop();
          run(b);
        },
      ),
    );
  }

  /// Present the [SwapAssist] for moving [mover] onto [destination]: free seats
  /// to take outright, ranked swap candidates, and blocked occupants.
  static void _openSwapAssist(
    BuildContext context, {
    required String tourId,
    required String sourceBusId,
    required Passenger mover,
    required String fromSeatId,
    required Bus destination,
  }) {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return;

    // Resolve the mover's CURRENT seat class + berth count on the SOURCE bus so
    // the finder can offer a physical swap on ANY bus — including a cross-bus
    // swap, where the mover doesn't sit on the destination layout and a
    // need-already-satisfied passenger would otherwise surface no candidates.
    final sourceBus = tour.buses.firstWhereOrNull((b) => b.id == sourceBusId);
    SeatType? moverSeatType;
    final sourceGrid = sourceBus?.layout?.grid;
    if (sourceGrid != null) {
      for (final cell in sourceGrid) {
        if (cell.seatId == fromSeatId) {
          moverSeatType = cell.seatType;
          break;
        }
      }
    }
    final moverBerths = _berthsOn(mover, sourceBusId, fromSeatId);

    final assist = SwapCandidateFinder.find(
      mover: mover,
      destinationBus: destination,
      passengers: tour.passengers,
      sourceBusId: sourceBusId,
      // Tell the finder where the mover currently sits so a swap is offered on
      // physical feasibility, not just on an outstanding request — a seated
      // passenger can swap with any compatible allocated seat, same OR another
      // bus.
      moverFromSeatId: destination.id == sourceBusId ? fromSeatId : null,
      moverFromSeatType: moverSeatType,
      moverFromBerths: moverBerths,
    );

    final c = UgamColors.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      isScrollControlled: true,
      // Root navigator + safe area: escape the shell's nested tab Navigator so
      // the sheet paints above (not behind) the bottom dock nav. See
      // UgamSheet.show for the full rationale.
      useRootNavigator: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (sheetCtx) => _SwapAssistSheet(
        mover: mover,
        destination: destination,
        assist: assist,
        onTakeFree: (freeSeatId) {
          Navigator.of(sheetCtx).pop();
          moveTo(
            context,
            tourId: tourId,
            sourceBusId: sourceBusId,
            mover: mover,
            fromSeatId: fromSeatId,
            destination: destination,
            toSeatId: freeSeatId,
          );
        },
        onSwap: (candidate) {
          Navigator.of(sheetCtx).pop();
          swapMover(
            context,
            tourId: tourId,
            sourceBusId: sourceBusId,
            mover: mover,
            fromSeatId: fromSeatId,
            destination: destination,
            candidate: candidate,
          );
        },
      ),
    );
  }

  /// Place [mover] onto a FREE seat of [destination]. A mover who travels with
  /// OTHERS and crosses to ANOTHER bus cascades the whole party (after a
  /// confirm) so the group is never split; a SAME-bus move just relocates this
  /// one member (the group stays whole — everyone is still on this bus). A
  /// whole double keeps both berths (the cross-bus [moveSeat] replicates the
  /// count).
  ///
  /// Returns what actually happened. A cascade can be refused by the
  /// destination or backed out of at the confirm, and even a successful cascade
  /// lands the party on ENGINE-chosen berths rather than [toSeatId] — callers
  /// that announce "moved" or dismiss a relocate banner must branch on this.
  static Future<SeatMoveOutcome> moveTo(
    BuildContext context, {
    required String tourId,
    required String sourceBusId,
    required Passenger mover,
    required String fromSeatId,
    required Bus destination,
    required String toSeatId,
  }) async {
    final crossBus = destination.id != sourceBusId;
    if (crossBus && _travelsWithOthers(tourId, mover)) {
      return _moveGroup(
        context,
        tourId: tourId,
        mover: mover,
        destination: destination,
      );
    }

    // Capacity guard (data-corruption fix): a SUBSTITUTE whole-double mover holds
    // 2 berths on the source cell. If the chosen FREE seat is a 1-capacity cell
    // (Single Sofa / Seater), moving BOTH berths would over-stuff that cell.
    // Compute the target cell's capacity (Double = 2, else 1) from the
    // destination layout and the mover's current berth count on the source cell,
    // then cap [berths] so moveSeat PEELS a single berth — matching the drag
    // engine's splitToSingle. When the mover fits (moverBerths <= targetCap) we
    // pass null and move every berth (a whole-double crosses intact).
    final targetCap = _seatCapacity(destination, toSeatId);
    final moverBerths = _berthsOn(mover, sourceBusId, fromSeatId);
    final berthsCap = moverBerths > targetCap ? targetCap : null;

    return _ctrl.moveSeat(
      tourId: tourId,
      passengerId: mover.id,
      busId: sourceBusId,
      fromSeatId: fromSeatId,
      toSeatId: toSeatId,
      toBusId: destination.id,
      berths: berthsCap,
    );
  }

  /// True when [mover] is part of a party of TWO OR MORE on this tour — the
  /// only case where a cross-bus move has to cascade the whole group.
  ///
  /// A booking keeps its groupId after the party shrinks to one rider, and a
  /// bare `groupId != null` check sent that solo rider through the engine
  /// cascade — which re-seats at engine-chosen berths and therefore threw away
  /// the seat the operator picked. Mirrors [TourController]'s own guard.
  static bool _travelsWithOthers(String tourId, Passenger mover) {
    final gid = mover.groupId;
    if (gid == null || gid.isEmpty) return false;
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return false;
    return tour.passengers.where((p) => p.groupId == gid).length > 1;
  }

  /// How many berths (assignment entries) [mover] holds on [seatId] of
  /// [busId] — a whole double held solo counts 2.
  static int _berthsOn(Passenger mover, String busId, String seatId) => mover
      .assignedSeats
      .where((a) => a.busId == busId && a.seatId == seatId)
      .length;

  /// Berth capacity of [seatId] on [bus]: a Double Sofa holds 2, every other
  /// seat class holds 1. Reads the destination layout grid; defaults to 1 when
  /// the cell can't be resolved (the safe floor — never over-assign).
  static int _seatCapacity(Bus bus, String seatId) {
    final base = seatId.split('#').first;
    final grid = bus.layout?.grid;
    if (grid == null) return 1;
    for (final cell in grid) {
      if (cell.seatId == base) {
        return cell.seatType == SeatType.doubleSofa ? 2 : 1;
      }
    }
    return 1;
  }

  /// Swap [mover] with a chosen movable [candidate] on [destination]. A grouped
  /// mover crossing to ANOTHER bus cascades the whole group (a one-for-one swap
  /// can't keep a group whole across buses); a SAME-bus swap just exchanges this
  /// one member with the candidate (both stay on this bus, so the group stays
  /// whole).
  static Future<void> swapMover(
    BuildContext context, {
    required String tourId,
    required String sourceBusId,
    required Passenger mover,
    required String fromSeatId,
    required Bus destination,
    required SwapCandidate candidate,
  }) async {
    final crossBus = destination.id != sourceBusId;
    if (crossBus && _travelsWithOthers(tourId, mover)) {
      await _moveGroup(
        context,
        tourId: tourId,
        mover: mover,
        destination: destination,
      );
      return;
    }

    if (!context.mounted) return;
    await SeatSwapGuard.run(
      context,
      tourId: tourId,
      busAId: sourceBusId,
      passengerAId: mover.id,
      seatAId: fromSeatId,
      passengerBId: candidate.passengerId,
      seatBId: candidate.seatId,
      busBId: destination.id,
    );
  }

  /// Cascade a grouped mover and all siblings onto [destination]. Uses
  /// [GroupCascade.planMove] only for the fit verdict + reason; confirms "Move
  /// whole group (N people)?" when the group is more than one, then hands the
  /// actual re-seat to [TourController.moveGroupToBus] (which re-seats the whole
  /// group on [destination] via the engine — within-bus arrangement is free, so
  /// the anchor's chosen seat is intentionally NOT preserved for grouped movers).
  ///
  /// Every exit reports itself: a refused destination is
  /// [SeatMoveOutcome.failed] with the reason on screen, a backed-out confirm is
  /// [SeatMoveOutcome.cancelled], and a successful cascade is
  /// [SeatMoveOutcome.groupReseated] — never a plain `moved`, because the seat
  /// the operator picked was not the seat anyone landed on.
  static Future<SeatMoveOutcome> _moveGroup(
    BuildContext context, {
    required String tourId,
    required Passenger mover,
    required Bus destination,
  }) async {
    final tour = _ctrl.getTour(tourId);
    if (tour == null) return SeatMoveOutcome.failed;
    final passengers = tour.passengers;

    final plan = GroupCascade.planMove(
      mover: mover,
      destinationBus: destination,
      passengers: passengers,
    );
    final memberCount = plan.memberPassengerIds.length;

    if (memberCount > 1) {
      final confirmed = await _confirmGroupMove(context, count: memberCount);
      if (confirmed != true) return SeatMoveOutcome.cancelled;
      if (!context.mounted) return SeatMoveOutcome.cancelled;
    }

    if (!plan.destinationFits) {
      _showBlockedDialog(context, plan.blockedReason);
      return SeatMoveOutcome.failed;
    }

    final ok = await _ctrl.moveGroupToBus(
      tourId: tourId,
      anchorPassengerId: mover.id,
      destinationBusId: destination.id,
    );
    return ok ? SeatMoveOutcome.groupReseated : SeatMoveOutcome.failed;
  }

  static Future<bool> _confirmGroupMove(
    BuildContext context, {
    required int count,
  }) {
    return UgamDialog.confirm(
      context,
      title: tr('seat_detail.group_move.title'),
      message: tr(
        'seat_detail.group_move.message',
        namedArgs: {'count': '$count'},
      ),
      confirmLabel: tr(
        'seat_detail.group_move.confirm',
        namedArgs: {'count': '$count'},
      ),
    );
  }

  static void _showBlockedDialog(BuildContext context, String? reason) {
    UgamDialog.show<void>(
      context,
      title: tr('seat_detail.blocked.title'),
      message: reason ?? tr('seat_detail.blocked.no_room'),
      actions: (ctx) => [
        UgamButton(
          label: tr('app.action.ok'),
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    );
  }
}
