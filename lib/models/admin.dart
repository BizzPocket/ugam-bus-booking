/// Mirrors the `public.admins` table. The synthetic email used for Supabase
/// Auth sign-in is derived from `phone` at call time (see SupabaseConfig).
class Admin {
  final String id;
  final String phone;
  final String name;
  final String? whatsappNumber;
  final DateTime? createdAt;

  // ── Self-service settings (migration 008) ─────────────────
  /// Account Details.
  final String? businessName;
  final String? businessEmail;

  /// Payment Settings — used to stamp collection receipts / share text.
  final String? upiId;
  final String? payeeName;
  final double? defaultAdvance;
  final String? receiptNote;

  /// WhatsApp Settings — the editable template used for the booking handoff
  /// message. Null/empty means "use the built-in default".
  final String? waHandoffTemplate;

  // Notification preferences.
  final bool notifyBookingRequests;
  final bool notifyPaymentReminders;
  final bool notifyDepartureReminders;
  final bool pushEnabled;

  Admin({
    required this.id,
    required this.phone,
    required this.name,
    this.whatsappNumber,
    this.createdAt,
    this.businessName,
    this.businessEmail,
    this.upiId,
    this.payeeName,
    this.defaultAdvance,
    this.receiptNote,
    this.waHandoffTemplate,
    this.notifyBookingRequests = true,
    this.notifyPaymentReminders = true,
    this.notifyDepartureReminders = true,
    this.pushEnabled = true,
  });

  /// The number customers should message in the booking handoff.
  /// Falls back to the login phone when an explicit WhatsApp number is
  /// not configured on the admin record.
  String get effectiveWhatsappNumber =>
      (whatsappNumber == null || whatsappNumber!.isEmpty)
          ? phone
          : whatsappNumber!;

  /// The name printed on payment receipts / used as the payee — falls back
  /// to the business name, then the admin's own name.
  String get effectivePayeeName {
    if (payeeName != null && payeeName!.isNotEmpty) return payeeName!;
    if (businessName != null && businessName!.isNotEmpty) return businessName!;
    return name;
  }

  factory Admin.fromMap(Map<String, dynamic> map) {
    bool flag(String key) {
      final v = map[key];
      if (v is bool) return v;
      if (v is String) return v.toLowerCase() == 'true' || v == 't';
      return true; // column default
    }

    double? money(String key) {
      final v = map[key];
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    String? str(String key) {
      final v = map[key];
      if (v == null) return null;
      final s = v.toString();
      return s.isEmpty ? null : s;
    }

    return Admin(
      id: (map['id'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      whatsappNumber: str('whatsapp_number'),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
      businessName: str('business_name'),
      businessEmail: str('business_email'),
      upiId: str('upi_id'),
      payeeName: str('payee_name'),
      defaultAdvance: money('default_advance'),
      receiptNote: str('receipt_note'),
      waHandoffTemplate: str('wa_handoff_template'),
      notifyBookingRequests: flag('notify_booking_requests'),
      notifyPaymentReminders: flag('notify_payment_reminders'),
      notifyDepartureReminders: flag('notify_departure_reminders'),
      pushEnabled: flag('push_enabled'),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'phone': phone,
        'name': name,
        if (whatsappNumber != null && whatsappNumber!.isNotEmpty)
          'whatsapp_number': whatsappNumber,
      };

  /// The mutable subset an admin can edit from the Settings screens.
  /// Nulls are sent explicitly so a cleared field is persisted as NULL.
  Map<String, dynamic> toUpdateMap() => {
        'name': name,
        'whatsapp_number': whatsappNumber,
        'business_name': businessName,
        'business_email': businessEmail,
        'upi_id': upiId,
        'payee_name': payeeName,
        'default_advance': defaultAdvance,
        'receipt_note': receiptNote,
        'wa_handoff_template': waHandoffTemplate,
        'notify_booking_requests': notifyBookingRequests,
        'notify_payment_reminders': notifyPaymentReminders,
        'notify_departure_reminders': notifyDepartureReminders,
        'push_enabled': pushEnabled,
      };

  Admin copyWith({
    String? name,
    String? whatsappNumber,
    String? businessName,
    String? businessEmail,
    String? upiId,
    String? payeeName,
    double? defaultAdvance,
    String? receiptNote,
    String? waHandoffTemplate,
    bool? notifyBookingRequests,
    bool? notifyPaymentReminders,
    bool? notifyDepartureReminders,
    bool? pushEnabled,
  }) {
    return Admin(
      id: id,
      phone: phone,
      name: name ?? this.name,
      whatsappNumber: whatsappNumber ?? this.whatsappNumber,
      createdAt: createdAt,
      businessName: businessName ?? this.businessName,
      businessEmail: businessEmail ?? this.businessEmail,
      upiId: upiId ?? this.upiId,
      payeeName: payeeName ?? this.payeeName,
      defaultAdvance: defaultAdvance ?? this.defaultAdvance,
      receiptNote: receiptNote ?? this.receiptNote,
      waHandoffTemplate: waHandoffTemplate ?? this.waHandoffTemplate,
      notifyBookingRequests:
          notifyBookingRequests ?? this.notifyBookingRequests,
      notifyPaymentReminders:
          notifyPaymentReminders ?? this.notifyPaymentReminders,
      notifyDepartureReminders:
          notifyDepartureReminders ?? this.notifyDepartureReminders,
      pushEnabled: pushEnabled ?? this.pushEnabled,
    );
  }
}
