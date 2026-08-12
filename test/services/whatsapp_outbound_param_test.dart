import 'package:flutter_test/flutter_test.dart';
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
