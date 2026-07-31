import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/money_summary.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';

/// Pins [BusMoneySummary.detachedCash] — the figure that explains a bus whose
/// collected cash exceeds the fares it bills.
///
/// Cash is tracked by `bus_id` (it stays with whoever physically took it) while
/// billed revenue is recomputed from who is seated RIGHT NOW, so re-seating a
/// rider after they paid pulls the two apart. Live example that prompted this:
/// bus "hello" showed ₹14,250 collected against ₹8,550 billed with no visible
/// reason. These tests fix the rule that names the gap — and, just as
/// importantly, fix that naming it changes NO net.
Passenger _rider(String id, {List<SeatAssignment> seats = const []}) =>
    Passenger(
      id: id,
      tourId: 't',
      name: id,
      phone: '',
      assignedSeats: seats,
    );

Collection _paid(String passengerId, String busId, double amount) => Collection(
  tourId: 't',
  busId: busId,
  passengerId: passengerId,
  amountDue: amount,
  amountReceived: amount,
);

BusMoneySummary _summary({
  required List<Collection> collections,
  Iterable<Passenger> passengers = const [],
  String busId = 'busA',
}) => BusMoneySummary.compute(
  busId: busId,
  collections: collections,
  expenses: const [],
  handovers: const [],
  passengers: passengers,
);

void main() {
  group('BusMoneySummary.detachedCash', () {
    test('cash from a rider still seated on the bus is NOT detached', () {
      final s = _summary(
        collections: [_paid('p1', 'busA', 1500)],
        passengers: [
          _rider('p1', seats: const [SeatAssignment(busId: 'busA', seatId: 'DL1')]),
        ],
      );
      expect(s.collected, 1500);
      expect(s.detachedCash, 0);
    });

    test('cash from a rider MOVED to another bus is detached', () {
      // Paid while on busA, later re-seated onto busB: the cash stayed with
      // busA's handler, the fare moved to busB.
      final s = _summary(
        collections: [_paid('p1', 'busA', 1500)],
        passengers: [
          _rider('p1', seats: const [SeatAssignment(busId: 'busB', seatId: 'DL1')]),
        ],
      );
      expect(s.detachedCash, 1500);
    });

    test('cash from a rider UNSEATED entirely is detached', () {
      final s = _summary(
        collections: [_paid('p1', 'busA', 1500)],
        passengers: [_rider('p1')],
      );
      expect(s.detachedCash, 1500);
    });

    test('cash from a payer no longer on the tour at all is detached', () {
      final s = _summary(
        collections: [_paid('ghost', 'busA', 900)],
        passengers: [
          _rider('p1', seats: const [SeatAssignment(busId: 'busA', seatId: 'DL1')]),
        ],
      );
      expect(s.detachedCash, 900);
    });

    test('only the detached rows count, not the whole bus', () {
      final s = _summary(
        collections: [
          _paid('p1', 'busA', 1500), // still seated here
          _paid('p2', 'busA', 900), // unseated
          _paid('p3', 'busB', 700), // another bus entirely — out of scope
        ],
        passengers: [
          _rider('p1', seats: const [SeatAssignment(busId: 'busA', seatId: 'DL1')]),
          _rider('p2'),
          _rider('p3', seats: const [SeatAssignment(busId: 'busB', seatId: 'SL1')]),
        ],
      );
      expect(s.collected, 2400);
      expect(s.detachedCash, 900);
    });

    test('a whole double sofa held on busA is not detached by its 2nd berth', () {
      // Two assignment entries on ONE seat id is the whole-sofa shape; the
      // rider is plainly still on the bus.
      final s = _summary(
        collections: [_paid('p1', 'busA', 3800)],
        passengers: [
          _rider(
            'p1',
            seats: const [
              SeatAssignment(busId: 'busA', seatId: 'DL1'),
              SeatAssignment(busId: 'busA', seatId: 'DL1'),
            ],
          ),
        ],
      );
      expect(s.detachedCash, 0);
    });

    test('no roster supplied → 0, never a false alarm', () {
      // With nobody to check against every row would look detached. Staying
      // silent is the only safe read; the handler-side summary calls this way.
      final s = _summary(collections: [_paid('p1', 'busA', 1500)]);
      expect(s.detachedCash, 0);
    });

    test('detached cash is DISPLAY ONLY — it changes no net', () {
      final detached = _summary(
        collections: [_paid('p1', 'busA', 1500)],
        passengers: [_rider('p1')],
      );
      final seated = _summary(
        collections: [_paid('p1', 'busA', 1500)],
        passengers: [
          _rider('p1', seats: const [SeatAssignment(busId: 'busA', seatId: 'DL1')]),
        ],
      );
      expect(detached.detachedCash, 1500);
      expect(seated.detachedCash, 0);
      // Same cash, same costs → identical settlement and P&L figures. The
      // handler really does hold the money either way.
      expect(detached.collected, seated.collected);
      expect(detached.netCollected, seated.netCollected);
      expect(detached.expectedHandover, seated.expectedHandover);
      expect(detached.outstandingHandover, seated.outstandingHandover);
    });

    test('change handed back is netted out before the row is called detached', () {
      // Took 2000, gave 500 back → 1500 of stranded cash, not 2000.
      final s = _summary(
        collections: [
          Collection(
            tourId: 't',
            busId: 'busA',
            passengerId: 'p1',
            amountDue: 1500,
            amountReceived: 2000,
            amountRefunded: 500,
          ),
        ],
        passengers: [_rider('p1')],
      );
      expect(s.detachedCash, 1500);
    });
  });

  group('rollups keep their own scope', () {
    test('HandlerMoneySummary.fromBuses does not sum the per-bus figures', () {
      // A rider shuffled between two buses the SAME handler runs looks detached
      // to each bus, but never left that handler's care — so the caller (which
      // can see the whole fleet) supplies the figure and the roll-up must not
      // invent one from the parts.
      final buses = [
        _summary(
          busId: 'busA',
          collections: [_paid('p1', 'busA', 1500)],
          passengers: [
            _rider('p1', seats: const [SeatAssignment(busId: 'busB', seatId: 'DL1')]),
          ],
        ),
        _summary(busId: 'busB', collections: [_paid('p1', 'busA', 1500)]),
      ];
      expect(buses.first.detachedCash, 1500);
      expect(HandlerMoneySummary.fromBuses('h1', buses).detachedCash, 0);
      expect(
        HandlerMoneySummary.fromBuses('h1', buses, detachedCash: 250).detachedCash,
        250,
      );
    });

    test('TourMoneySummary defaults to 0 and takes the caller override', () {
      final rows = [_paid('p1', 'busA', 1500)];
      expect(
        TourMoneySummary.compute(
          collections: rows,
          expenses: const [],
          handovers: const [],
        ).totalDetachedCash,
        0,
      );
      expect(
        TourMoneySummary.compute(
          collections: rows,
          expenses: const [],
          handovers: const [],
          detachedCashTotal: 1500,
        ).totalDetachedCash,
        1500,
      );
    });
  });
}
