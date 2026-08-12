/// Meta's validation rules for WhatsApp **template parameter values**, applied
/// locally BEFORE a send leaves the app.
///
/// The Cloud API rejects a template parameter that contains a new-line, a tab,
/// or more than four consecutive spaces, with:
///
///   (#132000) Param text cannot have new-line/tab characters or more than 4
///   consecutive spaces
///
/// and rejects a body longer than 1024 characters with `132005 Translated text
/// is too long`. Those rejections used to arrive as a per-recipient failure
/// AFTER the batch had been fanned out to Meta — and every one of our callers
/// threw the reason away, so a multi-paragraph announcement simply "did not
/// work" with no explanation anywhere. This module is the pre-flight check that
/// turns that into a specific, fixable message in the composer.
///
/// Deliberately pure (no Flutter, no network, no translations) so the rule set
/// is unit-testable and identical on every surface — admin composer, handler
/// composer, and the outbound service's own defence-in-depth check. Mirrored
/// server-side by `supabase/functions/_shared/wa_rules.ts`, which shares this
/// file's test vectors so the two cannot drift.
library;

import 'package:characters/characters.dart';

/// Which Meta rule a parameter value broke. The UI maps this to a localized
/// sentence; the enum itself never reaches the user.
enum WaParamIssue {
  /// Empty / whitespace-only. Meta rejects a blank body parameter.
  empty,

  /// Contains `\n` or `\r` — the rule that breaks multi-paragraph messages.
  newline,

  /// Contains a tab.
  tab,

  /// Contains a run of MORE than [WaTemplateParams.maxConsecutiveSpaces].
  consecutiveSpaces,

  /// Longer than [WaTemplateParams.maxBodyChars].
  tooLong,

  /// The RENDERED body — the template's own approved text plus every
  /// substituted value — exceeds [WaTemplateParams.maxBodyChars].
  ///
  /// This is the rule a per-parameter check cannot see. `bus_msg` wraps the
  /// typed text in a fixed greeting and closing blessing, so the real budget
  /// for `{{1}}` is 1024 MINUS that static text; `seat_allotment` spends the
  /// same 1024 across seven values. A message that passes [tooLong] can still
  /// come back from Meta as `132005 Translated text is too long`, which is
  /// precisely the refusal nobody could explain.
  ///
  /// Carried with [WaParamViolation.paramIndex] == [WaParamViolation.whole],
  /// because it belongs to the message rather than to any one parameter.
  renderedTooLong,
}

/// One broken rule, located precisely enough to point the agent at it.
class WaParamViolation {
  /// [paramIndex] for a violation that belongs to the whole message rather
  /// than to one parameter — see [WaParamIssue.renderedTooLong].
  static const int whole = -1;

  /// Which rule was broken.
  final WaParamIssue issue;

  /// 0-based index of the offending parameter within `bodyParams`, or
  /// [whole] when the violation is the message's rather than a parameter's.
  final int paramIndex;

  /// For [WaParamIssue.newline] / [WaParamIssue.tab] /
  /// [WaParamIssue.consecutiveSpaces]: how many offending runs were found.
  /// For [WaParamIssue.tooLong]: the actual length. Otherwise 0.
  final int count;

  const WaParamViolation({
    required this.issue,
    required this.paramIndex,
    this.count = 0,
  });

  @override
  String toString() =>
      'WaParamViolation(${issue.name}, param $paramIndex, count $count)';

  @override
  bool operator ==(Object other) =>
      other is WaParamViolation &&
      other.issue == issue &&
      other.paramIndex == paramIndex &&
      other.count == count;

  @override
  int get hashCode => Object.hash(issue, paramIndex, count);
}

/// Meta's parameter rules, as code.
class WaTemplateParams {
  WaTemplateParams._();

  /// Max characters in a template body. Meta counts CHARACTERS, not UTF-8
  /// bytes — but a Gujarati character costs 3 bytes, so a message that looks
  /// modest can still be refused upstream for size. When that happens the real
  /// `132005` reason now reaches the agent instead of being swallowed.
  static const int maxBodyChars = 1024;

  /// Meta allows up to four consecutive spaces; the fifth is a violation.
  static const int maxConsecutiveSpaces = 4;

  static final RegExp _newline = RegExp(r'[\r\n]+');
  static final RegExp _tab = RegExp(r'\t+');
  // Five or more spaces — i.e. MORE than the four Meta permits.
  static final RegExp _tooManySpaces = RegExp(' {5,}');

