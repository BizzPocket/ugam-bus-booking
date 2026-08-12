import 'package:flutter/material.dart';

/// Typography for the Ugam UI — futuristic-simple rebuild.
///
/// Two families, both bundled as variable TTFs (no `google_fonts` runtime
/// fetch): **Sora** carries the display voice — big calm hero figures, section
/// titles and numerals — and **Inter** carries body / small UI text where its
/// tighter metrics read better at size. Numeric styles set
/// `FontFeature.tabularFigures()` so counts and prices line up. Apply colour
/// at the call site via `.copyWith(color: ...)`.
///
/// ## The ladder
///
/// | Step            | Family | Size | Weight | Translated text? |
/// |-----------------|--------|------|--------|------------------|
/// | [hero]          | Sora   | 56*  | w300   | figures only     |
/// | [display]       | Sora   | 32   | w600   | yes              |
/// | [titleXl]       | Sora   | 26   | w600   | yes              |
/// | [titleL]        | Sora   | 22   | w600   | yes              |
/// | [titleM]        | Sora   | 18   | w600   | yes              |
/// | [titleS]        | Sora   | 15   | w600   | yes              |
/// | [bodyLg]        | Inter  | 15   | w500   | yes              |
/// | [body]          | Inter  | 14   | w500   | yes              |
/// | [bodyStrong]    | Inter  | 14   | w600   | yes              |
/// | [label]         | Inter  | 13   | w700   | yes              |
/// | [caption]       | Inter  | 12   | w500   | yes              |
/// | [captionStrong] | Inter  | 12   | w600   | yes              |
/// | [micro]         | Sora   | 10   | w600   | **NO — Latin only** |
/// | [numLg]         | Sora   | 20   | w600   | figures only     |
/// | [numXl]         | Sora   | 26   | w600   | figures only     |
///
/// \* [hero] expects its size to be set at the call site.
///
/// ## Which family
///
/// **Sora** is the display voice: page titles, hero figures, numerals. Use it
/// when the text is a headline or a number, i.e. when the reader scans it
/// rather than reads it.
///
/// **Inter** is everything the reader actually reads as language: values,
/// sentences, captions, labels, badges, empty-state copy. If a string comes
/// out of `.tr()`, it belongs on an Inter step.
///
/// ## Scripts — read this before picking a small step
///
/// The app ships Gujarati (primary), Hindi and English. Neither Inter nor Sora
/// carries Gujarati or Devanagari glyphs, so those runs fall through to
/// [indicFallback] — the two bundled Noto faces — for the glyphs themselves.
/// Three consequences:
///
///   * **12 is the floor.** `UgamScale` feeds a 0.85 factor into
///     `MediaQuery.textScaler` on small phones, so a 12 renders at 10.2 —
///     about the smallest a Gujarati conjunct stack survives. There is
///     deliberately **no 11 step**: 11 lands at 9.35 and would just be a new
///     version of [micro]'s bug. If 12 feels too loud, reach for colour
///     ([captionStrong] + `ink2`) or less text, never a smaller size.
///   * **Never force tracking on a step you'll translate.** `letterSpacing`
///     pulls apart conjuncts that are meant to join — it damages the script,
///     it doesn't style it.
///   * **`.toUpperCase()` is a no-op in Indic scripts.** Any design that
///     leans on caps for emphasis silently does nothing in the primary
///     language. Emphasis must come from weight and colour instead — and
///     because [indicFallback] ships **only the 400 face**, weight is
///     synthesised or ignored in Indic (see below), which makes **colour the
///     one emphasis device that always lands**.
///
/// ## Common mis-picks
///
///   * A subtitle under a title → [caption] or [body] with `ink2`. Not
///     [micro]; it is an eyebrow voice, not running text.
///   * A badge numeral or count → [captionStrong], or
///     `tabular(captionStrong)` if it sits in a column with others.
///     Not [micro].
///   * A section eyebrow over translated copy → [label]. Not [micro].
class UgamText {
  const UgamText._();

