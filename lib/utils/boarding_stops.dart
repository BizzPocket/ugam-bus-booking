// Turns a pickup-grouped roster into the stop-by-stop progression the handler
// actually works through on the ground.
//
// [groupByPickup] already puts riders under the right pickup headers in the
// admin's route order. What it does not say is which stop the bus is AT: the
// old attendance view rendered every section expanded at equal weight, so a
// handler at the third of six pickup points scrolled past two finished stops
// to reach the rows they needed, and nothing told them whether they were clear
// to leave a stop.

import '../models/passenger.dart';
import '../models/seat_layout.dart';
import 'aisle_order.dart';
import 'passenger_display.dart';
import 'pickup_grouping.dart';

/// One pickup point plus how far the handler has got through it.
class BoardingStop {
  final String? locationId;

  /// Null for the catch-all bucket of riders with no pickup point recorded.
  final String? locationName;

  final List<Passenger> riders;

  /// Riders here marked present on the leg being boarded.
  final int boarded;

  const BoardingStop({
    required this.locationId,
    required this.locationName,
    required this.riders,
    required this.boarded,
  });

  int get total => riders.length;

  /// Still to board here.
  int get pending => total - boarded;

  /// Every rider expected at this stop is aboard.
  bool get isComplete => total > 0 && boarded >= total;

  bool get isUnassigned => locationName == null || locationName!.trim().isEmpty;
}

/// The whole boarding picture for one bus on one leg.
class BoardingProgress {
  final List<BoardingStop> stops;

  /// Index into [stops] of the stop the handler is working now — the first one
  /// with anyone still to board. Null once every stop is complete.
  ///
  /// Note this is derived from ATTENDANCE, not from GPS or stop order
  /// acknowledgement: the bus is "at" the first stop that isn't finished. That
  /// is deliberately forgiving — a handler who boards someone out of order (a
  /// rider who walked up the route to meet the bus) doesn't get dragged
  /// backwards, because a stop only stops being current once it is full.
  final int? currentIndex;

  const BoardingProgress({required this.stops, required this.currentIndex});

  BoardingStop? get current =>
      currentIndex == null ? null : stops[currentIndex!];

  int get boarded => stops.fold(0, (sum, s) => sum + s.boarded);

  int get total => stops.fold(0, (sum, s) => sum + s.total);

  int get pending => total - boarded;

  /// Everyone expected on this leg is aboard.
  bool get isComplete => total > 0 && currentIndex == null;

  /// Stops fully boarded, for the "3 of 6 stops done" line.
  int get stopsComplete => stops.where((s) => s.isComplete).length;
}

/// Builds the stop-by-stop view of [riders] on one leg.
///
/// [isPresent] is the attendance lookup for the leg being boarded — the same
/// one the tally uses, so the stop counters and the header count can never
/// disagree.
///
/// [rankOf] is [groupByPickup]'s ordering hook (the admin's manual pickup
/// serial). Passing it through keeps the stops in route order rather than
/// alphabetical, which is the difference between a usable boarding list and a
/// scramble.
///
/// Every seat code this rider holds on [busId], in aisle-walking order. A
/// passenger with two double sofas at DL2 and DL9 therefore shows both codes
/// even though the berths are not adjacent — attendance is still one row per
/// person.
List<String> seatIdsOnBus(
  Passenger passenger,
  String busId, {
  AisleWalk? walk,
}) {
  final w = walk ?? AisleWalk.of(null);
  final ids = <String>[];
  for (final a in passenger.assignedSeats) {
    if (a.busId != busId) continue;
    final id = a.seatId;
    if (id.isEmpty) continue;
    if (!ids.contains(id)) ids.add(id);
  }
  ids.sort((a, b) {
    final ia = w.indexOf(a);
    final ib = w.indexOf(b);
    if (ia != null && ib != null && ia != ib) return ia.compareTo(ib);
    if (ia != null && ib == null) return -1;
    if (ia == null && ib != null) return 1;
    return a.compareTo(b);
  });
  return ids;
}

