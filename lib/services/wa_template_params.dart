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
/// composer, and the outbound service's own defence-in-depth check.
library;

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
}

/// One broken rule, located precisely enough to point the agent at it.
class WaParamViolation {
  /// Which rule was broken.
  final WaParamIssue issue;

  /// 0-based index of the offending parameter within `bodyParams`.
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

  /// How many CHARACTERS [value] is, the way Meta counts them.
  ///
  /// Dart's `String.length` is UTF-16 CODE UNITS, so every emoji counts twice
  /// (`'🙏'.length == 2`). A perfectly legal announcement of ~600 characters
  /// carrying emoji measured 1200 and was refused locally as "too long" — the
  /// send was then aborted and NOTHING went out. Counting runes measures the
  /// characters Meta actually limits, so an emoji costs one.
  static int characterCount(String value) => value.runes.length;

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