  static const String _display = 'Sora';
  static const String _body = 'Inter';

  /// The Indic faces every step below falls through to, in order.
  ///
  /// Both are registered as real font families under `fonts:` in
  /// `pubspec.yaml` — `NotoSansGujarati-Regular.ttf` and
  /// `NotoSansDevanagari-Regular.ttf`. They are *fallbacks*, never a primary
  /// family: Flutter consults a fallback only for a codepoint the primary
  /// family cannot draw, so Latin, digits and punctuation still come out of
  /// Inter/Sora with metrics unchanged to the pixel. Gujarati first — it is
  /// the primary language; a Devanagari codepoint is absent from the Gujarati
  /// face and simply moves to the next entry.
  ///
  /// ## Why this exists at all
  ///
  /// Before it, nothing in the app named a face that could draw its own
  /// primary language. Every Gujarati and Hindi string was rendered by
  /// whatever Indic font the handset shipped, which meant the primary
  /// language rendered *differently on every device* — a design nobody wrote,
  /// varying by vendor, and tofu on a device with poor Indic coverage. The
  /// point of this list is DETERMINISM: the same face, shipped by us, on
  /// every phone.
  ///
  /// ## The limitation — be honest about it
  ///
  /// **Only the Regular (400) face of each is on disk.** Registering them
  /// fixes *which* face draws a glyph. It does **not** restore the ladder's
  /// weight hierarchy in Indic: an Indic run at w300 ([hero]), w500 ([body])
  /// or w700 ([label]) all resolve to the same 400 outline, and the requested
  /// weight is either faux-bolded by the rasteriser or dropped, depending on
  /// platform. So the w300→w700 spread that separates a hero from a label in
  /// English still collapses in Gujarati — it now collapses *predictably*,
  /// which is a real but bounded win. Colour and size remain the emphasis
  /// devices that survive; see the Scripts section above.
  ///
  /// Real Indic weights need more font files, not more code — the six static
  /// faces (Medium/SemiBold/Bold x Gujarati/Devanagari) or the two variable
  /// `NotoSans<Script>[wdth,wght].ttf` files, plus `weight:`-tagged entries in
  /// `pubspec.yaml`. The exact filenames and sizes are listed there.
  ///
  /// ## Vertical metrics are NOT at risk
  ///
  /// Every step below pins `height`, and `TextStyle.getParagraphStyle` seeds
  /// the paragraph's own default font from `fontFamily` alone (the fallback
  /// list is attached per-run, in `getTextStyle`). So the strut and the line
  /// box stay anchored on Inter/Sora whichever face ends up drawing the
  /// glyphs, and adding this list cannot move a layout that contains no Indic
  /// text.
  static const List<String> indicFallback = <String>[
    'NotoSansGujarati',
    'NotoSansDevanagari',
  ];

