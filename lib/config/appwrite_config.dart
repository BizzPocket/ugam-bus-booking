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
  static const String busesCollection = '69e5f9e90001e4966697'; // Replaces busDetailsCollection

  /// Admin login records — `{phone, name, passwordHash, salt, whatsappNumber}`.
  /// Required schema (create manually in the Appwrite console under the
  /// project's database):
  ///   phone           — string, required, unique
  ///   name            — string, required
  ///   passwordHash    — string, required (hex SHA-256 of salt+password)
  ///   salt            — string, required (16-byte hex)
  ///   whatsappNumber  — string, optional (E.164 — used for the Phase 4
  ///                     customer booking handoff; falls back to `phone`
  ///                     if blank)
  static const String adminsCollection = '69fb3903000f8d629594';

  /// Per-admin contact directory. Powers booking-side enrichment ("who is
  /// +91 98XXX XXXXX?" → the name this admin has saved them as).
  ///
  /// Required schema:
  ///   phone           — string(10), required (last-10 normalised)
  ///   name            — string(100), required
  ///   source          — string(16), required (`device` / `booking` / `manual`)
  ///   addedByAdminId  — string(64), required (admin document `$id`)
  ///   note            — string(500), optional
  ///
  /// Indexes:
  ///   admin_phone_unique — compound unique on (addedByAdminId, phone)
  ///   phone_lookup       — key on phone
  static const String usersCollection = '69fb3829001533423094';

  /// Last-10-digit normaliser used when looking up admin records by phone.
  static String normalisePhone(String phone) {
    final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
    return cleaned.length >= 10
        ? cleaned.substring(cleaned.length - 10)
        : cleaned;
  }

  AppwriteConfig._();
}
