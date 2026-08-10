import '../models/collection.dart';
import 'seat_money_state.dart';

/// Builds the collection row to hand to `handler_upsert_collection`.
///
/// Extracted from the collect sheet because the rule it encodes is not obvious
/// and was got wrong once already, in a way no widget test could catch.
///
/// THE RULE: A ROW'S seat_id IS IMMUTABLE ONCE CREATED.
///
/// `existing` may be a row ADOPTED from a seat the rider has since left —
/// that is precisely what [collectionRowForSeat] is for. Rewriting its
/// `seat_id` to the rider's current seat makes `handler_upsert_collection`
/// (042:54) miss its `on conflict (passenger_id, bus_id, seat_id)` target: no
/// row matches the new triple, so Postgres attempts an INSERT carrying the
/// adopted row's existing id, and dies on the primary key.
///
/// The failure mode is worse than the bug adoption was introduced to fix. A
/// duplicate row at least records the cash; a PK violation means the handler
/// cannot record a moved rider's payment AT ALL, on a bus, with the passenger
/// waiting.
///
/// So an adopted row keeps its own seat_id and the resolver keeps mapping it
/// to wherever the rider now sits. Only a genuinely new row takes the current
/// seat.
Collection buildCollectionToSave({
  required Collection? existing,
  required String tourId,
  required String busId,
  required String passengerId,
  required String seatId,
  required double due,
  required double received,
  required double manualReturned,
  required String collectedBy,
  required String note,
}) {
  final base = existing ??
      Collection(
        tourId: tourId,
        busId: busId,
        passengerId: passengerId,
        // The one place a seat_id is ever set: at creation.
        seatId: seatId,
      );

  return base.copyWith(
    // Deliberately no seatId. See the rule above.
    amountDue: due,
    amountReceived: received,
    // Overpayment auto-books as change returned (net settles to due) unless
    // the handler typed an explicit return — the same rule as the admin
    // collection screen.
    amountRefunded: refundToRecord(
      due: due,
      received: received,
      manualReturned: manualReturned,
    ),
    collectedBy: collectedBy.isEmpty ? null : collectedBy,
    note: note.isEmpty ? null : note,
  );
}
