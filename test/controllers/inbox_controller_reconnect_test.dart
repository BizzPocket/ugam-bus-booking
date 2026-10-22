import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/inbox_controller.dart';
import 'package:occubusbooking/models/wa_conversation.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/services/whatsapp_inbox_service.dart';

class _Sync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// Each subscription gets its own controller, so a test can fail the first
/// and answer the second — the "opened offline, signal came back" case.
class _FakeInbox extends WhatsAppInboxService {
  final streams = <StreamController<List<WaConversation>>>[];

  @override
  Stream<List<WaConversation>> watchConversations() {
    final c = StreamController<List<WaConversation>>();
    streams.add(c);
    return c.stream;
  }
}

void main() {
  final originalBackoff = InboxController.resubscribeBackoff;
  late _Sync sync;
  late _FakeInbox service;
  late InboxController ctrl;

  setUp(() {
    Get.reset();
    sync = _Sync();
    Get.put<SyncService>(sync);
    service = _FakeInbox();
    // Long backoff: these tests drive recovery through the online edge.
    InboxController.resubscribeBackoff = (_) => const Duration(hours: 1);
    ctrl = Get.put(InboxController(service: service));
  });

  tearDown(() {
    InboxController.resubscribeBackoff = originalBackoff;
    Get.reset();
  });

  test('a stream that failed with nothing held reports loadFailed, not empty',
      () async {
    service.streams.single.addError(Exception('offline'));
    await pumpEventQueue();

    expect(ctrl.loading.value, isFalse);
    expect(ctrl.loadFailed.value, isTrue);
    expect(ctrl.conversations, isEmpty);
  });

  test('the online edge re-subscribes a failed inbox, exactly once', () async {
    service.streams.single.addError(Exception('offline'));
    await pumpEventQueue();

    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await pumpEventQueue();
    expect(service.streams, hasLength(2));

    service.streams.last.add(const <WaConversation>[]);
    await pumpEventQueue();
    expect(ctrl.loadFailed.value, isFalse);

    // Healthy now — further flaps must not churn the realtime channel.
    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await pumpEventQueue();
    expect(service.streams, hasLength(2));
  });

  test('after an error the stream re-subscribes on its own backoff', () async {
    InboxController.resubscribeBackoff =
        (_) => const Duration(milliseconds: 10);
    service.streams.single.addError(Exception('offline'));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(service.streams.length, greaterThanOrEqualTo(2));
  });
}
