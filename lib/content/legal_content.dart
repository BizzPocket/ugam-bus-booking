/// Structured, render-ready legal + about documents shown by
/// [LegalDocumentScreen]. The canonical Privacy Policy text is the
/// publish-ready `privacy_policy.html` at the repo root — this is the same
/// content ported into Ugam-native blocks so it reads on-brand inside the
/// dark-first app instead of as an off-theme embedded web page.
///
/// Body text is kept in English (the published, canonical wording). The
/// surrounding menu chrome is localised via easy_localization.
library;

enum LegalBlockKind { section, sub, paragraph, bullets }

/// One renderable unit of a [LegalDoc].
class LegalBlock {
  final LegalBlockKind kind;

  /// Text for [LegalBlockKind.section] / [LegalBlockKind.sub] /
  /// [LegalBlockKind.paragraph].
  final String? text;

  /// Items for [LegalBlockKind.bullets].
  final List<String>? items;

  /// When true the block renders inside a raised card (the html `.box`).
  final bool boxed;

  const LegalBlock._(this.kind, {this.text, this.items, this.boxed = false});

  const LegalBlock.section(String text) : this._(LegalBlockKind.section, text: text);
  const LegalBlock.sub(String text) : this._(LegalBlockKind.sub, text: text);
  const LegalBlock.paragraph(String text, {bool boxed = false})
      : this._(LegalBlockKind.paragraph, text: text, boxed: boxed);
  const LegalBlock.bullets(List<String> items)
      : this._(LegalBlockKind.bullets, items: items);
}

/// A full document: title, optional meta line, and the ordered blocks.
class LegalDoc {
  final String title;
  final String? meta;
  final List<LegalBlock> blocks;

  /// About-style docs show the brand logo above the title.
  final bool showLogo;

  const LegalDoc({
    required this.title,
    this.meta,
    required this.blocks,
    this.showLogo = false,
  });
}

class LegalContent {
  LegalContent._();

  // ─── PRIVACY POLICY ──────────────────────────────────────────────────
  // Ported verbatim (meaning-preserving) from privacy_policy.html.

