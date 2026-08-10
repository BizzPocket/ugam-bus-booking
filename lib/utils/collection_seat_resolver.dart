import '../models/collection.dart';
import '../models/passenger.dart';

/// A seat id with its BERTH SUFFIX stripped ('DL1#2' → 'DL1').
///
/// A double sofa is TWO berths on ONE physical seat, stored as two assignment
/// entries differing only by the '#n' suffix — but priced, and collected
/// against, as a single unit. `Bus.amountDueForSeat` does exactly this split
/// before pricing (bus_details.dart:534), so any code matching a collection row
/// to a seat has to compare the same normalised id: on the raw string a whole
/// sofa would look like two seats and earn two half-price records.
String baseSeatId(String seatId) => seatId.split('#').first;

/// The EXISTING collection row a tap on [seatId] must write into, or null when
/// this seat genuinely deserves a brand-new row.
///
/// THE BUG THIS KILLS. The handler resolved a collection by the full
/// (passenger, bus, seat) triple — the same triple the `collections` unique
/// index and `handler_upsert_collection`'s ON CONFLICT use. A rider who paid on
/// seat A and later sat in seat B therefore MISSED, was handed a fresh uuid, and
/// the insert did not collide: two rows for one rider. Both money engines fold
/// per collection ROW (`BusMoneySummary.compute`, and `HandlerBusMoney.compute`
/// through it), so that rider's cash was counted twice on the handler's screen
/// AND on the admin's board. Nothing healed it — `reconcileAfterSeatMove`
/// returns early for a SAME-bus move, so the stale row's seat_id was never
/// re-homed.
///
/// WHY THE FIX IS NOT "one row per rider per bus". Collections are keyed by seat
/// deliberately: `Bus.amountDueForSeat` prices ONE record per DISTINCT seat — a
/// whole double sofa is one record at the FULL sofa price, two separate seats
/// are two records — and `Bus.amountDueFor` is *defined* as the sum over exactly
/// those distinct seats (bus_details.dart:501-519). Collapsing a two-seat rider
/// onto one row would bill them for one seat and lose the other's fare, which is
/// a worse bug than the one being fixed. The two invariants that must survive
/// every resolution are:
///
///   rows(rider, bus)  ==  distinct seats(rider, bus)
///   Σ row.amountDue   ==  bus.amountDueFor(rider)
///
/// THE RULE, in order:
///
///   1. The row already naming this PHYSICAL seat wins (berth suffix stripped,
///      so both berths of a sofa share the one record).
///   2. Otherwise the seat may adopt an ORPHANED row — one whose seat this rider
///      no longer holds on this bus, i.e. cash stranded by a seat move. A row on
///      a seat they STILL hold is never taken over: that row is that seat's
///      record, and stealing it would silently drop a seat's worth of fare.
///      Orphans (oldest first) are paired INDEX-WISE with the rider's still
///      un-rowed seats (sorted), which makes the claim a bijection — two seats
///      can never adopt the same row, so the row count can neither grow past nor
///      fall below the seat count.
///   3. Otherwise null: a new seat, a new row.
///
/// The adopted row keeps its STORED seat_id; only its money is rewritten (see
/// the call site in handler_bus_chart_screen). Re-homing seat_id is a SERVER
/// change, not a client one: `handler_upsert_collection` inserts with an
/// explicit id and conflicts only on (passenger_id, bus_id, seat_id), so a row
/// sent back under a different seat misses that target and collides on the
/// PRIMARY KEY instead — the save would be rejected outright and the cash never
/// recorded. Leaving seat_id put costs nothing: every figure that reads these
/// rows is already documented seat-AGNOSTIC (money_summary.dart:91-100,
/// handler_bus_money.dart:100-107), and this resolver is what the chart's money
/// dot and the collect sheet read, so the stale seat is never user-visible.
Collection? collectionRowForSeat({
  required Passenger passenger,
  required String busId,
  required String seatId,
  required Iterable<Collection> collections,
}) {
  final target = baseSeatId(seatId);
  // Every row this rider already holds ON THIS BUS, oldest first. A cross-bus
  // move is a different animal — the fare is re-priced per bus and the row is
  // scoped to its own bus — so other buses' rows are out of scope entirely.
  // The order is the tie-break for the orphan pairing below and so must be
  // TOTAL: two rows written in the same millisecond would otherwise pair
  // differently on two devices, and id is the final discriminator.
  final rows =
      collections
          .where((c) => c.passengerId == passenger.id && c.busId == busId)
          .toList()
        ..sort((a, b) {
          final byAge = a.createdAt.compareTo(b.createdAt);
          return byAge != 0 ? byAge : a.id.compareTo(b.id);
        });
  if (rows.isEmpty) return null;

  // 1. This seat's own record.
  for (final row in rows) {
    if (baseSeatId(row.seatId) == target) return row;
  }

  final held = <String>{
    for (final a in passenger.assignedSeats)
      if (a.busId == busId) baseSeatId(a.seatId),
  };
  // A seat the rider does not hold can never be the destination of a seat move,
  // so it has nothing to adopt. Defensive — the chart only offers seats their
  // occupants hold — but it keeps the bijection below honest for any caller.
  if (!held.contains(target)) return null;

  final orphans = [
    for (final row in rows)
      if (!held.contains(baseSeatId(row.seatId))) row,
  ];
  if (orphans.isEmpty) return null;

  // Pair un-rowed seats to orphans by position. Sorted so the pairing is stable
  // across rebuilds and across devices: the chart calls this for EVERY seat on
  // every frame to paint the money dot, and a pairing that shuffled would make
  // a rider's paid dot hop between their seats.
  final rowedSeats = {for (final row in rows) baseSeatId(row.seatId)};
  final unrowed = held.where((s) => !rowedSeats.contains(s)).toList()..sort();
  final index = unrowed.indexOf(target);
  // More un-rowed seats than stranded rows: the seats past the end genuinely
  // have no record yet and open their own.
  if (index < 0 || index >= orphans.length) return null;
  return orphans[index];
}
