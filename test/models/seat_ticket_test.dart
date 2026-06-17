import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_ticket.dart';

void main() {
  // A payload shaped exactly like the live `seat_lookup_by_phone` RPC output,
  // captured against the real DB for Vasoya (RSR, DU3/DU3/SL3).
  final json = {
    'tour_id': '4cf2f719-c9b1-4657-8796-0a09e5935757',
    'tour_title': 'નિજ જેઠ સુદ બીજ 2026(AC)',
    'from_city': 'સુરત',
    'to_city': 'ભેડા પીપળીયા',
    'departure_date': '2026-06-16',
    'status': 'locked',
    'passenger_name': 'U Shaileshbhai Nanjibhai Vasoya Rampar',
    'assigned_seats': [
      {'busId': 'bus-rsr', 'seatId': 'DU3'},
      {'busId': 'bus-rsr', 'seatId': 'DU3'},
      {'busId': 'bus-rsr', 'seatId': 'SL3'},
    ],
    'buses': [
      {
        'id': 'bus-rsr',
        'tour_id': '4cf2f719-c9b1-4657-8796-0a09e5935757',
        'name': 'RSR',
        'registration_no': 'GJ05 1234',
        'bus_type': 'Sleeper',
        'total_seats': 40,
        'layout': null,
        'boarding_point': 'Surat',
        'departure_time': '17:00',
      },
    ],
  };

  test('parses the RPC ticket payload', () {
    final t = SeatTicket.fromJson(json);
    expect(t.passengerName, 'U Shaileshbhai Nanjibhai Vasoya Rampar');
    expect(t.status, 'locked');
    expect(t.departureDate, DateTime(2026, 6, 16));
    expect(t.buses.single.name, 'RSR');
    expect(t.assignedSeats.length, 3);
  });

  test('seatIdsForBus highlights only that bus\'s seats', () {
    final t = SeatTicket.fromJson(json);
    expect(t.seatIdsForBus('bus-rsr'), {'DU3', 'SL3'});
    expect(t.seatIdsForBus('other-bus'), isEmpty);
  });

  test('seatIds is the distinct, sorted seat list for the summary chip', () {
    final t = SeatTicket.fromJson(json);
    expect(t.seatIds, ['DU3', 'SL3']);
  });

  test('drops seat entries missing busId/seatId', () {
    final t = SeatTicket.fromJson({
      ...json,
      'assigned_seats': [
        {'busId': 'b', 'seatId': 'A1'},
        {'seatId': 'NOPE'}, // no busId → dropped
        {'busId': 'b'}, // no seatId → dropped
      ],
    });
    expect(t.assignedSeats.length, 1);
    expect(t.assignedSeats.single.seatId, 'A1');
  });
}
