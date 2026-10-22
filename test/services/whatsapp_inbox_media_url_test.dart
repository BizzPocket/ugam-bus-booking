import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/whatsapp_inbox_service.dart';

/// The chat bubble re-asks for its signed URL on every rebuild, and a chat
/// rebuilds on every realtime tick. On a dead link each ask was a storage
/// round-trip that was certain to fail.
void main() {
  test('a failed mint is remembered — rebuilds do not re-request it',
      () async {
    var calls = 0;
    final service = WhatsAppInboxService()
      ..debugCreateSignedUrl = (_) async {
        calls++;
        throw Exception('offline');
      };

    expect(await service.mediaUrl('a.jpg'), isNull);
    expect(await service.mediaUrl('a.jpg'), isNull);
    expect(await service.mediaUrl('a.jpg'), isNull);
    expect(calls, 1);
  });

  test('concurrent asks for one path share a single request', () async {
    var calls = 0;
    final service = WhatsAppInboxService()
      ..debugCreateSignedUrl = (p) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return 'https://signed/$p';
      };

    final urls = await Future.wait([
      service.mediaUrl('b.jpg'),
      service.mediaUrl('b.jpg'),
      service.mediaUrl('b.jpg'),
    ]);
    expect(urls.toSet(), {'https://signed/b.jpg'});
    expect(calls, 1);
    // ...and a success is cached for later rebuilds.
    expect(await service.mediaUrl('b.jpg'), 'https://signed/b.jpg');
    expect(calls, 1);
  });
}
