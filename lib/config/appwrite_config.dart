class AppwriteConfig {
  /// Appwrite endpoint (must end with `/v1`).
  static const String endpoint =
      'http://appwrite-tyj5kvidfjuzaddasema2ah1.122.174.67.207.sslip.io/v1';

  /// Appwrite project ID.
  static const String projectId = '69e5d41e002244ac3d72';

  /// Database ID — from the Appwrite console.
  static const String databaseId = '69e5ea7b000f6b95e6e9';

  // ── Collection IDs ─────────────────────────────────────────
  static const String toursCollection = '69e5eaa9003cf0176299';
  static const String passengersCollection = '69e5f8df001bfdbea1dd';
  static const String busDetailsCollection = '69e5f9e90001e4966697';

  // ── Admin phones ───────────────────────────────────────────
  /// Admin phone numbers (without country code).
  /// These users see the full admin dashboard.
  /// Everyone else enters as a passenger and sees only their bookings.
  static const List<String> adminPhones = ['9327148044'];

  /// Check if a phone number belongs to an admin.
  static bool isAdminPhone(String phone) {
    final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
    final last10 = cleaned.length >= 10
        ? cleaned.substring(cleaned.length - 10)
        : cleaned;
    return adminPhones.any((admin) {
      final adminLast10 =
          admin.length >= 10 ? admin.substring(admin.length - 10) : admin;
      return adminLast10 == last10;
    });
  }

  AppwriteConfig._();
}
