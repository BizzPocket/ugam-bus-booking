import 'package:easy_localization/easy_localization.dart';

/// Where one bus is in the handler's trip, and therefore what the whole
/// handler surface should be pointing at right now.
///
/// The old handler screen had no notion of this: it rendered the money hero,
/// the settlement card, the leg-completion card and the boarding tally all at
/// once, at equal weight, from the moment the chart opened until the trip was
/// over. A handler standing at the depot with nobody aboard saw the same screen
/// as one counting cash at the end of the night, so the app never told them
/// what to do next — they had to carry the sequence in their head.
///
/// The phase is never stored as a column. It is DERIVED by
/// [resolveHandlerPhase] from four things the server already knows about, so
/// two devices looking at the same bus always agree and there is no phase field
/// that can drift out of step with the facts underneath it.
enum HandlerPhase {
  /// At the pickup points, ticking riders aboard for the outbound leg.
  boardingGo,

  /// Outbound leg running. This is the long stretch where cash is collected.
  enRouteGo,

  /// Outbound finished, return not yet rolling — riders re-board.
  boardingRet,

  /// Return leg running.
  enRouteRet,

  /// Everyone is off the bus but the cash has not been fully handed over.
  settling,

  /// Trip over and the books are square. Read-only from here.
  closed;

  /// Whether the boarding tally is the thing that matters in this phase.
  bool get isBoarding =>
      this == HandlerPhase.boardingGo || this == HandlerPhase.boardingRet;

  /// Whether the bus is moving with passengers aboard.
  bool get isEnRoute =>
      this == HandlerPhase.enRouteGo || this == HandlerPhase.enRouteRet;

  /// Which leg's roster/attendance this phase is about. Return-side phases
  /// answer `true`; [settling] and [closed] keep whatever the last leg was, so
  /// callers pass their own fallback for those.
  bool get isReturnSide =>
      this == HandlerPhase.boardingRet || this == HandlerPhase.enRouteRet;

  String get label {
    switch (this) {
      case HandlerPhase.boardingGo:
        return tr('handler_phase.boarding_go');
      case HandlerPhase.enRouteGo:
        return tr('handler_phase.en_route_go');
      case HandlerPhase.boardingRet:
        return tr('handler_phase.boarding_ret');
      case HandlerPhase.enRouteRet:
        return tr('handler_phase.en_route_ret');
      case HandlerPhase.settling:
        return tr('handler_phase.settling');
      case HandlerPhase.closed:
        return tr('handler_phase.closed');
    }
  }
}

/// The four timestamps the handler themselves stamps on a bus, from
/// `handler_bus_trip_state`. All nullable — a bus that has not left yet has
/// none of them.
///
/// Deliberately per-BUS rather than per-tour, matching `handler_bus_leg_state`:
/// a two-bus tour can have one bus rolling while the other is still loading,
/// and a tour-level flag would force them to lie about each other.
class HandlerTripState {
  final String busId;

  /// Outbound departure — "we've left the last pickup point".
  final DateTime? goDepartedAt;

  /// Outbound arrival — the destination is reached and the outbound leg is
  /// over. This, NOT the seat-release RPC, is what ends the GO leg: a bus
  /// carrying only round-trip riders has no outbound-only seats to release, so
  /// keying the phase off `handler_complete_outbound_leg` would strand it in
  /// [HandlerPhase.enRouteGo] for the rest of the trip. Releasing the seats is
  /// offered alongside this stamp when there are any to release.
  final DateTime? goArrivedAt;

  /// Return departure.
  final DateTime? retDepartedAt;

  /// Trip over — everyone is off the bus.
  final DateTime? completedAt;

  const HandlerTripState({
    required this.busId,
    this.goDepartedAt,
    this.goArrivedAt,
    this.retDepartedAt,
    this.completedAt,
  });

  /// A bus the handler has not touched yet.
  const HandlerTripState.fresh(this.busId)
    : goDepartedAt = null,
      goArrivedAt = null,
      retDepartedAt = null,
      completedAt = null;

  factory HandlerTripState.fromMap(Map<dynamic, dynamic> map) {
    DateTime? at(String key) {
      final raw = map[key];
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString())?.toLocal();
    }

