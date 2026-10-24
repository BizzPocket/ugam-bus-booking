// The money summaries are memoized (perf round 2). Stale money is worse than
// slow money, so this pins that EVERY input change reaches the next read:
// after each mutation the memoized controller must print exactly what a brand
// new controller (empty memo) computes from the same inputs.
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/income_entry.dart';
import 'package:occubusbooking/models/money_summary.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

Tour _tour(String id, {double rent = 20000, int riders = 6}) {
  final buses = <Bus>[];
  final passengers = <Passenger>[];
  for (var b = 0; b < 2; b++) {
    final layout = BusLayout.generate(busType: BusType.seater, totalSeats: 10);
    buses.add(Bus(
      id: '${id}_b$b',
      name: 'Bus $b',
      tourId: id,
      busType: 'Seater',
      layout: layout,
      busPrice: rent,
      pricePerSeat: 1500,
    ));
    final cells = layout.grid.where((c) => c.hasSeat).take(riders).toList();
    for (var i = 0; i < cells.length; i++) {
      passengers.add(Passenger(
        id: '${id}_p${b}_$i',
        tourId: id,
        name: 'Rider $b $i',
        phone: '9$b$i',
        requestLines: [RequestLine(seatType: cells[i].seatType!, qty: 1)],
        assignedSeats: [
          SeatAssignment(busId: '${id}_b$b', seatId: cells[i].seatId!),
        ],
      ));
    }
  }
  return Tour(
    id: id,
    title: id,
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1500,
    buses: buses,
    passengers: passengers,
  );
}

Collection _col(Passenger p, double received) => Collection(
      tourId: p.tourId,
      busId: p.assignedSeats.first.busId,
      passengerId: p.id,
      seatId: p.assignedSeats.first.seatId,
      amountDue: 1500,
      amountReceived: received,
    );

String _busPrint(BusMoneySummary s) => [
      s.busId,
      s.collected,
      s.online,
      s.revenueBilled,
      s.expensesTotal,
      s.handedOver,
      s.toReturnTotal,
      s.toCollectTotal,
      s.income,
      s.busRent,
      s.fuelTotal,
      s.driverTotal,
      s.ownerAdvanceTotal,
      s.otherExpensesTotal,
      s.busMalikPayable,
      s.detachedCash,
    ].join('|');

String _tourPrint(TourMoneySummary s) => [
      s.totalCollected,
      s.totalOnline,
      s.totalRevenueBilled,
      s.totalExpenses,
      s.totalHandedOver,
      s.totalToReturn,
      s.totalToCollect,
      s.totalIncome,
      s.totalBusRent,
      s.totalDetachedCash,
      s.orphanExpenses,
      s.orphanCollected,
      s.orphanIncome,
      s.busesMissingRent,
      s.groundExpensesTotal,
      s.totalOutstandingHandover,
      s.pnl.tripProfit,
      s.pnl.cashSoFar,
    ].join('|');

/// Mutable ledger fixture both controllers read.
List<Map<String, dynamic>>? _rollups; // null = ledger down

Map<String, dynamic> _rollup(String tourId, String busId, int collected) => {
      'tour_id': tourId,
      'bus_id': busId,
      'outstanding_handover_minor': collected * 100,
      'billed_minor': 9000 * 100,
      'income_minor': 0,
      'ground_expenses_minor': 0,
      'rent_minor': 20000 * 100,
      'owner_unpaid_minor': 20000 * 100,
      'collected_minor': collected * 100,
      'handed_over_minor': 0,
      'to_collect_minor': 0,
      'to_return_minor': 0,
    };

LedgerMoneySource _ledger() => LedgerMoneySource()
  ..debugFetchBusRows = ((_) async {
    final r = _rollups;
    if (r == null) throw StateError('ledger down');
    return r;
  })
  ..debugFetchRiderRows = ((_) async => const [])
  ..debugFetchTourRows = (() async => throw StateError('no 076'));

