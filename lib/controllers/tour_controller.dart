import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent;
import '../models/booking_mode.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/priority_status.dart';
import '../models/bus_details.dart';
import '../models/payment_status.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour_seat_snapshot.dart';
import '../models/trip_type.dart';
import '../services/group_cascade.dart';
import '../services/realtime_service.dart';
import '../services/seating_engine.dart';
import '../services/seating_plan_applier.dart';
import '../services/sync_retry_policy.dart' as retry;
import '../services/sync_service.dart';
import '../services/tour_cache_store.dart';
import '../services/whatsapp_outbound.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_normalize.dart';
import '../utils/seat_leg_cancel.dart';
import '../utils/seat_leg_resolver.dart';
import '../utils/seat_occupants.dart';
import '../models/bus_type.dart';
import '../utils/bus_layout_recovery.dart';
import '../utils/tour_capacity.dart';
import '../utils/trip_auto_complete.dart';
import '../widgets/seat_move_money_notice.dart';
import 'auth_controller.dart';
import 'customer_memory_controller.dart';
import 'money_controller.dart';

part 'tour_controller/base.dart';
part 'tour_controller/capacity.dart';
part 'tour_controller/disk_cache.dart';
part 'tour_controller/hydration.dart';
part 'tour_controller/lifecycle.dart';
part 'tour_controller/passengers.dart';
part 'tour_controller/seat_notify.dart';
part 'tour_controller/seating.dart';
part 'tour_controller/seat_swaps.dart';
part 'tour_controller/buses.dart';
part 'tour_controller/groups.dart';
part 'tour_controller/sync.dart';

/// Whether a tour's roster (passengers / buses / groups) can be believed — see
/// [TourController.rosterStateOf]. Only [ready] lets a screen say "no buses".
enum TourRosterState {
  /// Fetched (or already held in memory): an empty bus list is the truth.
  ready,

  /// The on-demand hydrate has not answered yet — show the skeleton.
  loading,

  /// The hydrate gave up — show the retry state, never "Add bus".
  failed,
}

/// Result of [TourController.loadSeatSnapshotsResult]: the snapshots read, and
/// whether the read FAILED (so `[]` means "couldn't read", not "none taken").
typedef SeatSnapshotLoad = ({List<TourSeatSnapshot> snapshots, bool failed});

/// What a seat move actually did — the honest answer a caller needs before it
/// tells the operator "moved" and puts the relocate banner away.
///
/// A cross-bus move of a GROUPED rider is rerouted into a whole-group cascade
/// ([TourController.moveGroupToBus]), which can legitimately refuse (the
/// destination cannot hold the party) and, when it succeeds, re-seats everyone
/// at ENGINE-chosen berths rather than the seat the operator tapped. Both of
/// those are invisible in a `Future<void>`, and on a locked tour an invisible
/// failure means the family is never re-notified and turns up at the wrong bus.
enum SeatMoveOutcome {
  /// The passenger is now on the exact seat that was asked for.
  moved,

  /// The mover's whole group was re-seated together on the destination bus at
  /// engine-chosen berths. The move DID happen — but not onto the requested
  /// seat, so the caller must say so rather than report a plain "moved".
  groupReseated,

  /// Nothing moved. The passenger is still exactly where they were, and the
  /// reason has already been surfaced to the operator.
  failed,

  /// The operator backed out of a confirmation. Nothing moved and nothing is
  /// wrong, so no error is shown — but it is NOT a success either.
  cancelled,
}

class TourController extends _TourControllerBase
    with
        _TourCapacity,
        _TourDiskCache,
        _TourHydration,
        _TourLifecycle,
        _TourPassengers,
        _TourSeatNotify,
        _TourSeating,
        _TourSeatSwaps,
        _TourBuses,
        _TourGroups,
        _TourSync {
  @override
  void onInit() {
    super.onInit();
    // ignore: unawaited_futures
    _bootstrapLoad();
    _subscribeToChanges();
  }

  @override
  void onClose() {
    _realtimeSub?.cancel();
    _reconnectSub?.cancel();
    _refreshDebounce?.cancel();
    _cacheSaveDebounce?.cancel();
    super.onClose();
  }
}

