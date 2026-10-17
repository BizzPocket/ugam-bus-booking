part of 'board_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pure mapping — tour facts → Board facts.
// ─────────────────────────────────────────────────────────────────────────────

/// Whole calendar days from [now] to [departure]; negative once it has passed.
///
/// Calendar days, not elapsed hours: a bus leaving at 06:00 tomorrow is ONE day
/// out at 23:00 tonight and at 07:00 this morning alike, and the T-2d money
/// chase of spec §6 is a thing agents count in sleeps, not in hours.
int boardDaysUntilDeparture(DateTime departure, DateTime now) {
  final from = DateTime(now.year, now.month, now.day);
  final to = DateTime(departure.year, departure.month, departure.day);
  return to.difference(from).inDays;
}

/// The trip phase the ADMIN Board can honestly claim for [tour].
///
/// [HandlerPhase] is derived from the four timestamps a handler stamps on a bus
/// (`handler_bus_trip_state`), and the admin app does not hold them — so
/// inventing a phase here would be a guess dressed as a fact. Only one value is
/// knowable from tour state alone:
///
///  * a COMPLETED tour is [HandlerPhase.closed] — books square, read-only, and
///    spec §6 opens it on the roster rather than on a chase.
///
/// Everything else returns null, which [defaultLensForPhase] reads as "the bus
/// is still being filled" and then resolves against
/// [BoardController.daysUntilDeparture] — the one fact the admin side really
/// does know. That is what makes a tour two days out open on Money and a tour
/// two months out open on Occupancy, with no handler session in sight.
HandlerPhase? boardPhaseForTour(Tour tour) =>
    tour.status == TourStatus.completed ? HandlerPhase.closed : null;

/// Berth facts for one bus, keyed by `SeatCell.seatId`.
///
/// **Only OCCUPIED berths are emitted.** `boardBerthFor` already synthesises an
/// honest vacant / blocked berth for any cell the map has nothing for, from the
/// cell's own geometry, so filling this with 74 empty entries would be 74
/// allocations a rebuild to say what the canvas already knows. It also means a
/// partially-loaded roster degrades to "empty", never to a hole in the chart.
///
/// [collectionFor] resolves the money row for one rider on one berth — pass
/// `MoneyController.collectionFor`, which adopts a row the rider paid on a seat
/// they have since left. Reading the amounts through it rather than off the
/// passenger is what keeps the money lens agreeing with the money board.
///
/// A shared berth (a split sofa, or a GO rider and a RET rider on disjoint
/// legs) sums BOTH riders' fares and BOTH their payments, because the tile
/// draws one berth and the lens colours one berth. The individual positions are
/// resolved again, per rider, when the sheet opens.
Map<String, BoardBerth> boardBerthsForBus({
  required Bus bus,
  required List<Passenger> passengers,
  Map<String, String> groupNames = const <String, String>{},
  Collection? Function(Passenger passenger, String seatId)? collectionFor,
}) {
  final layout = bus.layout;
  if (layout == null) return const <String, BoardBerth>{};

  final occupants = occupantListForBus(passengers, bus.id);
  if (occupants.isEmpty) return const <String, BoardBerth>{};

  final out = <String, BoardBerth>{};
  for (final cell in layout.grid) {
    if (!cell.hasSeat) continue;
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) continue;
    final riders = occupants[seatId];
    if (riders == null || riders.isEmpty) continue;

    var fare = 0.0;
    var paid = 0.0;
    for (final p in riders) {
      fare += bus.amountDueForSeat(p, seatId);
      paid += collectionFor?.call(p, seatId)?.netCollected ?? 0;
    }

    final lead = riders.first;
    final groupId = lead.groupId;
    out[seatId] = BoardBerth(
      code: seatId,
      isOccupied: true,
      occupantName: lead.displayName,
      fareDue: fare,
      paid: paid,
      pickupStopId: lead.pickupLocationId,
      pickupStopName: lead.pickupLocationName,
      groupId: groupId,
      groupName: groupId == null ? null : groupNames[groupId],
      seatTypeLabel: cell.typeLabel,
    );
  }
  return out;
}

/// The pickup lens's colour budget for [berths] (spec §5's five-tint cap).
///
/// Buckets are keyed on `pickupStopId` and nothing else, because that is what
/// [PickupLens] asks a berth for — keying on the NAME here would tint a berth
/// the legend could then never match, and the swatch would filter to zero.
/// First-appearance order along the walk breaks ties, which for a bus is the
/// order it passes the stops.
BoardTintScale boardStopTints(Iterable<BoardBerth> berths) =>
    _tintsBy(berths, (b) => b.pickupStopId, (b) => b.pickupStopName);

/// The group lens's colour budget. Same rule, keyed on `groupId`.
BoardTintScale boardGroupTints(Iterable<BoardBerth> berths) =>
    _tintsBy(berths, (b) => b.groupId, (b) => b.groupName);

BoardTintScale _tintsBy(
  Iterable<BoardBerth> berths,
  String? Function(BoardBerth berth) idOf,
  String? Function(BoardBerth berth) nameOf,
) {
  final order = <String>[];
  final names = <String, String>{};
  final counts = <String, int>{};
  for (final b in berths) {
    if (!b.isOccupied) continue;
    final id = idOf(b);
    if (id == null || id.isEmpty) continue;
    if (!counts.containsKey(id)) {
      order.add(id);
      final name = nameOf(b)?.trim();
      names[id] = (name == null || name.isEmpty) ? id : name;
    }
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return BoardTintScale.fromSeeds([
    for (final id in order)
      BoardTintSeed(id: id, label: names[id]!, count: counts[id]!),
  ]);
}
