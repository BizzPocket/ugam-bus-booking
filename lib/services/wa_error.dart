/// Meta Cloud API failures, classified into causes an agent can act on.
///
/// Every send failure used to reach the agent the same way: Meta's raw English
/// sentence appended to a Gujarati snackbar. "(#132000) Param text cannot have
/// new-line/tab characters", "(#131026) Unable to deliver message" and
/// "(#132015) Template is paused" are three completely different problems —
/// one is fixed by tapping Fix automatically, one by phoning the passenger,
/// and one only by editing the template in Meta Business Manager. Presented
/// identically, all three read as "it didn't work".
///
/// This module maps a code to a [WaErrorCause]. The localized sentence pair
/// (what happened / what to do about it) lives in `utils/wa_error_text.dart`,
/// mirroring how [WaTemplateParams] and `utils/wa_param_error_text.dart`
/// already split the rule set from its wording.
///
/// Pure (no Flutter, no network, no translations) so the classification is
/// unit-testable and identical wherever a failure is rendered.
library;

/// What actually went wrong, at the granularity the reader can act on.
enum WaErrorCause {
  // ── The message text ──────────────────────────────────────────────────────
  /// `132000`, new-line/tab/space variant. Fixable in the composer.
  paramFormatting,

  /// `132000`, parameter-count variant — the request carried a different
  /// number of values than the approved template declares. NOT a text problem:
  /// the app's variable contract and the Meta template have drifted apart.
  /// Sharing one code with [paramFormatting] is why this was never diagnosed.
  paramCountMismatch,

  /// `132005`. The assembled body exceeded 1024 characters.
  bodyTooLong,

  // ── The template itself ───────────────────────────────────────────────────
  /// `132001`. Wrong name, or not approved in the language we asked for.
  templateNotFound,

  /// `132007`. Content violates WhatsApp policy.
  templatePolicy,

  /// `132012`. A component's shape differs from the approved template —
  /// typically a missing IMAGE header on `seat_allotment`.
  templateFormatMismatch,

  /// `132015`. Paused for low quality; sends resume if quality recovers.
  templatePaused,

  /// `132016`. Paused once too often and now permanently disabled.
  templateDisabled,

  // ── The recipient ─────────────────────────────────────────────────────────
  /// `131026`. Not reachable on WhatsApp — no account, old client, or terms
  /// not accepted. The only fix is a phone call.
  notWhatsAppUser,

  /// `131047`. Outside the 24-hour service window for a free-form message.
  outsideWindow,

  /// Our own: the stored phone could not be made dialable at all.
  noNumberOnFile,

  // ── Media ─────────────────────────────────────────────────────────────────
  /// `131053`. Meta refused the header media (type or size).
  mediaRejected,

  /// Our own: the seat chart never rendered or uploaded, so there was no image
  /// to attach. Distinct from [mediaRejected] — the break is local.
  chartFailed,

  // ── Setup ─────────────────────────────────────────────────────────────────
  /// `133010`. The sending number is not registered on the platform.
  senderNotRegistered,

  /// `190` and the 0/2/3/10 family. The access token is expired or unscoped.
  authFailed,

  /// Our own: the Edge Function has no `WHATSAPP_TOKEN` / phone-number-id.
  configMissing,

  /// `4`, `80007`, `130429`, `131048`. Too many sends too quickly.
  rateLimited,

  /// `100`, `131008`, `131009`. Malformed request — a developer-side defect.
  badRequest,

  /// Anything unmapped. The raw Meta text is still shown, so an unmapped code
  /// is never LESS informative than before this module existed.
  unknown,
}

/// A classified failure: the cause, plus the code and raw text it came from so
/// nothing Meta said is lost.
class WaErrorInfo {
  final WaErrorCause cause;
  final int? code;
  final String rawMessage;

  const WaErrorInfo({
    required this.cause,
    this.code,
    this.rawMessage = '',
  });

  /// True when the sender can fix this themselves in the composer.
  bool get isFixableHere => cause == WaErrorCause.paramFormatting ||
      cause == WaErrorCause.bodyTooLong;

  /// True when retrying the same message could plausibly succeed. A rejected
  /// template or a non-WhatsApp number will fail identically every time, and
  /// offering Retry for those wastes the agent's time.
  bool get isRetryable => switch (cause) {
        WaErrorCause.rateLimited ||
        WaErrorCause.chartFailed ||
        WaErrorCause.mediaRejected ||
        WaErrorCause.unknown =>
          true,
        _ => false,
      };

  @override
  String toString() => 'WaErrorInfo(${cause.name}, code $code)';

  @override
  bool operator ==(Object other) =>
      other is WaErrorInfo &&
      other.cause == cause &&
      other.code == code &&
      other.rawMessage == rawMessage;