void main() {
  late _InertTours tours;
  late MoneyController money;

  setUp(() async {
    _rollups = null;
    Get.put<SyncService>(_EmptySync());
    tours = _InertTours();
    Get.put<TourController>(tours);
    tours.tours.assignAll([_tour('t1'), _tour('t2', rent: 0)]);
    money = MoneyController(ledgerSource: _ledger());
    await money.loadForTour('t1');
  });
  tearDown(Get.reset);

  /// What a controller with an EMPTY memo computes from [money]'s inputs.
  Future<MoneyController> fresh() async {
    final ref = MoneyController(ledgerSource: _ledger());
    await ref.loadForTour(money.loadedTourId!);
    ref.collections.assignAll(money.collections);
    ref.expenses.assignAll(money.expenses);
    ref.handovers.assignAll(money.handovers);
    ref.incomes.assignAll(money.incomes);
    return ref;
  }

  Future<void> expectMatchesFresh(String reason) async {
    final ref = await fresh();
    final tour = tours.getTour(money.loadedTourId!)!;
    expect(_tourPrint(money.tourSummary()), _tourPrint(ref.tourSummary()),
        reason: '$reason: tourSummary');
    for (final b in tour.buses) {
      expect(_busPrint(money.summaryForBus(b.id)),
          _busPrint(ref.summaryForBus(b.id)),
          reason: '$reason: summaryForBus(${b.id})');
    }
  }

  /// Reads the summaries (filling the memo), applies [change], and proves the
  /// next read moved AND equals a fresh compute.
  Future<void> expectInvalidates(
    String reason,
    void Function() change,
  ) async {
    final before = _tourPrint(money.tourSummary());
    final beforeBus = _busPrint(money.summaryForBus('t1_b0'));
    change();
    final after = _tourPrint(money.tourSummary());
    final afterBus = _busPrint(money.summaryForBus('t1_b0'));
    expect(after != before || afterBus != beforeBus, isTrue,
        reason: '$reason: summary did not move — stale memo');
    await expectMatchesFresh(reason);
  }

  test('unchanged inputs return the memoized object', () {
    final a = money.tourSummary();
    final b = money.tourSummary();
    expect(identical(a, b), isTrue);
    expect(identical(money.summaryForBus('t1_b0'), money.summaryForBus('t1_b0')),
        isTrue);
  });

  group('every money-list change invalidates', () {
    test('collections: add, in-place replace, remove, clear', () async {
      final ps = tours.getTour('t1')!.passengers;
      await expectInvalidates(
          'add', () => money.collections.add(_col(ps[0], 1000)));
      await expectInvalidates(
          'replace same length',
          () => money.collections[0] = _col(ps[0], 1500));
      await expectInvalidates(
          'assignAll same length',
          () => money.collections.assignAll([_col(ps[0], 200)]));
      await expectInvalidates('remove', () => money.collections.removeAt(0));
    });

    test('expenses', () async {
      await expectInvalidates(
          'expense add',
          () => money.expenses.add(Expense(
              tourId: 't1', busId: 't1_b0', label: 'Toll', amount: 700)));
      await expectInvalidates(
          'expense edit',
          () => money.expenses[0] = Expense(
              tourId: 't1', busId: 't1_b0', label: 'Toll', amount: 900));
    });

    test('incomes', () async {
      await expectInvalidates(
          'income add',
          () => money.incomes.add(IncomeEntry(
              tourId: 't1', busId: 't1_b0', label: 'Cabin', amount: 800)));
    });

    test('handovers', () async {
      await expectInvalidates(
          'handover add',
          () => money.handovers.add(BusHandover(
              tourId: 't1',
              busId: 't1_b0',
              expectedAmount: 500,
              handedOverAmount: 300)));
    });
  });

  group('every tour / bus / seat change invalidates', () {
    test('bus re-priced (rent)', () async {
      await expectInvalidates('rent', () {
        final t = tours.getTour('t1')!;
        tours.tours[0] = t.copyWith(buses: [
          t.buses[0].copyWith(busPrice: 35000),
          t.buses[1],
        ]);
      });
    });

    test('rider unseated, and a rider added', () async {
      final ps = tours.getTour('t1')!.passengers;
      money.collections.add(_col(ps[0], 1000));
      await expectInvalidates('unseat', () {
        final t = tours.getTour('t1')!;
        tours.tours[0] = t.copyWith(passengers: [
          for (final p in t.passengers)
            p.id == ps[0].id ? p.copyWith(assignedSeats: const []) : p,
        ]);
      });
      await expectInvalidates('seated rider removed', () {
        final t = tours.getTour('t1')!;
        tours.tours[0] = t.copyWith(
            passengers: t.passengers.take(t.passengers.length - 1).toList());
      });
    });

    test('tour replaced WITHOUT a notify (coalesced write path)', () async {
      await expectInvalidates('silent replace', () {
        final t = tours.getTour('t1')!;
        // TourController._scheduleNotify mutates `tours.value` and refreshes a
        // microtask later — the memo must not wait for that notify.
        // ignore: invalid_use_of_protected_member
        tours.tours.value[0] = t.copyWith(passengers: const []);
      });
    });

    test('TourController re-registered', () async {
      money.tourSummary();
      Get.delete<TourController>(force: true);
      final again = _InertTours();
      Get.put<TourController>(again);
      again.tours.assignAll([_tour('t1', rent: 1)]);
      tours = again;
      await expectMatchesFresh('re-registered');
    });
  });

  test('switching the loaded tour invalidates', () async {
    final t1 = _tourPrint(money.tourSummary());
    await money.loadForTour('t2');
    expect(_tourPrint(money.tourSummary()), isNot(t1));
    await expectMatchesFresh('switch');
  });

  test('ledger rollups arriving, changing and failing all invalidate',
      () async {
    final legacy = _tourPrint(money.tourSummary());
    _rollups = [_rollup('t1', 't1_b0', 4000), _rollup('t1', 't1_b1', 0)];
    await money.refreshForTour('t1');
    final ledgered = _tourPrint(money.tourSummary());
    expect(ledgered, isNot(legacy));
    await expectMatchesFresh('ledger ready');

    _rollups = [_rollup('t1', 't1_b0', 6000), _rollup('t1', 't1_b1', 0)];
    await money.refreshForTour('t1');
    expect(_tourPrint(money.tourSummary()), isNot(ledgered));
    await expectMatchesFresh('ledger changed');

    _rollups = null;
    await money.refreshForTour('t1');
    await expectMatchesFresh('ledger down');
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _EmptySync extends SyncService {
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
          (rows: const <Map<String, dynamic>>[], failed: false, error: null);

  @override
  Future<void> invalidateCache(String cacheKey) async {}
}
