import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Pins the double-sofa SHARER fare rule against the exact pricing config of a
/// live bus (tour 5d427c61, bus d0297e0c: bands ₹1800 rows 0-4 / ₹1200 row 5,
/// whole-sofa override ₹3333, base ₹1800, row 6 unbanded).
///
/// The rule: one assignment entry = one berth. A rider sharing a double sofa
/// pays ONE berth; a rider holding the whole sofa (two entries) pays two. The
/// per-seat figure is per DISTINCT seat — summing it once per ENTRY double
/// counts every whole sofa (that measurement error is what made the live
/// `baseline_seat_due_paise` look 2x inflated; it is not).
///
/// Server mirror: `baseline_seat_due_paise` (070 body, verified live
/// 2026-10-22: equal to this code on all 141 seated seats of tours 5d427c61 and
/// 01d52052) and `bus_berth_price_paise` (a PER-BERTH price). Expected paise
/// below are what those RPCs return live for the same cells.
void main() {
  Bus liveBus() => Bus(
        id: 'b',
        name: 'BANSIDHAR',
        pricePerSeat: 1800,
        singleSofaPrice: 1800,
        doubleSofaPrice: 3333,
        priceBands: const [
          PriceBand(label: 'બેન્ડ', fromRow: 0, toRow: 4, price: 1800),
          PriceBand(label: 'બેન્ડ', fromRow: 5, toRow: 5, price: 1200),
        ],
        layout: BusLayout(rows: 7, cols: 5, grid: const [
          SeatCell(
              row: 3,
              col: 3,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.upper,
              seatId: 'DU4'),
          SeatCell(
              row: 3,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DL4'),
          SeatCell(
              row: 6,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DL7'),
          SeatCell(
              row: 3,
              col: 1,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SL4'),
        ]),
      );

  Passenger rider(List<SeatAssignment> seats,
          {TripType leg = TripType.roundTrip}) =>
      Passenger(
        tourId: 't',
        name: 'x',
        phone: '1',
        assignedSeats: seats,
        requestLines: [
          for (final t in SeatType.values)
            RequestLine(seatType: t, qty: 1, leg: leg),
        ],
        tripType: leg,
      );

  const rt = TripType.roundTrip;

  test('bus_berth_price_paise mirror: a double-sofa price is PER BERTH', () {
    final bus = liveBus();
    // Banded row: every berth = the band price (live RPC: 180000).
    expect(bus.berthPriceFor(SeatType.doubleSofa, 3), 1800);
    // Unbanded row: the ₹3333 override is the WHOLE sofa, so one berth is
    // half of it (live RPC: 166650).
    expect(bus.berthPriceFor(SeatType.doubleSofa, 6), 1666.5);
  });

  test('a rider SHARING a banded double sofa pays ONE berth', () {
    final bus = liveBus();
    final a = rider(const [SeatAssignment(busId: 'b', seatId: 'DL4', leg: rt)]);
    final b = rider(const [SeatAssignment(busId: 'b', seatId: 'DL4', leg: rt)]);
    expect(bus.amountDueForSeat(a, 'DL4'), 1800);
    expect(bus.amountDueForSeat(b, 'DL4'), 1800);
    // The two sharers together pay exactly what one whole-sofa rider pays.
    final whole = rider(const [
      SeatAssignment(busId: 'b', seatId: 'DU4', leg: rt),
      SeatAssignment(busId: 'b', seatId: 'DU4', leg: rt),
    ]);
    expect(bus.amountDueForSeat(whole, 'DU4'), 3600);
    expect(bus.amountDueForSeat(a, 'DL4') + bus.amountDueForSeat(b, 'DL4'),
        bus.amountDueForSeat(whole, 'DU4'));
  });

  test('unbanded double: whole = the ₹3333 override, sharer = half (rounded)',
      () {
    final bus = liveBus();
    final whole = rider(const [
      SeatAssignment(busId: 'b', seatId: 'DL7', leg: rt),
      SeatAssignment(busId: 'b', seatId: 'DL7', leg: rt),
    ]);
    final sharer =
        rider(const [SeatAssignment(busId: 'b', seatId: 'DL7', leg: rt)]);
    expect(bus.amountDueForSeat(whole, 'DL7'), 3333);
    // 1666.5 rounds half-away-from-zero, same as Postgres numeric round().
    expect(bus.amountDueForSeat(sharer, 'DL7'), 1667);
  });

  test('GO + RET reuse of one single sofa: each one-leg rider pays half', () {
    final bus = liveBus();
    final go = rider(
        const [
          SeatAssignment(
              busId: 'b', seatId: 'SL4', leg: TripType.outboundOnly)
        ],
        leg: TripType.outboundOnly);
    final ret = rider(
        const [
          SeatAssignment(busId: 'b', seatId: 'SL4', leg: TripType.returnOnly)
        ],
        leg: TripType.returnOnly);
    expect(bus.amountDueForSeat(go, 'SL4'), 900);
    expect(bus.amountDueForSeat(ret, 'SL4'), 900);
  });

  test('per-seat due is per DISTINCT seat: never multiply it by entries', () {
    final bus = liveBus();
    final whole = rider(const [
      SeatAssignment(busId: 'b', seatId: 'DU4', leg: rt),
      SeatAssignment(busId: 'b', seatId: 'DU4', leg: rt),
    ]);
    // The rider total is the whole-sofa price ONCE (3600), not 2 x 3600.
    expect(bus.amountDueFor(whole), 3600);
    final perEntrySum = whole.assignedSeats
        .map((a) => bus.amountDueForSeat(whole, a.seatId))
        .fold<double>(0, (s, v) => s + v);
    expect(perEntrySum, 7200,
        reason: 'summing per ENTRY double-counts a whole sofa — the trap');
  });
}
