// Regression tests for the three MoneyController ledger-path gaps found in the
// 2026-08-09 money audit (docs/2026-08-09-money-ledger-audit.md):
//
//   E2 · a reachable-but-empty ledger zeroed real money sitting in the legacy
//        tables, which is what rendered the ₹0 Profit & Loss screen.
//   E1 · money on a bus no longer listed by the tour fell out of the trip total
//        entirely, and `hasOrphanMoney` could never become true.
//   F1 · a rider seated on two buses had their WHOLE ledger AR attributed to
//        whichever bus happened to hold their first seat.

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

const _tourId = 't1';

Bus _bus(String id, {double price = 0, double rent = 0}) => Bus(
      id: id,
      name: id,
      tourId: _tourId,
      pricePerSeat: price,
      busPrice: rent,
      layout: BusLayout.generate(busType: BusType.seater, totalSeats: 4),
    );

Map<String, dynamic> _rollup(
  String busId, {
  int billed = 0,
  int collected = 0,
  int ground = 0,
  int rent = 0,
  int income = 0,
}) =>
    {
      'tour_id': _tourId,
      'bus_id': busId,
      'outstanding_handover_minor': collected + income - ground,
      'billed_minor': billed,
      'income_minor': income,
      'ground_expenses_minor': ground,
      'rent_minor': rent,
      'owner_unpaid_minor': rent,
      'collected_minor': collected,
      'handed_over_minor': 0,
      'to_collect_minor': 0,
      'to_return_minor': 0,
    };

Future<MoneyController> _controller({
  required List<Bus> buses,
  List<Passenger> passengers = const [],
  Map<String, List<Map<String, dynamic>>> legacy = const {},
  List<Map<String, dynamic>> rollups = const [],
  List<Map<String, dynamic>> riderRows = const [],
  bool ledgerFails = false,
}) async {
  Get.put<SyncService>(_StubSync(legacy));
  final tours = _InertTours();
  Get.put<TourController>(tours);
  tours.tours.assignAll([
    Tour(
      id: _tourId,
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 8, 21),
      pricePerSeat: 0,
      status: TourStatus.collecting,
      buses: buses,
      passengers: passengers,
    ),
  ]);
  final ledger = LedgerMoneySource()
    ..debugFetchBusRows = ((_) async {
      // A THROW is "the ledger is unreachable" (which drops the controller onto
      // its legacy recompute); an empty list is "the ledger answered, and it has
      // nothing" — a different path entirely. See _loadLedgerForTour.
      if (ledgerFails) throw StateError('ledger unreachable');
      return rollups;
    })
    ..debugFetchRiderRows = ((_) async => riderRows);
  final money = MoneyController(ledgerSource: ledger);
  await money.loadForTour(_tourId);
  return money;
}