  static const LegalDoc privacy = LegalDoc(
    title: 'Privacy Policy',
    meta: 'Ugam Foj — bus tour booking app\n'
        'Published by Occubit Solution · Effective 27 May 2026',
    blocks: [
      LegalBlock.paragraph(
        'This Privacy Policy explains how Occubit Solution ("we", "us") '
        'collects, uses, and shares information when you use the Ugam Foj '
        'mobile application (the "App"), which helps travellers request seats '
        'on group bus tours and helps tour organisers manage those bookings. '
        'By using the App you agree to this Policy.',
      ),

      LegalBlock.section('1. Information we collect'),
      LegalBlock.sub('Information you provide'),
      LegalBlock.bullets([
        'Booking details — your name, mobile phone number, the tour you '
            'choose, the seat(s) you select, passenger details, boarding '
            'point, and any notes you add.',
        'Organiser account — if you sign in as a tour organiser, your mobile '
            'phone number and password.',
      ]),
      LegalBlock.sub('Device contacts (tour organisers only)'),
      LegalBlock.paragraph(
        'If you sign in as a tour organiser, and only with your permission, '
        'the App reads the names and phone numbers stored in your device\'s '
        'address book and saves them to your organiser account on our servers. '
        'This lets you quickly find and select existing contacts when creating '
        'and managing bookings.\n\n'
        'This contacts sync does not run for travellers who use the App only '
        'to request a booking. You can decline the contacts permission, or '
        'revoke it later in your device settings, and continue using the rest '
        'of the App.',
        boxed: true,
      ),
      LegalBlock.sub('Information stored on your device'),
      LegalBlock.bullets([
        'A secure login/session token (kept in your device\'s encrypted '
            'storage).',
        'A local copy of your tours and bookings so the App works offline.',
        'Your language and app preferences, and basic network-connectivity '
            'status.',
      ]),
      LegalBlock.paragraph(
        'We do not collect your location, photos, or camera data, and the App '
        'contains no advertising and no third-party analytics or tracking SDKs.',
      ),

      LegalBlock.section('2. How we use your information'),
      LegalBlock.bullets([
        'To create, send, and manage your bus tour booking requests.',
        'To let tour organisers contact you about your booking and manage '
            'seat assignments.',
        'To authenticate organiser logins and keep your session secure.',
        'To operate the App offline and sync your data when you reconnect.',
      ]),

      LegalBlock.section('3. Permissions the App requests'),
      LegalBlock.bullets([
        'Contacts — used as described in Section 1, only for organiser '
            'accounts, to import names and numbers for booking management.',
        'Internet & network state — to sync your bookings with our servers '
            'and detect whether you are online.',
      ]),

      LegalBlock.section('4. How we share your information'),
      LegalBlock.bullets([
        'With your tour organiser. Booking requests you submit are shared '
            'with the organiser of that tour so they can confirm and manage '
            'your seats.',
        'Via WhatsApp. When you submit a booking request, the App opens '
            'WhatsApp with a pre-filled message containing your name, phone '
            'number, and booking details so you can send it to the organiser. '
            'Your use of WhatsApp is governed by WhatsApp / Meta\'s own '
            'privacy policy.',
        'Hosting provider (Supabase). We use Supabase to host our database '
            'and backend. Your data is processed and stored on their '
            'infrastructure on our behalf.',
        'Legal. We may disclose information if required by law or to protect '
            'our rights, users, or the public.',
      ]),
      LegalBlock.paragraph(
        'We do not sell your personal information, and we do not use it for '
        'advertising.',
      ),

      LegalBlock.section('5. Data storage and security'),
      LegalBlock.paragraph(
        'Your information is stored in our backend database (Supabase) and on '
        'your device. We rely on encrypted connections (HTTPS) and the '
        'platform\'s secure storage for session credentials. No method of '
        'transmission or storage is completely secure, but we take reasonable '
        'measures to protect your information.',
      ),

      LegalBlock.section('6. Data retention'),
      LegalBlock.paragraph(
        'We keep booking and contact information for as long as needed to '
        'provide the service and to maintain organisers\' booking records. '
        'You may request deletion of your personal information at any time '
        '(see Section 8), after which we will delete it unless we are required '
        'to keep it for legal reasons.',
      ),

      LegalBlock.section('7. Children\'s privacy'),
      LegalBlock.paragraph(
        'The App is intended for adults arranging group travel and is not '
        'directed to children under 13. We do not knowingly collect personal '
        'information from children. If you believe a child has provided us '
        'information, contact us and we will delete it.',
      ),

      LegalBlock.section('8. Your rights and choices'),
      LegalBlock.bullets([
        'Request access to, correction of, or deletion of your personal '
            'information.',
        'Withdraw contacts permission at any time in your device settings.',
        'Ask us questions about how your data is handled.',
      ]),
      LegalBlock.paragraph(
        'To exercise any of these, email us at the address below and we will '
        'respond within a reasonable time.',
      ),

      LegalBlock.section('9. Changes to this Policy'),
      LegalBlock.paragraph(
        'We may update this Policy from time to time. We will revise the '
        '"Effective" date above and, where appropriate, notify you within the '
        'App.',
      ),

      LegalBlock.section('10. Contact us'),
      LegalBlock.paragraph(
        'Questions or requests about this Policy or your data:\n\n'
        'Occubit Solution\n'
        'Email: zeel.shiyani68@gmail.com',
      ),
    ],
  );

  // ─── TERMS OF SERVICE ────────────────────────────────────────────────
  // App-appropriate terms for a booking-request handoff tool where payment
  // and confirmation happen directly with the tour organiser.

