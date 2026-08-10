import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/wa_template_params.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

// Defence-in-depth: even if a composer's pre-flight check were bypassed, an
// announcement Meta cannot accept must never reach the wire.
//
// "Cannot accept" now splits in two, because refusing everything meant a long
// multi-paragraph notice reached NOBODY:
//   * REPAIRABLE (line break / tab / 5+ spaces) — collapsed to the nearest
//     legal text and SENT. Flattened line breaks are the only way that message
//     can legally travel, and the operator needs it delivered.
//   * UNSENDABLE (empty, or over the character limit) — still refused, as a
//     normal per-recipient failure carrying a readable reason, because that is
//     the shape every caller already renders and only a human can fix it.

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
  test('a message with a line break is REPAIRED and allowed through', () async {
    // Sent to a bus with nobody on it, so the call stops at recipient selection
    // instead of reaching the network: an empty result proves the guard did not
    // reject the text. Previously this was refused outright and the operator's
    // two-paragraph announcement reached no one.
    final result = await WhatsAppOutbound().sendBusMessage(
      tour: _tour(),
      busId: 'bus-that-has-nobody',
      messageText: 'પહેલો ફકરો..\n\nબીજો ફકરો..',
    );

    expect(result.results, isEmpty, reason: 'no local rejection was recorded');
    expect(result.failed, 0);
  });

  test('what a repaired message puts on the wire is Meta-legal', () {
    // The invariant the repair has to preserve: whatever the agent types, the
    // body parameter that actually travels breaks none of Meta's rules.
    const typed = 'પહેલો ફકરો..\n\nબીજો ફકરો..\tત્રીજો..';
    expect(WaTemplateParams.validateOne(typed), isNotEmpty);
    expect(WaTemplateParams.validateOne(WaTemplateParams.sanitize(typed)),
        isEmpty);
  });

  test('an empty message is refused — there is nothing to repair', () async {
    final result = await WhatsAppOutbound().sendBusMessage(
      tour: _tour(),
      busId: _bus,
      messageText: '  \n\t ',
    );

    expect(result.anySent, isFalse);
    expect(result.failed, 1);
    expect(result.results.single.error, contains('empty'));
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
