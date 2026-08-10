// Finding A1 from the 2026-08-09 money audit: the cross-tour Profit & Loss
// report is fed ONLY by `finance_bus_summary`. When that view is deployed but
// unpopulated — the write-through triggers (062) never applied, or the backfill
// (058) never run — every column reads 0 and the report renders a confident
// "from 1 tour" badge over ₹0, with `loadFailed` false because nothing threw.
//
// A tour that has buses ALWAYS has something to post (bus rent is a real cost
// carried on `buses.bus_price`), so "tours with buses exist but the ledger
// returned nothing at all" is provably a broken ledger, not an empty business.

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/finance_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Tour _tour({String id = 't1', List<Bus> buses = const []}) => Tour(
      id: id,
      title: 'Trip',
      fromCity: 'Surat',
      toCity: 'Goa',
      departureDate: DateTime.now(),
      returnDate: DateTime.now(),
      pricePerSeat: 1000,
      status: TourStatus.collecting,
      buses: buses,
    );

Future<FinanceController> _load({
  required List<Tour> tours,
  required List<Map<String, dynamic>> rollups,
}) async {
  final tourCtrl = _InertTours();
  Get.put<TourController>(tourCtrl);
  tourCtrl.tours.assignAll(tours);
  final ledger = LedgerMoneySource()..debugFetchAllBusRows = (() async => rollups);
  final finance = FinanceController(ledgerSource: ledger);
  await finance.load();
  return finance;
}

void main() {
  tearDown(Get.reset);

  test('a tour with buses but no ledger rows at all flags the ledger as empty',
      () async {
    final finance = await _load(
      tours: [
        _tour(buses: [Bus(id: 'b1', name: 'Bus 1', busPrice: 30000)]),
      ],
      rollups: const [],
    );

    expect(finance.loadFailed.value, isFalse,
        reason: 'nothing threw — this is not a fetch failure');
    expect(finance.ledgerEmpty, isTrue,
        reason: 'rent alone should have posted; a silent ₹0 must be surfaced');
  });

  test('a populated ledger does not flag', () async {
    final finance = await _load(
      tours: [
        _tour(buses: [Bus(id: 'b1', name: 'Bus 1', busPrice: 30000)]),
      ],
      rollups: [
        {
          'tour_id': 't1',
          'bus_id': 'b1',
          'rent_minor': 3000000,
          'collected_minor': 0,
          'billed_minor': 0,
          'income_minor': 0,
          'ground_expenses_minor': 0,
          'owner_unpaid_minor': 3000000,
          'outstanding_handover_minor': 0,
          'handed_over_minor': 0,
          'to_collect_minor': 0,
          'to_return_minor': 0,
        },
      ],
    );

    expect(finance.ledgerEmpty, isFalse);
  });

  test('an agent with no buses anywhere is genuinely empty, not broken',
      () async {
    final finance = await _load(tours: [_tour()], rollups: const []);
    expect(finance.ledgerEmpty, isFalse);
  });

  test('an agent with no tours at all is genuinely empty, not broken', () async {
    final finance = await _load(tours: const [], rollups: const []);
    expect(finance.ledgerEmpty, isFalse);
  });

  test('a failed load is not reported as an empty ledger', () async {
    final tourCtrl = _InertTours();
    Get.put<TourController>(tourCtrl);
    tourCtrl.tours.assignAll([
      _tour(buses: [Bus(id: 'b1', name: 'Bus 1', busPrice: 30000)]),
    ]);
    final ledger = LedgerMoneySource()
      ..debugFetchAllBusRows = (() async => throw StateError('offline'));
    final finance = FinanceController(ledgerSource: ledger);
    await finance.load();

    expect(finance.loadFailed.value, isTrue);
    expect(finance.ledgerEmpty, isFalse,
        reason: 'a read failure already has its own retry surface');
  });
}
