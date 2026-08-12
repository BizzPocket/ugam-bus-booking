import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_selection.dart';
import 'package:occubusbooking/utils/party_fit.dart';
import 'package:occubusbooking/utils/seat_autopick.dart';

/// The picker fills one LEG BUCKET at a time.
///
/// A party is no longer "4 people on one leg". It is up to three counts —
/// both-ways, going-only, coming-back-only — and each needs its own pass,
/// because availability is leg-scoped: a round-trip berth must be free on BOTH
/// legs, while a one-way berth need only be free on its own.
///
/// *** THE CONSTRAINT THAT SHAPES THIS FILE ***
/// This picker CANNOT use `SeatingEngine.propose`. That needs the full
/// `List<Passenger>` roster, and the customer app deliberately never receives
/// one — there is no anon SELECT on `passengers`, precisely so a stranger
/// cannot read who is sitting where off a public tour.
void main() {
  SeatCell single(String id, int row, {int col = 0, SeatPosition? pos}) =>
      SeatCell(
        row: row,
        col: col,
        seatType: SeatType.singleSofa,
        position: pos ?? SeatPosition.upper,
        seatId: id,
      );

  Bus bus({required String id, required List<SeatCell> cells}) => Bus(
        id: id,
        name: 'Bus $id',
        busType: 'Sleeper',
        pricePerSeat: 1200,
        singleSofaPrice: 1400,
        doubleSofaPrice: 2200,
        layout: BusLayout(
          rows:
              cells.map((c) => c.row).fold<int>(0, (a, c) => a > c ? a : c) + 1,
          cols: SeatGridCols.count,
          grid: cells,
        ),
      );

  /// Six berths across three rows.
  Bus sixSeater(String id) => bus(id: id, cells: [
        for (var r = 0; r < 3; r++) ...[
          single('SU${r + 1}', r),
          single('SL${r + 1}', r, col: 1, pos: SeatPosition.lower),
        ],
      ]);

  List<ChartPick> allPicks(AutoPickResult r) =>
      [for (final s in r.selections) ...s.picks];

  int berthsOf(AutoPickResult r) =>
      allPicks(r).fold<int>(0, (sum, p) => sum + p.berths);

  group('it fills each bucket', () {
    test('a single-bucket party behaves exactly as before', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 4),
      );

      expect(berthsOf(r), 4);
      expect(r.hasShortfall, isFalse);
      expect(allPicks(r).every((p) => p.leg == TripType.roundTrip), isTrue);
    });

    test('a mixed party stamps each pick with its own leg', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, outboundOnly: 2),
      );

      final picks = allPicks(r);
      expect(berthsOf(r), 4);
      expect(picks.where((p) => p.leg == TripType.roundTrip), hasLength(2));
      expect(picks.where((p) => p.leg == TripType.outboundOnly), hasLength(2));
    });

    test('all three buckets at once', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, outboundOnly: 2, returnOnly: 2),
      );

      final picks = allPicks(r);
      expect(berthsOf(r), 6);
      expect(picks.where((p) => p.leg == TripType.returnOnly), hasLength(2));
      expect(r.hasShortfall, isFalse);
    });

    test('no cell is used by two passes', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, outboundOnly: 2, returnOnly: 2),
      );

      final ids = allPicks(r).map((p) => p.seatId).toList();
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason: 'the customer picker never puts two different people on one '
            'berth, even where disjoint legs would technically allow it — one '
            'tile is always one person',
      );
    });

    test('a bucket that cannot be seated reports its own shortfall', () {
      // Two berths only, but the party needs two round-trip AND two return-only.
      final b = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final r = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2, returnOnly: 2),
      );

      expect(
        berthsOf(r),
        2,
        reason: 'the round-trip pass succeeded and its picks must survive — '
            'throwing them away because a LATER leg failed is what the old '
            'all-or-nothing return could not avoid',
      );
      expect(r.shortfall[TripType.returnOnly], 2);
      expect(r.shortfall.containsKey(TripType.roundTrip), isFalse);
      expect(r.hasShortfall, isTrue);
    });

    test('everyone fitting means an empty shortfall', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1, outboundOnly: 1),
      );
      expect(r.shortfall, isEmpty);
      expect(r.hasShortfall, isFalse);
    });

    test('an empty party picks nothing', () {
      final r = autoPick(
        buses: [sixSeater('a')],
        availability: const {},
        intent: const PartyIntent(),
      );
      expect(r.isEmpty, isTrue);
      expect(r.shortfall, isEmpty);
    });

    test('no buses means no picks and no crash', () {
      final r = autoPick(
        buses: const [],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2),
      );
      expect(r.isEmpty, isTrue);
    });

    test('round-trip is packed BEFORE the one-way buckets', () {
      // One lower berth, one upper. Both buckets want one person. The picker
      // prefers lower berths, so whichever bucket runs FIRST takes the lower
      // one — which pins the ordering rule.
      final b = bus(id: 'a', cells: [
        single('SU1', 0),
        single('SL1', 0, col: 1, pos: SeatPosition.lower),
      ]);
      final r = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1, outboundOnly: 1),
      );

      final roundTripPick =
          allPicks(r).firstWhere((p) => p.leg == TripType.roundTrip);
      expect(
        roundTripPick.seatId,
        'SL1',
        reason: 'round-trip needs a berth free on BOTH legs, so it has the '
            'fewest candidates and must claim them first',
      );
    });

    test('the result is deterministic across identical runs', () {
      List<String> run() {
        final r = autoPick(
          buses: [sixSeater('a')],
          availability: const {},
          intent: const PartyIntent(roundTrip: 2, outboundOnly: 1),
        );
        return [for (final p in allPicks(r)) '${p.seatId}:${p.leg.name}'];
      }

      expect(
        run(),
        run(),
        reason: 'availability polls every 20 seconds; a picker that wobbled '
            'between runs would make the chart look broken on every refresh',
      );
    });
  });

  group('it respects the sharing answer', () {
    test('a party refusing to share is never given half a sofa', () {
      final b = bus(id: 'a', cells: [
        SeatCell(
          row: 0,
          col: 4,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'DL1',
        ),
      ]);
      final r = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1, shareOk: false),
      );

      expect(
        allPicks(r).single.berths,
        2,
        reason: 'refusing to share means buying the whole sofa, which is the '
            'only way such a party can use a double at all',
      );
    });
  });
}
