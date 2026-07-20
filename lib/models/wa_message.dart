/// Direction of a message in a WhatsApp thread. `'in'` = from the customer,
/// `'out'` = the agent's reply.
enum WaDirection { inbound, outbound }

/// A single message in a WhatsApp thread (migration 033, `wa_messages`).
///
/// Text is the only body captured today; other media kinds (`image`,
/// `document`, …) are recorded by [msgType] with a null [body] and rendered as a
/// localized placeholder — see [displayBody]. [waMessageId] is Meta's message id
/// (inbound) or the Graph send-response id (outbound), used to de-duplicate
/// webhook re-deliveries.
class WaMessage {
  final String id;
  final String conversationId;
  final String? waMessageId;
  final WaDirection direction;
  final String? body;
  final String msgType;
  final String? status;
  final DateTime createdAt;

  const WaMessage({
    required this.id,
    required this.conversationId,
    this.waMessageId,
    required this.direction,
    this.body,
    this.msgType = 'text',
    this.status,
    required this.createdAt,
  });

  factory WaMessage.fromMap(Map<String, dynamic> map) => WaMessage(
        id: map['id'] as String,
        conversationId: (map['conversation_id'] as String?) ?? '',
        waMessageId: map['wa_message_id']?.toString(),
        direction: (map['direction']?.toString() == 'out')
            ? WaDirection.outbound
            : WaDirection.inbound,
        body: map['body'] as String?,
        msgType: (map['msg_type'] as String?)?.trim().isNotEmpty ?? false
            ? (map['msg_type'] as String).trim()
            : 'text',
        status: map['status'] as String?,
        createdAt: _parseDate(map['created_at']) ?? DateTime.now(),
      );

  bool get isInbound => direction == WaDirection.inbound;
  bool get isOutbound => direction == WaDirection.outbound;
  bool get isText => msgType == 'text';

  /// The text to render. For text messages, the body; for other kinds, a plain
  /// placeholder. Screens may substitute a localized string for known media
  /// kinds (image/document) — this is the language-neutral fallback.
  String get displayBody {
    if (isText) return body ?? '';
    switch (msgType) {
      case 'image':
        return '📷 Photo';
      case 'document':
        return '📎 Document';
      case 'audio':
      case 'voice':
        return '🎤 Audio';
      case 'video':
        return '🎥 Video';
      default:
        return '[$msgType]';
    }
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}
