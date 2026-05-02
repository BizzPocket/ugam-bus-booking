import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tour.dart';
import '../models/passenger.dart';

/// Free WhatsApp messaging — two approaches:
///
/// 1. INDIVIDUAL: Opens WhatsApp with pre-filled message per passenger.
///    User taps send. Best for 1-50 people.
///
/// 2. BROADCAST HELPER: Copies message to clipboard, user pastes into
///    WhatsApp Business broadcast list. Best for 200-700 people.
///    (3 broadcast lists of ~233 each for 700 passengers)
///
/// Both are 100% free, 100% safe, zero ban risk.
class WhatsAppService {
  static final WhatsAppService _instance = WhatsAppService._internal();
  factory WhatsAppService() => _instance;
  WhatsAppService._internal();

  // ── Individual: Open WhatsApp with message ────────────────

  /// Opens WhatsApp chat with this passenger, message pre-filled.
  /// Returns true if WhatsApp opened successfully.
  Future<bool> sendToPassenger({
    required Passenger passenger,
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerName,
    String? handlerPhone,
  }) async {
    final msg = buildTicketMessage(
      passenger: passenger,
      tour: tour,
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerName: handlerName,
      handlerPhone: handlerPhone,
    );
    return _openWhatsApp(passenger.phone, msg);
  }

  /// Opens WhatsApp to share a tour announcement with one contact.
  Future<bool> sendAnnouncement({
    required String phone,
    required Tour tour,
  }) async {
    final msg = buildAnnouncementMessage(tour: tour);
    return _openWhatsApp(phone, msg);
  }

  // ── Broadcast Helper: Copy for broadcast lists ────────────

  /// Copies the ticket message to clipboard.
  /// User then pastes into WhatsApp Business broadcast list.
  Future<void> copyTicketToClipboard({
    required Passenger passenger,
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
  }) async {
    final msg = buildTicketMessage(
      passenger: passenger,
      tour: tour,
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
    );
    await Clipboard.setData(ClipboardData(text: msg));
  }

  /// Copies a generic broadcast message (same for all passengers).
  /// Ideal for WhatsApp Business broadcast list (up to 256/list).
  Future<void> copyBroadcastToClipboard({
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerPhone,
  }) async {
    final msg = buildBroadcastMessage(
      tour: tour,
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerPhone: handlerPhone,
    );
    await Clipboard.setData(ClipboardData(text: msg));
  }

  /// Copies tour announcement to clipboard for broadcast.
  Future<void> copyAnnouncementToClipboard({required Tour tour}) async {
    final msg = buildAnnouncementMessage(tour: tour);
    await Clipboard.setData(ClipboardData(text: msg));
  }

  // ── Send next in queue (for sequential sending) ───────────

  /// For sending tickets one by one. Call this in a loop with a button.
  /// Returns the passenger that was messaged, or null if done.
  Future<Passenger?> sendNextTicket({
    required Tour tour,
    required List<Passenger> remaining,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerPhone,
  }) async {
    if (remaining.isEmpty) return null;
    final passenger = remaining.first;

    await sendToPassenger(
      passenger: passenger,
      tour: tour,
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerPhone: handlerPhone,
    );

    return passenger;
  }

  // ── Message Builders ──────────────────────────────────────

  String buildTicketMessage({
    required Passenger passenger,
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerName,
    String? handlerPhone,
  }) {
    final seats = passenger.assignedSeats.isNotEmpty
        ? passenger.assignedSeats.join(', ')
        : 'To be assigned';
    final total = tour.pricePerSeat * passenger.requestedSeats;

    final lines = <String>[
      '🎫 *Ticket Confirmed!*',
      '',
      '🙏 Jai Shree Ram',
      '',
      '👤 *${passenger.name}*',
      '🗺 *${tour.title}*',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      '📅 ${_formatDate(tour.departureDate)}${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
      '💺 *Seats:* $seats',
    ];

    if (busNumber != null) lines.add('🚌 *Bus:* $busNumber');
    if (driverName != null) {
      lines.add('🧑‍✈️ *Driver:* $driverName${driverPhone != null ? ' ($driverPhone)' : ''}');
    }
    if (handlerPhone != null) lines.add('📞 *Handler:* $handlerPhone');
    if (total > 0) lines.add('💰 *Amount:* ₹${total.toStringAsFixed(0)}');

    lines.addAll(['', '🙏 Have a blessed journey!']);

    return lines.join('\n');
  }

  String buildBroadcastMessage({
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerPhone,
  }) {
    final lines = <String>[
      '🚌 *${tour.title}*',
      '',
      '🙏 Jai Shree Ram',
      '',
      '📍 *Route:* ${tour.fromCity} → ${tour.toCity}',
      '📅 *Date:* ${_formatDate(tour.departureDate)}${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
    ];

    if (busNumber != null) lines.add('🚌 *Bus:* $busNumber');
    if (driverName != null) lines.add('🧑‍✈️ *Driver:* $driverName${driverPhone != null ? ' ($driverPhone)' : ''}');
    if (handlerPhone != null) lines.add('📞 *Handler Contact:* $handlerPhone');
    if (tour.pricePerSeat > 0) {
      lines.add('💰 *Price:* ₹${tour.pricePerSeat.toStringAsFixed(0)}/seat');
    } else {
      lines.add('🆓 *Free Tour*');
    }

    lines.addAll([
      '',
      'Your seat details have been shared individually.',
      'Please save this number to receive updates.',
      '',
      '🙏 Have a wonderful journey!',
    ]);

    return lines.join('\n');
  }

  String buildAnnouncementMessage({required Tour tour}) {
    final lines = <String>[
      '🚌 *New Tour Announcement!*',
      '',
      '🙏 Jai Shree Ram',
      '',
      '🗺 *${tour.title}*',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      '📅 ${_formatDate(tour.departureDate)}${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
    ];

    if (tour.pricePerSeat > 0) {
      lines.add('💰 ₹${tour.pricePerSeat.toStringAsFixed(0)} per seat');
    } else {
      lines.add('🆓 *Free Tour*');
    }

    if (tour.description != null && tour.description!.isNotEmpty) {
      lines.addAll(['', '📝 ${tour.description}']);
    }

    lines.addAll([
      '',
      'To book your seat, reply with:',
      '✅ Your Name',
      '✅ Number of Seats',
      '✅ Mobile Number',
      '',
      '🙏 Limited seats available!',
    ]);

    return lines.join('\n');
  }

  // ── Internals ─────────────────────────────────────────────

  Future<bool> _openWhatsApp(String phone, String message) async {
    final normalized = _normalizePhone(phone);
    final waPhone = normalized.replaceAll('+', '');
    final encoded = Uri.encodeComponent(message);
    final url = Uri.parse('https://wa.me/$waPhone?text=$encoded');

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  String _normalizePhone(String phone) {
    phone = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (!phone.startsWith('+')) {
      if (phone.startsWith('91') && phone.length == 12) {
        phone = '+$phone';
      } else if (phone.length == 10) {
        phone = '+91$phone';
      }
    }
    return phone;
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}
