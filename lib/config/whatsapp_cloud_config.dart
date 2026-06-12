/// Configuration for the WhatsApp Cloud API integration.
///
/// The template NAMES + LANGUAGE here must match the templates you approved in
/// Meta Business Manager, and your templates' variable order must match the
/// `{{1}}, {{2}}, ...` contract documented below. The access token and
/// phone-number-id are NOT here — they live as Edge Function secrets
/// (`WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`) so they never ship in the app.
class WhatsAppCloudConfig {
  WhatsAppCloudConfig._();

  /// Supabase Edge Function name that fronts the Cloud API. MUST equal the
  /// deployed function name. Source: supabase/functions/quick-action/index.ts —
  /// deploy with `supabase functions deploy quick-action`.
  static const String functionName = 'quick-action';

  /// Country code prepended to bare 10-digit numbers (India = 91).
  static const String defaultCountryCode = '91';

  /// Default template language code — MUST match the language your approved
  /// templates were created in. Gujarati = 'gu'.
  static const String defaultLanguage = 'gu';

  // ── Seat-flow templates (created + approved in Gujarati) ──────────────────
  // Two real Meta templates, mapped to the two notification stages:
  //   PRE-LOCK greeting  → `seat_allocation`  (static header; 2 BODY vars —
  //                        {{1}} = passenger name, {{2}} = tour title)
  //   AFTER-LOCK details → `seat_allotment`   (no media header; 5 BODY vars)

  /// PRE-LOCK greeting, fired when the agent acknowledges an ASSIGNED request
  /// (Requests screen). BODY variables IN ORDER: {{1}} = passenger name,
  /// {{2}} = tour title. Sent via `bodyParams: [name, tour.title]`.
  /// The approved Meta template MUST carry these two body vars in this order.
  static const String seatConfirmedTemplate = 'seat_allocation';

  /// Same greeting template, used by the Confirm action on the Requests screen.
  static const String confirmTemplate = 'seat_allocation';

  /// AFTER-LOCK details, sent once the tour is locked and seats are final.
  /// Body variables, IN ORDER (must match the approved `seat_allotment` body):
  ///   {{1}} tour title  {{2}} seat numbers  {{3}} bus  {{4}} date (+ time)
  ///   {{5}} departure place (the bus's boarding point) — NOT the passenger name
  /// NOTE: this template has NO document header, so the seat-chart PDF is not
  /// attached. To send the PDF, add a Document header to `seat_allotment` and
  /// restore the upload in WhatsAppOutbound.sendSeatAllocations.
  static const String seatAllocationTemplate = 'seat_allotment';

  /// Per-bus free-text announcement (F4). Admin or the bus's handler types a
  /// message and it goes to every passenger seated on that ONE bus.
  ///
  /// PLACEHOLDER: replace `'bus_announcement'` with the name of the template you
  /// actually approve in Meta Business Manager. The template must have a single
  /// BODY variable {{1}} = the announcement text the agent/handler types — sent
  /// via `bodyParams: [messageText]`. Until the real template is approved and
  /// this name is updated (and the `bus-message` Edge Function deployed), the
  /// per-bus send will fail at Meta with a template-not-found error.
  static const String busMessageTemplate = 'bus_announcement';

  /// Storage buckets (created in migration 009).
  static const String broadcastBucket = 'tour-broadcasts';
  static const String seatChartBucket = 'seat-charts';
}
