import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/wa_conversation.dart';
import '../models/wa_message.dart';

/// Outcome of a single admin reply sent through the `wa-reply` Edge Function.
///
/// The function decides the send channel by WhatsApp's 24h customer-service
/// window: `session` = free-text (window open), `template` = approved template
/// (window closed / never inbound). On any failure — a Graph error or a
/// transport/parse exception — [ok] is false and [error] carries the reason;
/// the service NEVER throws on a per-send failure.
class WaReplyResult {
  final bool ok;
  final String? error;

  /// `'session'` | `'template'` when [ok]; null on failure.
  final String? channel;

  const WaReplyResult({required this.ok, this.error, this.channel});
}

/// Client for the two-way WhatsApp inbox (migration 033). Wraps the
/// `wa_conversations` / `wa_messages` Supabase realtime streams, the
/// `wa_mark_read` RPC, and the `wa-reply` Edge Function.
///
/// RLS already scopes every row to the signed-in owner (`owner_id = auth.uid()`
/// OR unassigned), so no client-side owner filter is applied here — reads see
/// exactly the admin's own threads plus any unassigned ones.
class WhatsAppInboxService {
  SupabaseClient get _client => Supabase.instance.client;

  /// Live list of conversations, newest activity first. Backed by a realtime
  /// subscription — emits on every insert/update/delete of a visible row.
  Stream<List<WaConversation>> watchConversations() {
    return _client
        .from('wa_conversations')
        .stream(primaryKey: ['id'])
        .order('last_message_at', ascending: false)
        .map(
          (rows) => rows
              .map((r) => WaConversation.fromMap(Map<String, dynamic>.from(r)))
              .toList(),
        );
  }

  /// Live message thread for one conversation, oldest first (chat order).
  Stream<List<WaMessage>> watchMessages(String conversationId) {
    return _client
        .from('wa_messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map(
          (rows) => rows
              .map((r) => WaMessage.fromMap(Map<String, dynamic>.from(r)))
              .toList(),
        );
  }

  /// Clears a thread's unread badge via the owner-scoped `wa_mark_read` RPC.
  Future<void> markRead(String conversationId) async {
    await _client.rpc(
      'wa_mark_read',
      params: {'p_conversation_id': conversationId},
    );
  }

  /// Sends an admin's free-text reply on [conversationId]. Routes through the
  /// `wa-reply` Edge Function (which picks session vs template by the 24h
  /// window, sends via the Graph API, then logs the outbound message). Never
  /// throws on a per-send failure — returns `WaReplyResult(ok: false, error: …)`
  /// on a Graph error or any transport/parse exception.
  Future<WaReplyResult> sendReply({
    required String conversationId,
    required String text,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'wa-reply',
        body: {'conversationId': conversationId, 'text': text},
      );
      final data = res.data;
      if (data is Map) {
        return WaReplyResult(
          ok: data['ok'] == true,
          error: data['error']?.toString(),
          channel: data['channel']?.toString(),
        );
      }
      return WaReplyResult(ok: false, error: 'Unexpected reply: $data');
    } catch (e) {
      return WaReplyResult(ok: false, error: e.toString());
    }
  }
}
