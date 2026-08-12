import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// A trip whose SECOND bus has no owner rent recorded (`busPrice` 0) — the
/// shape that made a pre-departure trip read as a confident profit: bus 2's
/// fares land in the billed net with no cost behind them.
Tour _tourWithOneRentMissing() => Tour(
      id: 't1',
      title: 'Shravan',
      fromCity: 'Surat',
      toCity: 'Bheda',
      departureDate: DateTime(2026, 8, 13),
      pricePerSeat: 1500,
      status: TourStatus.assigning,
      buses: [
        Bus(id: 'b1', name: 'shivkamal-1', busPrice: 50000),
        Bus(id: 'b2', name: 'shivkamal-2'), // rent never entered
      ],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'A',
          phone: '999',
          assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'L1')],
        ),
        Passenger(
          id: 'p2',
          tourId: 't1',
          name: 'B',
          phone: '888',
          assignedSeats: const [SeatAssignment(busId: 'b2', seatId: 'L1')],
        ),
      ],
    );

Map<String, dynamic> _rollup(String busId, int rentMinor) => {
      'tour_id': 't1',
      'bus_id': busId,
      'outstanding_handover_minor': 0,
      'billed_minor': 150000,
      'income_minor': 0,
      'ground_expenses_minor': 0,
      'rent_minor': rentMinor,
      'owner_unpaid_minor': rentMinor,
      'collected_minor': 0,
      'handed_over_minor': 0,
      'to_collect_minor': 150000,
      'to_return_minor': 0,
    };

void main() {
  group('tourSummary flags buses with no rent recorded', () {
    test('via the ledger roll-up path', () async {
      addTearDown(Get.reset);
      Get.put<SyncService>(_EmptySync());
      final tours = _InertTours();
      Get.put<TourController>(tours);
      tours.tours.assignAll([_tourWithOneRentMissing()]);

      final ledger = LedgerMoneySource();
      ledger.debugFetchBusRows = (_) async => [
            _rollup('b1', 5000000),
            _rollup('b2', 0),
          ];
      ledger.debugFetchRiderRows = (_) async => [
            {'tour_id': 't1', 'passenger_id': 'p1', 'owes_minor': 150000},
            {'tour_id': 't1', 'passenger_id': 'p2', 'owes_minor': 150000},
          ];

      final money = MoneyController(ledgerSource: ledger);
      await money.loadForTour('t1');

      final summary = money.tourSummary();
      expect(summary.busesMissingRent, 1);
      expect(summary.hasUnrecordedRent, isTrue);
    });

    // The ledger views can fail to read; the controller then falls back to
    // aggregating the raw rows. The warning must survive that fallback,
    // otherwise a transient ledger outage silently restores the overstated
    // green headline.
    test('via the raw-row fallback path when the ledger read fails', () async {
      addTearDown(Get.reset);
      Get.put<SyncService>(_EmptySync());
      final tours = _InertTours();
      Get.put<TourController>(tours);
      tours.tours.assignAll([_tourWithOneRentMissing()]);

      final ledger = LedgerMoneySource();
      ledger.debugFetchBusRows = (_) async => throw StateError('ledger down');
      ledger.debugFetchRiderRows = (_) async => throw StateError('ledger down');

      final money = MoneyController(ledgerSource: ledger);
      await money.loadForTour('t1');

      final summary = money.tourSummary();
      expect(summary.busesMissingRent, 1);
      expect(summary.hasUnrecordedRent, isTrue);
    });

    test('stays silent once every bus has a rent', () async {
      addTearDown(Get.reset);
      Get.put<SyncService>(_EmptySync());
      final tours = _InertTours();
      Get.put<TourController>(tours);
      final tour = _tourWithOneRentMissing();
      tours.tours.assignAll([
        tour.copyWith(
          buses: [
            tour.buses[0],
            tour.buses[1].copyWith(busPrice: 48000),
          ],
        ),
      ]);

      final ledger = LedgerMoneySource();
      ledger.debugFetchBusRows = (_) async => [
            _rollup('b1', 5000000),
            _rollup('b2', 4800000),
          ];
      ledger.debugFetchRiderRows = (_) async => [];

      final money = MoneyController(ledgerSource: ledger);
      await money.loadForTour('t1');

      expect(money.tourSummary().hasUnrecordedRent, isFalse);
    });
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
