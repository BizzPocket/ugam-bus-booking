import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';
import 'collection_seat_resolver.dart';

/// The at-a-glance collection state for one rider or a whole seat, mirroring
/// collection_screen's chip logic: return-due (warm) wins, then a shortfall is
/// owing (danger), then a squared-off collection with cash in is paid (good),
/// otherwise nothing has been collected yet (neutral).
enum SeatMoneyState { uncollected, paid, owing, returnDue }

/// How much of a collection to record as RETURNED, given the cash the rider
/// tendered and any amount the handler explicitly marked as returned.
///
/// - [received] is the cash handed over (the hero amount in the collect sheet).
/// - [manualReturned] is an explicit "returned to customer" override; `0` means
///   the handler left it blank.
///
/// When the rider OVERPAID ([received] > [due]) and no explicit return was
/// typed, the surplus is change to hand back: it is booked as refunded so the
/// line settles to net = due and the change is recorded on the books instead of
/// silently inflating "collected". An explicit [manualReturned] always wins, so
/// genuine refunds / partial returns are never overwritten.
double refundToRecord({
  required double due,
  required double received,
  required double manualReturned,
}) {
  if (manualReturned > 0) return manualReturned;
  final change = received - due;
  return change > 0 ? change : 0;
}

/// The value to PRE-SEED the collect sheet's "returned" field with when
/// re-opening a saved [collection], or `null` to leave it BLANK.
///
/// Only a GENUINE manual return is pre-seeded. When the stored refund is merely
/// the auto-recorded change (== `max(0, received − due)`), this returns `null`
/// so re-opening re-derives the change from the freshly typed received amount
/// via [refundToRecord]. Otherwise correcting an over-collected seat would
/// re-freeze the stale change as a manual return and store a phantom shortfall
/// (inflating the bus summary's to-collect). Shared by BOTH the admin
/// (collection_screen) and handler (handler_bus_chart_screen) collect sheets so
/// their re-open behaviour can never drift apart.
double? manualReturnToSeed(Collection? collection) {
  final col = collection;
  if (col == null || col.amountRefunded <= 0) return null;
  final autoChange = col.amountReceived - col.amountDue > 0
      ? col.amountReceived - col.amountDue
      : 0.0;
  final isManualReturn = (col.amountRefunded - autoChange).abs() > 0.005;
  return isManualReturn ? col.amountRefunded : null;
}

/// Cash a collection row actually holds (`received − refunded`), or 0 when
/// nothing has been collected for that seat yet.
double netCollectedOf(Collection? collection) =>
    collection == null ? 0 : collection.amountReceived - collection.amountRefunded;

/// Paid-vs-owed for one rider, measured against the LIVE [due] rather than the
/// `amount_due` snapshotted when the money was taken. +ve = hand money back,
/// −ve = still owed.
///
/// It has to be the live fare, because fares are per-BUS: carrying a rider from
/// a ₹1,500 band into a ₹2,000 one re-prices them the instant they land, so
/// someone who paid in full on bus 1 owes ₹500 on bus 2. Reading
/// [Collection.balance] instead would keep showing the OLD bus's expectation
/// and report them as settled until the row happened to be re-saved — the
/// stored value is a snapshot, not the current price.
///
/// Refunds count, so a partly-refunded row can never read as fully paid.
double liveBalanceOf(double due, Collection? collection) =>
    netCollectedOf(collection) - due;

/// What a bus is still owed, and what it still has to hand back, measured SEAT
/// BY SEAT against the LIVE fare.
///
/// THE BUG THIS KILLS. Three surfaces each answered "how much is still to
/// collect on this bus?" with their own arithmetic:
///
///   * the collection roster — live fare vs the resolved row ([liveBalanceOf]);
///   * [BusMoneySummary.compute] — `Collection.balance`, i.e. the `amount_due`
///     SNAPSHOT taken when the money was recorded;
///   * `MoneyController.summaryForBus` on the ledger path — each rider's
///     TOUR-WIDE `finance_rider_balance`, apportioned across their buses by
///     billed share.
///
/// So the collect screen's header and the roster printed underneath it were
/// computed two different ways, and disagreed the moment a fare changed after
/// money was taken: a header reading "₹449 to return" over a To-return filter
/// that matched nobody. The apportioning made it worse — splitting one rider's
/// net balance across the buses they sit on lands a FRACTION of it on a bus
/// whose own seat is square, so a figure appeared on a bus with no rider behind
/// it at all.
///
/// This is now the one answer. It walks the same seats the roster renders, in
/// the same order, using the same [liveBalanceOf] — so a header total is always
/// the sum of the lines below it, and "to collect ₹X" always has rows you can
/// point at.
///
/// Seats are deduplicated by BASE id ([baseSeatId]): both berths of a whole
/// double sofa are ONE priced record ([Bus.amountDueForSeat] charges the full
/// sofa once), so counting the raw ids would bill it twice.
///
/// Rows whose payer no longer holds a seat here are deliberately NOT counted as
/// money to hand back. That cash is [BusMoneySummary.detachedCash] — surfaced on
/// its own, display-only — and reading it as a refund due is precisely the
/// phantom this function exists to stop.
({double toCollect, double toReturn}) busSeatAr({
  required String busId,
  required Iterable<Passenger> passengers,
  required Iterable<Collection> collections,
  required double Function(Passenger passenger, String seatId) dueForSeat,
}) {
  var toCollect = 0.0;
  var toReturn = 0.0;
  for (final p in passengers) {
    final seatIds = <String>{
      for (final a in p.assignedSeats)
        if (a.busId == busId) baseSeatId(a.seatId),
    };
    for (final seatId in seatIds) {
      final balance = liveBalanceOf(
        dueForSeat(p, seatId),
        collectionRowForSeat(
          passenger: p,
          busId: busId,
          seatId: seatId,
          collections: collections,
        ),
      );
      if (balance > Collection.kMoneyEpsilon) {
        toReturn += balance;
      } else if (balance < -Collection.kMoneyEpsilon) {
        toCollect += -balance;
      }
    }
  }
  return (toCollect: toCollect, toReturn: toReturn);
}

/// Per-RIDER money state from their resolved [due] and [collection].
///
/// Kept pure (no Bus/Passenger) so the rule is testable and shared by every
/// surface that paints a collection dot/chip — the handler grid, the roster,
/// and the collect sheet all read the same truth.
SeatMoneyState riderMoneyStateOf(double due, Collection? collection) {
  final balance = liveBalanceOf(due, collection);
  if (balance > Collection.kMoneyEpsilon) return SeatMoneyState.returnDue;
  if (balance < -Collection.kMoneyEpsilon) return SeatMoneyState.owing;
  // Square. Cash in means settled; nothing in means a free/zero-fare seat that
  // was never collected on.
  return netCollectedOf(collection) > 0
      ? SeatMoneyState.paid
      : SeatMoneyState.uncollected;
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
