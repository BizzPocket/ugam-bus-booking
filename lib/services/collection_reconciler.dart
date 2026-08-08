import 'package:get/get.dart';

import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';
import '../models/tour.dart';

/// One passenger's money position after their seats moved.
///
/// Reported when the move crossed buses OR re-priced the passenger on a
/// different band, because that is the case the agent has to act on: the cash
/// was taken at the OLD price and the NEW seat bills a different one.
///
/// [paid] is real cash in hand (`amount_received - amount_refunded`) summed
/// across every collection row the passenger holds on this tour. [due] is the
/// live fare across every seat they hold RIGHT NOW, from each bus's own bands.
class SeatMoveMoneyDelta {
  final String passengerId;
  final String passengerName;

  /// Net cash already collected from this passenger on this tour.
  final double paid;

  /// Live fare across every seat this passenger now holds.
  final double due;

  /// Bus names the money was originally taken against.
  final List<String> fromBusNames;

  /// Bus names the passenger now sits on.
  final List<String> toBusNames;

  /// Bus ids matching [fromBusNames] — for deep-linking into collection.
  final List<String> fromBusIds;

  /// Bus ids matching [toBusNames] — destination drawer after the move.
  final List<String> toBusIds;

  const SeatMoveMoneyDelta({
    required this.passengerId,
    required this.passengerName,
    required this.paid,
    required this.due,
    required this.fromBusNames,
    required this.toBusNames,
    this.fromBusIds = const [],
    this.toBusIds = const [],
  });

  /// +ve = collect this much more; -ve = return this much to the customer.
  double get delta => due - paid;

  bool get isCollectMore => delta > Collection.kMoneyEpsilon;
  bool get isReturnDue => delta < -Collection.kMoneyEpsilon;
  bool get isSquare => delta.abs() <= Collection.kMoneyEpsilon;

  double get toCollect => isCollectMore ? delta : 0;
  double get toReturn => isReturnDue ? -delta : 0;
}

/// What [CollectionReconciler] wants written, plus what to tell the agent.
class CollectionReconcilePlan {
  /// Collection rows whose `bus_id` / `seat_id` / `amount_due` changed and
  /// therefore need persisting. Every row keeps its `id`, so these are plain
  /// updates — no row is ever created or destroyed by reconciliation, and cash
  /// (`amount_received` / `amount_refunded`) is never rewritten.
  final List<Collection> updates;

  /// Per-passenger deltas worth surfacing (bus actually changed).
  final List<SeatMoveMoneyDelta> deltas;

  const CollectionReconcilePlan({
    this.updates = const [],
    this.deltas = const [],
  });

  bool get isEmpty => updates.isEmpty && deltas.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// Keeps `collections` rows attached to the seats their payers actually hold.
///
/// Collections are keyed `(passenger_id, bus_id, seat_id)` and fares are
/// per-BUS ([Bus.amountDueForSeat] reads that bus's own price bands). A seat
/// move rewrites `passengers.assigned_seats` and nothing else, so before this
/// reconciler a moved payer's row was left pointing at a seat they no longer
/// hold. Two visible consequences:
///
///  * the destination bus billed them the FULL new fare as if they had never
///    paid (`collectionFor` matches all three key parts, so it returned null),
///  * the origin bus showed the cash as unexplained `detachedCash`.
///
/// So a rider who paid ₹1,500 in bus 1's band and moved into bus 2's ₹2,000
/// band was asked for ₹2,000 instead of the ₹500 difference.
///
/// Reconciliation re-homes each orphaned row onto a seat the passenger still
/// holds and re-prices `amount_due` to that seat's live fare. The cash columns
/// are untouched, so [Collection.balance] then reads the difference directly:
/// −₹500 "still to collect", or +₹200 "return to customer" when the new bus is
/// cheaper.
///
/// Deliberately NOT done here:
///  * money is never deleted. A passenger who ends up with fewer seats than
///    collection rows (unseated, or seats reduced) keeps the surplus rows where
///    they are, so the cash stays visible as `detachedCash` rather than
///    silently vanishing.
///  * no refund is auto-recorded. An overpayment surfaces as "return due" and
///    a human records the actual handover on the collection screen.
class CollectionReconciler {
  /// Build the write plan for [passengerIds] against the tour's current seating.
  ///
  /// [collections] must be every collection row known for [tour]; rows for
  /// other tours or other passengers are ignored. Pure and idempotent —
  /// re-running against the result of a previous run yields an empty plan.
  static CollectionReconcilePlan plan({
    required Tour tour,
    required Iterable<String> passengerIds,
    required List<Collection> collections,
  }) {
    final busById = {for (final b in tour.buses) b.id: b};
    final updates = <Collection>[];
    final deltas = <SeatMoveMoneyDelta>[];

    for (final pid in passengerIds.toSet()) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == pid);
      if (p == null) continue;

      final rows = collections
          .where((c) => c.tourId == tour.id && c.passengerId == pid)
          .toList();
      if (rows.isEmpty) continue; // nothing was ever collected — nothing to carry

      final result = _planForPassenger(
        passenger: p,
        rows: rows,
        busById: busById,
      );
      updates.addAll(result.updates);
      if (result.delta != null) deltas.add(result.delta!);
    }

