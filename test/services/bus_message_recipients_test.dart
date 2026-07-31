import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

// A per-bus WhatsApp announcement is addressed to PHONES, but the roster is
// keyed by passenger ROW — and one phone legitimately owns several rows (a
// family head books for the whole family under his own number). Building the
// batch per-row therefore sent the same announcement to that one phone two,
// three, even six times.
//
// Observed live on the 27 Jul 2026 tour: "ashvin bhai vekariya" holds two
// passenger rows on KHODAL DHAM, and the real send log shows 19 messages for
// 18 unique phones — he received the identical announcement twice.

const _bus = 'bus-khodal';
const _other = 'bus-vantara';

Passenger _p(String id, String phone, List<String> busIds) => Passenger(
      id: id,
      tourId: 't',
      name: id,
      phone: phone,
      assignedSeats: [
        for (var i = 0; i < busIds.length; i++)
          SeatAssignment(busId: busIds[i], seatId: 'S$i'),
      ],
    );

Tour _tour(List<Passenger> passengers) => Tour(
      title: 'Guru Purnima',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 27),
      pricePerSeat: 1000,
      passengers: passengers,
    );

void main() {
  group('busMessageRecipients — one message per phone', () {
    test('a phone owning several rows on the bus is messaged ONCE', () {
      final tour = _tour([
        _p('ashvin-row-1', '+919924902371', [_bus]),
        _p('ashvin-row-2', '+919924902371', [_bus]),
        _p('other', '+919825588226', [_bus]),
      ]);

      final to = WhatsAppOutbound.busMessageRecipients(tour, _bus);

      expect(to, ['919924902371', '919825588226']);
      expect(to.length, to.toSet().length, reason: 'no duplicate recipients');
    });

    test('reproduces the live KHODAL DHAM send: 19 rows -> 18 phones', () {
      final rows = <Passenger>[
        for (var i = 0; i < 18; i++)
          _p('p$i', '+9198000000${i.toString().padLeft(2, '0')}', [_bus]),
        _p('dupe', '+919800000000', [_bus]), // same phone as p0
      ];

      final to = WhatsAppOutbound.busMessageRecipients(_tour(rows), _bus);

      expect(rows.length, 19);
      expect(to.length, 18);
    });

    test('the same phone written in different formats still collapses to one', () {
      final tour = _tour([
        _p('a', '+91 99249 02371', [_bus]),
        _p('b', '9924902371', [_bus]),
        _p('c', '919924902371', [_bus]),
      ]);

      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus), ['919924902371']);
    });

    test('only riders on THIS bus are included', () {
      final tour = _tour([
        _p('on-bus', '+919000000001', [_bus]),
        _p('elsewhere', '+919000000002', [_other]),
      ]);

      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus), ['919000000001']);
    });

    test('a rider seated on BOTH buses gets each bus message once', () {
      final tour = _tour([
        _p('split-legs', '+919000000003', [_bus, _other]),
      ]);

      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus), ['919000000003']);
      expect(WhatsAppOutbound.busMessageRecipients(tour, _other), ['919000000003']);
    });

    test('blank phones are dropped, never sent as an empty recipient', () {
      final tour = _tour([
        _p('no-phone', '', [_bus]),
        _p('real', '+919000000004', [_bus]),
      ]);

      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus), ['919000000004']);
    });

    test('unseated passengers are never messaged', () {
      final tour = _tour([_p('unseated', '+919000000005', const [])]);

      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus), isEmpty);
    });
  });
}
