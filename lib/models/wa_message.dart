/// Direction of a message in a WhatsApp thread. `'in'` = from the customer,
/// `'out'` = the agent's reply.
enum WaDirection { inbound, outbound }

/// A single message in a WhatsApp thread (migration 033, `wa_messages`).
///
/// A message is either text or an attachment. For an attachment [msgType] names
/// the kind, [body] holds the CAPTION when the customer typed one, and the
/// media_* fields (migration 059) locate the stored bytes in the private
/// `wa-media` bucket. [waMessageId] is Meta's message id (inbound) or the Graph
/// send-response id (outbound), used to de-duplicate webhook re-deliveries.
class WaMessage {
  final String id;
  final String conversationId;
  final String? waMessageId;
  final WaDirection direction;
  final String? body;
  final String msgType;
  final String? status;
  final DateTime createdAt;

  /// Meta's media id. Present for every attachment, INCLUDING one whose download
  /// failed — so `mediaId != null && mediaPath == null` means "we know an
  /// attachment was sent and we do not have it".
  final String? mediaId;

  /// Object path inside the private `wa-media` bucket, `<conversationId>/<file>`.
  /// Null until the bytes are stored. Not a URL: the screen exchanges it for a
  /// short-lived signed URL, since the bucket is private on purpose.
  final String? mediaPath;

  final String? mediaMime;
  final String? mediaFilename;
  final int? mediaSize;

  const WaMessage({
    required this.id,
    required this.conversationId,
    this.waMessageId,
    required this.direction,
    this.body,
    this.msgType = 'text',
    this.status,
    required this.createdAt,
    this.mediaId,
    this.mediaPath,
    this.mediaMime,
    this.mediaFilename,
    this.mediaSize,
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
        // Read defensively: these columns arrive only once 059 is applied, and
        // a build that reaches a database without them must still show the
        // thread rather than throw on every row.
        mediaId: map['media_id']?.toString(),
        mediaPath: map['media_path']?.toString(),
        mediaMime: map['media_mime']?.toString(),
        mediaFilename: map['media_filename']?.toString(),
        mediaSize: _parseInt(map['media_size']),
      );

  bool get isInbound => direction == WaDirection.inbound;
  bool get isOutbound => direction == WaDirection.outbound;
  bool get isText => msgType == 'text';

  /// True when this message carries an attachment, downloaded or not.
  bool get hasAttachment => (mediaId ?? '').isNotEmpty || hasStoredMedia;

  /// True when the bytes are actually in the bucket and can be shown.
  bool get hasStoredMedia => (mediaPath ?? '').isNotEmpty;

  /// An attachment we know about but could not fetch. Rendered as an explicit
  /// "attachment unavailable" note — silently showing nothing would read as the
  /// customer having sent an empty message.
  bool get mediaMissing => hasAttachment && !hasStoredMedia;

  /// Renders inline as a picture. Sticker folds into image at ingest.
  bool get isImage => msgType == 'image';

  /// Plays in an audio bar (voice notes fold into audio at ingest).
  bool get isAudio => msgType == 'audio';

  bool get isVideo => msgType == 'video';
  bool get isDocument => msgType == 'document';

  /// The caption the customer typed with the attachment, if any.
  String? get caption {
    if (isText) return null;
    final c = body?.trim();
    return (c == null || c.isEmpty) ? null : c;
  }

  /// Human file size for the attachment row ("2.4 MB"). Null when unknown.
  String? get mediaSizeLabel {
    final b = mediaSize;
    if (b == null || b <= 0) return null;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// The text to render. For text messages, the body; for an attachment, the
  /// customer's caption when they typed one, else a plain placeholder. Screens
  /// may substitute a localized string for known media kinds — this is the
  /// language-neutral fallback.
  String get displayBody {
    if (isText) return body ?? '';
    final c = caption;
    if (c != null) return c;
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

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}
