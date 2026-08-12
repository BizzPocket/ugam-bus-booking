import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/whatsapp_cloud_config.dart';
import 'wa_error.dart';
import 'wa_template_params.dart';

/// One recipient's outcome from a Cloud API batch send.
class WaRecipientResult {
  final String to;
  final bool ok;
  final String? id;
  final String? error;

  /// Meta's numeric error code, when the Edge Function reported one. Kept
  /// separate from [error] because the code is what can be MAPPED to a cause
  /// and a remedy, while the message is only what can be quoted.
  ///
  /// Null for a locally generated failure (no usable number, chart render
  /// failed) and for an Edge Function deployed before the structured `code`
  /// field — [WaError.classify] recovers those from the text instead.
  final int? code;

  /// The passenger this result belongs to, when the caller knew it. Lets a
  /// failure be reported by NAME ("phone Rameshbhai") rather than by a bare
  /// number the agent then has to look up.
  final String? passengerId;

  const WaRecipientResult({
    required this.to,
    required this.ok,
    this.id,
    this.error,
    this.code,
    this.passengerId,
  });

  factory WaRecipientResult.fromMap(Map<String, dynamic> m) => WaRecipientResult(
        to: (m['to'] ?? '').toString(),
        ok: m['ok'] == true,
        id: m['id']?.toString(),
        error: m['error']?.toString(),
        code: _asInt(m['code']),
      );

  /// This failure, classified into a cause the agent can act on.
  WaErrorInfo get info => WaError.classify(code: code, message: error);

  /// Meta returns the code as a number, but a JSON round-trip through an older
  /// function shape can deliver it as a string. Accept both rather than lose
  /// the one field that makes a failure explainable.
  static int? _asInt(Object? v) => switch (v) {
        int i => i,
        num n => n.toInt(),
        String s => int.tryParse(s.trim()),
        _ => null,
      };

  WaRecipientResult withPassengerId(String? id) => WaRecipientResult(
        to: to,
        ok: ok,
        id: this.id,
        error: error,
        code: code,
        passengerId: id ?? passengerId,
      );
}

/// Aggregate result of a Cloud API batch send.
class WaSendResult {
  final int sent;
  final int failed;
  final List<WaRecipientResult> results;

  const WaSendResult({
    required this.sent,
    required this.failed,
    required this.results,
  });

  static const empty = WaSendResult(sent: 0, failed: 0, results: []);

  bool get allSent => failed == 0 && sent > 0;
  bool get anySent => sent > 0;

  /// Just the recipients that did not receive the message.
  List<WaRecipientResult> get failures =>
      results.where((r) => !r.ok).toList(growable: false);

  /// Failures gathered by cause, most-affected first — so a summary can say
  /// "3 numbers are not on WhatsApp" once instead of repeating one sentence
  /// three times.
  List<MapEntry<WaErrorCause, List<WaRecipientResult>>> get failuresByCause =>
      WaError.groupByCause(failures, (r) => r.info);

  /// Passenger ids worth trying again — those whose failure could plausibly
  /// succeed on a second attempt. Feeds `sendSeatAllocations(onlyPassengerIds:)`.
  /// A non-WhatsApp number or a disabled template is excluded: it would fail
  /// identically and waste the agent's time.
  Set<String> get retryablePassengerIds => {
        for (final r in failures)
          if (r.passengerId != null && r.info.isRetryable) r.passengerId!,
      };
}

/// Raised when a WhatsApp Edge Function refuses the whole send (a non-2xx
/// reply), e.g. the 403 the `bus-message` function returns when the caller is
/// not this bus's handler or the tour is not yet locked. Carries the server's
/// real [reason] (from the response body) so callers/logs can diagnose the
/// failure instead of seeing an opaque transport error.
class WhatsAppSendException implements Exception {
  final String reason;
  final int? status;

  const WhatsAppSendException(this.reason, {this.status});

