import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';

/// Online money posts with bus_id NULL on both legs, and finance_bus_summary
/// filters `where l.bus_id is not null` — so a per-bus rollup can never see it.
/// A fully prepaid trip therefore reported zero revenue against real rent and
/// printed a loss. These pin the separate read path that fixes it.
void main() {
  test('online minor is converted to rupees and keyed by tour', () async {
    final src = LedgerMoneySource()
      ..debugFetchTourRows = () async => [
            {'tour_id': 't1', 'online_minor': 250000},
            {'tour_id': 't2', 'online_minor': 0},
          ];

    final out = await src.fetchOnlineByTourRupees();

    expect(out['t1'], 2500.0);
    expect(out['t2'], 0.0);
  });

  test('rows with no tour id are skipped, not crashed on', () async {
    final src = LedgerMoneySource()
      ..debugFetchTourRows = () async => [
            {'tour_id': null, 'online_minor': 999},
            {'tour_id': '', 'online_minor': 999},
            {'tour_id': 't1', 'online_minor': 100},
          ];

    final out = await src.fetchOnlineByTourRupees();

    expect(out.keys, ['t1']);
  });

  test('a non-int minor value is coerced rather than dropped', () async {
    // PostgREST can hand back a bigint as a num or a string depending on the
    // driver; losing the figure silently would understate revenue again.
    final src = LedgerMoneySource()
      ..debugFetchTourRows = () async => [
            {'tour_id': 't1', 'online_minor': 150000.0},
            {'tour_id': 't2', 'online_minor': '75000'},
          ];

    final out = await src.fetchOnlineByTourRupees();

    expect(out['t1'], 1500.0);
    expect(out['t2'], 750.0);
  });

  test('a missing view fails soft — empty map, no exception', () async {
    // 076 may not be applied yet. A slightly low P&L beats a Finance screen
    // that will not load at all.
    final src = LedgerMoneySource()
      ..debugFetchTourRows =
          () async => throw StateError('relation does not exist');

    expect(await src.fetchOnlineByTourRupees(), isEmpty);
  });
}
