import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/waitlist_pairing.dart';

/// Pairing is the whole point of the waiting list: one berth carries a GO rider
/// and a RET rider at the same time, so 37 berths can serve up to 74 one-leg
/// riders. These tests pin WHO may share a berth with WHOM.
Passenger rider({
  required String id,
  required String name,
  required TripType leg,
  SeatType type = SeatType.singleSofa,
  int qty = 1,
  bool waitlisted = true,
  bool confirmed = false,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+9198240112$id',
      isWaitlisted: waitlisted,
      isConfirmed: confirmed,
      requestLines: [RequestLine(seatType: type, qty: qty, leg: leg)],
    );

void main() {
  group('pairCandidates', () {
    test('a GO rider pairs with a RET rider of the same seat type', () {
      final go = rider(id: '1', name: 'Asha', leg: TripType.outboundOnly);
      final ret = rider(id: '2', name: 'Bhavin', leg: TripType.returnOnly);

      final pairs = pairCandidates([go, ret]);

      expect(pairs.length, 1);
      expect(pairs.single.goRider.id, '1');
      expect(pairs.single.retRider.id, '2');
      expect(pairs.single.type, SeatType.singleSofa);
      expect(pairs.single.units, 1);
    });

    test('two riders going the SAME way cannot share a berth', () {
      // Both need the outbound slot of whatever berth they land on.
      final a = rider(id: '1', name: 'A', leg: TripType.outboundOnly);
      final b = rider(id: '2', name: 'B', leg: TripType.outboundOnly);

      expect(pairCandidates([a, b]), isEmpty);
    });

    test('different seat types cannot share a berth', () {
      // A berth IS a physical seat — a single sofa rider cannot share the
      // return leg of a double sofa.
      final go = rider(id: '1', name: 'A', leg: TripType.outboundOnly);
      final ret = rider(
        id: '2',
        name: 'B',
        leg: TripType.returnOnly,
        type: SeatType.doubleSofa,
      );

      expect(pairCandidates([go, ret]), isEmpty);
    });

    test('the shared units are the SMALLER of the two demands', () {
      // 3 going, 1 returning: one berth is fully shared, two carry the GO
      // rider alone.
      final go = rider(id: '1', name: 'A', leg: TripType.outboundOnly, qty: 3);
      final ret = rider(id: '2', name: 'B', leg: TripType.returnOnly, qty: 1);

      expect(pairCandidates([go, ret]).single.units, 1);
    });

    test('a round-trip rider is never a pairing candidate', () {
      // They already hold both legs of their berth.
      final full = rider(id: '1', name: 'A', leg: TripType.roundTrip);
      final ret = rider(id: '2', name: 'B', leg: TripType.returnOnly);

      expect(pairCandidates([full, ret]), isEmpty);
    });

    test('an already-confirmed rider is not offered for pairing', () {
      final go = rider(
        id: '1',
        name: 'A',
        leg: TripType.outboundOnly,
        waitlisted: false,
        confirmed: true,
      );
      final ret = rider(id: '2', name: 'B', leg: TripType.returnOnly);

      expect(pairCandidates([go, ret]), isEmpty);
    });

    test('every viable combination is offered, not just the first', () {
      // Two GO riders and one RET rider: the organiser must be able to choose
      // WHICH go rider gets the shared berth.
      final go1 = rider(id: '1', name: 'A', leg: TripType.outboundOnly);
      final go2 = rider(id: '2', name: 'B', leg: TripType.outboundOnly);
      final ret = rider(id: '3', name: 'C', leg: TripType.returnOnly);

      final pairs = pairCandidates([go1, go2, ret]);

      expect(pairs.length, 2);
      expect(pairs.map((p) => p.goRider.id).toSet(), {'1', '2'});
    });

    test('candidates for ONE rider filter to that rider', () {
      final go = rider(id: '1', name: 'A', leg: TripType.outboundOnly);
      final ret1 = rider(id: '2', name: 'B', leg: TripType.returnOnly);
      final ret2 = rider(id: '3', name: 'C', leg: TripType.returnOnly);

      final pairs = pairCandidatesFor(go, [go, ret1, ret2]);

      expect(pairs.length, 2);
      expect(pairs.every((p) => p.goRider.id == '1'), isTrue);
    });

    test('a mixed-leg rider is not a one-leg candidate', () {
      // Half of them is coming back, so the berth is not free on the return.
      final mixed = Passenger(
        id: '1',
        tourId: 't1',
        name: 'A',
        phone: '+919824011221',
        isWaitlisted: true,
        requestLines: const [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.roundTrip,
          ),
        ],
      );
      final ret = rider(id: '2', name: 'B', leg: TripType.returnOnly);

      expect(pairCandidates([mixed, ret]), isEmpty);
    });
  });
}
