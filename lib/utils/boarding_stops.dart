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
BoardingProgress buildBoardingProgress(
  List<Passenger> riders, {
  required bool Function(Passenger) isPresent,
  int? Function(String? locationId, String locationName)? rankOf,
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
        riders: g.items,
        boarded: g.items.where(isPresent).length,
      ),
  ];

  final currentIndex = stops.indexWhere((s) => !s.isComplete);
  return BoardingProgress(
    stops: stops,
    currentIndex: currentIndex == -1 ? null : currentIndex,
  );
}