  // ── Hero figure — the dashboard centrepiece. Sora Light, very large; set
  //    the size at the call site (e.g. 56–60). Calm, futuristic. ──
  static const TextStyle hero = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 56,
    fontWeight: FontWeight.w300,
    letterSpacing: -2.0,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // ── Display / page titles — Sora, medium weight, clean and wide. ──
  static const TextStyle display = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.06,
  );

  static const TextStyle titleXl = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.12,
  );

  static const TextStyle titleL = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.16,
  );

  static const TextStyle titleM = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.22,
  );

  static const TextStyle titleS = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  // ── Body — Inter. Sizes descend 15 → 14 → 13 → 12; 12 is the floor. ──

  /// Inter 15 — the top of the Inter ladder, for text a user reads one line at
  /// a time rather than in a paragraph: form-field values, a phone number on
  /// a settings row, a single edited value in a sheet.
  ///
  /// Deliberately identical to `body.copyWith(fontSize: 15)`, which several
  /// call sites (including `UgamInput`'s internal `valueStyle`) hand-roll
  /// today — adopting this step is a pure rename with no pixel change.
  static const TextStyle bodyLg = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  static const TextStyle body = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.45,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// [caption] with emphasis — same 12/Inter metrics, one weight step up,
  /// exactly as [bodyStrong] relates to [body]. For the emphasised half of a
  /// caption-sized pair (a value beside its label), a count, a badge numeral,
  /// or a status word that must hold against surrounding caption copy.
  ///
  /// w600, not w700: the ladder's emphasis delta is a single weight step, and
  /// keeping it uniform means `caption → captionStrong` and
  /// `body → bodyStrong` shift by the same visible amount. w700 at 12 also
  /// starts closing Inter's counters on low-DPI screens.
  static const TextStyle captionStrong = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  // ── Eyebrows & labels ──

  /// **The eyebrow/label step for translated text — use this, not [micro].**
  ///
  /// Inter 13, w700, no tracking, no case dependency. It does the job [micro]
  /// does — section eyebrows, field labels, chip and badge text, the caption
  /// over a stat — but in every language the app ships.
  ///
  /// Every choice here is the inverse of a way [micro] breaks in Indic:
  ///   * **Inter, not Sora** — same fallback story, but Inter's metrics match
  ///     the surrounding UI text this label annotates.
  ///   * **13, not 10** — 11.05 after the 0.85 small-phone scale, clear of the
  ///     legibility floor, and a visible step above [caption] so an eyebrow
  ///     still reads as chrome rather than copy.
  ///   * **`letterSpacing` 0** — set explicitly, because tracking breaks
  ///     Gujarati conjuncts. Never re-add it via `copyWith`.
  ///   * **w700, sentence case** — the emphasis has to live somewhere once
  ///     caps and tracking are gone, so this sits a full step above
  ///     [bodyStrong] rather than matching it. Do **not** call
  ///     `.toUpperCase()` on it: that is a no-op in Indic and would make the
  ///     English build the only one that looks designed.
  ///
  /// Pair it with a muted ink (`ink2`) for a quiet eyebrow or an accent for a
  /// live one. On a fallback Indic face the weight may be synthesised or
  /// ignored, so treat **colour as the emphasis that always survives**.
  static const TextStyle label = TextStyle(
    fontFamily: _body,
    fontFamilyFallback: indicFallback,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.25,
  );

  /// UPPERCASE Sora eyebrow — **Latin/numeric strings only. Never use this
  /// for a translated string.**
  ///
  /// Sora 10 / w600 / +1.4 tracking, and it only reads as designed in caps.
  /// All three of those devices fail in the app's primary language:
  /// `.toUpperCase()` is a no-op in Gujarati and Devanagari, the tracking
  /// pulls apart conjuncts that are meant to join, and 10 becomes 8.5 under
  /// the 0.85 small-phone scale — under the legibility floor for a conjunct
  /// stack. Sora carries no Indic coverage either, so the run falls back to
  /// the platform face and the "clean Sora caps" idea is gone anyway.
  ///
  /// Reach for [label] instead for anything a user reads. Keep [micro] for
  /// fixed Latin/numeric chrome — seat codes, `PNR`, `AC`, plate numbers,
  /// short untranslated keys — where the caps device actually fires.
  ///
  /// It is **not** a subtitle step and **not** a badge-numeral step; see the
  /// mis-picks list on [UgamText]. Its ~188 existing call sites are being
  /// migrated in a separate pass, so its size and metrics are frozen — do not
  /// "fix" it here.
  ///
  /// It still carries [indicFallback], despite being Latin-only by contract.
  /// That is deliberate: while those ~188 call sites are unmigrated, some of
  /// them DO pass a translated string, and a determinate 8.5pt Noto glyph is
  /// strictly better than an arbitrary platform one. The fallback is not
  /// permission to use this step for translated text — it is damage control
  /// until the migration lands.
  static const TextStyle micro = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    height: 1.2,
  );

  // ── Numeric (tabular figures) — Sora. ──
  static const TextStyle numLg = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.05,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle numXl = TextStyle(
    fontFamily: _display,
    fontFamilyFallback: indicFallback,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Convert any style to tabular figures while keeping size/weight.
  static TextStyle tabular(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
