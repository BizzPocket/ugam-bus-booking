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
    ..debugFetchBusRows = ((_) async => rollups)
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

  group('F1 · a cross-bus rider owes each bus its own share', () {
    test('AR splits in proportion to what each bus billed them', () async {
      addTearDown(Get.reset);
      // Billed 1000 on b1 and 3000 on b2 → a 2000 balance splits 500 / 1500.
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Cross', phone: '9',
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1'),
          SeatAssignment(busId: 'b2', seatId: 'ST1'),
        ],
      );
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 3000)],
        passengers: [rider],
        rollups: [_rollup('b1'), _rollup('b2')],
        riderRows: [
          {'tour_id': _tourId, 'passenger_id': 'p1', 'owes_minor': 200000},
        ],
      );

      expect(money.summaryForBus('b1').toCollectTotal, closeTo(500, 0.01));
      expect(money.summaryForBus('b2').toCollectTotal, closeTo(1500, 0.01));
      expect(money.tourSummary().totalToCollect, closeTo(2000, 0.01));
    });

    test('change due to a cross-bus rider splits the same way', () async {
      addTearDown(Get.reset);
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Cross', phone: '9',
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1'),
          SeatAssignment(busId: 'b2', seatId: 'ST1'),
        ],
      );
      final money = await _controller(
        buses: [_bus('b1', price: 1000), _bus('b2', price: 1000)],
        passengers: [rider],
        rollups: [_rollup('b1'), _rollup('b2')],
        riderRows: [
          {'tour_id': _tourId, 'passenger_id': 'p1', 'owes_minor': -100000},
        ],
      );

      expect(money.summaryForBus('b1').toReturnTotal, closeTo(500, 0.01));
      expect(money.summaryForBus('b2').toReturnTotal, closeTo(500, 0.01));
    });

    test('an unpriced rider falls back to an even split across their buses',
        () async {
      addTearDown(Get.reset);
      // Nothing billed anywhere (prices not entered yet) — apportioning by fare
      // is impossible, so the balance is shared evenly rather than dumped on
      // whichever seat happens to sort first.
      final rider = Passenger(
        id: 'p1', tourId: _tourId, name: 'Cross', phone: '9',
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1'),
          SeatAssignment(busId: 'b2', seatId: 'ST1'),
        ],
      );
      final money = await _controller(
        buses: [_bus('b1'), _bus('b2')],
        passengers: [rider],
        rollups: [_rollup('b1'), _rollup('b2')],
        riderRows: [
          {'tour_id': _tourId, 'passenger_id': 'p1', 'owes_minor': 100000},
        ],
      );

      expect(money.summaryForBus('b1').toCollectTotal, closeTo(500, 0.01));
      expect(money.summaryForBus('b2').toCollectTotal, closeTo(500, 0.01));
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
        riderRows: [
          {'tour_id': _tourId, 'passenger_id': 'p1', 'owes_minor': 100000},
        ],
      );

      expect(money.summaryForBus('b1').toCollectTotal, closeTo(1000, 0.01));
      expect(money.summaryForBus('b2').toCollectTotal, 0);
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