  @override
  String toString() =>
      'WhatsAppSendException(${status != null ? 'status: $status, ' : ''}$reason)';
}

/// A single templated WhatsApp message to send through the Edge Function.
class WaMessage {
  final String to;
  final String template;
  final String language;

  /// Text values for a TEXT header's `{{1}}, {{2}}, …` variables (e.g. the
  /// `seat_allotment` confirmation, whose header is `Jai Gurudev {{1}},`).
  /// Mutually exclusive with [headerImageUrl] / [headerDocumentUrl].
  final List<String> headerTextParams;
  final String? headerImageUrl;
  final String? headerDocumentUrl;
  final String? headerDocumentFilename;
  final List<String> bodyParams;

  const WaMessage({
    required this.to,
    required this.template,
    this.language = WhatsAppCloudConfig.defaultLanguage,
    this.headerTextParams = const [],
    this.headerImageUrl,
    this.headerDocumentUrl,
    this.headerDocumentFilename,
    this.bodyParams = const [],
  });

  Map<String, dynamic> toJson() => {
        'to': to,
        'template': template,
        'language': language,
        if (headerTextParams.isNotEmpty) 'headerTextParams': headerTextParams,
        if (headerImageUrl != null) 'headerImageUrl': headerImageUrl,
        if (headerDocumentUrl != null) 'headerDocumentUrl': headerDocumentUrl,
        if (headerDocumentFilename != null)
          'headerDocumentFilename': headerDocumentFilename,
        'bodyParams': bodyParams,
      };
}

/// Client for the official WhatsApp Cloud API, routed through the
/// `whatsapp-send` Supabase Edge Function (which holds the token). Also handles
/// uploading the broadcast image / seat-chart PDF to public Storage so the
/// Cloud API can fetch template header media by URL.
class WhatsAppCloudService {
  SupabaseClient get _client => Supabase.instance.client;

