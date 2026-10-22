import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';

import '../models/wa_conversation.dart';
import '../models/wa_message.dart';
import '../services/sync_service.dart';
import '../services/whatsapp_inbox_service.dart';

/// Owns the admin's live WhatsApp inbox: the list of conversations and the
/// derived unread badge count. Backed by [WhatsAppInboxService], whose realtime
/// streams (RLS-scoped to the signed-in owner + unassigned threads) keep
/// [conversations] fresh. Individual message threads are opened per-screen via
/// [watchMessages] rather than held here, so only the currently-open chat
/// subscribes to its message stream.
///
/// Registered lazily in `app.dart`; [onInit] subscribes and [onClose] tears the
/// subscription down.
class InboxController extends GetxController {
  InboxController({WhatsAppInboxService? service})
      : _service = service ?? WhatsAppInboxService();

  final WhatsAppInboxService _service;

  /// Conversations, newest activity first — kept fresh from
  /// [WhatsAppInboxService.watchConversations].
  final RxList<WaConversation> conversations = <WaConversation>[].obs;

  /// True until the first conversations event arrives.
  final RxBool loading = true.obs;

  /// Sum of unread counts across every visible conversation — drives the nav
  /// tab badge. Recomputed on each stream event; read inside an `Obx`.
  final RxInt _totalUnread = 0.obs;
  RxInt get totalUnread => _totalUnread;

  /// True when the conversation stream errored and has not delivered a list
  /// since. With nothing held this is a "couldn't load" state with Retry —
  /// NOT an empty inbox, which would send the agent off to check WhatsApp
  /// settings on a perfectly wired number.
  final RxBool loadFailed = false.obs;

  StreamSubscription<List<WaConversation>>? _sub;
  Worker? _onlineWorker;
  Timer? _resubscribeTimer;
  int _failures = 0;

  /// Backoff for the automatic re-subscribe after a stream error. Bounded so a
  /// dead link costs one attempt a minute, not a tight loop on the radio.
  @visibleForTesting
  static Duration Function(int failures) resubscribeBackoff = (failures) =>
      Duration(seconds: math.min(60, 5 * (1 << math.min(failures - 1, 4))));

  @override
  void onInit() {
    super.onInit();
    _subscribe();
    // Supabase's `.stream()` re-reads after a realtime REJOIN only if the
    // channel had been joined once before. A stream whose very first read
    // failed (opened offline, or on a link that dropped the request) never
    // recovers on its own — so the edge back online re-subscribes, but only
    // when the last attempt failed.
    if (Get.isRegistered<SyncService>()) {
      _onlineWorker = ever(Get.find<SyncService>().isOnline, (online) {
        if (online && loadFailed.value) retry();
      });
    }
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = _service.watchConversations().listen(
      (rows) {
        conversations.assignAll(rows);
        _totalUnread.value = rows.fold(0, (sum, c) => sum + c.unreadCount);
        loading.value = false;
        loadFailed.value = false;
        _failures = 0;
        _resubscribeTimer?.cancel();
      },
      onError: (_) {
        // Stream error (transient/offline): stop the spinner, keep the last
        // known list, flag the failure, and try again after a backoff.
        loading.value = false;
        loadFailed.value = true;
        _failures++;
        _resubscribeTimer?.cancel();
        _resubscribeTimer = Timer(resubscribeBackoff(_failures), () {
          if (!isClosed && loadFailed.value) _subscribe();
        });
      },
    );
  }

  /// Re-open the conversation stream now (the error state's Retry, or the
  /// online edge). The held list stays on screen while it reconnects.
  void retry() {
    if (isClosed) return;
    _resubscribeTimer?.cancel();
    if (conversations.isEmpty) loading.value = true;
    _subscribe();
  }

  /// Live message thread for one conversation (oldest first). The chat screen
  /// binds directly to this stream.
  Stream<List<WaMessage>> watchMessages(String conversationId) =>
      _service.watchMessages(conversationId);

  /// Sends an admin reply. Never throws — inspect [WaReplyResult.ok] / .error.
  Future<WaReplyResult> sendReply(String conversationId, String text) =>
      _service.sendReply(conversationId: conversationId, text: text);

  /// Short-lived signed URL for a stored attachment (`wa-media` is private —
  /// migration 059). Null when the object is gone or unreadable; the bubble
  /// shows the "couldn't be downloaded" note for both.
  Future<String?> mediaUrl(String mediaPath) => _service.mediaUrl(mediaPath);

  /// Clears a thread's unread badge. The realtime update then re-emits the
  /// conversation with `unread_count = 0`, so [totalUnread] follows.
  Future<void> markRead(String conversationId) =>
      _service.markRead(conversationId);

  @override
  void onClose() {
    _sub?.cancel();
    _sub = null;
    _onlineWorker?.dispose();
    _resubscribeTimer?.cancel();
    super.onClose();
  }
}
