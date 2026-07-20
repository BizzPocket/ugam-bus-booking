/// One customer WhatsApp thread in the two-way inbox (migration 033,
/// `wa_conversations`). There is exactly one row per customer phone number.
///
/// [ownerId] is the admin the thread was routed to (resolved from the customer's
/// most-recent tour); it is null while a thread is "unassigned" (an inbound from
/// a number that matches no booking yet). [lastInboundAt] drives the 24-hour
/// free-reply window — see [windowOpen].
class WaConversation {
  final String id;
  final String? ownerId;
  final String customerPhone;
  final String? customerName;
  final DateTime lastMessageAt;
  final String? lastMessagePreview;
  final DateTime? lastInboundAt;
  final int unreadCount;

  const WaConversation({
    required this.id,
    this.ownerId,
    required this.customerPhone,
    this.customerName,
    required this.lastMessageAt,
    this.lastMessagePreview,
    this.lastInboundAt,
    this.unreadCount = 0,
  });

  factory WaConversation.fromMap(Map<String, dynamic> map) => WaConversation(
        id: map['id'] as String,
        ownerId: map['owner_id']?.toString(),
        customerPhone: (map['customer_phone'] as String?) ?? '',
        customerName: (map['customer_name'] as String?)?.trim().isEmpty ?? true
            ? null
            : (map['customer_name'] as String).trim(),
        lastMessageAt:
            _parseDate(map['last_message_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        lastMessagePreview: map['last_message_preview'] as String?,
        lastInboundAt: _parseDate(map['last_inbound_at']),
        unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
      );

  /// Human label for the thread: the WhatsApp profile / booking name when known,
  /// otherwise a lightly-prettified phone number (drops a leading Indian `91`).
  String get displayName {
    final n = customerName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return _prettyPhone(customerPhone);
  }

  bool get hasUnread => unreadCount > 0;

  /// True while WhatsApp's 24-hour customer-service window is open — i.e. the
  /// customer messaged within the last 24h, so the agent can reply free-text.
  /// Outside it, [wa-reply] falls back to an approved template. [now] is
  /// injectable for tests.
  bool get windowOpen => isWindowOpen();

  bool isWindowOpen({DateTime? now}) {
    final last = lastInboundAt;
    if (last == null) return false;
    final ref = now ?? DateTime.now();
    return ref.difference(last) <= const Duration(hours: 24);
  }

  static String _prettyPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      return '+91 ${digits.substring(2)}';
    }
    if (digits.length == 10) return digits;
    return raw;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}
