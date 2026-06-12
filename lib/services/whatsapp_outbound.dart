import 'package:flutter/foundation.dart';

import '../config/whatsapp_cloud_config.dart';
import '../models/chart_footer.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../utils/time_format.dart';
import 'chart_footer_store.dart';
import 'seat_chart_pdf.dart';
import 'whatsapp_cloud_service.dart';

/// High-level WhatsApp Cloud API actions for the tour lifecycle:
///   * the PRE-LOCK greeting ([sendSeatConfirmed] / [sendConfirmed]) — the
///     `seat_allocation` template (body {{1}} = name, {{2}} = tour title),
///   * the AFTER-LOCK details ([sendSeatAllocations]) — the `seat_allotment`
///     template (tour, seats, bus, date, name in its body).
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
  /// template. Body variables, IN ORDER (must match the approved body):
  ///   {{1}} tour title  {{2}} seat numbers  {{3}} bus  {{4}} date  {{5}} name
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
    for (var start = 0; start < total; start += concurrency) {
      final end = start + concurrency > total ? total : start + concurrency;
      await Future.wait([
        for (var i = start; i < end; i++)
          _buildAllocationMessage(tour, seated[i], footer, date).then((m) {
            messages[i] = m;
            done++;
            onProgress?.call(done, total);
          }),
      ]);
    }

    final list = messages.whereType<WaMessage>().toList();
    debugPrint('[WA] sendSeatAllocations: template='
        '${WhatsAppCloudConfig.seatAllocationTemplate} built ${list.length} '
        'msg(s) -> ${list.map((m) => m.to).toList()}');
    return _cloud.send(list);
  }

  /// Builds ONE passenger's `seat_allotment` message — renders + uploads their
  /// seat-chart image header (handler gets the full bus chart, everyone else
  /// their own seats highlighted) and assembles the body params. A failed chart
  /// upload degrades to a no-image message rather than dropping the recipient.
  Future<WaMessage> _buildAllocationMessage(
    Tour tour,
    Passenger p,
    ChartFooter footer,
    String date,
  ) async {
    final busId = p.assignedSeats.first.busId;
    final busMatch = tour.buses.where((b) => b.id == busId).toList();
    final bus = busMatch.isEmpty ? null : busMatch.first;
    final busLabel = bus == null
        ? ''
        : (bus.busNumber.isNotEmpty ? bus.busNumber : bus.name);
    // Template variable order (must match the approved `seat_allotment` body):
    //   {{1}} tour  {{2}} seats  {{3}} bus  {{4}} departure date (+ time when
    //   set)  {{5}} departure PLACE = the bus's boarding point — NOT the name.
    final time = formatHhMm(bus?.departureTime) ?? '';
    final dateLabel = time.trim().isNotEmpty ? '$date · $time' : date;
    final place = bus?.boardingPoint.trim() ?? '';
    final seatNumbers = p.assignedSeats.map((a) => a.seatId).join(', ');

    String? chartUrl;
    try {
      final isHandler = tour.handlerId != null && p.id == tour.handlerId;
      final images = isHandler
          ? await SeatChartPdf.buildTourChartImages(tour: tour, footer: footer)
          : await SeatChartPdf.buildPassengerChartImages(
              tour: tour,
              passenger: p,
              footer: footer,
            );
      if (images.isNotEmpty) {
        chartUrl = await _cloud.uploadSigned(
          bucket: WhatsAppCloudConfig.seatChartBucket,
          path: '${tour.id}/${p.id}.png',
          bytes: images.first,
          contentType: 'image/png',
        );
      }
    } catch (e) {
      debugPrint('[WA] chart image failed for ${p.id}: $e');
    }

    return WaMessage(
      to: WhatsAppCloudService.graphPhone(p.phone),
      template: WhatsAppCloudConfig.seatAllocationTemplate,
      headerImageUrl: chartUrl,
      bodyParams: [tour.title, seatNumbers, busLabel, dateLabel, place],
    );
  }

  /// Per-bus free-text announcement (F4 — ADMIN path). The signed-in agent
  /// types one [messageText] and it goes to every passenger seated on [busId]
  /// (anyone holding a seat assignment on that bus, either leg). Builds one
  /// `busMessageTemplate` message per recipient — body var {{1}} = the typed
  /// text — and routes the batch through the same `quick-action` Edge Function
  /// the other sends use. Never throws on a per-recipient failure; inspect
  /// [WaSendResult]. (The HANDLER path goes through the dedicated `bus-message`
  /// function instead — see WhatsAppCloudService.sendBusMessageAsHandler.)
  Future<WaSendResult> sendBusMessage({
    required Tour tour,
    required String busId,
    required String messageText,
  }) async {
    final recipients = tour.passengers
        .where((p) => p.assignedSeats.any((a) => a.busId == busId))
        .toList();
    if (recipients.isEmpty) {
      debugPrint('[WA] sendBusMessage early-return: no passengers on bus $busId');
      return WaSendResult.empty;
    }

    final messages = recipients
        .map(
          (p) => WaMessage(
            to: WhatsAppCloudService.graphPhone(p.phone),
            template: WhatsAppCloudConfig.busMessageTemplate,
            bodyParams: [messageText],
          ),
        )
        .toList();

    debugPrint('[WA] sendBusMessage: template='
        '${WhatsAppCloudConfig.busMessageTemplate} bus=$busId built '
        '${messages.length} msg(s) -> ${messages.map((m) => m.to).toList()}');
    return _cloud.send(messages);
  }
}