void main() {
  group('E2 · an empty ledger must not erase money the legacy tables hold', () {
    test('summaryForBus falls back to the legacy rows for an unledgered bus',
        () async {
      addTearDown(Get.reset);
      final money = await _controller(
        buses: [_bus('b1', price: 1000, rent: 30000)],
        legacy: {
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountDue: 1600, amountReceived: 1600,
            ).toMap(),
            Collection(
              id: 'c2', tourId: _tourId, busId: 'b1', passengerId: 'p2',
              seatId: 'ST2', amountDue: 1600, amountReceived: 1000,
            ).toMap(),
          ],
          'expenses': [
            {
              'id': 'e1', 'tour_id': _tourId, 'bus_id': 'b1',
              'category': 'fuel', 'label': 'Diesel', 'amount': 4000,
            },
          ],
        },
        // The view answers, and answers with nothing — 062 was never applied,
        // or 058 was never run. Not an error, so loadFailed stays false.
        rollups: const [],
      );

      final s = money.summaryForBus('b1');
      expect(money.loadFailed.value, isFalse);
      expect(s.collected, 2600, reason: 'real cash must survive an empty ledger');
      expect(s.expensesTotal, 34000, reason: 'ground 4000 + rent 30000');
    });

    test('a ledgered bus still reads from the ledger', () async {
      addTearDown(Get.reset);
      final money = await _controller(
        buses: [_bus('b1', rent: 500)],
        legacy: {
          // Deliberately different from the ledger: the ledger wins.
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountReceived: 99999,
            ).toMap(),
          ],
        },
        rollups: [_rollup('b1', collected: 200000, rent: 50000)],
      );

      expect(money.summaryForBus('b1').collected, 2000);
    });
  });

  group('E1 · money on a bus the tour no longer lists', () {
    test('stays inside the trip total and is reported as orphan', () async {
      addTearDown(Get.reset);
      final money = await _controller(
        buses: [_bus('b1')],
        rollups: [
          _rollup('b1', collected: 200000),
          _rollup('gone', collected: 500000, ground: 120000),
        ],
      );

      final t = money.tourSummary();
      expect(t.totalCollected, 7000, reason: '2000 on b1 + 5000 stranded');
      expect(t.totalExpenses, 1200);
      expect(t.orphanCollected, 5000);
      expect(t.orphanExpenses, 1200);
      expect(t.hasOrphanMoney, isTrue);
    });

    test('a tour whose buses all still exist reports no orphan money', () async {
      addTearDown(Get.reset);
      final money = await _controller(
        buses: [_bus('b1')],
        rollups: [_rollup('b1', collected: 200000)],
      );

      final t = money.tourSummary();
      expect(t.totalCollected, 2000);
      expect(t.hasOrphanMoney, isFalse);
    });
  });

  // F1's original fix apportioned each rider's TOUR-WIDE `finance_rider_balance`
  // across their buses by billed share, because `ar.rider` lines carry no
  // bus_id. That answered the right question with the wrong instrument: a
  // fraction of one rider's net balance landed on a bus whose own seat was
  // square, so the collect screen's header could show money to hand back with
  // nobody in the To-return filter to hand it to. Per-bus AR is now priced from
  // the seats a rider actually holds there, against the row resolved for that
  // seat — the same walk the roster renders.
  group('F1 · a cross-bus rider owes each bus what THAT bus billed them', () {
    Passenger crossBusRider() => Passenger(
          id: 'p1', tourId: _tourId, name: 'Cross', phone: '9',
          assignedSeats: const [
            SeatAssignment(busId: 'b1', seatId: 'ST1'),
            SeatAssignment(busId: 'b2', seatId: 'ST1'),
          ],
        );

    test('each bus asks for its own fare, not a share of one balance', () async {
      addTearDown(Get.reset);
      // Nothing collected anywhere: b1 is owed its ₹1000, b2 its ₹3000. The old
      // apportioning turned the same rider into 500 / 1500 — two figures that
      // matched neither bus's actual price.
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 3000)],
        passengers: [crossBusRider()],
        rollups: [_rollup('b1'), _rollup('b2')],
      );

      expect(money.summaryForBus('b1').toCollectTotal, closeTo(1000, 0.01));
      expect(money.summaryForBus('b2').toCollectTotal, closeTo(3000, 0.01));
      expect(money.tourSummary().totalToCollect, closeTo(4000, 0.01));
    });

    test('paying one bus in full clears that bus and only that bus', () async {
      addTearDown(Get.reset);
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 3000)],
        passengers: [crossBusRider()],
        legacy: {
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountDue: 1000, amountReceived: 1000,
            ).toMap(),
          ],
        },
        rollups: [_rollup('b1'), _rollup('b2')],
      );

      expect(money.summaryForBus('b1').toCollectTotal, 0);
      expect(money.summaryForBus('b2').toCollectTotal, closeTo(3000, 0.01));
    });

    test('change stays on the bus that was overpaid', () async {
      addTearDown(Get.reset);
      // ₹1500 handed over for a ₹1000 seat on b1. That ₹500 is b1's to give
      // back — it must not be smeared across b2, which was paid nothing.
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 3000)],
        passengers: [crossBusRider()],
        legacy: {
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountDue: 1000, amountReceived: 1500,
            ).toMap(),
          ],
        },
        rollups: [_rollup('b1'), _rollup('b2')],
      );

      expect(money.summaryForBus('b1').toReturnTotal, closeTo(500, 0.01));
      expect(money.summaryForBus('b1').toCollectTotal, 0);
      expect(money.summaryForBus('b2').toReturnTotal, 0);
      expect(money.summaryForBus('b2').toCollectTotal, closeTo(3000, 0.01));
    });

    test('a single-bus rider is unaffected', () async {
      addTearDown(Get.reset);
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Solo', phone: '9',
        assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'ST1')],
      );
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 1000)],
        passengers: [rider],
        rollups: [_rollup('b1'), _rollup('b2')],
      );

      expect(money.summaryForBus('b1').toCollectTotal, closeTo(1000, 0.01));
      expect(money.summaryForBus('b2').toCollectTotal, 0);
    });

    test('the trip total matches the bus rows on the legacy path too', () async {
      addTearDown(Get.reset);
      // Ledger unreachable → every figure is recomputed from the legacy tables.
      // This rider overpaid: the seat now costs ₹1000 (the bus was re-priced
      // after they paid, so the row's own amount_due still says ₹1500) and they
      // handed over ₹1500, so ₹500 goes back.
      //
      // The bus row priced that live already; the TRIP total summed the rows'
      // stored amount_due for to-return and so read ₹0 — a total that
      // contradicted the single line printed underneath it.
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Overpaid', phone: '9',
        assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'ST1')],
      );
      final money = await _controller(
        buses: [_bus('b1', price: 1000)],
        passengers: [rider],
        legacy: {
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountDue: 1500, amountReceived: 1500,
            ).toMap(),
          ],
        },
        ledgerFails: true,
      );

      final bus = money.summaryForBus('b1');
      final tour = money.tourSummary();
      expect(bus.toReturnTotal, closeTo(500, 0.01));
      expect(tour.totalToReturn, closeTo(bus.toReturnTotal, 0.01));
      expect(tour.totalToCollect, closeTo(bus.toCollectTotal, 0.01));
    });

    test('a stale ledger rider balance can no longer invent a figure', () async {
      addTearDown(Get.reset);
      // THE ₹449 REGRESSION. The rider is square: one ₹1000 seat on b1, paid in
      // full. `finance_rider_balance` disagrees — it still carries the fare from
      // before this bus was re-priced, which nothing re-posted (migration 092).
      //
      // That view is no longer an input to per-bus AR, so the disagreement
      // cannot surface as a phantom "to return" the roster has no row for.
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Square', phone: '9',
        assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'ST1')],
      );
      final money = await _controller(
        buses: [_bus('b1', price: 1000)],
        passengers: [rider],
        legacy: {
          'collections': [
            Collection(
              id: 'c1', tourId: _tourId, busId: 'b1', passengerId: 'p1',
              seatId: 'ST1', amountDue: 1000, amountReceived: 1000,
            ).toMap(),
          ],
        },
        rollups: [_rollup('b1', collected: 100000)],
        riderRows: [
          {'tour_id': _tourId, 'passenger_id': 'p1', 'owes_minor': -44900},
        ],
      );

      expect(money.summaryForBus('b1').toReturnTotal, 0);
      expect(money.summaryForBus('b1').toCollectTotal, 0);
      expect(money.tourSummary().totalToReturn, 0);
      expect(money.tourSummary().totalToCollect, 0);
    });
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _StubSync extends SyncService {
  _StubSync(this.rows);

  final Map<String, List<Map<String, dynamic>>> rows;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
      smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async =>
          (
            rows: rows[table] ?? const <Map<String, dynamic>>[],
            failed: false,
            error: null,
          );

  @override
  Future<void> invalidateCache(String cacheKey) async {}
}