  /// Formats a stored phone to Graph's country-code + number digits, e.g.
  /// `919876543210`. Returns `''` when the number cannot be dialled at all, so
  /// callers can REPORT that rider instead of putting a malformed `to` on the
  /// wire (see [WhatsAppOutbound.unreachableBusRiders]).
  ///
  /// This used to add the country code only when the stripped number was
  /// EXACTLY 10 digits. Numbers written the way people actually keep them —
  /// `0 98765 43210` with the domestic trunk prefix, or `0091 …` with the
  /// international access prefix — stripped to 11 or 14 digits, so they were
  /// passed to Meta with no country code and that ONE rider silently never
  /// received the announcement while everyone else did. That is the "some
  /// passengers don't get the msg" report.
  static String graphPhone(String phone) {
    var digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return '';
    const cc = WhatsAppCloudConfig.defaultCountryCode;

    // "00" / "011"-style international access prefix written before the code.
    if (digits.length > 10 && digits.startsWith('00')) {
      digits = digits.substring(2);
    }
    // Already exactly country code + 10 digits — nothing to do.
    if (digits.length == cc.length + 10 && digits.startsWith(cc)) return digits;

    // Domestic trunk prefix: a 0 parked in front of the 10-digit mobile number.
    while (digits.length > 10 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    // Country code plus stray leading digits → keep the last 10, matching the
    // rule [displayPhone] already applies when rendering the same number.
    if (digits.length > 10 && digits.startsWith(cc)) {
      digits = digits.substring(digits.length - 10);
    }
    if (digits.length == 10) return '$cc$digits';

    // A genuine FOREIGN number (its own country code, no trunk prefix) is left
    // exactly as stored — this rule must not rewrite a non-Indian rider.
    if (digits.length >= 11 && digits.length <= 15 && !digits.startsWith('0')) {
      return digits;
    }

    // Too short / too long to be a real number. Empty says so out loud.
    return '';
  }

  /// Max messages per Edge Function invocation. Tours can have 200–700
  /// passengers; one giant batch sent sequentially server-side would risk the
  /// function's execution time limit.
  static const int _chunkSize = 20;

  /// Sends a batch of templated messages, split into invocations of at most
  /// [_chunkSize] messages each, and aggregates the per-chunk outcomes into
  /// one [WaSendResult]. Never throws on partial failure — inspect
  /// [WaSendResult.failed] / [WaSendResult.results]. If the FIRST chunk's
  /// invoke throws (config/transport error) it rethrows so the caller's catch
  /// sees it; if a LATER chunk throws, earlier progress is kept and that
  /// chunk's recipients are recorded as failed instead.
  /// [passengerIds], when given, is index-aligned with [messages] and travels
  /// back on each [WaRecipientResult]. It is what lets a failure be reported by
  /// NAME and retried for the right people, instead of leaving the agent with a
  /// bare phone number to match against the roster by hand.
  Future<WaSendResult> send(
    List<WaMessage> messages, {
    List<String>? passengerIds,
  }) async {
    if (messages.isEmpty) return WaSendResult.empty;

    // A message with no recipient can never be delivered, and putting a blank
    // `to` on the wire risks Meta refusing the WHOLE chunk — taking 19 valid
    // recipients down with one bad phone number. [graphPhone] returns '' for a
    // number it cannot make dialable, so filter here rather than at each of the
    // half-dozen call sites: one guard, and no future caller can miss it. The
    // dropped recipients are still REPORTED, never silently discarded.
    final addressed = <WaMessage>[];
    final addressedIds = <String?>[];
    final unaddressed = <WaRecipientResult>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final pid = (passengerIds != null && i < passengerIds.length)
          ? passengerIds[i]
          : null;
      if (m.to.trim().isEmpty) {
        unaddressed.add(WaRecipientResult(
          to: '',
          ok: false,
          passengerId: pid,
          error: 'No usable WhatsApp number for this passenger '
              '— contact them by phone.',
        ));
      } else {
        addressed.add(m);
        addressedIds.add(pid);
      }
    }
    if (addressed.isEmpty) {
      debugPrint('[WA] send: every recipient lacked a usable number '
          '(${unaddressed.length})');
      return WaSendResult(
        sent: 0,
        failed: unaddressed.length,
        results: unaddressed,
      );
    }
    if (unaddressed.isNotEmpty) {
      debugPrint('[WA] send: dropping ${unaddressed.length} recipient(s) '
          'with no usable number');
    }
    messages = addressed;

    var sent = 0;
    var failed = 0;
    final results = <WaRecipientResult>[];

    for (var start = 0; start < messages.length; start += _chunkSize) {
      final end = start + _chunkSize;
      final stop = end > messages.length ? messages.length : end;
      final chunk = messages.sublist(start, stop);
      // Both Edge Functions build their results index-aligned with the request,
      // so the passenger for result i is the one at chunk position i.
      final chunkIds = addressedIds.sublist(start, stop);
      String? idAt(int i) => i < chunkIds.length ? chunkIds[i] : null;
      final body = {'messages': chunk.map((m) => m.toJson()).toList()};
      try {
        debugPrint('[WA] invoke "${WhatsAppCloudConfig.functionName}" '
            '(${chunk.length} msg) body=$body');
        final res = await _client.functions.invoke(
          WhatsAppCloudConfig.functionName,
          body: body,
        );
        debugPrint('[WA] status=${res.status} data=${res.data}');

        final data = res.data;
        if (data is Map) {
          // A 2xx that still carries a top-level `error` (e.g. the function's
          // own "WHATSAPP_TOKEN not configured") describes the WHOLE chunk.
          // Without this it parsed as zero results and the caller reported
          // "no recipients" — a misdiagnosis of a configuration failure.
          final topLevelError = data['error']?.toString();
          final rawResults = (data['results'] as List?) ?? const [];
          final chunkResults = rawResults
              .whereType<Map>()
              .toList()
              .asMap()
              .entries
              .map((e) => WaRecipientResult.fromMap(
                    Map<String, dynamic>.from(e.value),
                  ).withPassengerId(idAt(e.key)))
              .toList();

          if (chunkResults.isEmpty &&
              topLevelError != null &&
              topLevelError.trim().isNotEmpty) {
            failed += chunk.length;
            results.addAll(chunk.asMap().entries.map((e) => WaRecipientResult(
                  to: e.value.to,
                  ok: false,
                  error: topLevelError,
                  passengerId: idAt(e.key),
                )));
            continue;
          }

          results.addAll(chunkResults);
          sent += (data['sent'] as num?)?.toInt() ??
              chunkResults.where((r) => r.ok).length;
          failed += (data['failed'] as num?)?.toInt() ??
              chunkResults.where((r) => !r.ok).length;
        } else {
          // Neither a Map nor a throw: the reply shape is not one we understand
          // (an HTML error page, a bare string, null). Previously this fell
          // through as 0 sent / 0 failed / no results — indistinguishable from
          // "there was nobody to message", which is exactly how a real failure
          // came to be reported as "no recipients". Record it as a failure of
          // every recipient in the chunk, carrying what we did receive.
          debugPrint('[WA] unexpected reply shape: ${data.runtimeType} / $data');
          failed += chunk.length;
          results.addAll(chunk.asMap().entries.map((e) => WaRecipientResult(
                to: e.value.to,
                ok: false,
                error: 'Unexpected response from WhatsApp sender '
                    '(HTTP ${res.status})',
                passengerId: idAt(e.key),
              )));
        }
      } catch (err) {
        debugPrint('[WA] invoke FAILED: $err');
        if (start == 0) rethrow;
        failed += chunk.length;
        results.addAll(chunk.asMap().entries.map(
              (entry) => WaRecipientResult(
                to: entry.value.to,
                ok: false,
                error: err.toString(),
                passengerId: idAt(entry.key),
              ),
            ));
      }
    }
    return WaSendResult(
      sent: sent,
      failed: failed + unaddressed.length,
      results: [...results, ...unaddressed],
    );
  }

