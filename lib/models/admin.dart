/// Mirrors the `public.admins` table. The synthetic email used for Supabase
/// Auth sign-in is derived from `phone` at call time (see SupabaseConfig).
class Admin {
  final String id;
  final String phone;
  final String name;
  final String? whatsappNumber;
  final DateTime? createdAt;

  Admin({
    required this.id,
    required this.phone,
    required this.name,
    this.whatsappNumber,
    this.createdAt,
  });

  /// The number customers should message in the booking handoff.
  /// Falls back to the login phone when an explicit WhatsApp number is
  /// not configured on the admin record.
  String get effectiveWhatsappNumber =>
      (whatsappNumber == null || whatsappNumber!.isEmpty)
          ? phone
          : whatsappNumber!;

  factory Admin.fromMap(Map<String, dynamic> map) {
    return Admin(
      id: (map['id'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      whatsappNumber: map['whatsapp_number']?.toString(),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'phone': phone,
        'name': name,
        if (whatsappNumber != null && whatsappNumber!.isNotEmpty)
          'whatsapp_number': whatsappNumber,
      };
}
