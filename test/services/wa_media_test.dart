import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/wa_media.dart';

/// Meta caps an image header at 5 MB — an order of magnitude tighter than the
/// 100 MB it allows a document, and easy to cross with a large multi-deck seat
/// chart rendered on a high-DPI device. Over the line, Meta replies with a bare
/// "(#131053) Unable to upload the media used in the message", per recipient,
/// mentioning neither the size nor the limit.
void main() {
  const oneMb = 1024 * 1024;

  group('the seat-chart image', () {
    test('an ordinary PNG chart passes', () {
      expect(
        WaMedia.validateImage(bytes: 900 * 1024, contentType: 'image/png'),
        isNull,
      );
    });

    test('JPEG is accepted too', () {
      expect(
        WaMedia.validateImage(bytes: 2 * oneMb, contentType: 'image/jpeg'),
        isNull,
      );
    });

    test('exactly 5 MB is legal; one byte more is not', () {
      expect(
        WaMedia.validateImage(
          bytes: WaMedia.maxImageBytes,
          contentType: 'image/png',
        ),
        isNull,
      );
      final v = WaMedia.validateImage(
        bytes: WaMedia.maxImageBytes + 1,
        contentType: 'image/png',
      );
      expect(v?.issue, WaMediaIssue.tooLarge);
    });

    test('an over-size chart reports numbers the agent can act on', () {
      final v = WaMedia.validateImage(
        bytes: (6.2 * oneMb).round(),
        contentType: 'image/png',
      );
      expect(v?.issue, WaMediaIssue.tooLarge);
      expect(v?.sizeLabel, '6.2 MB');
      expect(v?.limitLabel, '5 MB',
          reason: 'a bare 131053 says neither of these');
    });

    test('a format Meta does not take as an image is named', () {
      final v = WaMedia.validateImage(
        bytes: 100 * 1024,
        contentType: 'image/webp',
      );
      expect(v?.issue, WaMediaIssue.unsupportedType);
      expect(v?.contentType, 'image/webp');
    });

    test('a PDF is not an image, however small', () {
      expect(
        WaMedia.validateImage(bytes: 1024, contentType: 'application/pdf')
            ?.issue,
        WaMediaIssue.unsupportedType,
      );
    });

    test('an empty render is reported as empty, not as a type problem', () {
      expect(
        WaMedia.validateImage(bytes: 0, contentType: 'image/png')?.issue,
        WaMediaIssue.empty,
      );
    });

    test('a charset suffix and odd casing still match', () {
      // Servers really do label things this way; refusing on it would be a
      // false negative that looks exactly like a genuine media rejection.
      expect(
        WaMedia.validateImage(
          bytes: 1024,
          contentType: 'IMAGE/PNG; charset=binary',
        ),
        isNull,
      );
    });
  });

  group('document rules, recorded for correctness', () {
    test('a PDF is accepted up to 100 MB', () {
      expect(
        WaMedia.validateDocument(
          bytes: 50 * oneMb,
          contentType: 'application/pdf',
        ),
        isNull,
      );
      expect(
        WaMedia.validateDocument(
          bytes: WaMedia.maxDocumentBytes + 1,
          contentType: 'application/pdf',
        )?.issue,
        WaMediaIssue.tooLarge,
      );
    });

    test('the office formats Meta lists are all present', () {
      expect(WaMedia.documentTypes, contains('application/pdf'));
      expect(WaMedia.documentTypes, contains('text/plain'));
      expect(
        WaMedia.documentTypes,
        contains(
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
      );
    });

    test('an image is not a document', () {
      expect(
        WaMedia.validateDocument(bytes: 1024, contentType: 'image/png')?.issue,
        WaMediaIssue.unsupportedType,
      );
    });
  });

  group('the limits themselves', () {
    test('image 5 MB, document 100 MB, video 16 MB', () {
      expect(WaMedia.maxImageBytes, 5 * oneMb);
      expect(WaMedia.maxDocumentBytes, 100 * oneMb);
      expect(WaMedia.maxVideoBytes, 16 * oneMb);
    });

    test('only JPEG and PNG count as images', () {
      expect(WaMedia.imageTypes, {'image/jpeg', 'image/png'});
    });
  });
}