  /// Per-bus announcement, HANDLER path (F4). The handler has no Supabase Auth
  /// session, so this goes through the dedicated `bus-message` Edge Function
  /// (verify_jwt = false), which re-checks `is_request_handler([requestId])` and
  /// that the bus's `handler_passenger_id` is that handler before sending. The
  /// function loads that bus's passenger phones server-side and sends the
  /// `busMessageTemplate` (body {{1}} = [message]) via the Graph API, returning
  /// the same `{results, sent, failed}` shape [send] parses.
  ///
  /// On a non-2xx reply `invoke()` THROWS a [FunctionException] (most notably the
  /// 403 the function returns when the caller is not this bus's handler / the
  /// tour is not yet locked); the concrete reason lives in the JSON body. We
  /// catch it and rethrow a [WhatsAppSendException] carrying that real reason so
  /// the failure is DIAGNOSABLE — rather than swallowing it behind an opaque
  /// transport error. A per-recipient failure never throws — inspect
  /// [WaSendResult]; a malformed 2xx reply returns [WaSendResult.empty].
  Future<WaSendResult> sendBusMessageAsHandler({
    required String requestId,
    required String busId,
    required String message,
  }) async {
    // The handler composer applies the same repair, but this method is the
    // only door to `bus-message` and it used to forward whatever it was given.
    // Meta refuses a parameter carrying a line break with 132000 for EVERY
    // passenger on the bus, so a handler typing two paragraphs reached nobody
    // and saw nothing explaining it. Repairing here — as the admin path
    // already did — means neither the client nor the server can be the gap.
    final safe = WaTemplateParams.sanitize(message);
    final body = {'requestId': requestId, 'busId': busId, 'message': safe};
    debugPrint('[WA] invoke "bus-message" (handler) body=$body');
    final FunctionResponse res;
    try {
      res = await _client.functions.invoke('bus-message', body: body);
    } on FunctionException catch (e) {
      final reason = _functionErrorReason(e);
      debugPrint('[WA] bus-message FAILED status=${e.status} reason=$reason');
      throw WhatsAppSendException(reason, status: e.status);
    }
    debugPrint('[WA] bus-message status=${res.status} data=${res.data}');

    final data = res.data;
    if (data is! Map) return WaSendResult.empty;

    final rawResults = (data['results'] as List?) ?? const [];
    final results = rawResults
        .whereType<Map>()
        .map((r) => WaRecipientResult.fromMap(Map<String, dynamic>.from(r)))
        .toList();
    final sent = (data['sent'] as num?)?.toInt() ??
        results.where((r) => r.ok).length;
    final failed = (data['failed'] as num?)?.toInt() ??
        results.where((r) => !r.ok).length;
    return WaSendResult(sent: sent, failed: failed, results: results);
  }

