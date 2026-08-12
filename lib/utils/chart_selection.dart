// Pure-Dart: turn a customer's tapped seats into the Passenger shape the rest
// of the app already understands. NO Flutter imports, NO I/O.
//
// This is the client-side twin of the request-line derivation inside migration
// 048's `chart_claim_seats`. The server does this authoritatively; this exists
// so the chart can price and summarise the selection before submitting, and so
// the mapping is unit-testable without a database.
//
// THE POINT OF THIS FILE: a chart booking must produce a Passenger that is
// INDISTINGUISHABLE in shape from a request-mode one — same request_lines, same
// assigned_seats — just with the seats already filled in. That is what lets
// money, capacity, the handler manifest, the chart PDF, notify and settlement
// keep working without knowing chart mode exists.

import '../models/bus_details.dart';
import '../models/request_line.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';

/// One tapped seat and how many of its berths the customer took.
///
/// [berths] is what makes half a double sofa expressible. The evidence from the
/// Indian sleeper market is that a "double" is two independently sold berths
/// and that strangers routinely share one — Bitla shipped a dedicated COVID
/// feature to BLOCK the second half, which you only build if it otherwise
/// sells. So one tap on a double takes one berth; a second tap takes both.
class ChartPick {
  final SeatCell cell;
  final int berths;

  /// Which legs the person in this berth is travelling.
  ///
  /// A chart booking used to carry ONE leg for the whole basket, which made a
  /// party where some people stay on impossible to express. The leg belongs to
  /// the person in the seat, not to the booking.
  ///
  /// Defaults to round-trip so every existing construction keeps its previous
  /// meaning — the old single-leg basket was always "everyone, both ways"
  /// unless the screen said otherwise.
  final TripType leg;

  const ChartPick({
    required this.cell,
    required this.berths,
    this.leg = TripType.roundTrip,
  });

  SeatType get seatType => cell.seatType!;
  String get seatId => cell.seatId!;

  /// Whether this pick takes a whole double sofa rather than half of one.
  bool get isWholeDouble =>
      seatType == SeatType.doubleSofa && berths >= 2;

  Map<String, dynamic> toClaimMap() =>
      {'seatId': seatId, 'berths': berths, 'leg': leg.storageKey};
}

/// The seat TYPE a pick books as.
///
/// Half a double sofa books as a SINGLE sofa, not as "half a double" — the
/// engine already cross-fills single-sofa demand onto double berths (see
/// `resolveAssignmentLegs`), and [RequestLine.qty] counts whole units, so a
/// doubleSofa line can only ever mean the full two-berth pair. Encoding a half
/// as a single is what keeps [Passenger.seatBerths] equal to the number of
/// assignment entries, which every capacity and money getter depends on.
SeatType lineTypeFor(ChartPick pick) {
  if (pick.seatType == SeatType.seater) return SeatType.seater;
  if (pick.isWholeDouble) return SeatType.doubleSofa;
  return SeatType.singleSofa;
}

/// The berth position a pick books at — always null for a seater.
SeatPosition? linePositionFor(ChartPick pick) =>
    pick.seatType == SeatType.seater ? null : pick.cell.position;

/// Collapse picks into request lines, grouped by (seat type, position, LEG), in
/// a stable order. Mirrors the `group by` in `chart_claim_seats`.
///
/// The leg joins the key because two people in the same kind of berth on
/// DIFFERENT legs are two different lines — and are billed differently, since
/// a one-way berth pays half.
List<RequestLine> requestLinesFor({required List<ChartPick> picks}) {
  // Insertion-ordered so the output is deterministic for a given pick order.
  final counts =
      <String, ({SeatType type, SeatPosition? pos, TripType leg, int qty})>{};
  for (final p in picks) {
    final type = lineTypeFor(p);
    final pos = linePositionFor(p);
    final key = '${type.name}|${pos?.name ?? ''}|${p.leg.name}';
    final prev = counts[key];
    counts[key] = (
      type: type,
      pos: pos,
      leg: p.leg,
      qty: (prev?.qty ?? 0) + 1,
    );
  }
  return [
    for (final v in counts.values)
      RequestLine(seatType: v.type, position: v.pos, qty: v.qty, leg: v.leg),
  ];
}

/// One [SeatAssignment] PER BERTH, each stamped with its own pick's leg. A whole
/// double sofa is therefore TWO entries sharing a seatId — exactly how the app
/// already stores a solo-held double (see `seatOccupantsForBus`), so occupancy
/// resolution is unchanged.
List<SeatAssignment> assignmentsFor({
  required List<ChartPick> picks,
  required String busId,
}) {
  final out = <SeatAssignment>[];
  for (final p in picks) {
    for (var i = 0; i < p.berths; i++) {
      out.add(SeatAssignment(busId: busId, seatId: p.seatId, leg: p.leg));
    }
  }
  return out;
}

/// The coarse trip type a mixed basket reports as. Round-trip when any pick is
/// round-trip or the legs are mixed, else the single shared value.
///
/// Deliberately the same rule as `summaryTripTypeOf` in `round_trip_combine.dart`
/// — request mode has always derived `booking_requests.trip_type` this way, and
/// two different derivations of one column is how they drift apart.
TripType summaryLegOf(List<ChartPick> picks) {
  if (picks.isEmpty) return TripType.roundTrip;
  if (picks.any((p) => p.leg == TripType.roundTrip)) return TripType.roundTrip;
  final legs = picks.map((p) => p.leg).toSet();
  return legs.length == 1 ? legs.first : TripType.roundTrip;
}

/// Total physical berths in a selection — the number the customer is paying
/// for, and the `party_size` the booking request records.
int totalBerths(List<ChartPick> picks) =>
    picks.fold(0, (sum, p) => sum + p.berths);

/// The claim payload for `chart_claim_seats`.
List<Map<String, dynamic>> claimPayload(List<ChartPick> picks) =>
    [for (final p in picks) p.toClaimMap()];

/// One bus's share of a checkout: the bus itself plus what was picked on it.
///
/// The chart's basket can now span buses (migration 068), so checkout receives
/// a LIST of these rather than a single bus. Each carries its own [Bus] because
/// fares are per bus — two buses on one tour can price the same seat type
/// differently, and quoting a split party off the visible bus would misquote it.
class ChartBusSelection {
  final Bus bus;
  final List<ChartPick> picks;

  const ChartBusSelection({required this.bus, required this.picks});

  int get berths => totalBerths(picks);
}
