import 'package:flutter/foundation.dart';

import '../config/whatsapp_cloud_config.dart';
import '../models/chart_footer.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_grid_placement.dart';
import '../utils/time_format.dart';
import 'chart_footer_store.dart';
import 'seat_chart_pdf.dart';
import 'wa_template_params.dart';
import 'whatsapp_cloud_service.dart';

/// High-level WhatsApp Cloud API actions for the tour lifecycle:
///   * the PRE-LOCK greeting ([sendSeatConfirmed] / [sendConfirmed]) — the
///     `seat_allocation` template (body {{1}} = name, {{2}} = tour title),
///   * the AFTER-LOCK details ([sendSeatAllocations]) — the `seat_allotment`
///     template (image header = the passenger's highlighted seat chart; body =
///     passenger name, tour, bus, boarding place, departure date, departure
///     time, handler contact).
/// Builds each template payload (matching the variable contract in
/// [WhatsAppCloudConfig]) and routes it through [WhatsAppCloudService] →
/// the `quick-action` Edge Function.
class WhatsAppOutbound {
  final WhatsAppCloudService _cloud = WhatsAppCloudService();

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _fmtDate(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';

  /// Whether a "notify again" for [passenger] should deliver the FULL
  /// after-lock seat-allotment (highlighted chart image + boarding place +
  /// departure + handler contact) rather than the lighter pre-lock "seat
  /// confirmed" greeting. True only once the tour is LOCKED (or completed) —
  /// before lock the seat numbers are provisional and stay hidden — AND the
  /// passenger actually holds seats to draw on a chart.
  static bool shouldSendFullAllotment(Tour tour, Passenger passenger) =>
      passenger.assignedSeats.isNotEmpty &&
      (tour.status == TourStatus.locked ||
          tour.status == TourStatus.completed);

  /// PRE-LOCK greeting for ONE passenger with an assigned (not-yet-locked) seat.
  /// The `seat_allocation` template has a static header and a BODY with two
  /// variables, IN ORDER: {{1}} = passenger name, {{2}} = tour title. No seat
  /// numbers or bus yet — those are still provisional until the tour is locked.
  /// Never throws on a per-recipient failure; inspect [WaSendResult].
  Future<WaSendResult> sendSeatConfirmed({
    required Tour tour,
    required Passenger passenger,
  }) async {
    final message = WaMessage(
      to: WhatsAppCloudService.graphPhone(passenger.phone),
      template: WhatsAppCloudConfig.seatConfirmedTemplate,
      bodyParams: [passenger.name, tour.title],
    );
    return _cloud.send([message]);
  }

  /// PRE-LOCK greeting fired by the Confirm action on the Requests screen. Uses
  /// the same `seat_allocation` template — BODY {{1}} = passenger name,
  /// {{2}} = tour title. Never throws per-recipient; inspect [WaSendResult].
  Future<WaSendResult> sendConfirmed({
    required Tour tour,
    required Passenger passenger,
  }) async {
    final message = WaMessage(
      to: WhatsAppCloudService.graphPhone(passenger.phone),
      template: WhatsAppCloudConfig.confirmTemplate,
      bodyParams: [passenger.name, tour.title],
    );
    return _cloud.send([message]);
  }

  /// AFTER-LOCK details: sends each seated passenger the `seat_allotment`
  /// template. The seat numbers are NOT in the text any more — each passenger's
  /// own seats are highlighted on the chart IMAGE header instead. Body variables,
  /// IN ORDER (must match the approved body):
  ///   {{1}} passenger name  {{2}} tour title  {{3}} bus  {{4}} boarding place
  ///   {{5}} departure date  {{6}} departure time  {{7}} handler contact
  ///
  /// Each passenger's IMAGE-header chart is built + uploaded CONCURRENTLY (a
  /// bounded pool of [concurrency] at a time — the per-passenger PDF render +
  /// upload is the real bottleneck, so this is what stops the send dragging
  /// "one by one"). [onProgress] fires as each chart finishes, so the caller can
  /// show a "preparing X of N" indicator; the actual Meta sends are then batched
  /// by [WhatsAppCloudService.send].
  ///
  /// Pass [onlyPassengerIds] to restrict the send to a subset (used to RETRY
  /// only the recipients that failed). Never throws on a per-recipient failure;
  /// inspect [WaSendResult].
  Future<WaSendResult> sendSeatAllocations({
    required Tour tour,
    Iterable<String>? onlyPassengerIds,
    void Function(int done, int total)? onProgress,
    int concurrency = 5,
  }) async {
    if (tour.buses.isEmpty || tour.passengers.isEmpty) {
      debugPrint('[WA] sendSeatAllocations early-return: '
          'buses=${tour.buses.length} passengers=${tour.passengers.length}');
      return WaSendResult.empty;
    }

    final only = onlyPassengerIds?.toSet();
    final footer = await ChartFooterStore.load(tour.id);
    final date = _fmtDate(tour.departureDate);
    final seated = tour.passengers
        .where((p) => p.assignedSeats.isNotEmpty)
        .where((p) => only == null || only.contains(p.id))
        .toList();
    if (seated.isEmpty) return WaSendResult.empty;

    final total = seated.length;
    var done = 0;
    onProgress?.call(0, total);

    // Build + upload charts in bounded-concurrency waves so a big tour doesn't
    // spawn hundreds of simultaneous PDF renders (memory) yet never grinds one
    // passenger at a time. Results stay index-aligned with [seated].
    final messages = List<WaMessage?>.filled(total, null);
    // Recipients whose chart could not be rendered/uploaded. They are NOT sent
    // an image-less message: `seat_allotment` declares an IMAGE header, so Meta
    // rejects a header-less payload with "(#132012) Parameter format does not
    // match format in the created template" for EVERY such recipient. Reporting
    // the real cause here beats a blanket 132012 that hides it — this is the
    // failure mode that makes the send look broken on one platform only, when
    // the actual break is the local rasteriser.
    final chartFailures = <WaRecipientResult>[];
    for (var start = 0; start < total; start += concurrency) {
      final end = start + concurrency > total ? total : start + concurrency;
      await Future.wait([
        for (var i = start; i < end; i++)
          _buildAllocationMessage(tour, seated[i], footer, date).then((r) {
            if (r.message != null) {
              messages[i] = r.message;
            } else {
              chartFailures.add(WaRecipientResult(
                to: WhatsAppCloudService.graphPhone(seated[i].phone),
                ok: false,
                error: r.error ?? 'Seat chart could not be prepared',
              ));
            }
            done++;
            onProgress?.call(done, total);
          }),
      ]);
    }

    final list = messages.whereType<WaMessage>().toList();
    debugPrint('[WA] sendSeatAllocations: template='
        '${WhatsAppCloudConfig.seatAllocationTemplate} built ${list.length} '
        'msg(s), ${chartFailures.length} chart failure(s) '
        '-> ${list.map((m) => m.to).toList()}');
    if (chartFailures.isNotEmpty) {
      debugPrint('[WA] chart failure reason(s): '
          '${chartFailures.map((f) => f.error).toSet().toList()}');
    }

    if (list.isEmpty) {
      return WaSendResult(
        sent: 0,
        failed: chartFailures.length,
        results: chartFailures,
      );
    }

    final res = await _cloud.send(list);
    if (chartFailures.isEmpty) return res;
    return WaSendResult(
      sent: res.sent,
      failed: res.failed + chartFailures.length,
      results: [...res.results, ...chartFailures],
    );
  }

  /// Builds ONE passenger's `seat_allotment` message — renders + uploads their
  /// seat-chart image header (each recipient gets their own bus with their own
  /// seats highlighted) and assembles the body params. The seat
  /// numbers live ONLY on the highlighted chart now; the body carries the
  /// departure details + handler contact.
  ///
  /// Returns `(message: …, error: null)` on success, or `(message: null,
  /// error: reason)` when the chart could not be rendered or uploaded. It
  /// deliberately does NOT fall back to a no-image message: the approved
  /// `seat_allotment` template declares an IMAGE header, so Meta rejects a
  /// header-less payload with 132012 and the true cause is lost.
  Future<({WaMessage? message, String? error})> _buildAllocationMessage(
    Tour tour,
    Passenger p,
    ChartFooter footer,
    String date,
  ) async {
    final busId = p.assignedSeats.first.busId;
    final busMatch = tour.buses.where((b) => b.id == busId).toList();
    final bus = busMatch.isEmpty ? null : busMatch.first;
    // The customer's bus line ({{3}}) is the bus NAME only (e.g. "Raj") via the
    // shared [Bus.customerLabel] — no registration number, no internal "Bus N"
    // slot. The plate is an agent-only detail (it stays on the admin screens'
    // [Bus.displayLabel]); the customer just needs the name.
    final busLabel = _orDash(bus == null ? '' : bus.customerLabel);
    // Template variable order (must match the approved `seat_allotment` body):
    //   {{1}} passenger name  {{2}} tour (in the greeting "{name}, {tour} માટે
    //   …")  {{3}} bus  {{4}} boarding place  {{5}} departure date
    //   {{6}} departure time  {{7}} handler contact (name + phone).
    //   Tour appears only in the greeting now — no separate "પ્રવાસ:" line. The
    //   seat numbers are intentionally gone — highlighted on the chart image.
    //
    // Departure date is the tour date; time + place come from the passenger's
    // bus, falling back to the tour-level chart footer (mirrors what the chart
    // image footer prints).
    final timeLabel = _orDash(formatHhMm(bus?.departureTime) ??
        (footer.departureTime.trim().isNotEmpty
            ? footer.departureTime.trim()
            : ''));
    final place = _orDash(
      (bus?.boardingPoint.trim().isNotEmpty ?? false)
          ? bus!.boardingPoint.trim()
          : footer.boardingPlace.trim(),
    );

    // Handler contact for THIS passenger's bus (per-bus handler wins, else the
    // tour handler) — so the customer has someone to reach on the day.
    // displayPhone trims the +91 down to a clean 10-digit number.
    final handlerId = bus?.handlerPassengerId ?? tour.handlerId;
    final handlerMatch = handlerId == null
        ? const <Passenger>[]
        : tour.passengers.where((hp) => hp.id == handlerId).toList();
    final handler = handlerMatch.isNotEmpty ? handlerMatch.first : tour.handler;
    final handlerPhone = displayPhone(handler?.phone) ?? '';
    final handlerContact = _orDash(
      handler == null
          ? ''
          : (handlerPhone.isNotEmpty
              ? '${handler.displayName} – $handlerPhone'
              : handler.displayName),
    );

    String? chartUrl;
    try {
      // Every recipient — handler included — gets THEIR OWN bus chart with
      // their seats highlighted (one image per occupied bus; we send the first).
      final images = await SeatChartPdf.buildPassengerChartImages(
        tour: tour,
        passenger: p,
        footer: footer,
      );
      if (images.isEmpty) {
        debugPrint('[WA] chart render produced no page for ${p.id}');
        return (message: null, error: 'Seat chart image could not be rendered');
      }
      chartUrl = await _cloud.uploadSigned(
        bucket: WhatsAppCloudConfig.seatChartBucket,
        path: '${tour.id}/${p.id}.png',
        bytes: images.first,
        contentType: 'image/png',
      );
    } catch (e) {
      // Surfaced to the agent verbatim (the summary dialog prints the first
      // error), because THIS string is what identifies a platform-specific
      // rasteriser or upload break instead of a generic "send failed".
      debugPrint('[WA] chart image failed for ${p.id}: $e');
      return (message: null, error: 'Seat chart failed: $e');
    }

    return (
      message: WaMessage(
        to: WhatsAppCloudService.graphPhone(p.phone),
        template: WhatsAppCloudConfig.seatAllocationTemplate,
        headerImageUrl: chartUrl,
        bodyParams: [
          _orDash(p.name),
          tour.title, // {{2}} greeting: "{name}, {tour} માટે …"
          busLabel,
          place,
          date,
          timeLabel,
          handlerContact,
        ],
      ),
      error: null,
    );
  }

  /// Meta rejects empty body parameters, so coerce blanks to a dash. Callers
  /// pass already-trimmed text; this is the last guard before a value is sent.
  static String _orDash(String s) => s.trim().isEmpty ? '—' : s.trim();

  /// Per-bus free-text announcement (F4 — ADMIN path). The signed-in agent
  /// types one [messageText] and it goes to every passenger seated on [busId]
  /// (anyone holding a seat assignment on that bus, either leg). Builds one
  /// `busMessageTemplate` message per recipient — body var {{1}} = the typed
  /// text — and routes the batch through the same `quick-action` Edge Function
  /// the other sends use. Never throws on a per-recipient failure; inspect
  /// [WaSendResult]. (The HANDLER path goes through the dedicated `bus-message`
  /// function instead — see WhatsAppCloudService.sendBusMessageAsHandler.)
  /// The Graph-formatted phone numbers a [busId] announcement should reach:
  /// every rider holding a seat on that bus, DE-DUPLICATED BY PHONE and in a
  /// stable roster order.
  ///
  /// One message per PHONE, not per passenger row. A family that booked under a
  /// single number has several passenger rows on the same bus, so building the
  /// batch per-row delivered the identical announcement two or three times to
  /// that one phone. The handler path (the `bus-message` Edge Function) already
  /// de-duplicates exactly this way; this keeps the admin path consistent.
  /// Blank phones are dropped rather than sent as an empty `to` Meta rejects.
  ///
  /// Pure + static so the recipient rule is unit-testable without a network.
  static List<String> busMessageRecipients(Tour tour, String busId) {
    final seen = <String>{};
    final out = <String>[];
    for (final p in tour.passengers) {
      if (!p.assignedSeats.any((a) => a.busId == busId)) continue;
      final to = WhatsAppCloudService.graphPhone(p.phone);
      if (to.isEmpty || !seen.add(to)) continue;
      out.add(to);
    }
    return out;
  }

  /// Riders seated on [busId] whose stored phone cannot be dialled at all — a
  /// blank number, or digits that do not resolve to a real subscriber number.
  ///
  /// [busMessageRecipients] drops these so nothing malformed reaches Meta, but
  /// dropping them SILENTLY is what left the agent saying "some passengers
  /// don't get the msg, I don't know why". Naming them turns an invisible gap
  /// into a short list of people to phone by hand.
  ///
  /// Pure + static so the rule is unit-testable without a network.
  static List<Passenger> unreachableBusRiders(Tour tour, String busId) => [
        for (final p in tour.passengers)
          if (p.assignedSeats.any((a) => a.busId == busId) &&
              WhatsAppCloudService.graphPhone(p.phone).isEmpty)
            p,
      ];

  Future<WaSendResult> sendBusMessage({
    required Tour tour,
    required String busId,
    required String messageText,
  }) async {
    // Meta rejects a body parameter carrying a new-line, a tab or 5+ spaces.
    // REPAIR rather than refuse: collapsing a paragraph break to a space is the
    // only way that text can legally travel, and an announcement delivered with
    // its line breaks flattened beats the old behaviour — where a perfectly
    // ordinary long, multi-paragraph message was rejected here and reached NOBODY.
    // The composers apply the same repair up front so the agent sees the final
    // wording; this is the last line of defence for every other caller.
    final text = WaTemplateParams.sanitize(messageText);

    // What survives a repair genuinely cannot be sent: nothing to say, or too
    // long for the template. Both need a human, so they stay a hard refusal —
    // reported as a per-recipient failure (not an exception) so it flows through
    // the same result plumbing every caller already renders.
    final violations = WaTemplateParams.validateOne(text);
    if (violations.isNotEmpty) {
      debugPrint('[WA] sendBusMessage BLOCKED locally: '
          '${violations.map((v) => v.issue.name).toList()}');
      return WaSendResult(
        sent: 0,
        failed: 1,
        results: [
          WaRecipientResult(
            to: '',
            ok: false,
            error: 'Message rejected before sending: '
                '${violations.map((v) => v.issue.name).join(', ')}. '
                'A WhatsApp template message must not be empty and must stay '
                'within ${WaTemplateParams.maxBodyChars} characters.',
          ),
        ],
      );
    }

    // Riders whose phone cannot be dialled are reported by NAME rather than
    // quietly dropped — this is the other half of "some passengers don't get
    // the msg". They are counted as failures so the summary the agent reads
    // adds up to the roster.
    final unreachable = [
      for (final p in unreachableBusRiders(tour, busId))
        WaRecipientResult(
          to: '',
          ok: false,
          error: 'No usable WhatsApp number on file for ${p.displayName} '
              '— contact them by phone.',
        ),
    ];

    final phones = busMessageRecipients(tour, busId);
    if (phones.isEmpty) {
      debugPrint('[WA] sendBusMessage early-return: no recipient on bus $busId');
      if (unreachable.isEmpty) return WaSendResult.empty;
      return WaSendResult(
        sent: 0,
        failed: unreachable.length,
        results: unreachable,
      );
    }

    final messages = phones
        .map(
          (to) => WaMessage(
            to: to,
            template: WhatsAppCloudConfig.busMessageTemplate,
            bodyParams: [text],
          ),
        )
        .toList();

    debugPrint('[WA] sendBusMessage: template='
        '${WhatsAppCloudConfig.busMessageTemplate} bus=$busId built '
        '${messages.length} msg(s), ${unreachable.length} unreachable '
        '-> ${messages.map((m) => m.to).toList()}');
    final res = await _cloud.send(messages);
    if (unreachable.isEmpty) return res;
    return WaSendResult(
      sent: res.sent,
      failed: res.failed + unreachable.length,
      results: [...res.results, ...unreachable],
    );
  }

  /// Sends a single "request cancelled" utility notification to [passenger].
  /// Uses the flexible `bus_msg` template (body {{1}} free text) so the admin
  /// can notify cancellations without requiring a dedicated Meta template.
  Future<WaSendResult> sendRequestCancelled({
    required Tour tour,
    required Passenger passenger,
  }) {
    return _cloud.send([
      WaMessage(
        to: WhatsAppCloudService.graphPhone(passenger.phone),
        template: WhatsAppCloudConfig.busMessageTemplate,
        bodyParams: [_requestCancelledText(tour, passenger)],
      ),
    ]);
  }

  /// Batch variant of [sendRequestCancelled] for bulk declines.
  Future<WaSendResult> sendRequestCancelledBatch({
    required Tour tour,
    required Iterable<Passenger> passengers,
  }) {
    final msgs = passengers
        .map(
          (p) => WaMessage(
            to: WhatsAppCloudService.graphPhone(p.phone),
            template: WhatsAppCloudConfig.busMessageTemplate,
            bodyParams: [_requestCancelledText(tour, p)],
          ),
        )
        .toList();
    return _cloud.send(msgs);
  }

  String _requestCancelledText(Tour tour, Passenger passenger) {
    return 'Namaste ${_orDash(passenger.displayName)}, your booking request for '
        '${tour.title} (${tour.fromCity} → ${tour.toCity}) has been cancelled '
        'by admin. Please contact support/admin for details.';
  }
}
