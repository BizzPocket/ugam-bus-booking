import 'dart:async';

import 'package:get/get.dart';

import '../models/wa_conversation.dart';
import '../models/wa_message.dart';
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

  StreamSubscription<List<WaConversation>>? _sub;

  @override
  void onInit() {
    super.onInit();
    _sub = _service.watchConversations().listen(
      (rows) {
        conversations.assignAll(rows);
        _totalUnread.value = rows.fold(0, (sum, c) => sum + c.unreadCount);
        loading.value = false;
      },
      onError: (_) {
        // Stream error (transient/offline): stop the spinner, keep the last
        // known list. Realtime reconnects and re-emits on recovery.
        loading.value = false;
      },
    );
  }

  /// Live message thread for one conversation (oldest first). The chat screen
  /// binds directly to this stream.
  Stream<List<WaMessage>> watchMessages(String conversationId) =>
      _service.watchMessages(conversationId);

  /// Sends an admin reply. Never throws — inspect [WaReplyResult.ok] / .error.
  Future<WaReplyResult> sendReply(String conversationId, String text) =>
      _service.sendReply(conversationId: conversationId, text: text);

  /// Clears a thread's unread badge. The realtime update then re-emits the
  /// conversation with `unread_count = 0`, so [totalUnread] follows.
  Future<void> markRead(String conversationId) =>
      _service.markRead(conversationId);

  @override
  void onClose() {
    _sub?.cancel();
    _sub = null;
    super.onClose();
  }
}
