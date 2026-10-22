import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/whatsapp_cloud_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The chart image a WhatsApp send carries is uploaded first. On a lossy 2G
/// uplink that upload is the likeliest step to drop.
void main() {
  final originalDelay = WhatsAppCloudService.uploadRetryDelay;
  setUp(() => WhatsAppCloudService.uploadRetryDelay = Duration.zero);
  tearDown(() => WhatsAppCloudService.uploadRetryDelay = originalDelay);

  final bytes = Uint8List.fromList([1, 2, 3]);

  test('a dropped upload is retried once (upsert to a fixed path is safe)',
      () async {
    var calls = 0;
    final svc = WhatsAppCloudService()
      ..debugUpload = (_, _, _, _) async {
        calls++;
        if (calls == 1) throw const SocketException('connection reset');
      };
    await svc.debugUpsert('seat-charts', 't1/b1.png', bytes, 'image/png');
    expect(calls, 2);
  });

  test('a storage REFUSAL is not retried', () async {
    var calls = 0;
    final svc = WhatsAppCloudService()
      ..debugUpload = (_, _, _, _) async {
        calls++;
        throw StorageException('new row violates row-level security',
            statusCode: '403');
      };
    await expectLater(
      svc.debugUpsert('seat-charts', 't1/b1.png', bytes, 'image/png'),
      throwsA(isA<StorageException>()),
    );
    expect(calls, 1);
  });

  test('a link that stays down fails after the second attempt', () async {
    var calls = 0;
    final svc = WhatsAppCloudService()
      ..debugUpload = (_, _, _, _) async {
        calls++;
        throw const SocketException('network is unreachable');
      };
    await expectLater(
      svc.debugUpsert('seat-charts', 't1/b1.png', bytes, 'image/png'),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 2);
  });
}