  /// Pulls the human-readable reason out of a failed Edge Function reply. The
  /// `bus-message` function reports failures as `{ "error": "<reason>" }` in the
  /// JSON body, surfaced as [FunctionException.details]; fall back to the raw
  /// details / HTTP reason phrase / status when the shape differs.
  static String _functionErrorReason(FunctionException e) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    if (d is String && d.trim().isNotEmpty) return d;
    if (d != null) return d.toString();
    return e.reasonPhrase ?? 'HTTP ${e.status}';
  }

  /// Default lifetime for an upload link. The Cloud API fetches the media once
  /// at send time, so a few days is ample.
  static const int _signedUrlTtlSeconds = 7 * 24 * 60 * 60; // 7 days

  /// Uploads [bytes] to Storage [bucket]/[path] and returns a SIGNED URL that
  /// expires after [ttlSeconds]. Upserts so re-sends reuse the path.
  ///
  /// THE SIGNATURE IS THE ACCESS CONTROL — do not "fix" this by making a
  /// bucket public.
  ///
  /// This docstring used to claim that migration 009 makes both buckets
  /// public-read, so signing was cosmetic. That has been false since 011:139
  /// made seat-charts private, and 051 deliberately kept it private because an
  /// object here is a rendered roster: every occupant's name and phone, their
  /// pickup point, and the handler's contact details.
  ///
  /// Meta does not need a public bucket. It fetches
  /// `/object/sign/<bucket>/<path>?token=<jwt>`, which storage-api authorises
  /// by validating the token — no database role is involved. Proof inside this
  /// repo: 059 makes wa-media private with a single owner-scoped
  /// `to authenticated` policy and NO anon policy at all, and
  /// whatsapp_inbox_service.dart mints signed URLs that conversation_screen
  /// renders with Image.network, sending neither apikey nor Authorization.
  /// That path works in production.
  ///
  /// The stale claim was the likeliest reason someone would re-add
  /// `wa_seatcharts_public_read` (dropped in 081) and re-expose every
  /// passenger roster ever generated, so it is corrected here rather than
  /// merely deleted.
  ///
  /// The URL still silently EXPIRES, so never persist it in the database; use
  /// [uploadPublic] for that.
  Future<String> uploadSigned({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
    int ttlSeconds = _signedUrlTtlSeconds,
  }) async {
    await _client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    return _client.storage.from(bucket).createSignedUrl(path, ttlSeconds);
  }

  /// Uploads [bytes] to Storage [bucket]/[path] and returns the permanent
  /// PUBLIC URL — for assets whose URL is STORED in the database and must not
  /// expire (e.g. `tours.broadcast_image_url`). Upserts so re-uploads reuse
  /// the path.
  Future<String> uploadPublic({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    await _client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    return _client.storage.from(bucket).getPublicUrl(path);
  }
}
