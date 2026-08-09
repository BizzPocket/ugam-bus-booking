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

  /// Storage bucket holding inbound WhatsApp attachments (migration 059).
  static const _mediaBucket = 'wa-media';

  /// How long a media link stays valid. Long enough to open a document in an
  /// external viewer, short enough that a link leaked from a screenshot or a
  /// share sheet stops working — the bucket is private precisely because these
  /// are customers' photos, voice notes and payment screenshots.
  static const _signedUrlTtl = Duration(hours: 1);

  final Map<String, String> _signedUrlCache = {};

  /// Exchanges a stored [mediaPath] for a temporary signed URL.
  ///
  /// Cached per path for the life of the app process: a chat rebuilds its
  /// bubbles on every realtime tick, and minting a fresh URL each time would
  /// fire one storage round-trip per visible attachment per rebuild — and make
  /// [Image.network] re-download the picture, because the URL is the cache key.
  ///
  /// Returns null when the object is gone or the caller isn't allowed to read
  /// it; the caller shows the "attachment unavailable" state rather than an
  /// error, because from the admin's point of view those are the same thing.
  Future<String?> mediaUrl(String mediaPath) async {
    final cached = _signedUrlCache[mediaPath];
    if (cached != null) return cached;
    try {
      final url = await _client.storage
          .from(_mediaBucket)
          .createSignedUrl(mediaPath, _signedUrlTtl.inSeconds);
      _signedUrlCache[mediaPath] = url;
      return url;
    } catch (_) {
      return null;
    }
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
    } on FunctionException catch (e) {
      // `invoke` THROWS on any non-2xx, so wa-reply's own 401/403/404/500 bodies
      // ("Not authenticated", "Not your conversation", "Conversation not found",
      // "WHATSAPP_TOKEN … not configured") arrive here rather than as data.
      // Left to `e.toString()` they reached the agent as
      // "FunctionException(status: 403, details: {error: ...})" — technically
      // the reason, practically unreadable. Unwrap the body's own message.
      final details = e.details;
      final message = details is Map
          ? (details['error'] ?? details['message'])?.toString()
          : details?.toString();
      return WaReplyResult(
        ok: false,
        error: (message == null || message.trim().isEmpty)
            ? 'HTTP ${e.status}${e.reasonPhrase == null ? '' : ' ${e.reasonPhrase}'}'
            : message.trim(),
      );
    } catch (e) {
      return WaReplyResult(ok: false, error: e.toString());
    }
  }
}
