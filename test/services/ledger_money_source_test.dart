import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';

void main() {
  test('fetchBusRollups maps view rows via debug hook', () async {
    final src = LedgerMoneySource();
    src.debugFetchBusRows = (_) async => [
          {
            'tour_id': 't1',
            'bus_id': 'b1',
            'outstanding_handover_minor': 10000,
            'billed_minor': 20000,
            'income_minor': 0,
            'ground_expenses_minor': 0,
            'rent_minor': 0,
            'owner_unpaid_minor': 0,
            'collected_minor': 10000,
            'handed_over_minor': 0,
            'to_collect_minor': 0,
            'to_return_minor': 0,
          },
        ];

    final list = await src.fetchBusRollups('t1');
    expect(list, hasLength(1));
    expect(list.single.busId, 'b1');
    expect(list.single.collected, 100);
    expect(list.single.outstandingHandover, 100);
  });

  test('fetchRiderOwesRupees maps paise owes', () async {
    final src = LedgerMoneySource();
    src.debugFetchRiderRows = (_) async => [
          {'tour_id': 't1', 'passenger_id': 'p1', 'owes_minor': 50000},
          {'tour_id': 't1', 'passenger_id': 'p2', 'owes_minor': -2000},
        ];

    final map = await src.fetchRiderOwesRupees('t1');
    expect(map['p1'], 500);
    expect(map['p2'], -20);
  });
}
