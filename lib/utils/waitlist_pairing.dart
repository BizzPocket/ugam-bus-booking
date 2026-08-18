import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// Two waitlisted riders who could share ONE physical berth — one going, one
/// coming back.
class WaitlistPair {
  final Passenger goRider;
  final Passenger retRider;

  /// The seat type they would share. A berth is a physical seat, so both riders
  /// must want the same kind.
  final SeatType type;

  /// How many WHOLE units of [type] the two can actually share — the smaller of
  /// the two demands. A rider wanting three singles and one wanting one share
  /// exactly one berth; the other two carry the first rider alone.
  final int units;

  const WaitlistPair({
    required this.goRider,
    required this.retRider,
    required this.type,
    required this.units,
  });

  /// Stable identity for widget keys and de-duplication.
  String get key => '${goRider.id}|${retRider.id}|${type.name}';
}

/// Every way the waitlisted riders in [riders] could be paired onto shared
/// berths.
///
/// *** WHY PAIRING EXISTS ***
/// A berth offers ONE outbound slot and ONE return slot. A Go-only rider uses
/// the first and leaves the second idle; pairing them with a Return-only rider
/// of the same seat type fills both, which is how 37 berths carry up to 74
/// one-leg riders. Left unpaired, every one-leg sale throws away half a berth.
///
/// Who is excluded, and why each exclusion is load-bearing:
///   * a rider going the SAME way — they need the same slot, not the other one;
///   * a DIFFERENT seat type — a berth is a physical seat, and a single-sofa
///     rider cannot occupy the return leg of a double sofa;
///   * a ROUND-TRIP or mixed-leg rider — they already hold both slots of their
///     berth, so there is no free leg to give away;
///   * anyone already confirmed or off the waitlist — they are no longer the
///     organiser's to place.
///
/// Every viable combination is returned, not a chosen matching: which GO rider
/// gets the shared berth is the organiser's call, not this function's.
///
/// Pure — no Flutter, no I/O — so the pairing screen and its tests share one
/// definition of "can these two share a seat".
List<WaitlistPair> pairCandidates(Iterable<Passenger> riders) {
  final open = riders.where(_isPairable).toList();

  final going = open.where((p) => _soleLeg(p) == TripType.outboundOnly);
  final returning =
      open.where((p) => _soleLeg(p) == TripType.returnOnly).toList();

  final out = <WaitlistPair>[];
  for (final go in going) {
    final goUnits = _unitsByType(go);
    for (final ret in returning) {
      final retUnits = _unitsByType(ret);
      for (final entry in goUnits.entries) {
        final theirs = retUnits[entry.key] ?? 0;
        if (theirs <= 0) continue;
        out.add(WaitlistPair(
          goRider: go,
          retRider: ret,
          type: entry.key,
          units: entry.value < theirs ? entry.value : theirs,
        ));
      }
    }
  }
  return out;
}

/// The pairings available for ONE rider — what the organiser sees when they
/// open a waitlisted rider and ask "who can share this berth?".
List<WaitlistPair> pairCandidatesFor(
  Passenger rider,
  Iterable<Passenger> riders,
) =>
    pairCandidates(riders)
        .where((p) => p.goRider.id == rider.id || p.retRider.id == rider.id)
        .toList();

/// Still the organiser's to place: on the waitlist, not confirmed, not done.
bool _isPairable(Passenger p) =>
    p.isWaitlisted && !p.isConfirmed && !p.journeyDone;

/// The ONE leg this rider travels, or null when they are round-trip or mixed.
///
/// Mixed is deliberately excluded rather than partially paired: some of their
/// berths would be free on the return and some not, and offering the rider as a
/// pairing candidate would promise a leg that may already be spoken for.
TripType? _soleLeg(Passenger p) {
  if (p.requestLines.isEmpty) return null;
  final legs = p.requestLines.map((l) => l.leg).toSet();
  if (legs.length != 1) return null;
  final leg = legs.first;
  return leg.isOneWay ? leg : null;
}

/// Whole units wanted per seat type (a Double Sofa is one unit, two berths).
Map<SeatType, int> _unitsByType(Passenger p) {
  final out = <SeatType, int>{};
  for (final l in p.requestLines) {
    if (l.qty <= 0) continue;
    out[l.seatType] = (out[l.seatType] ?? 0) + l.qty;
  }
  return out;
}
