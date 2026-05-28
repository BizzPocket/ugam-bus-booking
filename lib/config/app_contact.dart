/// Brand + support contact constants surfaced on the customer "More" screen.
///
/// These are intentionally editable in one place. The customer app has no
/// logged-in organiser, so the per-tour `tour.createdBy` number used by the
/// booking flow isn't available here — the "Contact" row falls back to these
/// brand-level channels instead.
class AppContact {
  AppContact._();

  /// Support WhatsApp number in international format **without** the `+`
  /// (e.g. `919876543210`). Leave empty to fall back to [supportEmail] for
  /// the Contact row.
  ///
  /// TODO(ops): set this to the organiser's public WhatsApp number.
  static const String supportWhatsApp = '';

  /// Support email — the address published in the Privacy Policy.
  static const String supportEmail = 'zeel.shiyani68@gmail.com';

  /// Brand site.
  static const String website = 'https://devam.org';

  /// Pre-filled greeting used when the Contact row opens WhatsApp.
  static const String whatsAppGreeting =
      '🙏 Jai Gurudev — I have a question about Ugam Foj bus booking.';
}