  /// Every rule [value] breaks, as the single parameter at [paramIndex].
  /// Empty list = Meta will accept it. Order is stable: emptiness first (it
  /// makes the rest moot), then newline, tab, spaces, length.
  static List<WaParamViolation> validateOne(String value, {int paramIndex = 0}) {
    final out = <WaParamViolation>[];

    if (value.trim().isEmpty) {
      return [WaParamViolation(issue: WaParamIssue.empty, paramIndex: paramIndex)];
    }

    final newlines = _newline.allMatches(value).length;
    if (newlines > 0) {
      out.add(WaParamViolation(
        issue: WaParamIssue.newline,
        paramIndex: paramIndex,
        count: newlines,
      ));
    }

    final tabs = _tab.allMatches(value).length;
    if (tabs > 0) {
      out.add(WaParamViolation(
        issue: WaParamIssue.tab,
        paramIndex: paramIndex,
        count: tabs,
      ));
    }

    final spaceRuns = _tooManySpaces.allMatches(value).length;
    if (spaceRuns > 0) {
      out.add(WaParamViolation(
        issue: WaParamIssue.consecutiveSpaces,
        paramIndex: paramIndex,
        count: spaceRuns,
      ));
    }

    final chars = characterCount(value);
    if (chars > maxBodyChars) {
      out.add(WaParamViolation(
        issue: WaParamIssue.tooLong,
        paramIndex: paramIndex,
        count: chars,
      ));
    }

    return out;
  }

  /// How many CHARACTERS [value] is, as a reader would count them.
  ///
  /// Dart's `String.length` is UTF-16 CODE UNITS, so every emoji counts twice
  /// (`'🙏'.length == 2`). A perfectly legal announcement of ~600 characters
  /// carrying emoji measured 1200 and was refused locally as "too long" — the
  /// send was then aborted and NOTHING went out.
  ///
  /// Runes fixed the common case but not the general one: a ZWJ sequence such
  /// as 👨‍👩‍👧‍👦 is SEVEN runes and one visible character, and a Gujarati
  /// consonant carrying a matra is two. Grapheme clusters count what the
  /// sender sees, which is the only number they can act on when told to
  /// shorten a message.
  ///
  /// Meta does not document its own counting rule, so this is a best reading
  /// rather than a proven match. It is strictly closer than runes, and the
  /// server stays the ground truth: a residual mismatch now arrives as a
  /// mapped, explained `132005` instead of a silent refusal.
  static int characterCount(String value) => value.characters.length;

  /// Characters left for free text once [staticBodyChars] of approved template
  /// text is accounted for. Never negative.
  static int freeTextBudget(int staticBodyChars) {
    final left = maxBodyChars - staticBodyChars;
    return left < 0 ? 0 : left;
  }

  /// Length of the message Meta will actually assemble: the template's own
  /// approved text plus every substituted value.
  static int renderedLength({
    required List<String> params,
    required int staticBodyChars,
  }) =>
      staticBodyChars +
      params.fold(0, (sum, p) => sum + characterCount(p));

  /// Every rule broken by a whole template send — each parameter's own rules,
  /// plus the rendered-body limit that no single parameter can reveal.
  ///
  /// [staticBodyChars] is the approved body with its `{{n}}` placeholders
  /// removed, from [WaTemplateCatalog]. Callers without catalog data should
  /// pass [conservativeStaticChars].
  ///
  /// The per-parameter [tooLong] check is deliberately kept as well: it points
  /// at WHICH value is oversized, which the aggregate cannot.
  static List<WaParamViolation> validateRendered({
    required List<String> params,
    required int staticBodyChars,
  }) {
    final out = validateAll(params);
    final rendered = renderedLength(
      params: params,
      staticBodyChars: staticBodyChars,
    );
    if (rendered > maxBodyChars) {
      out.add(WaParamViolation(
        issue: WaParamIssue.renderedTooLong,
        paramIndex: WaParamViolation.whole,
        count: rendered,
      ));
    }
    return out;
  }

  /// Static-text allowance assumed when the live template catalog is
  /// unavailable — a token without `whatsapp_business_management` scope, a
  /// token spanning several business accounts (ambiguous, so the server
  /// refuses to guess), or simply no network yet.
  ///
  /// Sized to comfortably cover the longest of our three approved bodies. It
  /// makes the composer slightly STRICTER than Meta, never looser: refusing a
  /// legal message with a clear "shorten it" beats fanning out a batch that
  /// Meta rejects one recipient at a time.
  static const int conservativeStaticChars = 224;

  /// Every rule broken across a whole `bodyParams` list, in parameter order.
  static List<WaParamViolation> validateAll(List<String> params) => [
        for (var i = 0; i < params.length; i++)
          ...validateOne(params[i], paramIndex: i),
      ];

  /// True when Meta will accept every parameter.
  static bool isValid(List<String> params) => validateAll(params).isEmpty;

  /// Rewrites [value] into the nearest Meta-legal equivalent:
  /// every run of new-lines and every tab collapses to ONE space, runs of more
  /// than four spaces collapse to one, and the result is trimmed.
  ///
  /// Length is deliberately NOT truncated — silently cutting the tail off an
  /// agent's announcement is worse than telling them to shorten it themselves.
  static String sanitize(String value) => value
      .replaceAll(_newline, ' ')
      .replaceAll(_tab, ' ')
      .replaceAll(_tooManySpaces, ' ')
      .trim();

  /// True when [sanitize] would produce something different — i.e. there is an
  /// automatic fix worth offering. False when the only problem is length (or
  /// there is no problem), because that needs a human edit.
  static bool canAutoFix(String value) =>
      value.trim().isNotEmpty && sanitize(value) != value;
}