/// Pure transformation behind [TourController.cancelReturnSeat] — kept top-level
/// so it can be unit-tested without GetX/SyncService.
///
/// Returns `null` when the rider should be REMOVED outright: a return-only rider
/// (every request line is [TripType.returnOnly]) never rode any leg, so dropping
/// the return drops them entirely.
///
/// Otherwise returns the demoted passenger: every round-trip line becomes
/// outbound-only, outbound-only lines are kept as-is, return-only lines are
/// dropped (the cancelled return portion), seats are freed, and [journeyDone] is
/// set — mirroring how completeOutboundLeg retires a one-way rider after their
/// only leg.
Passenger? cancelReturnSeatTransform(Passenger p) {
  final lines = p.requestLines;
  final usesReturnOnly =
      lines.isNotEmpty && lines.every((l) => l.leg == TripType.returnOnly);
  if (usesReturnOnly) return null;

  final newLines = <RequestLine>[
    for (final l in lines)
      if (l.leg == TripType.roundTrip)
        l.copyWith(leg: TripType.outboundOnly)
      else if (l.leg == TripType.outboundOnly)
        l,
    // returnOnly lines are intentionally dropped (the cancelled return portion).
  ];

  return p.copyWith(
    requestLines: newLines,
    assignedSeats: const [],
    journeyDone: true,
    tripType: TripType.outboundOnly,
  );
}

/// Pure builder: freeze the [leg] seat chart for a tour. Returns null when no
/// seat on any bus is occupied for this leg (e.g. a one-way tour has no return
/// riders) — callers skip storing an empty snapshot.
///
/// Captures EVERY rider on each seat for [leg], not one. It used to read
/// `seatOccupantsForBus(...).go / .ret`, which keeps a single holder per leg —
/// so a Double Sofa whose two berths were taken by two DIFFERENT same-leg
/// riders archived only the first, and this snapshot is written at GO-leg
/// completion and never rebuilt. The loss was permanent.
///
/// The leg comes from the SEAT ([Passenger.legForSeat]), not the rider's overall
/// tripType: a round-trip rider whose GO berth and RET berth are different seats
/// would otherwise be frozen onto both seats on both legs.
TourSeatSnapshot? buildSeatSnapshot({
  required String tourId,
  required SnapshotLeg leg,
  required List<Bus> buses,
  required List<Passenger> passengers,
  required DateTime capturedAt,
}) {
  // Build one SnapshotBus per bus, skipping buses with no captured seats.
  final snapshotBuses = <SnapshotBus>[];
  var seatCount = 0;
  for (final bus in buses) {
    final occupants = occupantListForBus(passengers, bus.id);
    final seats = <SnapshotSeat>[];
    occupants.forEach((seatId, riders) {
      for (final p in riders) {
        final rideLeg = p.legForSeat(seatId, busId: bus.id);
        final onThisLeg = leg == SnapshotLeg.outbound
            ? rideLeg.usesOutbound
            : rideLeg.usesReturn;
        if (!onThisLeg) continue;
        seats.add(SnapshotSeat(
          seatId: seatId,
          name: p.displayName,
          phone: p.phone,
        ));
      }
    });
    if (seats.isEmpty) continue;
    seatCount += seats.length;
    snapshotBuses.add(SnapshotBus(busId: bus.id, seats: seats));
  }

  // Don't store an empty snapshot (e.g. one-way tour → no return riders).
  if (seatCount == 0) return null;

  return TourSeatSnapshot(
    tourId: tourId,
    leg: leg,
    buses: snapshotBuses,
    capturedAt: capturedAt,
  );
}
