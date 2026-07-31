// Pure-Dart seat availability for the CUSTOMER seat chart. NO Flutter imports,
// NO I/O, no wall-clock, no randomness — identical input always yields
// identical output.
//
// This is the client-side twin of the leg accounting in migration 048's
// `chart_seat_availability` / `chart_claim_seats`. The two MUST agree: the
// server is the authority (it re-validates every claim inside an advisory
// lock), and this file exists so the chart can grey out a seat before the
// customer wastes a tap on it. Any change here needs the same change in 048.
//
// The rule, once: a berth offers ONE outbound slot and ONE return slot. A
// double sofa cell is two berths, everything else is one. A booking consumes
// the GO slot when its leg is roundTrip/outboundOnly and the RET slot when it
// is roundTrip/returnOnly — which is exactly what lets one physical berth be
// sold to an outbound-only rider and a return-only rider at the same time.

import 'dart:math' as math;

import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// Anonymised occupancy of ONE seat, as returned by `chart_seat_availability`.
///
/// Carries NO name and NO phone — deliberately. Every Indian operator app
/// surveyed shows a booked seat with a GENDER MARKER and never an identity, and
/// `passengers` has no anon SELECT policy precisely to stop a stranger reading
/// the roster off a public tour. [ladyGo]/[ladyRet] are that marker.
class SeatAvailability {
  final String busId;
  final String seatId;

  /// Berths of this seat already consumed on the outbound / return leg.
  final int usedGo;
  final int usedRet;

  /// Whether a female rider holds this seat on that leg. Drives the "booked
  /// ladies seat" tile; null/false means either no female or gender unknown
  /// (request-mode and legacy bookings carry no gender).
  final bool ladyGo;
  final bool ladyRet;

  const SeatAvailability({
    required this.busId,
    required this.seatId,
    this.usedGo = 0,
    this.usedRet = 0,
    this.ladyGo = false,
    this.ladyRet = false,
  });

  /// Composite key used by [availabilityByKey]. A seatId is only unique within
  /// a bus, so the bus has to be part of the key.
  static String keyFor(String busId, String seatId) => '$busId|$seatId';

  String get key => keyFor(busId, seatId);

  factory SeatAvailability.fromMap(Map<String, dynamic> map) {
    return SeatAvailability(
      busId: (map['bus_id'] ?? '').toString(),
      seatId: (map['seat_id'] ?? '').toString(),
      usedGo: (map['used_go'] as num?)?.toInt() ?? 0,
      usedRet: (map['used_ret'] as num?)?.toInt() ?? 0,
      ladyGo: map['lady_go'] as bool? ?? false,
      ladyRet: map['lady_ret'] as bool? ?? false,
    );
  }
}

/// Index an availability list by `busId|seatId`. Seats missing from the feed
/// are wholly free — the server only emits OCCUPIED seats.
Map<String, SeatAvailability> availabilityByKey(
  Iterable<SeatAvailability> rows,
) {
  return {for (final r in rows) r.key: r};
}

/// Physical berths one seat cell holds: a Double Sofa is an upper+lower pair
/// (2), everything else is a single berth (1). Mirrors [SeatType.berthsPerUnit]
/// and the `case when seatType = 'doubleSofa' then 2 else 1` in migration 048.
int berthsOfCell(SeatCell cell) =>
    cell.seatType == SeatType.doubleSofa ? 2 : 1;

/// How many berths of [cell] a customer travelling [leg] may still claim.
///
/// A round-trip rider needs the berth free on BOTH legs, so they are limited by
/// the busier leg — `capacity - max(usedGo, usedRet)`. A one-way rider only
/// needs their own leg. A seat the organiser has [SeatCell.reserved] is never
/// claimable. Never negative.
int freeBerths({
  required SeatCell cell,
  required SeatAvailability? occupancy,
  required TripType leg,
}) {
  if (!cell.hasSeat || cell.reserved) return 0;
  final capacity = berthsOfCell(cell);
  final usedGo = occupancy?.usedGo ?? 0;
  final usedRet = occupancy?.usedRet ?? 0;

  final int used;
  if (leg.usesOutbound && leg.usesReturn) {
    used = math.max(usedGo, usedRet);
  } else if (leg.usesOutbound) {
    used = usedGo;
  } else {
    used = usedRet;
  }
  return math.max(0, capacity - used);
}

/// Whether a female rider already holds [cell] on any leg the [leg] booking
/// would share. Used for the ladies marker, NOT to block a booking — this app
/// does not enforce the gender-adjacency rule that redBus does, it only shows
/// the same signal every operator app shows.
bool hasLadyOn({required SeatAvailability? occupancy, required TripType leg}) {
  if (occupancy == null) return false;
  if (leg.usesOutbound && occupancy.ladyGo) return true;
  if (leg.usesReturn && occupancy.ladyRet) return true;
  return false;
}

/// How a seat tile should render on the customer chart, for the leg they chose.
///
/// Note there is deliberately no per-leg badge state. Every real system —
/// QwikBus's segment "seat sharing", Turnit's O&D inventory, redBus's
/// route-scoped seat layout — makes the customer commit to the leg FIRST and
/// then renders an already-filtered map, so "available" always means
/// "available for you". Painting GO/RET state onto the tile is a pattern with
/// no precedent anywhere, and it is the same mistake as putting a leg chip on
/// the admin seat tile.
enum ChartSeatState {
  /// Every berth is claimable on this leg.
  free,

  /// Some but not all berths are gone — half a double sofa, or the same berth
  /// already sold on the opposite leg. Still bookable.
  partlyTaken,

  /// Nothing left on this leg.
  taken,

  /// The organiser held this seat back; never offered.
  blocked,

  /// The customer has it in their current selection.
  selected,
}

/// Resolve the tile state for one cell. [selectedBerths] is how many berths of
/// this cell the customer has already picked in the current, uncommitted
/// selection.
ChartSeatState chartSeatState({
  required SeatCell cell,
  required SeatAvailability? occupancy,
  required TripType leg,
  int selectedBerths = 0,
}) {
  if (!cell.hasSeat || cell.reserved) return ChartSeatState.blocked;
  if (selectedBerths > 0) return ChartSeatState.selected;
  final free = freeBerths(cell: cell, occupancy: occupancy, leg: leg);
  if (free <= 0) return ChartSeatState.taken;
  return free < berthsOfCell(cell)
      ? ChartSeatState.partlyTaken
      : ChartSeatState.free;
}
