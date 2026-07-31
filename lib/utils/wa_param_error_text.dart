import 'package:easy_localization/easy_localization.dart';

import '../services/wa_template_params.dart';
import '../services/whatsapp_cloud_service.dart';

/// Turns the pure [WaParamViolation]s from [WaTemplateParams] into the sentence
/// the agent actually reads. Kept out of the validator so the rule set stays
/// free of Flutter/localization, and shared by every surface that can refuse a
/// send (admin composer, handler composer, snackbars) so the wording can never
/// drift between them.
String waViolationText(WaParamViolation v) => switch (v.issue) {
      WaParamIssue.empty => tr('bus_message.invalid_empty'),
      WaParamIssue.newline => tr(
          'bus_message.invalid_newline',
          namedArgs: {'count': '${v.count}'},
        ),
      WaParamIssue.tab => tr('bus_message.invalid_tab'),
      WaParamIssue.consecutiveSpaces => tr('bus_message.invalid_spaces'),
      WaParamIssue.tooLong => tr(
          'bus_message.invalid_too_long',
          namedArgs: {
            'count': '${v.count}',
            'max': '${WaTemplateParams.maxBodyChars}',
          },
        ),
    };

/// All of [violations] as one readable block, one rule per line. Empty string
/// when there is nothing wrong.
String waViolationsText(List<WaParamViolation> violations) =>
    violations.map(waViolationText).join('\n');

/// The first real failure reason in a batch — Meta's own text, e.g.
/// "(#132000) Param text cannot have new-line/tab characters or more than 4
/// consecutive spaces" — prefixed with a newline so it appends cleanly to a
/// summary line. Empty when nothing carries a reason.
///
/// Both Edge Functions already return `data.error.message` per recipient; every
/// caller used to drop it, which is why a refused send read as "it just didn't
/// work". One shared accessor so no surface can quietly go back to hiding it.
String firstWaError(WaSendResult result) {
  for (final r in result.results) {
    if (!r.ok && (r.error ?? '').trim().isNotEmpty) return '\n${r.error!.trim()}';
  }
  return '';
}
