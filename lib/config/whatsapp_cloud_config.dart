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
  //   AFTER-LOCK details → `seat_allotment`   (IMAGE header = the passenger's
  //                        highlighted seat chart; 5 BODY vars, no seat numbers)

  /// PRE-LOCK greeting, fired when the agent acknowledges an ASSIGNED request
  /// (Requests screen). BODY variables IN ORDER: {{1}} = passenger name,
  /// {{2}} = tour title. Sent via `bodyParams: [name, tour.title]`.
  /// The approved Meta template MUST carry these two body vars in this order.
  static const String seatConfirmedTemplate = 'seat_allocation';

  /// Same greeting template, used by the Confirm action on the Requests screen.
  static const String confirmTemplate = 'seat_allocation';

  /// AFTER-LOCK details, sent once the tour is locked and seats are final — one
  /// message per seated passenger.
  /// Header: IMAGE — the passenger's own seat chart with their seats highlighted
  /// (the tour handler gets the full bus chart). Built + uploaded per recipient
  /// in WhatsAppOutbound._buildAllocationMessage.
  /// Body variables, IN ORDER (must match the approved `seat_allotment` body):
  ///   {{1}} passenger name  {{2}} tour title (in the greeting line)  {{3}} bus
  ///   NAME only  {{4}} boarding place  {{5}} departure date  {{6}} departure
  ///   time  {{7}} handler contact
  /// The tour title lives in the line-2 greeting ("{name}, {tour} માટે …") —
  /// there is no separate "પ્રવાસ:" line. Bus is the customer label
  /// ([Bus.customerLabel] = name only, no registration plate) — the same label
  /// used on the chart-image footer and every customer screen, so the convention
  /// can't drift; the plate stays on the admin screens' [Bus.displayLabel]. The
  /// seat numbers are NOT in the body — they're highlighted on the image. The
  /// approved Meta template MUST be re-created with an Image header and these
  /// seven body vars in this exact order, or every send fails at Meta.
  static const String seatAllocationTemplate = 'seat_allotment';

  /// Per-bus free-text announcement (F4). Admin or the bus's handler types a
  /// message and it goes to every passenger seated on that ONE bus.
  ///
  /// Approved as `bus_msg` (NOT `bus_announcement` — an "announcement" name/body
  /// gets classified by Meta as MARKETING, which needs opt-out + costs more; a
  /// plain utility name stays UTILITY). The template has a single BODY variable
  /// {{1}} = the free-text the agent/handler types — sent via
  /// `bodyParams: [messageText]`. Must match the name approved in Meta and the
  /// `BUS_MESSAGE_TEMPLATE` constant in the `bus-message` Edge Function.
  static const String busMessageTemplate = 'bus_msg';

  /// Storage buckets (created in migration 009).
  static const String broadcastBucket = 'tour-broadcasts';
  static const String seatChartBucket = 'seat-charts';
}
