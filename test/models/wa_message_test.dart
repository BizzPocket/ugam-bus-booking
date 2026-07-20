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
}
