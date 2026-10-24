import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/utils/tour_capacity.dart';

/// Microbenchmark (prints, asserts nothing about time): the money + capacity
/// reads every money/dashboard Obx runs on each rebuild, over a realistic big
/// trip (4 buses x ~19 seat cells, every seat taken, one collection per rider).
Tour bigTour() {
  final buses = <Bus>[];
  final passengers = <Passenger>[];
  for (var b = 0; b < 4; b++) {
    final layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 37);
    buses.add(Bus(
      id: 'b$b',
      name: 'Bus $b',
      busType: 'Sleeper',
      layout: layout,
      busPrice: 60000,
    ));
    var i = 0;
    for (final cell in layout.grid.where((c) => c.hasSeat)) {
      final berths = cell.seatType == SeatType.doubleSofa ? 2 : 1;
      passengers.add(Passenger(
        id: 'p${b}_$i',
        tourId: 't1',
        name: 'Rider $b $i',
        phone: '9$b$i',
        requestLines: [RequestLine(seatType: cell.seatType!, qty: 1)],
        assignedSeats: [
          for (var k = 0; k < berths; k++)
            SeatAssignment(busId: 'b$b', seatId: cell.seatId!),
        ],
      ));
      i++;
    }
  }
  return Tour(
    id: 't1',
    title: 'Big',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1500,
    buses: buses,
    passengers: passengers,
  );
}

double _avgMicros(int n, void Function() f) {
  for (var i = 0; i < 5; i++) {
    f();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    f();
  }
  return sw.elapsedMicroseconds / n;
}

void main() {
  test('BENCH money summaries + capacity on a 4-bus full trip', () async {
    addTearDown(Get.reset);
    Get.put<SyncService>(_EmptySync());
    final tours = _InertTours();
    Get.put<TourController>(tours);
    final tour = bigTour();
    tours.tours.assignAll([tour]);

    final ledger = LedgerMoneySource();
    ledger.debugFetchBusRows = (_) async => throw StateError('ledger down');
    ledger.debugFetchRiderRows = (_) async => throw StateError('ledger down');
    final money = MoneyController(ledgerSource: ledger);
    await money.loadForTour('t1');
    money.collections.assignAll([
      for (final p in tour.passengers)
        Collection(
          tourId: 't1',
          busId: p.assignedSeats.first.busId,
          passengerId: p.id,
          seatId: p.assignedSeats.first.seatId,
          amountDue: 1500,
          amountReceived: 1000,
        ),
    ]);

    // ignore: avoid_print
    print('BENCH riders=${tour.passengers.length} '
        'tourSummary=${_avgMicros(50, money.tourSummary).toStringAsFixed(0)}us '
        'summariesForBuses=${_avgMicros(50, () => money.summariesForBuses(tour.buses.map((b) => b.id))).toStringAsFixed(0)}us '
        'handlerSummaries=${_avgMicros(50, money.handlerSummaries).toStringAsFixed(0)}us '
        'computeTourCapacity=${_avgMicros(20, () => computeTourCapacity(tour)).toStringAsFixed(0)}us '
        'actualCapacity=${_avgMicros(50, () => computeActualCapacity(tour)).toStringAsFixed(0)}us');
    // COLD: every call after an input change (the memo is dropped first) — the
    // cost of the first read after a write, i.e. the un-memoized compute.
    // ignore: avoid_print
    print('BENCH cold '
        'tourSummary=${_avgMicros(50, () {
          money.collections.refresh();
          money.tourSummary();
        }).toStringAsFixed(0)}us '
        'summariesForBuses=${_avgMicros(50, () {
          money.collections.refresh();
          money.summariesForBuses(tour.buses.map((b) => b.id));
        }).toStringAsFixed(0)}us '
        'oneBus=${_avgMicros(50, () {
          money.collections.refresh();
          money.summaryForBus('b0');
        }).toStringAsFixed(0)}us');
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
}
