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
///
/// *** WHY THREE COUNTS AND NOT ONE ***
/// The leg used to be a property of the whole booking — one `TripType` on the
/// screen, one `p_leg` on the RPC. That cannot express the ordinary case of a
/// family where some stay on: four travel out to Dwarka, two remain with
/// relatives, two come home. The leg belongs to the PERSON, so the intent
/// counts people per leg.
///
/// Request mode has always worked this way (`RequestLine.leg`); chart mode was
/// the odd one out.
class PartyIntent {
  /// People travelling both ways. Their berth must be free on BOTH legs.
  final int roundTrip;

  /// People taking the outbound bus only, then staying on.
  final int outboundOnly;

  /// People already at the destination, boarding only for the journey home.
  final int returnOnly;

  /// Whether they will share a two-person sofa with a stranger.
  ///
  /// False means half-sofas are never auto-picked and never offered on tap.
  /// This replaces a hidden double-tap that committed the customer to sharing
  /// without ever saying the word.
  final bool shareOk;

  // `hasLadies` was removed. The gate collected it, threaded it through here
  // and handed it to the picker, which never read it — so it changed nothing a
  // customer could see. Gender is still collected at checkout, and the lady
  // marker on the chart is read from occupancy data, not from this answer.

  const PartyIntent({
    this.roundTrip = 0,
    this.outboundOnly = 0,
    this.returnOnly = 0,
    this.shareOk = true,
  });

  /// Total berths to place. One person, one berth, on whichever legs they take.
  int get people => roundTrip + outboundOnly + returnOnly;

  /// True when this party spans more than one leg — the case that needs a
  /// return tab on the chart and a per-seat leg on the claim.
  bool get isMixed => activeLegs.length > 1;

  /// How many people are travelling on exactly [leg].
  int countFor(TripType leg) => switch (leg) {
        TripType.roundTrip => roundTrip,
        TripType.outboundOnly => outboundOnly,
        TripType.returnOnly => returnOnly,
      };

  /// Non-empty buckets, MOST CONSTRAINED FIRST.
  ///
  /// Round-trip leads because its berth must be free on both legs, so it has
  /// the fewest candidates; letting a one-way pass take those cells first would
  /// strand it. The picker walks this list in order and must not re-sort it.
  List<TripType> get activeLegs => [
        for (final leg in const [
          TripType.roundTrip,
          TripType.outboundOnly,
          TripType.returnOnly,
        ])
          if (countFor(leg) > 0) leg,
      ];

  /// The default for a customer who reached the chart without the gate (a deep
  /// link, or a returning rider): one traveller, both ways, willing to share.
  static const solo = PartyIntent(roundTrip: 1);
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
