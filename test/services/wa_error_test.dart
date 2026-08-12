import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/wa_error.dart';

void main() {
  group('132000 — the overloaded code', () {
    // The single most misleading error in the system: one code, two problems,
    // opposite remedies. One is fixed by tapping Fix automatically; the other
    // means the app's variable contract and the Meta template have drifted and
    // no amount of editing the text will help.
    test('the new-line variant is a fixable text problem', () {
      final info = WaError.classify(
        message: '(#132000) Param text cannot have new-line/tab characters or '
            'more than 4 consecutive spaces',
      );
      expect(info.cause, WaErrorCause.paramFormatting);
      expect(info.code, 132000);
      expect(info.isFixableHere, isTrue);
    });

    test('the count variant is a template-contract problem', () {
      final info = WaError.classify(
        code: 132000,
        message: '(#132000) Number of parameters does not match the expected '
            'number of params',
      );
      expect(info.cause, WaErrorCause.paramCountMismatch);
      expect(info.isFixableHere, isFalse,
          reason: 'editing the message cannot fix a variable-count drift');
      expect(info.isRetryable, isFalse);
    });
  });

  group('the code is recovered even when the server does not send one', () {
    test('from Meta\'s (#nnnnn) prefix', () {
      expect(
        WaError.classify(message: '(#132001) Template name does not exist').cause,
        WaErrorCause.templateNotFound,
      );
    });

    test('an explicit code wins over the prefix', () {
      final info = WaError.classify(code: 131026, message: 'something else');
      expect(info.cause, WaErrorCause.notWhatsAppUser);
      expect(info.code, 131026);
    });

    test('the raw Meta text is always preserved', () {
      const raw = '(#99999) Some brand new Meta error';
      final info = WaError.classify(message: raw);
      expect(info.cause, WaErrorCause.unknown);
      expect(info.rawMessage, raw,
          reason: 'an unmapped code must never be LESS informative than before');
    });
  });

  group('every mapped code lands on its cause', () {
    const cases = <int, WaErrorCause>{
      132001: WaErrorCause.templateNotFound,
      132005: WaErrorCause.bodyTooLong,
      132007: WaErrorCause.templatePolicy,
      132012: WaErrorCause.templateFormatMismatch,
      132015: WaErrorCause.templatePaused,
      132016: WaErrorCause.templateDisabled,
      131026: WaErrorCause.notWhatsAppUser,
      131047: WaErrorCause.outsideWindow,
      131053: WaErrorCause.mediaRejected,
      133010: WaErrorCause.senderNotRegistered,
      190: WaErrorCause.authFailed,
      130429: WaErrorCause.rateLimited,
      131009: WaErrorCause.badRequest,
    };

    for (final entry in cases.entries) {
      test('${entry.key} → ${entry.value.name}', () {
        expect(WaError.classify(code: entry.key).cause, entry.value);
      });
    }
  });

  group('locally generated failures join the same presentation', () {
    test('a missing token is recognised as a setup problem', () {
      expect(
        WaError.classify(
          message: 'WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID not configured',
        ).cause,
        WaErrorCause.configMissing,
      );
    });

    test('an undialable phone is recognised', () {
      expect(
        WaError.classify(
          message: 'No usable WhatsApp number on file for Ramesh — contact '
              'them by phone.',
        ).cause,
        WaErrorCause.noNumberOnFile,
      );
    });

    test('a chart render failure is distinct from Meta rejecting the media', () {
      expect(
        WaError.classify(message: 'Seat chart failed: rasteriser error').cause,
        WaErrorCause.chartFailed,
      );
      expect(WaError.classify(code: 131053).cause, WaErrorCause.mediaRejected);
    });

    test('nothing at all is unknown, not a crash', () {
      expect(WaError.classify().cause, WaErrorCause.unknown);
      expect(WaError.classify(message: '').cause, WaErrorCause.unknown);
    });
  });

  group('retry is offered only where it could work', () {
    test('rate limits and chart failures are worth retrying', () {
      expect(WaError.classify(code: 130429).isRetryable, isTrue);
      expect(
        WaError.classify(message: 'Seat chart failed: boom').isRetryable,
        isTrue,
      );
    });

    test('a disabled template or a non-WhatsApp number is not', () {
      expect(WaError.classify(code: 132016).isRetryable, isFalse);
      expect(WaError.classify(code: 131026).isRetryable, isFalse,
          reason: 'it will fail identically every time — phone them instead');
    });
  });

  group('grouping a batch by cause', () {
    test('most-affected cause comes first', () {
      final failures = [
        WaError.classify(code: 131026),
        WaError.classify(code: 132015),
        WaError.classify(code: 131026),
        WaError.classify(code: 131026),
        WaError.classify(code: 132015),
      ];
      final grouped = WaError.groupByCause(failures, (f) => f);

      expect(grouped.first.key, WaErrorCause.notWhatsAppUser);
      expect(grouped.first.value, hasLength(3));
      expect(grouped[1].key, WaErrorCause.templatePaused);
      expect(grouped[1].value, hasLength(2));
    });

    test('equal counts keep first-seen order rather than reshuffling', () {
      final failures = [
        WaError.classify(code: 132015),
        WaError.classify(code: 131026),
      ];
      final grouped = WaError.groupByCause(failures, (f) => f);
      expect(grouped.map((e) => e.key), [
        WaErrorCause.templatePaused,
        WaErrorCause.notWhatsAppUser,
      ]);
    });

    test('an empty batch groups to nothing', () {
      expect(WaError.groupByCause(<WaErrorInfo>[], (f) => f), isEmpty);
    });
  });
}
