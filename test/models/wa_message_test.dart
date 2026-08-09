import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/wa_message.dart';

/// Guards message direction mapping ('in'/'out' → enum) and the media-kind
/// placeholder used when a non-text message has no body.
void main() {
  WaMessage from(Map<String, dynamic> extra) => WaMessage.fromMap({
        'id': 'm1',
        'conversation_id': 'c1',
        'created_at': '2026-07-09T10:00:00Z',
        ...extra,
      });

  group('direction', () {
    test("'out' maps to outbound", () {
      final m = from({'direction': 'out'});
      expect(m.isOutbound, isTrue);
      expect(m.isInbound, isFalse);
    });

    test("'in' maps to inbound", () {
      final m = from({'direction': 'in'});
      expect(m.isInbound, isTrue);
      expect(m.isOutbound, isFalse);
    });

    test('unknown/missing direction defaults to inbound (safe: shows on left)', () {
      expect(from({}).isInbound, isTrue);
    });
  });

  group('displayBody', () {
    test('text message shows its body', () {
      final m = from({'direction': 'in', 'msg_type': 'text', 'body': 'Hi'});
      expect(m.isText, isTrue);
      expect(m.displayBody, 'Hi');
    });

    test('image with null body shows a photo placeholder', () {
      final m = from({'direction': 'in', 'msg_type': 'image'});
      expect(m.isText, isFalse);
      expect(m.displayBody, '📷 Photo');
    });

    test('document shows a document placeholder', () {
      expect(from({'msg_type': 'document'}).displayBody, '📎 Document');
    });

    test('unknown media kind shows a bracketed type', () {
      expect(from({'msg_type': 'sticker'}).displayBody, '[sticker]');
    });

    test('missing msg_type defaults to text', () {
      final m = from({'direction': 'in', 'body': 'plain'});
      expect(m.msgType, 'text');
      expect(m.displayBody, 'plain');
    });
  });

  // Attachments (migration 059). Before it, every one of these arrived as a
  // bare "[image]" with the file discarded — Meta drops inbound media after
  // ~14 days, so anything not stored on arrival is gone for good.
  group('attachments', () {
    test('a stored photo is renderable, not just labelled', () {
      final m = from({
        'direction': 'in',
        'msg_type': 'image',
        'media_id': 'wamid.MEDIA1',
        'media_path': 'c1/wamid.ABC.jpg',
        'media_mime': 'image/jpeg',
        'media_size': 245760,
      });
      expect(m.isImage, isTrue);
      expect(m.hasAttachment, isTrue);
      expect(m.hasStoredMedia, isTrue);
      expect(m.mediaMissing, isFalse);
      expect(m.mediaSizeLabel, '240 KB');
    });

    test(
      'the caption IS the message — a payment ref must not be reduced to "Photo"',
      () {
        final m = from({
          'direction': 'in',
          'msg_type': 'image',
          'body': 'paid, ref 4471',
          'media_id': 'wamid.MEDIA2',
          'media_path': 'c1/wamid.DEF.jpg',
        });
        expect(m.caption, 'paid, ref 4471');
        expect(m.displayBody, 'paid, ref 4471');
      },
    );

    test('a captionless photo falls back to the placeholder', () {
      final m = from({
        'direction': 'in',
        'msg_type': 'image',
        'media_id': 'wamid.MEDIA3',
        'media_path': 'c1/x.jpg',
      });
      expect(m.caption, isNull);
      expect(m.displayBody, '📷 Photo');
    });

    test('whitespace-only caption counts as no caption', () {
      final m = from({
        'direction': 'in',
        'msg_type': 'image',
        'body': '   ',
        'media_path': 'c1/x.jpg',
      });
      expect(m.caption, isNull);
    });

    test(
      'a known-but-undownloaded attachment reads as missing, not as an empty '
      'message — the admin has to know to ask for it again',
      () {
        final m = from({
          'direction': 'in',
          'msg_type': 'audio',
          'media_id': 'wamid.MEDIA4',
        });
        expect(m.isAudio, isTrue);
        expect(m.hasAttachment, isTrue);
        expect(m.hasStoredMedia, isFalse);
        expect(m.mediaMissing, isTrue);
      },
    );

    test('a plain text message carries no attachment state', () {
      final m = from({'direction': 'in', 'msg_type': 'text', 'body': 'hi'});
      expect(m.hasAttachment, isFalse);
      expect(m.mediaMissing, isFalse);
      expect(m.caption, isNull);
    });

    test('document keeps its filename and reports megabytes', () {
      final m = from({
        'direction': 'in',
        'msg_type': 'document',
        'media_id': 'wamid.MEDIA5',
        'media_path': 'c1/y.pdf',
        'media_filename': 'itinerary.pdf',
        'media_size': 2621440,
      });
      expect(m.isDocument, isTrue);
      expect(m.mediaFilename, 'itinerary.pdf');
      expect(m.mediaSizeLabel, '2.5 MB');
    });

    test('media_size arriving as a string (PostgREST bigint) still parses', () {
      final m = from({'msg_type': 'video', 'media_size': '1048576'});
      expect(m.mediaSize, 1048576);
      expect(m.mediaSizeLabel, '1.0 MB');
    });

    test('rows from a database without the 059 columns still load', () {
      final m = from({'direction': 'in', 'msg_type': 'image'});
      expect(m.mediaId, isNull);
      expect(m.mediaPath, isNull);
      expect(m.mediaSize, isNull);
      expect(m.mediaSizeLabel, isNull);
      expect(m.hasAttachment, isFalse);
      expect(m.displayBody, '📷 Photo');
    });
  });
}
