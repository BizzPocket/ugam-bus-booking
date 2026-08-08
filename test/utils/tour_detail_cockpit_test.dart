import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/utils/tour_detail_cockpit.dart';

Bus _bus(String id, {String driver = '', int seats = 37}) => Bus(
      id: id,
      name: id,
      busType: 'AC',
      driverName: driver,
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

Passenger _p(
  String id, {
  String name = 'A',
  String phone = '9000000001',
  int qty = 1,
  SeatType type = SeatType.singleSofa,
  List<SeatAssignment> seats = const [],
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: phone,
      requestLines: [RequestLine(seatType: type, qty: qty)],
      assignedSeats: seats,
    );

Tour _tour({
  double price = 0,
  List<Passenger> passengers = const [],
  List<Bus> buses = const [],
}) =>
    Tour(
      id: 't1',
      title: 'Test',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 8, 14),
      pricePerSeat: price,
      passengers: passengers,
      buses: buses,
    );

void main() {
  group('resolveTourHeroChip', () {
    test('prefers seats left when pending > 0 even if price is 0', () {
      final tour = _tour(
        price: 0,
        buses: [_bus('b1')],
        passengers: [
          _p('p1', name: 'Nikunj'),
          _p('p2', name: 'Rajesh', seats: [
            const SeatAssignment(busId: 'b1', seatId: 'A1'),
          ]),
        ],
      );
      final chip = resolveTourHeroChip(tour);
      expect(chip.kind, TourHeroChipKind.seatsLeft);
      expect(chip.seatsLeft, greaterThan(0));
    });

    test('shows price when no pending seats and price > 0', () {
      final tour = _tour(
        price: 1500,
        buses: [_bus('b1')],
        passengers: [
          _p('p1', seats: [
            const SeatAssignment(busId: 'b1', seatId: 'A1'),
          ]),
        ],
      );
      final chip = resolveTourHeroChip(tour);
      expect(chip.kind, TourHeroChipKind.pricePerSeat);
      expect(chip.pricePerSeat, 1500);
    });
  });

  group('filterTravelers', () {
    final passengers = [
      _p('1', name: 'Nikunj Gajera', phone: '9111111111'),
      _p('2', name: 'Rajeshbhai', phone: '9222222222', seats: [
        const SeatAssignment(busId: 'b1', seatId: 'A1'),
      ]),
      _p('3',
          name: 'Double Rider',
          type: SeatType.doubleSofa,
          qty: 1),
    ];

    test('needsSeat filters unassigned', () {
      final out = filterTravelers(passengers, filter: TravelerFilter.needsSeat);
      expect(out.map((p) => p.id), containsAll(['1', '3']));
      expect(out.map((p) => p.id), isNot(contains('2')));
    });

    test('query matches name or phone', () {
      final out = filterTravelers(
        passengers,
        filter: TravelerFilter.all,
        query: 'nikunj',
      );
      expect(out, hasLength(1));
      expect(out.first.id, '1');
    });

    test('double filter', () {
      final out = filterTravelers(passengers, filter: TravelerFilter.double_);
      expect(out.map((p) => p.id), ['3']);
    });
  });

  group('buildNeedsAttention', () {
    test('flags unseated and buses without drivers', () {
      final tour = _tour(
        passengers: [_p('1', name: 'Nikunj')],
        buses: [_bus('shiv-1'), _bus('shiv-2', driver: 'Ramesh')],
      );
      final items = buildNeedsAttention(tour);
      expect(items.map((i) => i.kind), contains(NeedsAttentionKind.unseated));
      expect(items.map((i) => i.kind), contains(NeedsAttentionKind.noDriver));
    });
  });
}