/// The frontmost seat on [busId] — used for sort position only.
String? seatIdOnBus(Passenger passenger, String busId, {AisleWalk? walk}) {
  final ids = seatIdsOnBus(passenger, busId, walk: walk);
  return ids.isEmpty ? null : ids.first;
}

/// Aisle index of the frontmost seat on [busId], or a large sentinel.
int frontSeatRank(Passenger passenger, String busId, AisleWalk walk) {
  final id = seatIdOnBus(passenger, busId, walk: walk);
  return walk.indexOf(id) ?? (1 << 30);
}

/// Sort riders the way the seat chart reads: front to back along the aisle.
int comparePassengersByBusSeat(
  Passenger a,
  Passenger b, {
  required String busId,
  BusLayout? layout,
}) {
  final walk = AisleWalk.of(layout);
  int rank(Passenger p) {
    final id = seatIdOnBus(p, busId, walk: walk);
    final i = walk.indexOf(id);
    if (i != null) return i;
    return 1 << 30;
  }

  final ra = rank(a);
  final rb = rank(b);
  if (ra != rb) return ra.compareTo(rb);
  final sa = seatIdOnBus(a, busId, walk: walk) ?? '';
  final sb = seatIdOnBus(b, busId, walk: walk) ?? '';
  final bySeat = sa.compareTo(sb);
  if (bySeat != 0) return bySeat;
  return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
}

/// Orders riders at one pickup: booking groups stay together, positioned by the
/// family's frontmost seat; inside a group, seat order; ungrouped riders sort
/// by their own seats.
List<Passenger> sortRidersForBoarding(
  List<Passenger> riders, {
  required String busId,
  BusLayout? layout,
}) {
  if (riders.length <= 1) return riders;
  final walk = AisleWalk.of(layout);

  final clusters = <String, List<Passenger>>{};
  for (final p in riders) {
    final key = (p.groupId == null || p.groupId!.isEmpty) ? p.id : p.groupId!;
    clusters.putIfAbsent(key, () => []).add(p);
  }

  int clusterRank(List<Passenger> members) {
    var best = 1 << 30;
    for (final m in members) {
      final r = frontSeatRank(m, busId, walk);
      if (r < best) best = r;
    }
    return best;
  }

  final ordered = clusters.entries.toList()
    ..sort((a, b) {
      final ra = clusterRank(a.value);
      final rb = clusterRank(b.value);
      if (ra != rb) return ra.compareTo(rb);
      return a.key.compareTo(b.key);
    });

  final out = <Passenger>[];
  for (final e in ordered) {
    final members = List<Passenger>.from(e.value)
      ..sort(
        (a, b) => comparePassengersByBusSeat(
          a,
          b,
          busId: busId,
          layout: layout,
        ),
      );
    out.addAll(members);
  }
  return out;
}

BoardingProgress buildBoardingProgress(
  List<Passenger> riders, {
  required bool Function(Passenger) isPresent,
  int? Function(String? locationId, String locationName)? rankOf,
  String? seatSortBusId,
  BusLayout? seatSortLayout,
}) {
  final groups = groupByPickup<Passenger>(
    riders,
    idOf: (p) => p.pickupLocationId,
    nameOf: (p) => p.pickupLocationName,
    rankOf: rankOf,
  );

  final stops = <BoardingStop>[
    for (final g in groups)
      BoardingStop(
        locationId: g.locationId,
        locationName: g.locationName,
        riders: seatSortBusId == null
            ? g.items
            : sortRidersForBoarding(
                g.items,
                busId: seatSortBusId,
                layout: seatSortLayout,
              ),
        boarded: g.items.where(isPresent).length,
      ),
  ];

  final currentIndex = stops.indexWhere((s) => !s.isComplete);
  return BoardingProgress(
    stops: stops,
    currentIndex: currentIndex == -1 ? null : currentIndex,
  );
}
