import 'package:easy_localization/easy_localization.dart';

import '../services/wa_template_params.dart';

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
      // The whole rendered body, not one value — so it names the static frame
      // the agent never typed and says exactly how much has to go.
      WaParamIssue.renderedTooLong => tr(
          'bus_message.invalid_rendered_too_long',
          namedArgs: {
            'count': '${v.count}',
            'max': '${WaTemplateParams.maxBodyChars}',
            'over': '${v.count - WaTemplateParams.maxBodyChars}',
          },
        ),
    };

/// All of [violations] as one readable block, one rule per line. Empty string
/// when there is nothing wrong.
String waViolationsText(List<WaParamViolation> violations) =>
    violations.map(waViolationText).join('\n');

// `firstWaError` lived here. It surfaced Meta's raw English — the right
// instinct, since callers used to drop the reason entirely — but it showed
// only the FIRST failure, and showed it untranslated. A batch normally fails
// for two or three different reasons at once, each needing a different
// response: phone this passenger, shorten that message, wait for Meta to
// un-pause the template. Superseded by `waFailureAppendix` in
// `utils/wa_error_text.dart`, which groups failures by cause and gives each
// one its remedy in the reader's own language.
