import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/services/wa_template_params.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

/// The seat-flow parameters were never validated.
///
/// `_buildAllocationMessage` passed `tour.title`, `bus.customerLabel`,
/// `boardingPoint` and `handlerContact` straight into `bodyParams` behind a
/// bare `trim()`. Every one of those is operator-entered or operator-derived,
/// and Meta refuses a template parameter containing a new-line with `132000`
/// — PER RECIPIENT.
///
/// So a boarding point somebody typed across two lines cost every passenger on
/// that bus their allotment message, while the rest of the tour received
/// theirs and nothing on screen connected the two. That is the shape of the
/// standing "some passengers don't get the msg" report, and it is what these
/// tests exist to stop coming back.
void main() {
  group('the allotment message names the bus the way its chart does', () {
    // The rider gets a photo of the seat chart with "Raj · GJ05HU7162" printed
    // on it, and a line of text above it. If that line says only "Raj" they are
    // reading two different names for one vehicle, and in a car park with two
    // coaches called Raj the plate is the only thing that resolves it. This
    // flipped once (plate-on-charts-only); these tests are what stops it
    // flipping back by accident.
    test('the plate rides along with the name', () {
      expect(
        WhatsAppOutbound.allocationBusLabel(
          Bus(id: 'b1', name: 'Raj', busNumber: 'GJ05HU7162'),
        ),
        'Raj · GJ05HU7162',
      );
    });

    test('it is the SAME string the chart image and the A4 print carry', () {
      final bus = Bus(id: 'b1', name: 'જય વાલમ', busNumber: 'GJ 05 HU 7162');
      expect(WhatsAppOutbound.allocationBusLabel(bus), bus.displayLabel);
    });

    test('a bus with no plate entered yet degrades to the bare name', () {
      expect(
        WhatsAppOutbound.allocationBusLabel(Bus(id: 'b1', name: 'Raj')),
        'Raj',
      );
    });

    test('the separator survives sanitizing — Meta gets the whole label', () {
      final sent = WhatsAppOutbound.paramValue(
        WhatsAppOutbound.allocationBusLabel(
          Bus(id: 'b1', name: 'Raj', busNumber: 'GJ05HU7162'),
        ),
      );
      expect(sent, 'Raj · GJ05HU7162');
      expect(WaTemplateParams.validateOne(sent), isEmpty);
    });

    test('a plate typed across two lines is repaired, not refused', () {
      final sent = WhatsAppOutbound.paramValue(
        WhatsAppOutbound.allocationBusLabel(
          Bus(id: 'b1', name: 'Raj', busNumber: 'GJ05\nHU7162'),
        ),
      );
      expect(WaTemplateParams.validateOne(sent), isEmpty);
      expect(sent, 'Raj · GJ05 HU7162');
    });

    test('an unseated passenger still sends — a blank bus becomes a dash', () {
      expect(WhatsAppOutbound.allocationBusLabel(null), '');
      expect(
        WhatsAppOutbound.paramValue(WhatsAppOutbound.allocationBusLabel(null)),
        '—',
        reason: 'Meta rejects an empty parameter with 132000',
      );
    });
  });

  group('every parameter is repaired before it is sent', () {
    test('a boarding point typed across two lines is joined, not refused', () {
      const typed = 'ગામ ના પાદર\nબસ સ્ટેન્ડ પાસે';
      final sent = WhatsAppOutbound.paramValue(typed);

      expect(WaTemplateParams.validateOne(sent), isEmpty);
      expect(sent, 'ગામ ના પાદર બસ સ્ટેન્ડ પાસે');
    });

    test('a tab in a handler contact line is repaired', () {
      expect(
        WaTemplateParams.validateOne(
          WhatsAppOutbound.paramValue('Rameshbhai\t98765 43210'),
        ),
        isEmpty,
      );
    });

    test('a run of spaces from a copy-paste is collapsed', () {
      expect(
        WhatsAppOutbound.paramValue('Dwarka${' ' * 8}Yatra'),
        'Dwarka Yatra',
      );
    });

    test('a Windows line ending counts as a line break too', () {
      expect(
        WaTemplateParams.validateOne(
          WhatsAppOutbound.paramValue('Bus 1\r\nAC Sleeper'),
        ),
        isEmpty,
      );
    });
  });

  group('blank values still become a dash', () {
    test('Meta rejects an empty parameter, so nothing empty is sent', () {
      expect(WhatsAppOutbound.paramValue(''), '—');
      expect(WhatsAppOutbound.paramValue('   '), '—');
      expect(WhatsAppOutbound.paramValue('\n\n'), '—',
          reason: 'whitespace that sanitizes to nothing is still nothing');
    });
  });

  group('what must NOT change', () {
    test('an ordinary value passes through untouched', () {
      const ordinary = 'જય વાલમ બસ – ગામ ના પાદર';
      expect(WhatsAppOutbound.paramValue(ordinary), ordinary);
    });

    test('exactly four spaces are legal and are preserved', () {
      expect(WhatsAppOutbound.paramValue('a${' ' * 4}b'), 'a${' ' * 4}b');
    });

    test('an emoji survives — repair must not strip characters', () {
      expect(WhatsAppOutbound.paramValue('શુભ યાત્રા 🙏'), 'શુભ યાત્રા 🙏');
    });

    test('length is never truncated — that needs a human', () {
      final long = 'ક' * 1200;
      expect(WhatsAppOutbound.paramValue(long).length, 1200);
    });
  });
}
