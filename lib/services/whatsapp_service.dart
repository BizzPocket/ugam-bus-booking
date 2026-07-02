import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import '../controllers/auth_controller.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../models/trip_type.dart';

/// Free WhatsApp messaging — three approaches:
///
/// 1. INDIVIDUAL: Opens WhatsApp with a pre-filled deep-link message per
///    passenger. User taps send.
///
/// 2. FREE BROADCAST: Opens WhatsApp's own contact/broadcast picker with
///    the tour message pre-filled, so the agent picks their broadcast list.
///
/// 3. CLIPBOARD: Copies the tour announcement so the agent can paste it
///    into any chat, group or broadcast list.
///
/// All are 100% free, 100% safe, zero ban risk.
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
    String? handlerPhone,
  }) async {
    final msg = buildTicketMessage(
      passenger: passenger,
      tour: tour,
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerPhone: handlerPhone,
    );
    return _openWhatsApp(passenger.phone, msg);
  }

  // ── Broadcast Helper: Copy for broadcast lists ────────────

  /// Copies tour announcement to clipboard for broadcast.
  Future<void> copyAnnouncementToClipboard({required Tour tour}) async {
    final msg = buildAnnouncementMessage(tour: tour);
    await Clipboard.setData(ClipboardData(text: msg));
  }

  /// Free tour broadcast — no Cloud API, no server, no Meta approval.
  ///
  /// Copies the broadcast message to the clipboard (backup) and opens
  /// WhatsApp's own contact/broadcast picker with the message pre-filled and
  /// NO recipient, so the agent taps their saved Broadcast List or a group to
  /// send. Uses [buildTourBroadcastMessage]. Returns true if WhatsApp opened;
  /// false means it isn't installed (the message is still on the clipboard).
  Future<bool> broadcastTour({required Tour tour}) async {
    final msg = buildTourBroadcastMessage(tour: tour);
    await Clipboard.setData(ClipboardData(text: msg));

    final encoded = Uri.encodeComponent(msg);
    // whatsapp:// opens the picker straight inside WhatsApp; wa.me is the
    // universal fallback (also routed to WhatsApp via the manifest query).
    for (final raw in [
      'whatsapp://send?text=$encoded',
      'https://wa.me/?text=$encoded',
    ]) {
      final url = Uri.parse(raw);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
        return true;
      }
    }
    return false;
  }

  // ── Request acknowledgment (Phase 3) ──────────────────────

  /// Builds the message the agent sends back to a passenger: a
  /// request-received ack before any seats exist, or a booking-confirmed
  /// message once seats have been assigned (but before the tour is locked).
  ///
  /// The confirmed message deliberately OMITS the exact seat numbers and bus —
  /// at assign-but-not-locked those are still provisional and can change before
  /// lock. The final seat numbers + bus + full chart go out at lock (phase 8,
  /// the `seat_allocation` Cloud template).
  String buildAckMessage({
    required Passenger passenger,
    required Tour tour,
  }) {
    final seatParts = passenger.requestLines
        .map((l) => '${l.qty} ${l.label.replaceAll(' ×', '')}')
        .join(' + ');
    final dateLine = '📅 ${_formatDate(tour.departureDate)}'
        '${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}';

    if (passenger.assignedSeats.isNotEmpty) {
      // Describe the booking by what was requested ("2 Double Sofa") rather
      // than the provisional seat ids; fall back to a plain count when an
      // agent-added passenger has no request lines.
      final seatsLine = seatParts.isNotEmpty
          ? seatParts
          : '${passenger.assignedSeats.length} '
              '${passenger.assignedSeats.length == 1 ? 'seat' : 'seats'}';

      final lines = <String>[
        '✅ *Seat Confirmed — Ugam Booking*',
        '',
        '🙏 Jay Gurudev',
        '',
        'Hi ${passenger.name}, your booking is confirmed! 🎉',
        '',
        '🗺 *${tour.title}*',
        '📍 ${tour.fromCity} → ${tour.toCity}',
        dateLine,
        '💺 *Seats confirmed:* $seatsLine',
        '',
        'Your exact seat numbers and bus details will be',
        'shared once the trip is finalised. 🚌',
        '',
        '🙏 Thank you!',
      ];

      return lines.join('\n');
    }

    final lines = <String>[
      '✅ *Request Received — Ugam Booking*',
      '',
      '🙏 Jay Gurudev',
      '',
      'Hi ${passenger.name}, we got your booking request.',
      '',
      '🗺 *${tour.title}*',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      dateLine,
      if (seatParts.isNotEmpty) '💺 *Seats requested:* $seatParts',
      '',
      'We will share final seat numbers and bus details',
      'once the bus is booked. 🚌',
      '',
      '🙏 Thank you!',
    ];

    return lines.join('\n');
  }

  /// Opens WhatsApp on the agent's device addressed to [passenger] with
  /// [buildAckMessage] pre-filled — a request-received ack before seats
  /// exist, a seat-confirmed message once seats are assigned. Agent taps
  /// send.
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
      '🙏 Jay Gurudev',
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

    if (note != null && note.trim().isNotEmpty) {
      lines.addAll(['', '📝 ${note.trim()}']);
    }

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

  /// Opens a WhatsApp chat to [phone] (any local/international format — the
  /// number is normalised internally) pre-filled with [message]. Used by the
  /// customer "Contact organiser" action on a tour. Returns true if WhatsApp
  /// opened successfully.
  Future<bool> openChat({required String phone, required String message}) =>
      _openWhatsApp(phone, message);

  // ── Message Builders ──────────────────────────────────────

  String buildTicketMessage({
    required Passenger passenger,
    required Tour tour,
    String? busNumber,
    String? driverName,
    String? driverPhone,
    String? handlerPhone,
  }) {
    final seats = passenger.assignedSeats.isNotEmpty
        ? passenger.assignedSeats.map((a) => a.seatId).join(', ')
        : 'To be assigned';

    final lines = <String>[
      '🎫 *Ticket Confirmed!*',
      '',
      '🙏 Jay Gurudev',
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

    lines.addAll(['', '🙏 Have a blessed journey!']);

    return lines.join('\n');
  }

  String buildAnnouncementMessage({required Tour tour}) {
    final lines = <String>[
      '🚌 *નવા પ્રવાસની જાહેરાત!*',
      '',
      '🙏 જય ગુરુદેવ',
      '',
      '🗺 *${tour.title}*',
      '📍 ${tour.fromCity} → ${tour.toCity}',
      '📅 ${_formatDate(tour.departureDate)}${tour.returnDate != null ? ' – ${_formatDate(tour.returnDate!)}' : ''}',
    ];

    if (tour.description != null && tour.description!.isNotEmpty) {
      lines.addAll(['', '📝 ${tour.description}']);
    }

    // Booking details + the "Book seats" button live on the tour detail page,
    // so the broadcast intentionally omits the old "reply with name/seats/
    // mobile" how-to-book block — it only announces the trip.
    lines.addAll([
      '',
      '🙏 મર્યાદિત બેઠકો ઉપલબ્ધ છે!',
    ]);

    final signature = adminSignature();
    if (signature != null) {
      lines.addAll(['', signature]);
    }

    return lines.join('\n');
  }

  /// The free-broadcast text for a tour. Prefers the agent's own composed
  /// broadcast (the "Broadcast" field on Create Tour, stored as
  /// [Tour.broadcastMessage]) used verbatim; when that is blank it falls back
  /// to the generated [buildAnnouncementMessage]. The admin's WhatsApp
  /// signature is appended to the composed message (the generated announcement
  /// already includes it).
  String buildTourBroadcastMessage({required Tour tour}) {
    final typed = (tour.broadcastMessage ?? '').trim();
    if (typed.isEmpty) return buildAnnouncementMessage(tour: tour);

    final lines = <String>[typed];
    final signature = adminSignature();
    if (signature != null) lines.addAll(['', signature]);
    return lines.join('\n');
  }

  /// The admin's editable WhatsApp signature (Settings → WhatsApp), appended
  /// to outgoing announcements. Read lazily from the logged-in admin so call
  /// sites don't have to thread it through. Returns null when unset or when
  /// no admin session is active (e.g. customer app).
  String? adminSignature() {
    if (!Get.isRegistered<AuthController>()) return null;
    final sig = Get.find<AuthController>().currentAdmin.value?.waHandoffTemplate;
    if (sig == null || sig.trim().isEmpty) return null;
    return sig.trim();
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