    return HandlerTripState(
      busId: (map['bus_id'] ?? '').toString(),
      goDepartedAt: at('go_departed_at'),
      goArrivedAt: at('go_arrived_at'),
      retDepartedAt: at('ret_departed_at'),
      completedAt: at('completed_at'),
    );
  }

  HandlerTripState copyWith({
    DateTime? goDepartedAt,
    DateTime? goArrivedAt,
    DateTime? retDepartedAt,
    DateTime? completedAt,
  }) => HandlerTripState(
    busId: busId,
    goDepartedAt: goDepartedAt ?? this.goDepartedAt,
    goArrivedAt: goArrivedAt ?? this.goArrivedAt,
    retDepartedAt: retDepartedAt ?? this.retDepartedAt,
    completedAt: completedAt ?? this.completedAt,
  );
}

/// The milestone a handler can stamp next. Exactly one is offered at a time —
/// that single-ness is the point, since the failure being fixed is a screen
/// that offered every action at once.
enum HandlerMilestone {
  /// "We've left" — stamps `go_departed_at`.
  departGo,

  /// "We've arrived" — stamps `go_arrived_at`, and releases outbound-only
  /// seats when the bus carries any.
  arriveGo,

  /// "Heading back" — stamps `ret_departed_at`.
  departRet,

  /// "Trip finished" — stamps `completed_at`.
  endTrip;

  String get label {
    switch (this) {
      case HandlerMilestone.departGo:
        return tr('handler_phase.milestone_depart_go');
      case HandlerMilestone.arriveGo:
        return tr('handler_phase.milestone_arrive_go');
      case HandlerMilestone.departRet:
        return tr('handler_phase.milestone_depart_ret');
      case HandlerMilestone.endTrip:
        return tr('handler_phase.milestone_end_trip');
    }
  }

  /// Confirm-dialog body — every one of these is hard to walk back, so none of
  /// them fire straight off the tap.
  String get confirmBody {
    switch (this) {
      case HandlerMilestone.departGo:
        return tr('handler_phase.confirm_depart_go');
      case HandlerMilestone.arriveGo:
        return tr('handler_phase.confirm_arrive_go');
      case HandlerMilestone.departRet:
        return tr('handler_phase.confirm_depart_ret');
      case HandlerMilestone.endTrip:
        return tr('handler_phase.confirm_end_trip');
    }
  }
}

/// Resolves the phase for one bus from state that already exists server-side.
///
/// [hasReturnRiders] comes from `handler_bus_leg_state.ridersOnReturn`: a bus
/// whose riders are all one-way outbound has no return leg at all, so arriving
/// takes it straight to [HandlerPhase.settling] rather than parking it on a
/// return boarding screen nobody will ever use.
///
/// [moneySettled] is `HandlerBusMoney.isSettled` — nothing left to hand over.
/// It is the ONLY thing separating [HandlerPhase.settling] from
/// [HandlerPhase.closed], so a handler still holding cash can never reach a
/// state that reads as finished.
HandlerPhase resolveHandlerPhase({
  required HandlerTripState trip,
  required bool hasReturnRiders,
  required bool moneySettled,
}) {
  // Trip explicitly ended, or an outbound-only bus that has arrived: nothing
  // left but the cash.
  final overOnArrival = trip.goArrivedAt != null && !hasReturnRiders;
  if (trip.completedAt != null || overOnArrival) {
    return moneySettled ? HandlerPhase.closed : HandlerPhase.settling;
  }
  if (trip.retDepartedAt != null) return HandlerPhase.enRouteRet;
  if (trip.goArrivedAt != null) return HandlerPhase.boardingRet;
  if (trip.goDepartedAt != null) return HandlerPhase.enRouteGo;
  return HandlerPhase.boardingGo;
}

/// The milestone offered in [phase], or null when the phase's next step isn't a
/// milestone at all ([HandlerPhase.settling] wants a handover, not a stamp;
/// [HandlerPhase.closed] wants nothing).
HandlerMilestone? milestoneFor(HandlerPhase phase) {
  switch (phase) {
    case HandlerPhase.boardingGo:
      return HandlerMilestone.departGo;
    case HandlerPhase.enRouteGo:
      return HandlerMilestone.arriveGo;
    case HandlerPhase.boardingRet:
      return HandlerMilestone.departRet;
    case HandlerPhase.enRouteRet:
      return HandlerMilestone.endTrip;
    case HandlerPhase.settling:
    case HandlerPhase.closed:
      return null;
  }
}
