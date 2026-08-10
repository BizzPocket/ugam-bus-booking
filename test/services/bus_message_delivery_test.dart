import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/wa_template_params.dart';
import 'package:occubusbooking/services/whatsapp_cloud_service.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

/// THE REPORTED BUG (10 Aug 2026): "some bus passengers sometimes don't get the
/// msg i dont know why some get the msg" — plus "we have to send the long msg
/// and sometimes with some emoji and other chars and spaces so at that time it
/// wont work".
///
/// Three separate causes, all of them silent:
///
///   1. [WhatsAppCloudService.graphPhone] only prefixed the country code when
///      the stored number stripped to EXACTLY 10 digits. A number saved the way
///      people actually write it — `0 98765 43210` (trunk prefix) or
///      `0091 …` — stripped to 11 or 14 digits, took no country code, and went
///      to Meta malformed. That ONE recipient silently never received the
///      announcement while everyone else did.
///
///   2. Those riders then vanished from the batch with no trace, so the agent
///      had no way to know who had been skipped.
///
///   3. The Meta length rule was measured with `String.length` — UTF-16 code
///      units — so every emoji counted DOUBLE. An announcement well under
///      Meta's 1024-CHARACTER limit was refused locally as "too long", and the
///      whole send was aborted rather than delivered.
const _bus = 'bus-khodal';

Passenger _p(String id, String phone) => Passenger(
      id: id,
      tourId: 't',
      name: id,
      phone: phone,
      assignedSeats: const [SeatAssignment(busId: _bus, seatId: 'S1')],
    );

Tour _tour(List<Passenger> passengers) => Tour(
      title: 'Guru Purnima',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 8, 10),
      pricePerSeat: 1000,
      passengers: passengers,
    );

