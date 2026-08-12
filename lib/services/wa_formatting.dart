/// WhatsApp's inline text formatting, as it applies to what an agent types.
///
/// WhatsApp renders `*bold*`, `_italic_`, `~strikethrough~` and
/// `` `monospace` `` (also triple-backtick) in the DELIVERED message. Meta
/// accepts these characters in a template parameter without complaint — which
/// is exactly the problem: an announcement typed with an asterisk around a time
/// ("બસ *સવારે 6* વાગ્યે") arrives with that phrase silently bold, and one with
/// a stray pair of tildes arrives struck through. Nothing in the app ever told
/// the sender that would happen.
///
/// So this is ADVISORY, deliberately kept out of [WaTemplateParams]: a message
/// carrying formatting marks is perfectly sendable and must never be blocked.
/// The composer uses [parse] to show what will actually arrive, and offers
/// [toPlain] to the sender who did not mean it.
///
/// Only PAIRED marks are recognised, because only paired marks format. A lone
/// asterisk in "10*20" renders as a literal asterisk and must not be flagged —
/// flagging it would train senders to ignore the warning.
///
/// Pure (no Flutter, no network) so the rules are unit-testable and can be
/// mirrored server-side.
library;

/// One of WhatsApp's four inline styles.
enum WaStyle { bold, italic, strikethrough, monospace }

/// A run of text carrying zero or more [WaStyle]s, for rendering the preview.
class WaSpan {
  final String text;
  final Set<WaStyle> styles;

  const WaSpan(this.text, [this.styles = const {}]);

  @override
  String toString() =>
      'WaSpan(${styles.map((s) => s.name).join('+')}: ${text.replaceAll('\n', r'\n')})';

  @override
  bool operator ==(Object other) =>
      other is WaSpan &&
      other.text == text &&
      other.styles.length == styles.length &&
      other.styles.every(styles.contains);

  @override
  int get hashCode => Object.hash(text, Object.hashAllUnordered(styles));
}

/// Detects and removes WhatsApp's inline formatting.
class WaFormatting {
  WaFormatting._();

  /// A marker pairs only when it wraps at least one non-space character and
  /// neither side of the content is whitespace — the rule WhatsApp itself
  /// applies. `*x*` and `*two words*` format; `* x *` and a lone `10*20` do not.
  ///
  /// The content may not contain the marker itself or a newline, so a marker
  /// left open at the end of one line cannot reach down and capture the next.
  static RegExp _pair(String marker) {
    final m = RegExp.escape(marker);
    return RegExp('$m(\\S|\\S[^$m\\n]*\\S)$m');
  }

  // Triple-backtick is tried BEFORE single, so ```code``` is one monospace run
  // rather than a backtick-delimited fragment starting with two backticks.
  static final _monospaceBlock = RegExp(r'```(\S|\S[^\n]*?\S)```');
  static final _markers = <WaStyle, RegExp>{
    WaStyle.bold: _pair('*'),
    WaStyle.italic: _pair('_'),
    WaStyle.strikethrough: _pair('~'),
    WaStyle.monospace: _pair('`'),
  };

  /// [text] split into styled runs, exactly as WhatsApp will render it.
  /// Nested marks compose, so `*_x_*` yields one span carrying both styles.
  static List<WaSpan> parse(String text) => _parse(text, const {});

  static List<WaSpan> _parse(String text, Set<WaStyle> inherited) {
    if (text.isEmpty) return const [];

    // The EARLIEST match across every marker wins, so styles are recognised in
    // the order they were typed rather than in marker order.
    RegExpMatch? best;
    WaStyle? bestStyle;

    for (final entry in <MapEntry<WaStyle, RegExp>>[
      MapEntry(WaStyle.monospace, _monospaceBlock),
      ..._markers.entries,
    ]) {
      final m = entry.value.firstMatch(text);
      if (m == null) continue;
      if (best == null || m.start < best.start) {
        best = m;
        bestStyle = entry.key;
      }
    }

    if (best == null || bestStyle == null) return [WaSpan(text, inherited)];

    return [
      if (best.start > 0) WaSpan(text.substring(0, best.start), inherited),
      ..._parse(best.group(1)!, {...inherited, bestStyle}),
      ..._parse(text.substring(best.end), inherited),
    ];
  }

  /// Every style [text] will actually render, in the order first encountered.
  /// Empty when the text carries no paired marks.
  static List<WaStyle> marksIn(String text) {
    final out = <WaStyle>[];
    for (final span in parse(text)) {
      for (final s in span.styles) {
        if (!out.contains(s)) out.add(s);
      }
    }
    return out;
  }

  /// True when [text] will arrive with some formatting applied.
  static bool hasMarks(String text) => marksIn(text).isNotEmpty;

  /// [text] with every PAIRED marker removed, so the words arrive literally.
  /// Unpaired markers are left exactly as typed — they were always going to
  /// render as themselves, and deleting them would silently edit the message.
  static String toPlain(String text) =>
      parse(text).map((s) => s.text).join();
}
