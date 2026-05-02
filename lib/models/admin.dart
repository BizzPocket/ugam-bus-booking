/// Stored in the Appwrite `admins` collection. The `passwordHash` is a hex
/// SHA-256 of `salt + plain password`; `salt` is 16 random bytes hex-encoded.
class Admin {
  final String id;
  final String phone;
  final String name;
  final String passwordHash;
  final String salt;
  final String? whatsappNumber;
  final DateTime? createdAt;

  Admin({
    required this.id,
    required this.phone,
    required this.name,
    required this.passwordHash,
    required this.salt,
    this.whatsappNumber,
    this.createdAt,
  });

  /// The number customers should message in the Phase 4 booking handoff.
  /// Falls back to the login phone when an explicit WhatsApp number is
  /// not configured on the admin record.
  String get effectiveWhatsappNumber =>
      (whatsappNumber == null || whatsappNumber!.isEmpty)
          ? phone
          : whatsappNumber!;

  factory Admin.fromAppwrite(Map<String, dynamic> doc) {
    return Admin(
      id: (doc[r'$id'] ?? doc['id'] ?? '').toString(),
      phone: (doc['phone'] ?? '').toString(),
      name: (doc['name'] ?? '').toString(),
      passwordHash: (doc['passwordHash'] ?? '').toString(),
      salt: (doc['salt'] ?? '').toString(),
      whatsappNumber: doc['whatsappNumber']?.toString(),
      createdAt: doc[r'$createdAt'] != null
          ? DateTime.tryParse(doc[r'$createdAt'].toString())
          : null,
    );
  }

  Map<String, dynamic> toAppwrite() => {
        'phone': phone,
        'name': name,
        'passwordHash': passwordHash,
        'salt': salt,
        if (whatsappNumber != null && whatsappNumber!.isNotEmpty)
          'whatsappNumber': whatsappNumber,
      };
}