void main() {
  group('graphPhone — the numbers that silently never received a message', () {
    test('a domestic trunk prefix (leading 0) still reaches the rider', () {
      // How half of India writes a mobile number in a notebook.
      expect(WhatsAppCloudService.graphPhone('0 98765 43210'), '919876543210');
      expect(WhatsAppCloudService.graphPhone('09876543210'), '919876543210');
    });

    test('an international access prefix (0091) is normalised', () {
      expect(WhatsAppCloudService.graphPhone('0091 98765 43210'),
          '919876543210');
    });

    test('the formats that already worked keep working', () {
      const want = '919876543210';
      expect(WhatsAppCloudService.graphPhone('9876543210'), want);
      expect(WhatsAppCloudService.graphPhone('+91 98765 43210'), want);
      expect(WhatsAppCloudService.graphPhone('+91-98765-43210'), want);
      expect(WhatsAppCloudService.graphPhone('919876543210'), want);
      expect(WhatsAppCloudService.graphPhone('+919876543210'), want);
    });

    test('a number too short to dial resolves to empty, not to garbage', () {
      // Previously '12345' was handed to Meta verbatim and failed upstream with
      // an opaque error. An undialable number must be recognisable as such.
      expect(WhatsAppCloudService.graphPhone('12345'), '');
      expect(WhatsAppCloudService.graphPhone(''), '');
      expect(WhatsAppCloudService.graphPhone('abc'), '');
    });

    test('a genuine foreign number is passed through untouched', () {
      // Not every rider is Indian; a real country code must not be rewritten.
      expect(WhatsAppCloudService.graphPhone('+1 202 555 0143'), '12025550143');
    });
  });

  group('recipients — nobody is dropped without being named', () {
    test('a trunk-prefixed rider is now in the batch', () {
      final tour = _tour([
        _p('trunk-prefix', '09876543210'),
        _p('normal', '+919825588226'),
      ]);

      expect(
        WhatsAppOutbound.busMessageRecipients(tour, _bus),
        ['919876543210', '919825588226'],
      );
    });

    test('the same rider written two ways still collapses to one message', () {
      final tour = _tour([
        _p('a', '09924902371'),
        _p('b', '+91 99249 02371'),
      ]);
      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus),
          ['919924902371']);
    });

    test('riders with an undialable phone are REPORTED, not silently skipped',
        () {
      final tour = _tour([
        _p('no-phone', ''),
        _p('junk-phone', '12345'),
        _p('reachable', '+919825588226'),
      ]);

      final unreachable = WhatsAppOutbound.unreachableBusRiders(tour, _bus);

      expect(
        unreachable.map((p) => p.id),
        ['no-phone', 'junk-phone'],
        reason: 'the agent must be told exactly who to contact by hand',
      );
      expect(WhatsAppOutbound.busMessageRecipients(tour, _bus),
          ['919825588226']);
    });

    test('every rider reachable → nothing to report', () {
      final tour = _tour([_p('a', '9876543210'), _p('b', '09825588226')]);
      expect(WhatsAppOutbound.unreachableBusRiders(tour, _bus), isEmpty);
    });
  });

  group('an unaddressable message never reaches the wire', () {
    test('a batch of only blank recipients fails locally and is reported',
        () async {
      // graphPhone now returns '' for a number it cannot make dialable. Every
      // send path feeds that straight into `to:`, so the guard lives in send()
      // itself — one place no caller can bypass. Reaching the network with a
      // blank `to` risks Meta refusing the WHOLE chunk and taking the valid
      // recipients down with it.
      final result = await WhatsAppCloudService().send(const [
        WaMessage(to: '', template: 'bus_msg', bodyParams: ['hi']),
        WaMessage(to: '   ', template: 'bus_msg', bodyParams: ['hi']),
      ]);

      expect(result.anySent, isFalse);
      expect(result.failed, 2, reason: 'both are counted, not discarded');
      expect(result.results, hasLength(2));
      expect(result.results.first.error, contains('No usable WhatsApp number'));
    });

    test('an empty batch is still just empty', () async {
      expect(
        (await WhatsAppCloudService().send(const [])).results,
        isEmpty,
      );
    });
  });

  group('length is measured in CHARACTERS, the way Meta counts', () {
    test('an emoji-rich message under the limit is not refused', () {
      // 600 emoji = 600 characters to Meta, but 1200 UTF-16 code units to Dart.
      // Counting code units refused this as "too long" at 1200 > 1024.
      final emoji = '🙏' * 600;
      expect(emoji.length, 1200, reason: 'Dart counts UTF-16 code units');
      expect(emoji.runes.length, 600, reason: 'Meta counts characters');

      expect(
        WaTemplateParams.validateOne(emoji),
        isEmpty,
        reason: '600 characters is comfortably inside Meta\'s 1024 limit',
      );
    });

    test('a genuinely over-length message is still refused', () {
      final tooLong = 'ક' * (WaTemplateParams.maxBodyChars + 1);
      expect(
        WaTemplateParams.validateOne(tooLong).map((v) => v.issue),
        [WaParamIssue.tooLong],
      );
      // …and so is an emoji message that really does exceed the limit.
      final tooManyEmoji = '🙏' * (WaTemplateParams.maxBodyChars + 1);
      expect(
        WaTemplateParams.validateOne(tooManyEmoji).map((v) => v.issue),
        [WaParamIssue.tooLong],
      );
    });

    test('the reported length is the CHARACTER count, not the code-unit count',
        () {
      final tooManyEmoji = '🙏' * 1100;
      final v = WaTemplateParams.validateOne(tooManyEmoji).single;
      expect(v.count, 1100, reason: 'tell the agent how many characters over');
    });

    test('emoji survive the auto-repair untouched', () {
      const typed = 'બસ 7 વાગ્યે ઉપડશે 🙏\n\nસમયસર પહોંચી જવું 🚌';
      final fixed = WaTemplateParams.sanitize(typed);
      expect(fixed, contains('🙏'));
      expect(fixed, contains('🚌'));
      expect(WaTemplateParams.validateOne(fixed), isEmpty);
    });
  });

  group('a long multi-paragraph announcement actually gets sent', () {
    test('line breaks are repaired and the send proceeds', () async {
      // The exact shape that used to reach NOBODY: the composer refused it and
      // the service refused it, so a perfectly ordinary two-paragraph notice
      // simply never went out. Meta will not accept the line break — but the
      // announcement must still be delivered, with the break collapsed.
      final result = await WhatsAppOutbound().sendBusMessage(
        tour: _tour([]),
        busId: 'bus-with-nobody',
        messageText: 'પહેલો ફકરો.. 🙏\n\nબીજો ફકરો.. સમયસર પહોંચી જવું..',
      );

      expect(
        result.results,
        isEmpty,
        reason: 'no local rejection — the text was repaired, not refused',
      );
      expect(result.failed, 0);
    });

    test('tabs and long space runs are repaired too', () async {
      final result = await WhatsAppOutbound().sendBusMessage(
        tour: _tour([]),
        busId: 'bus-with-nobody',
        messageText: 'બસ\t7 વાગ્યે${' ' * 8}ઉપડશે..',
      );
      expect(result.results, isEmpty);
      expect(result.failed, 0);
    });

    test('an empty message is still refused — there is nothing to repair',
        () async {
      final result = await WhatsAppOutbound().sendBusMessage(
        tour: _tour([_p('a', '+919825588226')]),
        busId: _bus,
        messageText: '   ',
      );
      expect(result.anySent, isFalse);
      expect(result.results.single.error, contains('empty'));
    });

    test('an over-length message is still refused — a human must shorten it',
        () async {
      final result = await WhatsAppOutbound().sendBusMessage(
        tour: _tour([_p('a', '+919825588226')]),
        busId: _bus,
        messageText: 'ક' * 1100,
      );
      expect(result.anySent, isFalse);
      expect(result.results.single.error, contains('tooLong'));
    });
  });
}
