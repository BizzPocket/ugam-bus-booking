// CROSS-SYSTEM REGRESSION SAFETY NET.
//
// The app's five subsystems — seat engine / leg-resolver, seat render, money /
// collection / settlement, handler money, and notify — are all coupled through
// three shared facts: the per-seat SeatAssignment.leg, the assignedSeats list,
// and money-as-double arithmetic. Each subsystem is unit-tested in isolation,
// but historically a change that was "correct" in one silently broke another at
// the SEAM between them (fix seats → handler money drifts; fix money → tint
// disagrees; …). These tests pin the CROSS-SYSTEM invariants so that the next
// change that breaks a seam trips a red test here instead of reaching a client.
//
// Each group names the invariant it guards and which subsystems it couples.
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/handler_bus_money.dart';
import 'package:occubusbooking/models/money_summary.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_leg_capacity.dart';
import 'package:occubusbooking/utils/seat_leg_resolver.dart';

// A bus with two single sofas (1200) and one whole double sofa (1550 → 775/berth)
// and two seaters (900). One of everything the seams below exercise.
Bus _bus() => Bus(
      id: 'bus1',
      name: 'Bus 1',
      pricePerSeat: 1000,
      singleSofaPrice: 1200,
      doubleSofaPrice: 1550,
      seaterPrice: 900,
      layout: BusLayout(rows: 3, cols: 5, grid: const [
        SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1'),
        SeatCell(
            row: 0,
            col: 2,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL2'),
        SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DL1'),
        SeatCell(row: 1, col: 0, seatType: SeatType.seater, seatId: 'ST1'),
        SeatCell(row: 1, col: 1, seatType: SeatType.seater, seatId: 'ST2'),
      ]),
    );

SeatType? _cellTypeAt(String busId, String seatId) {
  const single = {'SL1', 'SL2'};
  const seater = {'ST1', 'ST2'};
  if (single.contains(seatId)) return SeatType.singleSofa;
  if (seater.contains(seatId)) return SeatType.seater;
  if (seatId == 'DL1') return SeatType.doubleSofa;
  return null;
}

void main() {
  // ── SEAM 1: seat render, money and capacity all read the SAME per-seat leg ──
  // A mixed same-type booking (1 single GO-only + 1 single RET-only) collapses
  // the coarse Passenger.tripType to roundTrip, but each seat carries its OWN
  // leg. Tint (legForSeat), money (amountDueForSeat) and capacity (a.leg) must
  // agree PER SEAT — never re-collapse to the round-trip summary.
  group('Seam: per-seat leg is the single source (tint == money)', () {
    // Mixed-leg rider: SL1 held GO-only, SL2 held RET-only.
    final mixed = Passenger(
      id: 'g',
      tourId: 't1',
      name: 'Mixed',
      phone: '+910000000000',
      tripType: TripType.roundTrip, // coarse summary of the mixed booking
      requestLines: const [
        RequestLine(
            seatType: SeatType.singleSofa, qty: 1, leg: TripType.outboundOnly),
        RequestLine(
            seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
      ],
      assignedSeats: const [
        SeatAssignment(busId: 'bus1', seatId: 'SL1', leg: TripType.outboundOnly),
        SeatAssignment(busId: 'bus1', seatId: 'SL2', leg: TripType.returnOnly),
      ],
    );

    test('tint leg (legForSeat) is per-seat, not the round-trip summary', () {
      expect(mixed.tripType, TripType.roundTrip);
      expect(mixed.legForSeat('SL1'), TripType.outboundOnly);
      expect(mixed.legForSeat('SL2'), TripType.returnOnly);
    });

    test('money charges each seat by its own leg (half), agreeing with tint',
        () {
      final bus = _bus();
      // SL1 tints GO-only → billed half (600); SL2 tints RET-only → half (600).
      expect(bus.amountDueForSeat(mixed, 'SL1'), 600);
      expect(bus.amountDueForSeat(mixed, 'SL2'), 600);
      // The COARSE per-type leg collapses this mixed [GO, RET] booking to the
      // heavier one-way (outbound) for BOTH seats — so SL2's real RETURN leg
      // (violet) would render/charge as OUTBOUND (cyan) if any reader reverted
      // to the coarse leg. The per-seat leg keeps SL2 honest (returnOnly).
      expect(mixed.legForSeatType(SeatType.singleSofa), TripType.outboundOnly);
      expect(mixed.legForSeat('SL2'), TripType.returnOnly);
    });
  });

  // ── SEAM 1b / leg-share manual gap (the tap "seat here" refusal) ────────────
  // The manual share offer builds the occupied seat's per-leg holders. Reading
  // the coarse tripType wrongly showed a mixed-leg rider as occupying BOTH legs,
  // refusing a legitimate complementary-leg share. It must read legForSeat.
  group('Seam: leg-share placement uses the seat-own leg', () {
    // G holds single seat SL1 on GO only (RET leg free); G.tripType == roundTrip.
    final g = Passenger(
      id: 'g',
      tourId: 't1',
      name: 'G',
      phone: '+910000000000',
      tripType: TripType.roundTrip,
      assignedSeats: const [
        SeatAssignment(busId: 'bus1', seatId: 'SL1', leg: TripType.outboundOnly),
      ],
    );

    test('a RET rider CAN share the free return leg when holder leg is per-seat',
        () {
      // Correct input: holder leg = G.legForSeat('SL1') = outboundOnly.
      final allowed = seatHasLegRoom(
        activeTrip: TripType.returnOnly,
        need: 1,
        cap: 1, // single sofa = one berth, reusable across the two legs
        occupants: [(trip: g.legForSeat('SL1'), berths: 1)],
      );
      expect(allowed, isTrue, reason: 'RET leg is free → share allowed');
    });

    test('the OLD coarse-tripType input reproduces the refusal (guard)', () {
      final refused = seatHasLegRoom(
        activeTrip: TripType.returnOnly,
        need: 1,
        cap: 1,
        occupants: [(trip: g.tripType, berths: 1)], // buggy: roundTrip
      );
      expect(refused, isFalse,
          reason: 'coarse roundTrip wrongly blocks the free RET leg');
    });
  });

  // ── SEAM 2: money reconciles — whole == sum of per-seat records ─────────────
  // amountDueFor(passenger) MUST equal the sum of the per-(passenger,bus,seat)
  // collection records (each rounded at source), and a whole double is priced
  // per berth so mixed-weight berths (round-trip + one-way) sum correctly.
  group('Seam: money reconciles (whole == sum of per-seat records)', () {
    test('passenger whole total equals the sum of its per-seat dues', () {
      final bus = _bus();
      final p = Passenger(
        tourId: 't1',
        name: 'p',
        phone: '+910000000000',
        requestLines: const [
          RequestLine(
              seatType: SeatType.singleSofa,
              qty: 1,
              leg: TripType.outboundOnly),
          RequestLine(
              seatType: SeatType.singleSofa,
              qty: 1,
              leg: TripType.returnOnly),
        ],
        assignedSeats: const [
          SeatAssignment(
              busId: 'bus1', seatId: 'SL1', leg: TripType.outboundOnly),
          SeatAssignment(
              busId: 'bus1', seatId: 'SL2', leg: TripType.returnOnly),
        ],
      );
      final perSeat =
          bus.amountDueForSeat(p, 'SL1') + bus.amountDueForSeat(p, 'SL2');
      expect(bus.amountDueFor(p), perSeat);
      expect(perSeat, 1200); // 600 + 600
    });

    test('whole double with mixed-weight berths sums per berth (1.0 + 0.5)', () {
      final bus = _bus(); // double berth = 775
      // One passenger holds BOTH berths of DL1: one round-trip, one outbound.
      final p = Passenger(
        tourId: 't1',
        name: 'p',
        phone: '+910000000000',
        requestLines: const [
          RequestLine(
              seatType: SeatType.doubleSofa, qty: 1, leg: TripType.roundTrip),
        ],
        assignedSeats: const [
          SeatAssignment(busId: 'bus1', seatId: 'DL1', leg: TripType.roundTrip),
          SeatAssignment(
              busId: 'bus1', seatId: 'DL1', leg: TripType.outboundOnly),
        ],
      );
      // 775×1.0 + 775×0.5 = 1162.5 → 1163 (not 2×full=1550, not 2×half=775).
      expect(bus.amountDueForSeat(p, 'DL1'), 1163);
      expect(bus.amountDueFor(p), 1163);
    });
  });

  // ── SEAM 3: handler bus money == admin bus money (the ₹23k-vs-₹30k class) ────
  // The same bus's net is computed by two divergent paths (admin
  // BusMoneySummary.expectedHandover vs handler HandlerBusMoney.inHand). They
  // MUST agree for identical inputs, or the handler and admin disagree on cash.
  group('Seam: handler bus money == admin bus money', () {
    double due(Passenger p, String seatId) => _bus().amountDueForSeat(p, seatId);

    // p1 fully paid on SL1; p2 seated on SL2 but uncollected (both sides derive
    // its to-collect from dueForSeat). Both seats stamped round-trip → full 1200.
    final passengers = [
      Passenger(
        id: 'p1',
        tourId: 't1',
        name: 'p1',
        phone: '+910000000001',
        assignedSeats: const [
          SeatAssignment(busId: 'bus1', seatId: 'SL1', leg: TripType.roundTrip),
        ],
      ),
      Passenger(
        id: 'p2',
        tourId: 't1',
        name: 'p2',
        phone: '+910000000002',
        assignedSeats: const [
          SeatAssignment(busId: 'bus1', seatId: 'SL2', leg: TripType.roundTrip),
        ],
      ),
    ];
    final collections = [
      Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'SL1',
        amountDue: 1200,
        amountReceived: 1200,
      ),
    ];
    final expenses = [
      Expense(
        tourId: 't1',
        busId: 'bus1',
        amount: 500,
        category: ExpenseCategory.fuel,
        label: 'Fuel',
      ),
    ];
    const busRent = 2000.0;

    test('expectedHandover (admin) == inHand (handler), and collected/to-collect',
        () {
      final admin = BusMoneySummary.compute(
        busId: 'bus1',
        collections: collections,
        expenses: expenses,
        handovers: const [],
        busRent: busRent,
        passengers: passengers,
        dueForSeat: due,
      );
      final handler = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: passengers,
        collections: collections,
        expenses: expenses,
        dueForSeat: due,
      );
      expect(admin.collected, handler.collected);
      expect(admin.toCollectTotal, handler.toCollect);
      expect(admin.toReturnTotal, handler.toReturn);
      // The settlement figure both roles show the owner must be identical.
      expect(admin.expectedHandover, handler.inHand);
      // Sanity on the absolute number: 1200 collected − 500 ground. The bus
      // owner's rent is ADMIN-only — the admin pays it out of this handover, so
      // it must never shrink what the handler is asked to hand over.
      expect(handler.inHand, 1200 - 500);
      expect(admin.netCollected, handler.inHand - busRent);
      expect(handler.toCollect, 1200); // p2 uncollected, full round-trip fare
    });
  });

  // ── SEAM 4: request-leg edit repropagates to money (Fix B regression) ───────
  // Editing a rider's leg AFTER seats are assigned must re-stamp the seats'
  // legs; otherwise money (which now reads the per-seat leg) prices the STALE
  // leg. This pins the null-then-resolve re-stamp the edit path performs.
  group('Seam: a request-leg edit repropagates to money', () {
    test('changing a seat GO→round-trip via re-stamp reprices half → full', () {
      final bus = _bus();
      // Originally booked GO-only on ST1 → half fare.
      final before = Passenger(
        tourId: 't1',
        name: 'p',
        phone: '+910000000000',
        requestLines: const [
          RequestLine(
              seatType: SeatType.seater, qty: 1, leg: TripType.outboundOnly),
        ],
        assignedSeats: const [
          SeatAssignment(busId: 'bus1', seatId: 'ST1', leg: TripType.outboundOnly),
        ],
      );
      expect(bus.amountDueForSeat(before, 'ST1'), 450); // half of 900

      // Edit the request to a full round trip. The edit path nulls the stored
      // legs and re-derives them from the NEW request lines (updatePassenger-
      // FromRequestEdit). Simulate that exact composition here.
      const newLines = [
        RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.roundTrip),
      ];
      final restamped = resolveAssignmentLegs(
        requestLines: newLines,
        assigned: const [SeatAssignment(busId: 'bus1', seatId: 'ST1')], // leg nulled
        cellTypeAt: _cellTypeAt,
      );
      final after = before.copyWith(
        requestLines: newLines,
        assignedSeats: restamped,
      );
      expect(after.assignedSeats.single.leg, TripType.roundTrip);
      expect(bus.amountDueForSeat(after, 'ST1'), 900); // now full
    });
  });

  // ── SEAM 5: resolveAssignmentLegs is idempotent + preserves stamped legs ────
  // The resolver runs at 9 controller sites (assign/move/swap/consolidate/fill).
  // Running it again on already-stamped output must be a no-op, or a re-persist
  // silently reshuffles legs → wrong tint + wrong fare + wrong capacity at once.
  group('Seam: resolveAssignmentLegs idempotence', () {
    const lines = [
      RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.outboundOnly),
      RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.returnOnly),
    ];
    test('f(f(x)) == f(x) on a fully-stamped mixed list', () {
      final once = resolveAssignmentLegs(
        requestLines: lines,
        assigned: const [
          SeatAssignment(busId: 'bus1', seatId: 'ST1'),
          SeatAssignment(busId: 'bus1', seatId: 'ST2'),
        ],
        cellTypeAt: _cellTypeAt,
      );
      final twice = resolveAssignmentLegs(
        requestLines: lines,
        assigned: once,
        cellTypeAt: _cellTypeAt,
      );
      expect(twice.map((a) => a.leg).toList(),
          once.map((a) => a.leg).toList(),
          reason: 're-running the resolver must never change a stamped leg');
      expect(once.map((a) => a.leg).toList(),
          [TripType.outboundOnly, TripType.returnOnly]);
    });
  });
}