    return CollectionReconcilePlan(updates: updates, deltas: deltas);
  }

  static ({List<Collection> updates, SeatMoveMoneyDelta? delta})
  _planForPassenger({
    required Passenger passenger,
    required List<Collection> rows,
    required Map<String, Bus> busById,
  }) {
    // Distinct seats the passenger holds right now, on buses that still exist.
    // A whole-double contributes two berths on ONE cell but only one collection
    // row (the key is per seat, not per berth), so de-duplicate.
    final seats = <({String busId, String seatId})>[];
    for (final a in passenger.assignedSeats) {
      if (!busById.containsKey(a.busId)) continue;
      final key = (busId: a.busId, seatId: a.seatId);
      if (!seats.contains(key)) seats.add(key);
    }

    // Rows already sitting on a seat the passenger still holds keep their slot;
    // everything else is an orphan looking for a home.
    final claimed = <({String busId, String seatId})>{};
    final matched = <Collection>[];
    final orphans = <Collection>[];
    for (final r in rows) {
      final key = (busId: r.busId, seatId: r.seatId);
      if (seats.contains(key) && !claimed.contains(key)) {
        claimed.add(key);
        matched.add(r);
      } else {
        orphans.add(r);
      }
    }
    final free = seats.where((s) => !claimed.contains(s)).toList();

    // Re-home orphans. Prefer a free seat on the SAME bus (a plain same-bus
    // seat move, where the fare usually does not change) before moving the row
    // across buses, so a passenger holding seats on two buses keeps each row
    // attached to the bus whose cash drawer actually took the money.
    final placed = <Collection>[];
    final rehomedFromBus = <String>{};
    for (final r in orphans) {
      if (free.isEmpty) continue; // no seat to attach to — leave the cash put
      var idx = free.indexWhere((s) => s.busId == r.busId);
      if (idx < 0) idx = 0;
      final target = free.removeAt(idx);
      if (target.busId != r.busId) rehomedFromBus.add(r.busId);
      placed.add(r.copyWith(busId: target.busId, seatId: target.seatId));
    }

    // Re-price every row that is attached to a live seat, including the ones
    // that never moved — a same-bus band edit re-prices them too.
    final updates = <Collection>[];
    var totalDue = 0.0;
    for (final r in [...matched, ...placed]) {
      final bus = busById[r.busId];
      if (bus == null) continue;
      final due = bus.amountDueForSeat(passenger, r.seatId);
      totalDue += due;
      final priced = (due - r.amountDue).abs() > Collection.kMoneyEpsilon
          ? r.copyWith(amountDue: due)
          : r;
      final original = rows.firstWhereOrNull((o) => o.id == priced.id);
      final changed =
          original == null ||
          original.busId != priced.busId ||
          original.seatId != priced.seatId ||
          (original.amountDue - priced.amountDue).abs() >
              Collection.kMoneyEpsilon;
      if (changed) updates.add(priced);
    }

    // Cash position is passenger-wide: sum EVERY row (including any left
    // stranded), because that is the money physically taken from this person.
    final paid = rows.fold<double>(0, (s, r) => s + r.netCollected);
    final outstanding = totalDue - paid;
    final isSquare = outstanding.abs() <= Collection.kMoneyEpsilon;

    // Surfaced when the agent must act: crossed buses, OR same-bus band
    // reprice that leaves a collect/return gap. Same-band seat shuffle that
    // stays square stays silent.
    final dueRepriced = updates.any((u) {
      final original = rows.firstWhereOrNull((o) => o.id == u.id);
      if (original == null) return false;
      return (original.amountDue - u.amountDue).abs() > Collection.kMoneyEpsilon;
    });
    final shouldReport =
        !isSquare && (rehomedFromBus.isNotEmpty || dueRepriced);
    if (!shouldReport) return (updates: updates, delta: null);

    final toBusNames = <String>[];
    final toBusIds = <String>[];
    for (final s in seats) {
      if (!toBusIds.contains(s.busId)) {
        toBusIds.add(s.busId);
        final n = busById[s.busId]?.name;
        if (n != null) toBusNames.add(n);
      }
    }
    final fromBusIds = <String>[];
    final fromBusNames = <String>[];
    if (rehomedFromBus.isNotEmpty) {
      for (final id in rehomedFromBus) {
        fromBusIds.add(id);
        final n = busById[id]?.name;
        if (n != null) fromBusNames.add(n);
      }
    } else {
      // Same-bus band change: origin is the bus(es) the updated rows sat on.
      for (final u in updates) {
        final original = rows.firstWhereOrNull((o) => o.id == u.id);
        final id = original?.busId ?? u.busId;
        if (fromBusIds.contains(id)) continue;
        fromBusIds.add(id);
        final n = busById[id]?.name;
        if (n != null) fromBusNames.add(n);
      }
    }

    return (
      updates: updates,
      delta: SeatMoveMoneyDelta(
        passengerId: passenger.id,
        passengerName: passenger.name,
        paid: paid,
        due: totalDue,
        fromBusNames: fromBusNames,
        toBusNames: toBusNames,
        fromBusIds: fromBusIds,
        toBusIds: toBusIds,
      ),
    );
  }
}
