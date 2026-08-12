import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/party_fit.dart';
import 'package:occubusbooking/utils/seat_autopick.dart';

/// The chart must OPEN with seats already chosen.
///
/// A customer booking a pilgrimage for four relatives should not have to solve
/// a 36-cell puzzle. They answer three questions and the app proposes; the map
/// becomes something to adjust, not something to decode.
///
/// *** THE CONSTRAINT THAT SHAPES THIS FILE ***
/// This picker CANNOT use `SeatingEngine.propose`. That needs the full
/// `List<Passenger>` roster, and the customer app deliberately never receives
/// one — there is no anon SELECT on `passengers`, precisely so a stranger
/// cannot read who is sitting where off a public tour. So the picker sees only
/// the layout, the ANONYMISED availability, the leg, and the party's own
/// answers. Everything below is expressed in those terms.
void main() {
  SeatCell single(String id, int row, {int col = 0, SeatPosition? pos}) =>
      SeatCell(
        row: row,
        col: col,
        seatType: SeatType.singleSofa,
        position: pos ?? SeatPosition.upper,
        seatId: id,
      );

  SeatCell dbl(String id, int row, {int col = 4, SeatPosition? pos}) => SeatCell(
        row: row,
        col: col,
        seatType: SeatType.doubleSofa,
        position: pos ?? SeatPosition.lower,
        seatId: id,
      );

  Bus bus({
    required String id,
    required List<SeatCell> cells,
    double singlePrice = 1400,
    double doublePrice = 2200,
  }) =>
      Bus(
        id: id,
        name: 'Bus $id',
        busType: 'Sleeper',
        pricePerSeat: 1200,
        singleSofaPrice: singlePrice,
        doubleSofaPrice: doublePrice,
        layout: BusLayout(
          rows: cells.map((c) => c.row).fold<int>(0, (a, c) => a > c ? a : c) + 1,
          cols: SeatGridCols.count,
          grid: cells,
        ),
      );

  /// Total berths the pick covers.
  int berthsOf(AutoPickResult r) => r.selections.fold<int>(
        0,
        (sum, s) => sum + s.picks.fold<int>(0, (n, p) => n + p.berths),
      );

  Set<String> seatIdsOf(AutoPickResult r) => {
        for (final s in r.selections)
          for (final p in s.picks) p.seatId,
      };

  group('it seats the party', () {
    test('a solo traveller gets one berth', () {
      final b = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1),
      );
      expect(berthsOf(picks), 1);
      expect(picks.selections, hasLength(1));
      expect(picks.selections.single.bus.id, 'a');
    });

    test('a party of four is seated on one bus', () {
      final b = bus(id: 'a', cells: [
        for (var r = 0; r < 3; r++) ...[
          single('SU${r + 1}', r),
          single('SL${r + 1}', r, col: 1),
        ],
      ]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 4),
      );
      expect(berthsOf(picks), 4);
      expect(picks.selections, hasLength(1), reason: 'one bus was enough');
    });

    test('a party that does not fit keeps what it got, and is told the gap', () {
      final b = bus(id: 'a', cells: [single('SU1', 0)]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 4),
      );

      // *** THIS CONTRACT CHANGED WITH PER-SEAT LEGS ***
      // The picker used to be all-or-nothing: a party of four facing one free
      // berth got NOTHING, on the reasoning that silently under-booking them
      // was worse than saying there is no room. That reasoning still holds —
      // but the shortfall now carries it, and throwing the picks away cannot
      // survive mixed legs: a party whose outbound leg is seated and whose
      // return leg is not must keep the outbound seats while being told,
      // precisely, which leg is short.
      expect(berthsOf(picks), 1);
      expect(picks.shortfall[TripType.roundTrip], 3);
      expect(picks.hasShortfall, isTrue);
    });

    test('exactly enough room is still enough', () {
      final b = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2),
      );
      expect(berthsOf(picks), 2);
      expect(seatIdsOf(picks), {'SU1', 'SL1'});
    });

    test('already-taken berths are never proposed', () {
      final b = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final picks = autoPick(
        buses: [b],
        availability: availabilityByKey(const [
          SeatAvailability(busId: 'a', seatId: 'SU1', usedGo: 1, usedRet: 1),
        ]),
        intent: const PartyIntent(roundTrip: 1),
      );
      expect(seatIdsOf(picks), {'SL1'});
    });

    test('a reserved seat is never proposed', () {
      final b = bus(id: 'a', cells: [
        SeatCell(
          row: 0,
          col: 0,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
          seatId: 'SU1',
          reserved: true,
        ),
        single('SL1', 0, col: 1),
      ]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1),
      );
      expect(seatIdsOf(picks), {'SL1'});
    });
  });

  group('it prefers lower berths', () {
    test('a solo traveller is put on a lower berth when one is free', () {
      final b = bus(id: 'a', cells: [
        single('SU1', 0, pos: SeatPosition.upper),
        single('SL1', 0, col: 1, pos: SeatPosition.lower),
      ]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1),
      );
      expect(
        seatIdsOf(picks),
        {'SL1'},
        reason: 'lower berths matter most to the elders in these groups, and '
            'the gate deliberately does not ask about them',
      );
    });
  });

  group('it keeps the party together', () {
    test('adjacency beats price', () {
      // Row 0 holds a PAIR at full price. Rows 3 and 4 hold one cheap berth
      // each. Buying on price alone would take the two cheap ones and split
      // the couple across rows; sitting together must win instead.
      final layout = BusLayout(
        rows: 5,
        cols: SeatGridCols.count,
        grid: [
          single('SU1', 0),
          single('SL1', 0, col: 1),
          single('SU4', 3),
          single('SU5', 4),
        ],
      );
      final cheapRear = Bus(
        id: 'a',
        name: 'Bus a',
        busType: 'Sleeper',
        pricePerSeat: 1200,
        singleSofaPrice: 1400,
        doubleSofaPrice: 2200,
        rearRows: 2, // rows 3 and 4 are the cheap rear zone
        rearPrice: 200,
        layout: layout,
      );

      final picks = autoPick(
        buses: [cheapRear],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2),
      );

      expect(
        seatIdsOf(picks),
        {'SU1', 'SL1'},
        reason: 'the cheap pair (SU4 + SU5 at ₹200) sits across two rows. '
            'Splitting a couple to save ₹2,400 is the wrong trade for a '
            'family booking a pilgrimage together.',
      );
      final rows = {
        for (final s in picks.selections)
          for (final p in s.picks) p.cell.row,
      };
      expect(rows, hasLength(1));
    });
  });

  group('sharing a sofa with a stranger', () {
    test('a half-sold double is offered when sharing is fine', () {
      final b = bus(id: 'a', cells: [dbl('DU1', 0)]);
      final picks = autoPick(
        buses: [b],
        availability: availabilityByKey(const [
          SeatAvailability(busId: 'a', seatId: 'DU1', usedGo: 1, usedRet: 1),
        ]),
        intent: const PartyIntent(roundTrip: 1, shareOk: true),
      );
      expect(seatIdsOf(picks), {'DU1'});
      expect(berthsOf(picks), 1, reason: 'half the sofa');
    });

    test('a half-sold double is REFUSED when sharing is not fine', () {
      final b = bus(id: 'a', cells: [dbl('DU1', 0)]);
      final picks = autoPick(
        buses: [b],
        availability: availabilityByKey(const [
          SeatAvailability(busId: 'a', seatId: 'DU1', usedGo: 1, usedRet: 1),
        ]),
        intent: const PartyIntent(roundTrip: 1, shareOk: false),
      );
      expect(
        picks.isEmpty,
        isTrue,
        reason: 'the only berth left would put a stranger on their sofa, and '
            'they said no — proposing it anyway is the bug this replaces',
      );
    });

    test('a solo traveller who will not share takes the WHOLE sofa', () {
      final b = bus(id: 'a', cells: [dbl('DU1', 0)]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 1, shareOk: false),
      );
      expect(seatIdsOf(picks), {'DU1'});
      expect(
        berthsOf(picks),
        2,
        reason: 'privacy costs both berths — that is the real-world trade, and '
            'the summary bar has to say so',
      );
    });

    test('a pair takes a whole sofa rather than two scattered singles', () {
      final b = bus(id: 'a', cells: [
        dbl('DU1', 0),
        single('SU3', 2),
        single('SL3', 2, col: 1),
      ]);
      final picks = autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2),
      );
      expect(
        seatIdsOf(picks),
        {'DU1'},
        reason: 'a couple wants the sofa, not two singles across the aisle',
      );
      expect(berthsOf(picks), 2);
    });
  });

  group('legs', () {
    test('a berth sold GO-only is still free for a RETURN-only party', () {
      final b = bus(id: 'a', cells: [single('SU1', 0)]);
      final avail = availabilityByKey(const [
        SeatAvailability(busId: 'a', seatId: 'SU1', usedGo: 1, usedRet: 0),
      ]);

      expect(
        autoPick(
          buses: [b],
          availability: avail,
          intent: const PartyIntent(outboundOnly: 1),
        ).isEmpty,
        isTrue,
      );
      expect(
        seatIdsOf(autoPick(
          buses: [b],
          availability: avail,
          intent: const PartyIntent(returnOnly: 1),
        )),
        {'SU1'},
        reason: 'the return leg of that berth is untouched',
      );
    });
  });

  group('splitting across buses', () {
    test('one bus is preferred even when a second has room', () {
      final roomy = bus(id: 'a', cells: [
        single('SU1', 0),
        single('SL1', 0, col: 1),
      ]);
      final other = bus(id: 'b', cells: [single('SU1', 0)]);

      final picks = autoPick(
        buses: [roomy, other],
        availability: const {},
        intent: const PartyIntent(roundTrip: 2),
      );
      expect(picks.selections, hasLength(1), reason: 'bus a alone seats them');
      expect(picks.selections.single.bus.id, 'a');
    });

    test('the party splits only when no single bus can hold it', () {
      final a = bus(id: 'a', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);
      final b = bus(id: 'b', cells: [single('SU1', 0), single('SL1', 0, col: 1)]);

      final picks = autoPick(
        buses: [a, b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 4),
      );
      expect(berthsOf(picks), 4);
      expect(
        picks.selections.map((s) => s.bus.id).toSet(),
        {'a', 'b'},
        reason: 'four people, two berths per bus — splitting is the only way, '
            'and the summary bar must then say which buses',
      );
    });

    test('no combination of buses is enough — every free berth is still taken',
        () {
      final a = bus(id: 'a', cells: [single('SU1', 0)]);
      final b = bus(id: 'b', cells: [single('SU1', 0)]);
      final picks = autoPick(
        buses: [a, b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 5),
      );

      expect(berthsOf(picks), 2, reason: 'both buses gave what they had');
      expect(picks.selections.map((s) => s.bus.id).toSet(), {'a', 'b'});
      expect(
        picks.shortfall[TripType.roundTrip],
        3,
        reason: 'the gap is reported rather than the picks being discarded',
      );
    });
  });

  group('determinism', () {
    test('the same inputs always give the same seats', () {
      final b = bus(id: 'a', cells: [
        for (var r = 0; r < 4; r++) ...[
          single('SU${r + 1}', r),
          single('SL${r + 1}', r, col: 1),
          dbl('DU${r + 1}', r),
        ],
      ]);
      final first = seatIdsOf(autoPick(
        buses: [b],
        availability: const {},
        intent: const PartyIntent(roundTrip: 3),
      ));
      for (var i = 0; i < 5; i++) {
        expect(
          seatIdsOf(autoPick(
            buses: [b],
            availability: const {},
            intent: const PartyIntent(roundTrip: 3),
          )),
          first,
          reason: 'a picker that wobbles between runs makes the chart feel '
              'broken when a poll refreshes it',
        );
      }
    });
  });
}
