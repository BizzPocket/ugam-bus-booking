import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

// Defence-in-depth: even if a composer's pre-flight check were bypassed, an
// announcement Meta cannot accept must never reach the wire — and the refusal
// must arrive as a normal per-recipient failure carrying a readable reason,
// because that is the shape every caller already renders.

const _bus = 'bus-1';

Tour _tour() => Tour(
      title: 'Dwarka Darshan',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 27),
      pricePerSeat: 1000,
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't',
          name: 'Rameshbhai',
          phone: '+919800000001',
          assignedSeats: const [SeatAssignment(busId: _bus, seatId: 'S1')],
        ),
      ],
    );

void main() {
  test('a message with a line break is blocked before any network call', () async {
    final result = await WhatsAppOutbound().sendBusMessage(
      tour: _tour(),
      busId: _bus,
      messageText: 'પહેલો ફકરો..\n\nબીજો ફકરો..',
    );

    expect(result.anySent, isFalse);
    expect(result.failed, 1);
    // The reason must be present and specific — the whole point of the change.
    expect(result.results.single.error, contains('newline'));
    expect(result.results.single.error, contains('line breaks'));
  });

  test('an over-length message is blocked with its own reason', () async {
    final result = await WhatsAppOutbound().sendBusMessage(
      tour: _tour(),
      busId: _bus,
      messageText: 'ક' * 1100,
    );

    expect(result.anySent, isFalse);
    expect(result.results.single.error, contains('tooLong'));
  });

  test('a clean single-paragraph message passes the guard', () async {
    // Reaches recipient selection (no violation short-circuit). With no seated
    // rider on an unknown bus it returns the empty result rather than a
    // validation failure — proving the guard let it through.
    final result = await WhatsAppOutbound().sendBusMessage(
      tour: _tour(),
      busId: 'bus-that-has-nobody',
      messageText: 'બસ 7 વાગ્યે ઉપડશે.. સમયસર પહોંચી જવું..',
    );

    expect(result.results, isEmpty, reason: 'no local rejection was recorded');
    expect(result.failed, 0);
  });
}
