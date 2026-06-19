import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';

/// The at-a-glance collection state for one rider or a whole seat, mirroring
/// collection_screen's chip logic: return-due (warm) wins, then a shortfall is
/// owing (danger), then a squared-off collection with cash in is paid (good),
/// otherwise nothing has been collected yet (neutral).
enum SeatMoneyState { uncollected, paid, owing, returnDue }

/// Per-RIDER money state from their resolved [due] and [collection].
///
/// Kept pure (no Bus/Passenger) so the rule is testable and shared by every
/// surface that paints a collection dot/chip — the handler grid, the roster,
/// and the collect sheet all read the same truth.
SeatMoneyState riderMoneyStateOf(double due, Collection? collection) {
  final col = collection;
  if (col == null) {
    return due > 0 ? SeatMoneyState.owing : SeatMoneyState.uncollected;
  }
  if (col.isReturnDue) return SeatMoneyState.returnDue;
  if (col.balance < 0) return SeatMoneyState.owing;
  if (col.isSquare && col.amountReceived > 0) return SeatMoneyState.paid;
  return SeatMoneyState.uncollected;
}

/// Seat-level money state across EVERY rider sharing the berth (a Double Sofa
/// can seat up to four across GO+RET).
///
/// The dot is only [paid] (green) when ALL riders have squared off — if even
/// one still owes, the seat reads [owing] (red), so a half-paid shared sofa
/// never looks settled with only one person's cash entered. When nobody owes,
/// the worst remaining state wins: returnDue (someone is due change) over
/// uncollected. An empty seat is [uncollected].
SeatMoneyState seatMoneyStateOf(Iterable<SeatMoneyState> riderStates) {
  final states = riderStates.toList();
  if (states.isEmpty) return SeatMoneyState.uncollected;
  if (states.every((s) => s == SeatMoneyState.paid)) return SeatMoneyState.paid;
  if (states.any((s) => s == SeatMoneyState.owing)) return SeatMoneyState.owing;
  if (states.any((s) => s == SeatMoneyState.returnDue)) {
    return SeatMoneyState.returnDue;
  }
  return SeatMoneyState.uncollected;
}

/// The seat-level money state for EVERY occupied seat on a chart, keyed by
/// seatId. For each seat it aggregates across all riders via
/// [seatMoneyStateOf]; empty seats are omitted (no dot). [occupantsBySeat] is
/// the per-seat rider list (one entry per distinct rider) and [collectionFor]
/// resolves a rider's collection for a seat — the single computation every
/// chart that paints a money dot shares.
Map<String, SeatMoneyState> seatMoneyStatesForChart({
  required Bus bus,
  required Map<String, List<Passenger>> occupantsBySeat,
  required Collection? Function(String passengerId, String seatId) collectionFor,
}) {
  final out = <String, SeatMoneyState>{};
  for (final entry in occupantsBySeat.entries) {
    if (entry.value.isEmpty) continue;
    out[entry.key] = seatMoneyStateOf(
      entry.value.map(
        (p) => riderMoneyStateOf(
          bus.amountDueForSeat(p, entry.key),
          collectionFor(p.id, entry.key),
        ),
      ),
    );
  }
  return out;
}
