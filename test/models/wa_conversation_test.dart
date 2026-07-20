import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/wa_conversation.dart';

/// Guards the two derived rules the inbox UI leans on: the 24-hour free-reply
/// window (WhatsApp's customer-service window) and the display name fallback.
void main() {
  WaConversation build({
    String? customerName,
    String customerPhone = '919876543210',
    DateTime? lastInboundAt,
    int unreadCount = 0,
  }) =>
      WaConversation(
        id: 'c1',
        customerPhone: customerPhone,
        customerName: customerName,
        lastMessageAt: DateTime(2026, 7, 9, 10, 0),
        lastInboundAt: lastInboundAt,
        unreadCount: unreadCount,
      );

  group('windowOpen (24h customer-service window)', () {
    final now = DateTime(2026, 7, 9, 12, 0);

    test('open when the last inbound was within 24h', () {
      final c = build(lastInboundAt: now.subtract(const Duration(hours: 23)));
      expect(c.isWindowOpen(now: now), isTrue);
    });

    test('closed exactly past 24h', () {
      final c = build(
        lastInboundAt: now.subtract(const Duration(hours: 24, minutes: 1)),
      );
      expect(c.isWindowOpen(now: now), isFalse);
    });

    test('closed when the customer has never messaged (null lastInboundAt)', () {
      expect(build(lastInboundAt: null).isWindowOpen(now: now), isFalse);
    });
  });

  group('displayName', () {
    test('uses the customer name when present', () {
      expect(build(customerName: 'Ramesh').displayName, 'Ramesh');
    });

    test('falls back to a prettified +91 number when name is blank', () {
      final c = build(customerName: null, customerPhone: '919876543210');
      expect(c.displayName, '+91 9876543210');
    });

    test('shows a bare 10-digit number as-is', () {
      final c = build(customerName: '', customerPhone: '9876543210');
      expect(c.displayName, '9876543210');
    });
  });

  group('fromMap', () {
    test('parses snake_case columns and coerces types', () {
      final c = WaConversation.fromMap({
        'id': 'c9',
        'owner_id': 'admin-1',
        'customer_phone': '919999999999',
        'customer_name': '  Priya  ',
        'last_message_at': '2026-07-09T10:00:00Z',
        'last_message_preview': 'Hello',
        'last_inbound_at': '2026-07-09T09:59:00Z',
        'unread_count': 3,
      });
      expect(c.id, 'c9');
      expect(c.ownerId, 'admin-1');
      expect(c.customerName, 'Priya'); // trimmed
      expect(c.unreadCount, 3);
      expect(c.hasUnread, isTrue);
      expect(c.lastInboundAt, isNotNull);
    });

    test('blank customer_name becomes null (so displayName falls back)', () {
      final c = WaConversation.fromMap({
        'id': 'c1',
        'customer_phone': '919876543210',
        'customer_name': '   ',
        'last_message_at': '2026-07-09T10:00:00Z',
        'unread_count': 0,
      });
      expect(c.customerName, isNull);
      expect(c.hasUnread, isFalse);
    });
  });
}
