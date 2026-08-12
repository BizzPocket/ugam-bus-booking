import 'package:easy_localization/easy_localization.dart';

import '../services/wa_error.dart';
import '../services/whatsapp_cloud_service.dart';

/// Turns a classified [WaErrorCause] into the two sentences the agent reads:
/// what went wrong, and what to do about it.
///
/// Kept out of [WaError] so the classification stays free of Flutter and
/// localization — the same split [WaTemplateParams] and `wa_param_error_text`
/// already use. Every surface that reports a failed send goes through here, so
/// the wording cannot drift between the admin composer, the handler composer
/// and the allotment summary.
///
/// The RESOLUTION is the point. "(#131026) Unable to deliver message" told the
/// agent nothing they could act on; "This number is not on WhatsApp — call
/// them instead" tells them exactly what to do next.
String waCauseText(WaErrorCause cause) => tr('wa_error.${_key(cause)}.cause');

/// What to do about it.
String waFixText(WaErrorCause cause) => tr('wa_error.${_key(cause)}.fix');

String _key(WaErrorCause cause) => switch (cause) {
      WaErrorCause.paramFormatting => 'param_formatting',
      WaErrorCause.paramCountMismatch => 'param_count',
      WaErrorCause.bodyTooLong => 'body_too_long',
      WaErrorCause.templateNotFound => 'template_not_found',
      WaErrorCause.templatePolicy => 'template_policy',
      WaErrorCause.templateFormatMismatch => 'template_format',
      WaErrorCause.templatePaused => 'template_paused',
      WaErrorCause.templateDisabled => 'template_disabled',
      WaErrorCause.notWhatsAppUser => 'not_whatsapp_user',
      WaErrorCause.outsideWindow => 'outside_window',
      WaErrorCause.noNumberOnFile => 'no_number',
      WaErrorCause.mediaRejected => 'media_rejected',
      WaErrorCause.chartFailed => 'chart_failed',
      WaErrorCause.senderNotRegistered => 'sender_not_registered',
      WaErrorCause.authFailed => 'auth_failed',
      WaErrorCause.configMissing => 'config_missing',
      WaErrorCause.rateLimited => 'rate_limited',
      WaErrorCause.badRequest => 'bad_request',
      WaErrorCause.unknown => 'unknown',
    };

/// One grouped failure, ready to render: how many recipients, why, and the fix.
class WaFailureGroup {
  final WaErrorCause cause;
  final List<WaRecipientResult> recipients;

  const WaFailureGroup({required this.cause, required this.recipients});

  int get count => recipients.length;

  /// "3 · Not on WhatsApp" — the headline for this group.
  String get causeText => waCauseText(cause);

  /// What the agent should do about these recipients.
  String get fixText => waFixText(cause);

  /// Meta's own words, shown only for an UNMAPPED cause — where our sentence
  /// would say less than the raw text does. Empty otherwise, so a mapped
  /// failure reads as plain language rather than an error dump.
  String get rawDetail {
    if (cause != WaErrorCause.unknown) return '';
    for (final r in recipients) {
      final raw = r.info.rawMessage.trim();
      if (raw.isNotEmpty) return raw;
    }
    return '';
  }
}

/// [result]'s failures gathered by cause, most-affected first.
List<WaFailureGroup> waFailureGroups(WaSendResult result) => [
      for (final entry in result.failuresByCause)
        WaFailureGroup(cause: entry.key, recipients: entry.value),
    ];

/// A compact multi-line summary of why a send did not fully succeed — one
/// "N · cause" line per group, each followed by its fix. Empty when nothing
/// failed.
///
/// This replaces `firstWaError`, which appended Meta's raw English to a
/// Gujarati snackbar and showed only the FIRST failure, hiding the fact that
/// a batch usually fails for two or three different reasons at once.
String waFailureSummary(WaSendResult result) => waFailureGroups(result)
    .map((g) {
      final detail = g.rawDetail;
      return '${g.count} · ${g.causeText}\n${g.fixText}'
          '${detail.isEmpty ? '' : '\n$detail'}';
    })
    .join('\n\n');

/// [waFailureSummary] prefixed with a blank line so it appends cleanly to a
/// "sent N, failed M" headline. Empty when nothing failed.
///
/// This is the drop-in replacement for the old `firstWaError`, which appended
/// Meta's raw English and showed only the FIRST failure — hiding that a batch
/// typically fails for two or three different reasons at once, each needing a
/// different response from the agent.
String waFailureAppendix(WaSendResult result) {
  final summary = waFailureSummary(result);
  return summary.isEmpty ? '' : '\n\n$summary';
}

/// The single most important thing to say when there is only room for one
/// line — the largest failure group's cause and fix. Empty when nothing failed.
String waPrimaryFailure(WaSendResult result) {
  final groups = waFailureGroups(result);
  if (groups.isEmpty) return '';
  final g = groups.first;
  final detail = g.rawDetail;
  return '${g.causeText} ${g.fixText}${detail.isEmpty ? '' : ' ($detail)'}';
}
