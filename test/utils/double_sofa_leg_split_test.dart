import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_drop_engine.dart';
import 'package:occubusbooking/utils/seat_fit.dart';
import 'package:occubusbooking/utils/seat_leg_capacity.dart';

/// THE REPORTED BUG (10 Aug 2026), in the operator's words:
///
///   "ડબલ ના સોફા માં જાવક માં અલગ અલગ વ્યક્તિ ને 2 સિંગલ સીટ આપેલી હોય પછી એજ
///    સીટ માં ડબલ નો સોફો ફક્ત આવક માં આપેલો હોય તો ફાળવાતો નથી"
///
/// One Double Sofa. On the OUTBOUND (જાવક) leg its two berths are given to TWO
/// DIFFERENT single-seat riders. The RETURN (આવક) leg of that sofa is therefore
/// completely free — and a rider who booked the WHOLE double for the return leg
/// only must be seatable there. The screen refused them.
///
/// A double sofa is 2 berths on GO **and** 2 berths on RET — four berth-legs.
/// Two GO-only singles consume GO 2/2 and leave RET 2/2 open, which is exactly
/// what a return-only whole-double needs.
///
/// WHY IT FAILED: seats placed by hand carry NO per-seat leg
/// ([SeatAssignment.leg] is null), and [Passenger.legForSeat] fell back to the
/// RAW stored [Passenger.tripType] — a column that defaults to `roundTrip` and
/// is never stamped for riders whose leg lives on their request LINES. So the
/// two GO-only sharers were read as ROUND-TRIP occupants, which fills both legs
/// and blocks every further placement on that sofa.
///
/// The active-passenger side of the same gate had already been fixed to read
/// `derivedTripType` (the per-line truth); the OCCUPANT side had not. These
/// tests pin both sides to the same rule.
void main() {
  // A rider whose leg lives ONLY on the request line — `tripType` is left at its
  // default (roundTrip), which is what every request-mode booking looks like.
  Passenger rider({
    required String name,
    required SeatType seatType,
    required int qty,
    required TripType leg,
    List<SeatAssignment> seats = const [],
  }) {
    return Passenger(
      tourId: 't1',
      name: name,
      phone: '1',
      requestLines: [RequestLine(seatType: seatType, qty: qty, leg: leg)],
      assignedSeats: seats,
    );
  }

  group('Passenger.legForSeat — unstamped seat falls back to the LINE leg', () {
    test('a GO-only rider on an unstamped seat is NOT read as round-trip', () {
      final go = rider(
        name: 'Go only',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );

      // The seat carries no leg (hand placement never stamped one)…
      expect(go.assignedSeats.single.leg, isNull);
      // …so the fallback must come from the request line, not the unset
      // `tripType` column that silently reads roundTrip.
      expect(
        go.legForSeat('DS1', busId: 'b1'),
        TripType.outboundOnly,
        reason: 'the rider booked GO only; nothing about them is round-trip',
      );
    });

    test('a RET-only rider on an unstamped seat reads returnOnly', () {
      final ret = rider(
        name: 'Ret only',
        seatType: SeatType.doubleSofa,
        qty: 1,
        leg: TripType.returnOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      expect(ret.legForSeat('DS1', busId: 'b1'), TripType.returnOnly);
    });

    test('a genuinely round-trip rider still reads roundTrip', () {
      final rt = rider(
        name: 'Round trip',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.roundTrip,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      expect(rt.legForSeat('DS1', busId: 'b1'), TripType.roundTrip);
    });

    test('a legacy rider with NO request lines keeps the stored tripType', () {
      // The pre-per-line-leg shape: the leg lived only on the passenger row.
      // Falling back to a derived summary would lose it, so this stays.
      final legacy = Passenger(
        tourId: 't1',
        name: 'Legacy',
        phone: '1',
        tripType: TripType.returnOnly,
        requestLines: const [],
        assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      expect(legacy.legForSeat('DS1', busId: 'b1'), TripType.returnOnly);
    });

    test('effectiveTripType is the shared rule every leg gate now uses', () {
      // Four separate call sites were reading the raw `tripType` column and so
      // carried this same bug: the own-double partner-berth claim and the
      // swap-conflict picker in tour_seat_assignment_screen, and both sides of
      // SeatSwapGuard's overbook check. They all read this getter now.
      final oneWay = rider(
        name: 'GO only',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
      );
      expect(oneWay.tripType, TripType.roundTrip,
          reason: 'the stored column is an unset default — this is the trap');
      expect(oneWay.effectiveTripType, TripType.outboundOnly);

      // Mixed legs stay round-trip, so capacity is never over-sold.
      final mixed = Passenger(
        tourId: 't1',
        name: 'Mixed',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.seater,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
          RequestLine(
            seatType: SeatType.seater,
            qty: 1,
            leg: TripType.returnOnly,
          ),
        ],
      );
      expect(mixed.effectiveTripType, TripType.roundTrip);

      // A legacy row with no lines still trusts the stored column.
      final legacy = Passenger(
        tourId: 't1',
        name: 'Legacy',
        phone: '1',
        tripType: TripType.returnOnly,
        requestLines: const [],
      );
      expect(legacy.effectiveTripType, TripType.returnOnly);
    });

    test('an explicitly stamped seat leg always wins over any fallback', () {
      final mixed = Passenger(
        tourId: 't1',
        name: 'Mixed',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.seater,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
          RequestLine(
            seatType: SeatType.seater,
            qty: 1,
            leg: TripType.returnOnly,
          ),
        ],
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1', leg: TripType.outboundOnly),
          SeatAssignment(busId: 'b1', seatId: 'ST2', leg: TripType.returnOnly),
        ],
      );
      expect(mixed.legForSeat('ST1', busId: 'b1'), TripType.outboundOnly);
      expect(mixed.legForSeat('ST2', busId: 'b1'), TripType.returnOnly);
    });
  });

  group('the reported double-sofa scenario', () {
    // The two GO-only riders already sharing the sofa's outbound berths.
    List<Passenger> goSharers() => [
          rider(
            name: 'Single A',
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.outboundOnly,
            seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
          ),
          rider(
            name: 'Single B',
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.outboundOnly,
            seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
          ),
        ];

    /// Exactly how `_seatHereBerths` in tour_seat_assignment_screen builds the
    /// per-leg holders for an occupied cell.
    List<SeatLegHolder> holdersOn(List<Passenger> occupants, String seatId) => [
          for (final o in occupants)
            (
              trip: o.legForSeat(seatId, busId: 'b1'),
              berths: o.assignedSeats
                  .where((a) => a.busId == 'b1' && a.seatId == seatId)
                  .length,
            ),
        ];

    test('two GO-only singles occupy the sofa on GO only, never on RET', () {
      final holders = holdersOn(goSharers(), 'DS1');
      expect(holders, hasLength(2));
      expect(
        holders.every((h) => h.trip == TripType.outboundOnly),
        isTrue,
        reason: 'both sharers are outbound-only riders',
      );

      // GO is now full…
      expect(
        seatHasLegRoom(
          activeTrip: TripType.outboundOnly,
          need: 1,
          cap: 2,
          occupants: holders,
        ),
        isFalse,
        reason: 'GO 2/2 — no third outbound rider fits',
      );
      // …but RET is untouched, with room for BOTH berths.
      expect(
        seatHasLegRoom(
          activeTrip: TripType.returnOnly,
          need: 2,
          cap: 2,
          occupants: holders,
        ),
        isTrue,
        reason: 'RET 0/2 — the whole sofa is free on the return leg',
      );
    });

    test('a RET-only WHOLE-DOUBLE rider is offered both berths of that sofa',
        () {
      final incoming = rider(
        name: 'Return double',
        seatType: SeatType.doubleSofa,
        qty: 1,
        leg: TripType.returnOnly,
      );
      final holders = holdersOn(goSharers(), 'DS1');

      final berths = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: null,
        activeTrip: incoming.derivedTripType,
        cap: 2,
        occupants: holders,
      );

      expect(
        berths,
        2,
        reason: 'the entire sofa is free on RET — allocate both berths',
      );
    });

    test('the GO leg is still protected — a third GO rider is refused', () {
      final holders = holdersOn(goSharers(), 'DS1');
      final berths = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: null,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: holders,
      );
      expect(berths, 0, reason: 'GO 2/2 is genuinely full — do not overbook');
    });

    test('a ROUND-TRIP whole-double rider is still refused (RET free, GO not)',
        () {
      final holders = holdersOn(goSharers(), 'DS1');
      final berths = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: null,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: holders,
      );
      expect(
        berths,
        0,
        reason: 'a round-trip rider needs BOTH legs; the GO leg is taken',
      );
    });

    test('the reverse order works too — RET double first, then two GO singles',
        () {
      // The operator stressed the ORDER must not matter. Seat the return-only
      // whole double FIRST, then bring the two outbound-only singles.
      final retDouble = rider(
        name: 'Return double',
        seatType: SeatType.doubleSofa,
        qty: 1,
        leg: TripType.returnOnly,
        seats: const [
          SeatAssignment(busId: 'b1', seatId: 'DS1'),
          SeatAssignment(busId: 'b1', seatId: 'DS1'),
        ],
      );
      final holders = holdersOn([retDouble], 'DS1');
      expect(holders.single.berths, 2);
      expect(holders.single.trip, TripType.returnOnly);

      // First GO-only single fits (GO 0/2 → 1/2).
      expect(
        berthsForFreeCell(
          remaining: const [
            PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
          ],
          cellType: SeatType.doubleSofa,
          cellPosition: null,
          activeTrip: TripType.outboundOnly,
          cap: 2,
          occupants: holders,
        ),
        1,
      );

      // Second GO-only single also fits (GO 1/2 → 2/2).
      final withOneGo = [
        ...holders,
        (trip: TripType.outboundOnly, berths: 1),
      ];
      expect(
        berthsForFreeCell(
          remaining: const [
            PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
          ],
          cellType: SeatType.doubleSofa,
          cellPosition: null,
          activeTrip: TripType.outboundOnly,
          cap: 2,
          occupants: withOneGo,
        ),
        1,
        reason: 'GO 1/2 still has one berth left',
      );
    });
  });

  // The operator's other emphasis: "we need this order, we can't use any other
  // order seats assign". Placement must not depend on WHICH leg was seated
  // first, so the DRAG path (the engine behind the sofa-assign grid) is checked
  // in both directions. It reads occupant legs through the same
  // [Passenger.legForSeat] that the tap path uses — see `_occupantFor` in
  // tour_seat_assignment_screen.dart — so both were broken by one cause.
  group('drag-and-drop the sofa in either order', () {
    const doubleCell = (
      seatId: 'DS1',
      seatType: SeatType.doubleSofa,
      reserved: false,
    );
    const otherDouble = (
      seatId: 'DS2',
      seatType: SeatType.doubleSofa,
      reserved: false,
    );

    /// The engine view of [p] on [seatId], exactly as `_occupantFor` builds it.
    SeatOccupant occupantFor(Passenger p, String seatId) => (
          passengerId: p.id,
          trip: p.legForSeat(seatId, busId: 'b1'),
          berthsHere:
              p.assignedSeats.where((a) => a.seatId == seatId).length,
          wholeDoublesHeld: 0,
          requestedDoubleQty: p.requestLines
              .where((l) => l.seatType == SeatType.doubleSofa)
              .fold<int>(0, (s, l) => s + l.qty),
        );

    test('GO singles first, then drag the RET whole-double onto them', () {
      final a = rider(
        name: 'A',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      final b = rider(
        name: 'B',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      // The return-only rider is parked on a spare sofa and dragged across.
      final retDouble = rider(
        name: 'RET double',
        seatType: SeatType.doubleSofa,
        qty: 1,
        leg: TripType.returnOnly,
        seats: const [
          SeatAssignment(busId: 'b1', seatId: 'DS2'),
          SeatAssignment(busId: 'b1', seatId: 'DS2'),
        ],
      );

      final decision = decideSeatDrop(
        fromCell: otherDouble,
        targetCell: doubleCell,
        fromOccupants: [occupantFor(retDouble, 'DS2')],
        targetOccupants: [occupantFor(a, 'DS1'), occupantFor(b, 'DS1')],
      );

      expect(decision.action, SeatDropAction.fillPairInto,
          reason: 'GO 2/2 + RET 2/2 — all three share the one sofa');
      expect(decision.block, isNull);
    });

    test('RET whole-double first, then drag a GO single onto it', () {
      final retDouble = rider(
        name: 'RET double',
        seatType: SeatType.doubleSofa,
        qty: 1,
        leg: TripType.returnOnly,
        seats: const [
          SeatAssignment(busId: 'b1', seatId: 'DS1'),
          SeatAssignment(busId: 'b1', seatId: 'DS1'),
        ],
      );
      final goSingle = rider(
        name: 'GO single',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS2')],
      );

      final decision = decideSeatDrop(
        fromCell: otherDouble,
        targetCell: doubleCell,
        fromOccupants: [occupantFor(goSingle, 'DS2')],
        targetOccupants: [occupantFor(retDouble, 'DS1')],
      );

      expect(decision.action, SeatDropAction.fill,
          reason: 'the outbound leg of that sofa is untouched');
    });

    test('a same-leg overload is still refused in either order', () {
      final goA = rider(
        name: 'GO A',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      final goB = rider(
        name: 'GO B',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS1')],
      );
      final goC = rider(
        name: 'GO C',
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        seats: const [SeatAssignment(busId: 'b1', seatId: 'DS2')],
      );

      final decision = decideSeatDrop(
        fromCell: otherDouble,
        targetCell: doubleCell,
        fromOccupants: [occupantFor(goC, 'DS2')],
        targetOccupants: [occupantFor(goA, 'DS1'), occupantFor(goB, 'DS1')],
      );

      expect(decision.action, SeatDropAction.blocked);
      expect(decision.block, SeatDropBlock.noLegRoom,
          reason: 'three outbound riders cannot share two outbound berths');
    });
  });
}
