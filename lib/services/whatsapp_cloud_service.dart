import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/whatsapp_cloud_config.dart';

/// One recipient's outcome from a Cloud API batch send.
class WaRecipientResult {
  final String to;
  final bool ok;
  final String? id;
  final String? error;

  const WaRecipientResult({
    required this.to,
    required this.ok,
    this.id,
    this.error,
  });

  factory WaRecipientResult.fromMap(Map<String, dynamic> m) => WaRecipientResult(
        to: (m['to'] ?? '').toString(),
        ok: m['ok'] == true,
        id: m['id']?.toString(),
        error: m['error']?.toString(),
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

  /// Formats a stored phone (10-digit or otherwise) to Graph's
  /// country-code + number digits, e.g. `919876543210`.
  static String graphPhone(String phone) {
    var digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length == 10) {
      digits = '${WhatsAppCloudConfig.defaultCountryCode}$digits';
    }
    return digits;
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
  Future<WaSendResult> send(List<WaMessage> messages) async {
    if (messages.isEmpty) return WaSendResult.empty;

    var sent = 0;
    var failed = 0;
    final results = <WaRecipientResult>[];

    for (var start = 0; start < messages.length; start += _chunkSize) {
      final end = start + _chunkSize;
      final chunk =
          messages.sublist(start, end > messages.length ? messages.length : end);
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
          final rawResults = (data['results'] as List?) ?? const [];
          final chunkResults = rawResults
              .whereType<Map>()
              .map((r) => WaRecipientResult.fromMap(Map<String, dynamic>.from(r)))
              .toList();
          results.addAll(chunkResults);
          sent += (data['sent'] as num?)?.toInt() ??
              chunkResults.where((r) => r.ok).length;
          failed += (data['failed'] as num?)?.toInt() ??
              chunkResults.where((r) => !r.ok).length;
        }
      } catch (e) {
        debugPrint('[WA] invoke FAILED: $e');
        if (start == 0) rethrow;
        failed += chunk.length;
        results.addAll(chunk.map(
          (m) => WaRecipientResult(to: m.to, ok: false, error: e.toString()),
        ));
      }
    }
    return WaSendResult(sent: sent, failed: failed, results: results);
  }

  /// Per-bus announcement, HANDLER path (F4). The handler has no Supabase Auth
  /// session, so this goes through the dedicated `bus-message` Edge Function
  /// (verify_jwt = false), which re-checks `is_request_handler([requestId])` and
  /// that the bus's `handler_passenger_id` is that handler before sending. The
  /// function loads that bus's passenger phones server-side and sends the
  /// `busMessageTemplate` (body {{1}} = [message]) via the Graph API, returning
  /// the same `{results, sent, failed}` shape [send] parses. Returns
  /// [WaSendResult.empty] on an unauthorized (403) / malformed reply; never
  /// throws on a per-recipient failure — inspect [WaSendResult].
  Future<WaSendResult> sendBusMessageAsHandler({
    required String requestId,
    required String busId,
    required String message,
  }) async {
    final body = {'requestId': requestId, 'busId': busId, 'message': message};
    debugPrint('[WA] invoke "bus-message" (handler) body=$body');
    final res = await _client.functions.invoke('bus-message', body: body);
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

  /// Default lifetime for an upload link. The Cloud API fetches the media once
  /// at send time, so a few days is ample.
  static const int _signedUrlTtlSeconds = 7 * 24 * 60 * 60; // 7 days

  /// Uploads [bytes] to Storage [bucket]/[path] and returns a SIGNED URL that
  /// expires after [ttlSeconds]. Upserts so re-sends reuse the path.
  ///
  /// NOTE: this is NOT access control. Migration 009 makes both buckets
  /// public-read (Meta must fetch template media by plain URL), so the object
  /// stays reachable at its public path regardless of signing. Fine for a
  /// send-time fetch — but the URL silently EXPIRES, so never persist it in
  /// the database; use [uploadPublic] for that.
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
