// Can a bus seat a party, and how do we explain that in the customer's terms?
//
// Pure Dart — NO Flutter imports, no I/O — so the arithmetic behind the party
// gate can be pinned by unit tests without pumping a widget.
//
// *** PEOPLE IN, SOFAS OUT ***
// The gate asks "how many of you?" because a customer knows their party size,
// not the seat taxonomy. But a sleeper customer shops in SOFAS, so the answer
// is explained back as sofas ("fits your 4 — 2 whole sofas"). Both numbers have
// to be right at once, and they are not the same number: a double sofa is ONE
// cell and TWO people. Counting cells would tell a party of six that a bus with
// three free doubles only seats three.

import '../models/seat_layout.dart';
import '../models/trip_type.dart';
import 'chart_seat_availability.dart';

/// What the customer told the gate before the chart was drawn.
///
/// Deliberately only what the picker CANNOT work out for itself. There is no
/// "must you stay on one bus?" field: keeping a party together is simply what
/// the picker tries first, and asking the customer to predict when that is
/// impossible was asking them to do the picker's job.
class PartyIntent {
  /// How many people are travelling. One berth each.
  final int people;

  /// Whether the group includes women. Feeds the ladies marker and colours the
  /// sharing decision — a lone woman asked to share a sofa with an unknown man
  /// is the case this exists to handle.
  final bool hasLadies;

  /// Whether they will share a two-person sofa with a stranger.
  ///
  /// False means half-sofas are never auto-picked and never offered on tap.
  /// This replaces a hidden double-tap that committed the customer to sharing
  /// without ever saying the word.
  final bool shareOk;

  const PartyIntent({
    required this.people,
    this.hasLadies = false,
    this.shareOk = true,
  });

  /// The default for a customer who reached the chart without the gate (a deep
  /// link, or a returning rider): one traveller, willing to share.
  static const solo = PartyIntent(people: 1);
}

/// What one bus can offer a party of a given size, on a given leg.
class BusFit {
  final String busId;

  /// Berths (people) still claimable on this leg.
  final int freeBerths;

  /// Doubles with BOTH berths still free — the ones a couple can take whole.
  /// A half-sold double still sells a berth, but it is no longer a whole sofa,
  /// which is the distinction a customer choosing for two actually cares about.
  final int wholeSofas;

  /// The party this fit was computed against.
  final int people;

  const BusFit({
    required this.busId,
    required this.freeBerths,
    required this.wholeSofas,
    required this.people,
  });

  /// Whether the WHOLE party can travel on this one bus.
  bool get fitsWholeParty => freeBerths >= people;

  /// How many people would be left behind. Zero when the party fits.
  int get shortfall => fitsWholeParty ? 0 : people - freeBerths;
}

/// Compute [BusFit] for one bus.
///
/// Availability is resolved through the SAME [freeBerths] used by the chart and
/// mirrored by migration 048's SQL, so the gate can never promise a seat the
/// chart would refuse.
BusFit busFit({
  required String busId,
  required BusLayout? layout,
  required Map<String, SeatAvailability> availability,
  required TripType leg,
  required int people,
}) {
  var berths = 0;
  var wholeSofas = 0;

  for (final cell in layout?.grid ?? const <SeatCell>[]) {
    if (!cell.hasSeat) continue;
    final free = freeBerths(
      cell: cell,
      occupancy: availability[SeatAvailability.keyFor(busId, cell.seatId ?? '')],
      leg: leg,
    );
    if (free <= 0) continue;
    berths += free;
    // Only a double with BOTH berths intact counts as a whole sofa.
    if (berthsOfCell(cell) == 2 && free == 2) wholeSofas++;
  }

  return BusFit(
    busId: busId,
    freeBerths: berths,
    wholeSofas: wholeSofas,
    people: people,
  );
}

// `shouldAskTogether` was removed with the same-bus/split question it guarded.
// The picker decides whether a party can stay on one bus, and says so on the
// summary bar when it cannot.