  static const LegalDoc terms = LegalDoc(
    title: 'Terms of Service',
    meta: 'Ugam Foj — bus tour booking app\n'
        'Published by Occubit Solution · Effective 27 May 2026',
    blocks: [
      LegalBlock.paragraph(
        'These Terms of Service ("Terms") govern your use of the Ugam Foj '
        'mobile application (the "App"), published by Occubit Solution. By '
        'using the App you agree to these Terms. If you do not agree, please '
        'do not use the App.',
      ),

      LegalBlock.section('1. What the App does'),
      LegalBlock.paragraph(
        'Ugam Foj lets travellers browse published group bus tours and submit '
        'a booking request, and lets tour organisers manage tours, buses, '
        'seating, and those requests. The App is a coordination tool — it is '
        'not a payment processor or a ticketing authority.',
      ),

      LegalBlock.section('2. Booking requests are not confirmations'),
      LegalBlock.paragraph(
        'Submitting a booking request does not guarantee a seat. A booking is '
        'only confirmed once the tour organiser accepts your request and '
        'assigns seats. Seat availability, pricing, dates, and routes shown in '
        'the App are provided by the organiser and may change.',
      ),

      LegalBlock.section('3. Your responsibilities'),
      LegalBlock.bullets([
        'Provide accurate name, phone number, and passenger details when '
            'requesting a booking.',
        'Keep your contact number reachable so the organiser can confirm your '
            'booking.',
        'Use the App only for lawful, personal travel-booking purposes.',
      ]),

      LegalBlock.section('4. Payments'),
      LegalBlock.paragraph(
        'The App does not collect payments. Any fares, deposits, or refunds '
        'are arranged and settled directly between you and the tour organiser, '
        'on the organiser\'s own terms. Occubit Solution is not a party to '
        'that transaction.',
      ),

      LegalBlock.section('5. Cancellations and changes'),
      LegalBlock.paragraph(
        'Cancellation, rescheduling, and refund decisions are made by the tour '
        'organiser. You can edit or withdraw a pending request from within the '
        'App; once seats are assigned, contact the organiser directly for any '
        'changes.',
      ),

      LegalBlock.section('6. Organiser accounts'),
      LegalBlock.paragraph(
        'Organiser accounts are provisioned by the developer and secured with '
        'a phone number and password. Organisers are responsible for keeping '
        'their credentials confidential and for the accuracy of the tours and '
        'booking information they publish.',
      ),

      LegalBlock.section('7. Acceptable use'),
      LegalBlock.bullets([
        'Do not submit false, fraudulent, or spam booking requests.',
        'Do not attempt to access accounts or data that are not yours.',
        'Do not interfere with, disrupt, or reverse-engineer the App or its '
            'backend.',
      ]),

      LegalBlock.section('8. Service availability'),
      LegalBlock.paragraph(
        'The App is provided "as is" and "as available". We work to keep it '
        'running but do not guarantee uninterrupted or error-free operation, '
        'and we may update, suspend, or discontinue features at any time.',
      ),

      LegalBlock.section('9. Limitation of liability'),
      LegalBlock.paragraph(
        'To the maximum extent permitted by law, Occubit Solution is not '
        'liable for the conduct of tour organisers or travellers, for the '
        'quality, safety, or completion of any tour, or for indirect or '
        'consequential losses arising from your use of the App.',
      ),

      LegalBlock.section('10. Changes to these Terms'),
      LegalBlock.paragraph(
        'We may update these Terms from time to time. We will revise the '
        '"Effective" date above and, where appropriate, notify you within the '
        'App. Continued use of the App after changes means you accept the '
        'updated Terms.',
      ),

      LegalBlock.section('11. Contact'),
      LegalBlock.paragraph(
        'Questions about these Terms:\n\n'
        'Occubit Solution\n'
        'Email: zeel.shiyani68@gmail.com',
      ),
    ],
  );

  // ─── ABOUT ───────────────────────────────────────────────────────────

  static const LegalDoc about = LegalDoc(
    title: 'About Ugam Foj',
    showLogo: true,
    meta: 'Group bus tour booking · devam.org',
    blocks: [
      LegalBlock.paragraph(
        'Ugam Foj is the bus-booking companion for group pilgrimages and '
        'tours organised around Bhedapipaliya Dham (DEVAM). It brings the '
        'whole journey — from announcing a tour, to gathering seat requests, '
        'to assigning seats and sending tickets over WhatsApp — into one '
        'simple app.',
      ),

      LegalBlock.section('For travellers'),
      LegalBlock.paragraph(
        'Browse upcoming tours, see what\'s available, and request your seats '
        'in a few taps. Track every request and its latest status under "My '
        'Requests", and pick up your seat details once the organiser confirms '
        'them.',
      ),

      LegalBlock.section('For organisers'),
      LegalBlock.paragraph(
        'Publish tours, manage buses and seat layouts, review incoming '
        'requests, assign seats, and message travellers — all built to work '
        'offline and stay in sync.',
      ),

      LegalBlock.section('Who makes it'),
      LegalBlock.paragraph(
        'Ugam Foj is published by Occubit Solution.\n\n'
        'Web: devam.org\n'
        'Email: zeel.shiyani68@gmail.com',
      ),
    ],
  );
}