  @override
  int get hashCode => Object.hash(cause, code, rawMessage);
}

/// Turns what the wire gave us into a [WaErrorInfo].
class WaError {
  WaError._();

  /// Meta prefixes its message with the code in parentheses, e.g.
  /// "(#132000) Param text cannot have new-line/tab characters". When the
  /// Edge Function predates the structured `code` field, that prefix is the
  /// only place the code exists.
  static final RegExp _codeInMessage = RegExp(r'\(#(\d+)\)');

  /// The substring that distinguishes 132000's two meanings. Meta's count
  /// variant reads "number of parameters does not match"; the formatting
  /// variant reads "Param text cannot have new-line/tab characters …".
  static final RegExp _countMismatch = RegExp(
    r'number of (localizable_params|parameters)|param(eter)?s? does not match|'
    r'expected number of params',
    caseSensitive: false,
  );

  /// Classifies a failure from an explicit [code] (preferred) and/or Meta's
  /// [message]. Either may be absent; when [code] is null it is recovered from
  /// the `(#nnnnn)` prefix in [message].
  static WaErrorInfo classify({int? code, String? message}) {
    final raw = (message ?? '').trim();
    final resolved = code ?? _codeFromMessage(raw);

    if (resolved == null) return WaErrorInfo(cause: _fromText(raw), rawMessage: raw);

    final cause = switch (resolved) {
      // 132000 is overloaded: same code, opposite remedies. The text decides.
      132000 => _countMismatch.hasMatch(raw)
          ? WaErrorCause.paramCountMismatch
          : WaErrorCause.paramFormatting,
      132001 => WaErrorCause.templateNotFound,
      132005 => WaErrorCause.bodyTooLong,
      132007 => WaErrorCause.templatePolicy,
      132012 || 132068 || 132069 => WaErrorCause.templateFormatMismatch,
      132015 => WaErrorCause.templatePaused,
      132016 => WaErrorCause.templateDisabled,
      131026 => WaErrorCause.notWhatsAppUser,
      131047 => WaErrorCause.outsideWindow,
      131053 || 131052 => WaErrorCause.mediaRejected,
      133010 || 133005 || 133009 => WaErrorCause.senderNotRegistered,
      190 || 0 || 2 || 3 || 10 => WaErrorCause.authFailed,
      4 || 80007 || 130429 || 131048 => WaErrorCause.rateLimited,
      100 || 131008 || 131009 || 131000 => WaErrorCause.badRequest,
      _ => WaErrorCause.unknown,
    };
    return WaErrorInfo(cause: cause, code: resolved, rawMessage: raw);
  }

  static int? _codeFromMessage(String message) {
    final m = _codeInMessage.firstMatch(message);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Last resort for a codeless failure: the Edge Functions and this app both
  /// emit a few plain-English reasons of their own (no token configured, no
  /// usable number, chart render failed). Recognising them keeps locally
  /// generated failures in the same grouped, explained presentation as Meta's.
  static WaErrorCause _fromText(String raw) {
    final t = raw.toLowerCase();
    if (t.isEmpty) return WaErrorCause.unknown;
    if (t.contains('not configured') || t.contains('whatsapp_token')) {
      return WaErrorCause.configMissing;
    }
    if (t.contains('no usable whatsapp number') ||
        t.contains('no usable number')) {
      return WaErrorCause.noNumberOnFile;
    }
    if (t.contains('seat chart')) return WaErrorCause.chartFailed;
    return WaErrorCause.unknown;
  }

  /// Groups a batch's failures by cause, most-affected first, so a dialog can
  /// say "3 numbers are not on WhatsApp" instead of listing three identical
  /// sentences. Ordering is stable for equal counts.
  static List<MapEntry<WaErrorCause, List<T>>> groupByCause<T>(
    Iterable<T> failures,
    WaErrorInfo Function(T) infoOf,
  ) {
    final byCause = <WaErrorCause, List<T>>{};
    for (final f in failures) {
      byCause.putIfAbsent(infoOf(f).cause, () => []).add(f);
    }
    // Dart's List.sort is not guaranteed stable, so first-seen order is carried
    // explicitly as the tie-break. Without it, two causes with equal counts
    // could swap places between rebuilds and the dialog would visibly reorder
    // itself while the agent is reading it.
    final order = byCause.keys.toList();
    final entries = byCause.entries.toList();
    entries.sort((a, b) {
      final byCount = b.value.length.compareTo(a.value.length);
      return byCount != 0
          ? byCount
          : order.indexOf(a.key).compareTo(order.indexOf(b.key));
    });
    return entries;
  }
}
