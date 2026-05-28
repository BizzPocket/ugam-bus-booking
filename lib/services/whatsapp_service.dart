import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../models/trip_type.dart';

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

  // ── Request acknowledgment (Phase 3) ──────────────────────

  /// Builds a short ack message the agent sends back to a passenger
  /// after seeing their request, before bus/seat details exist.
  String buildAckMessage({
    required Passenger passenger,
    required Tour tour,
  }) {
    final seatParts = passenger.requestLines
        .map((l) => '${l.qty} ${l.label.replaceAll(' ×', '')}')
        .join(' + ');

    final lines = <String>[
      '✅ *Request Received — Ugam Booking*',
      '',
      '🙏 Jai Gurudev',
      '',
      'Hi ${passenger.name}, we got your booking request.',
      '',
      '🗺 *${tour.title}*',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      '📅 ${_formatDate(tour.departureDate)}'
          '${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
      if (seatParts.isNotEmpty) '💺 *Seats requested:* $seatParts',
      '',
      'We will share final seat numbers and bus details',
      'once the bus is booked. 🚌',
      '',
      '🙏 Thank you!',
    ];

    return lines.join('\n');
  }

  /// Opens WhatsApp on the agent's device addressed to [passenger]
  /// with the ack message pre-filled. Agent taps send.
  Future<bool> sendAck({
    required Passenger passenger,
    required Tour tour,
  }) async {
    final msg = buildAckMessage(passenger: passenger, tour: tour);
    return _openWhatsApp(passenger.phone, msg);
  }

  // ── Customer booking request (Phase 4) ────────────────────

  /// Short tour reference shown in customer→admin request messages.
  /// `UGM-` prefix + last 6 chars of the tour id, upper-cased.
  static String tourCode(String tourId) {
    final tail = tourId.length >= 6
        ? tourId.substring(tourId.length - 6)
        : tourId;
    return 'UGM-${tail.toUpperCase()}';
  }

  /// Builds the standardized booking-request message that the customer
  /// will send back to the admin via WhatsApp.
  ///
  /// The format is fixed so the admin's parser can recognise it
  /// regardless of which customer sent it.
  String buildBookingRequestMessage({
    required Tour tour,
    required String customerName,
    required int singleSofaCount,
    required int doubleSofaCount,
    String? note,
    bool isUpdate = false,
    TripType tripType = TripType.roundTrip,
  }) {
    final totalSeats = singleSofaCount + doubleSofaCount;
    final total = tour.pricePerSeat * totalSeats;

    final seatParts = <String>[];
    if (doubleSofaCount > 0) {
      seatParts.add('$doubleSofaCount Double Sofa');
    }
    if (singleSofaCount > 0) {
      seatParts.add('$singleSofaCount Single Sofa');
    }

    final tripLine = switch (tripType) {
      TripType.roundTrip => '🔁 *Trip:* Round-trip (both legs)',
      TripType.outboundOnly =>
          '➡️ *Trip:* One-way — ${tour.fromCity} → ${tour.toCity} (outbound only)',
      TripType.returnOnly =>
          '⬅️ *Trip:* One-way — ${tour.toCity} → ${tour.fromCity} (return only)',
    };

    final lines = <String>[
      if (isUpdate)
        '🔄 *Updated Booking Request — Ugam Booking*'
      else
        '🪷 *Booking Request — Ugam Booking*',
      '',
      '🙏 Jai Gurudev',
      '',
      if (isUpdate) ...[
        'I updated my earlier request — please use these new details:',
        '',
      ],
      '🗺 *Tour:* ${tour.title}',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      '📅 ${_formatDate(tour.departureDate)}'
          '${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
      '',
      '👤 *Name:* $customerName',
      '💺 *Seats:* ${seatParts.join(' + ')}',
      tripLine,
    ];

    if (total > 0) {
      lines.add('💰 *Estimated total:* ₹${total.toStringAsFixed(0)}');
    }

    if (note != null && note.trim().isNotEmpty) {
      lines.addAll(['', '📝 ${note.trim()}']);
    }

    lines.addAll([
      '',
      '[Tour ID: ${tourCode(tour.id)}]',
    ]);

    return lines.join('\n');
  }

  /// Opens WhatsApp on the customer's device with the booking request
  /// pre-filled, addressed to [adminPhone]. Returns true if WhatsApp
  /// opened successfully.
  Future<bool> sendBookingRequest({
    required String adminPhone,
    required Tour tour,
    required String customerName,
    required int singleSofaCount,
    required int doubleSofaCount,
    String? note,
    bool isUpdate = false,
    TripType tripType = TripType.roundTrip,
  }) async {
    final msg = buildBookingRequestMessage(
      tour: tour,
      customerName: customerName,
      singleSofaCount: singleSofaCount,
      doubleSofaCount: doubleSofaCount,
      note: note,
      isUpdate: isUpdate,
      tripType: tripType,
    );
    return _openWhatsApp(adminPhone, msg);
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
        ? passenger.assignedSeats.map((a) => a.seatId).join(', ')
        : 'To be assigned';
    final total = tour.pricePerSeat * passenger.totalSeatsRequested;

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
