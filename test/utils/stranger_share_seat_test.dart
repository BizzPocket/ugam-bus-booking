import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/stranger_share_seat.dart';

Bus _bus() => Bus(
      id: 'b1',
      name: 'b1',
      busType: 'Sleeper',
      layout: BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: [
          SeatCell(
            row: 0,
            col: 3,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.upper,
            seatId: 'DU1',
          ),
        ],
      ),
    );

Passenger _p({
  required String id,
  required TripType trip,
  List<SeatAssignment> seats = const [],
  String? groupId,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      tripType: trip,
      groupId: groupId,
      requestLines: [
        RequestLine(seatType: SeatType.singleSofa, qty: 1, leg: trip),
      ],
      assignedSeats: seats,
    );

Tour _tour(List<Passenger> passengers) => Tour(
      id: 't1',
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 8, 1),
      pricePerSeat: 1000,
      buses: [_bus()],
      passengers: passengers,
    );

void main() {
  test('finds stranger-occupied double with a free overlapping berth', () {
    final placed = _p(
      id: 'a',
      trip: TripType.outboundOnly,
      seats: [const SeatAssignment(busId: 'b1', seatId: 'DU1')],
    );
    final waiting = _p(id: 'b', trip: TripType.outboundOnly);
    final seat = findStrangerShareSeat(_tour([placed, waiting]), waiting);
    expect(seat, isNotNull);
    expect(seat!.seatId, 'DU1');
    expect(seat.busId, 'b1');
  });

  test('skips same-group holders (not a stranger share)', () {
    final placed = _p(
      id: 'a',
      trip: TripType.outboundOnly,
      groupId: 'fam',
      seats: [const SeatAssignment(busId: 'b1', seatId: 'DU1')],
    );
    final waiting = _p(id: 'b', trip: TripType.outboundOnly, groupId: 'fam');
    expect(findStrangerShareSeat(_tour([placed, waiting]), waiting), isNull);
  });

  test('skips disjoint-leg holders (engine auto-shares those)', () {
    final placed = _p(
      id: 'a',
      trip: TripType.outboundOnly,
      seats: [const SeatAssignment(busId: 'b1', seatId: 'DU1')],
    );
    final waiting = _p(id: 'b', trip: TripType.returnOnly);
    expect(findStrangerShareSeat(_tour([placed, waiting]), waiting), isNull);
  });
}
