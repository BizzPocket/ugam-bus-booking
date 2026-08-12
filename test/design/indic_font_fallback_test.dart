import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/text_styles.dart';
import 'package:occubusbooking/design/theme.dart';

/// Does the app actually control the face that draws its PRIMARY language?
///
/// Inter and Sora carry zero Gujarati and zero Devanagari glyphs. Until
/// `pubspec.yaml` registered `NotoSansGujarati` / `NotoSansDevanagari` as font
/// families and [UgamText.indicFallback] wired them onto every step of the
/// ladder, every translated string in the app was drawn by whatever Indic face
/// the handset happened to ship — vendor-dependent, never designed, and tofu
/// on a device with poor coverage.
///
/// ## Why this file has to work harder than a normal test
///
/// A `fontFamilyFallback` entry naming a family that does not resolve is
/// **silently ignored**. There is no warning, no exception, no debug paint —
/// the glyph just comes from somewhere else. So "fallback wired correctly" and
/// "fallback misspelt and doing nothing" are indistinguishable unless the test
/// measures real glyph advances from the real font files.
///
/// `flutter test` does not load `pubspec.yaml` fonts, and its default face
/// (`FlutterTest`) is a placeholder that advances ~1 em per glyph regardless of
/// script — see `test/overflow/README.md`. Every width measured without an
/// explicit [FontLoader] is therefore a placeholder width, and a test built on
/// them would pass identically with the fallback wired, misspelt, or absent.
/// So [setUpAll] loads the four real TTFs off disk, and every case below is
/// stated as a comparison between two measurements that must differ (or must
/// match) for a *structural* reason.
///
/// ## The chain this file closes
///
///  1. The TTFs on disk really do draw Gujarati/Devanagari, and naming them in
///     `fontFamilyFallback` on a real ladder step really does route Indic
///     codepoints to them — while leaving Latin on Inter, byte for byte.
///     (`the fallback is live`)
///  2. `pubspec.yaml` registers *those exact family names* against *those exact
///     files*, so the app at runtime gets what this test rigged by hand.
///     (`pubspec registration`)
///  3. The `assets:` declarations the PDF exporter loads by path are still
///     there, so registering the faces as UI fonts did not break the WhatsApp
///     seat chart. (`pubspec registration`)
///  4. The theme carries the fallback all the way down to a hand-rolled
///     `TextStyle` at a call site, which is why `theme.dart` needed no wiring
///     of its own. (`reaches unstyled and hand-rolled text`)

// ── Sample strings ─────────────────────────────────────────────────────────
//
// Six codepoints each, and each contains a combining mark — that is the whole
// point of the choice, see `_markDelta` below.

/// "booking" in Gujarati: બ ુ ક િ ં ગ.
const _gujarati = 'બુકિંગ';

/// "booking" in Devanagari: ब ु क ि ं ग.
const _devanagari = 'बुकिंग';

const _latin = 'Booking';

/// Two Gujarati base consonants, no marks.
const _guBase = 'બક';

/// [_guBase] with U+0AC1 GUJARATI VOWEL SIGN U inserted — a below-base
/// combining mark. In a real Gujarati face it hangs under the બ and adds
/// **zero** advance. A face that cannot draw it emits one notdef box instead,
/// which adds a full box of advance. That difference is the tofu detector.
const _guBaseWithMark = 'બુક';

// ── Font loading ───────────────────────────────────────────────────────────

const _fontDir = 'assets/fonts';

/// The families the app declares, mapped to the file each is declared against.
/// The keys are asserted against [UgamText.indicFallback] and against
/// `pubspec.yaml` below, so this map cannot drift away from either.
const _indicFiles = <String, String>{
  'NotoSansGujarati': '$_fontDir/NotoSansGujarati-Regular.ttf',
  'NotoSansDevanagari': '$_fontDir/NotoSansDevanagari-Regular.ttf',
};

/// Register [path] under [family], the same way `pubspec.yaml`'s `fonts:`
/// block does at app startup.
///
/// Read straight off the filesystem rather than through `rootBundle`: the file
/// on disk is the artefact that ships, and this keeps the test independent of
/// how the test harness happens to assemble its asset bundle.
Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: '$path is missing — pubspec.yaml declares it twice (as an asset '
        'for SeatChartPdf and as a UI font family) and both break without it',
  );
  final bytes = file.readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

// ── Measurement ────────────────────────────────────────────────────────────

double _width(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    // Pinned: a scaler would fold an unrelated variable into every number.
    textScaler: TextScaler.noScaling,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// What one combining mark costs, in pixels, under [style].
///
/// ~0 means the run was shaped by a face that owns the mark. One full glyph
/// box means it was not — the mark became a separate notdef.
double _markDelta(TextStyle style) =>
    _width(_guBaseWithMark, style) - _width(_guBase, style);

/// [style] with the Indic fallback removed — the "before this change" control.
TextStyle _withoutFallback(TextStyle style) =>
    style.copyWith(fontFamilyFallback: const <String>[]);

/// [style] re-pointed at [family] as its PRIMARY face, with no fallback: what
/// the text measures when the Noto face draws every glyph directly. A style
/// whose fallback is live must produce exactly this for a pure-Indic run.
TextStyle _directly(TextStyle style, String family) =>
    style.copyWith(fontFamily: family, fontFamilyFallback: const <String>[]);

// ── pubspec.yaml ───────────────────────────────────────────────────────────

/// `pubspec.yaml` with comments stripped and blank lines dropped, indentation
/// preserved (the section scan below needs it).
List<String> _pubspecLines() => File('pubspec.yaml')
    .readAsLinesSync()
    .map((String l) => l.split('#').first.trimRight())
    .where((String l) => l.trim().isNotEmpty)
    .toList();

/// family name -> declared asset paths, read out of the `flutter: fonts:`
/// block. Deliberately a hand-rolled scan: pulling in a YAML parser to read
/// six lines would be the worse trade.
Map<String, List<String>> _declaredFontFamilies() {
  final families = <String, List<String>>{};
  var inFlutter = false;
  var inFonts = false;
  String? family;

  for (final String line in _pubspecLines()) {
    final String key = line.trim();
    final bool topLevel = !line.startsWith(' ') && !line.startsWith('\t');

    if (topLevel) {
      inFlutter = key == 'flutter:';
      inFonts = false;
      continue;
    }
    if (!inFlutter) continue;

    // `fonts:` / `assets:` are the two list-valued keys directly under
    // `flutter:`; anything else at that depth closes the fonts block.
    if (line.startsWith('  ') && !line.startsWith('   ') && key.endsWith(':')) {
      inFonts = key == 'fonts:';
      continue;
    }
    if (!inFonts) continue;

    if (key.startsWith('- family:')) {
      family = key.substring('- family:'.length).trim();
      families[family] = <String>[];
    } else if (key.startsWith('- asset:') && family != null) {
      families[family]!.add(key.substring('- asset:'.length).trim());
    }
  }
  return families;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The two brand faces, so the Latin side of every comparison is real Inter
    // and real Sora rather than the 1-em placeholder.
    await _loadFont('Inter', '$_fontDir/Inter-Variable.ttf');
    await _loadFont('Sora', '$_fontDir/Sora-Variable.ttf');
    for (final MapEntry<String, String> e in _indicFiles.entries) {
      await _loadFont(e.key, e.value);
    }
  });

  group('the fallback is live', () {
    // Each case pairs a measurement against a control that MUST differ. If the
    // fallback ever stops resolving — a renamed family, a dropped pubspec
    // entry, a typo in indicFallback — the two collapse onto each other and
    // the case fails.

    test('a Gujarati run is drawn by the bundled Noto Gujarati face', () {
      final live = _width(_gujarati, UgamText.body);
      final direct = _width(
        _gujarati,
        _directly(UgamText.body, 'NotoSansGujarati'),
      );
      final unwired = _width(_gujarati, _withoutFallback(UgamText.body));

      // Exact, not approximate. Identical advances can only mean identical
      // glyphs out of an identical face.
      expect(
        live,
        closeTo(direct, 0.01),
        reason: 'UgamText.body must resolve Gujarati to NotoSansGujarati',
      );
      // The control proves the assertion above is not vacuous: strip the
      // fallback and the same string measures something else entirely.
      expect(
        live,
        isNot(closeTo(unwired, 1.0)),
        reason: 'measured the same with and without the fallback — the '
            'fallback is doing nothing',
      );
      expect(live, greaterThan(0));
    });

    test('a Devanagari run skips the Gujarati face and lands on Noto '
        'Devanagari', () {
      // Gujarati is listed FIRST in indicFallback. Devanagari codepoints are
      // absent from that face, so this also proves the chain walks past a
      // non-matching entry instead of stopping at it.
      expect(
        _width(_devanagari, UgamText.body),
        closeTo(
          _width(_devanagari, _directly(UgamText.body, 'NotoSansDevanagari')),
          0.01,
        ),
      );
      expect(
        _width(_devanagari, UgamText.body),
        isNot(closeTo(_width(_devanagari, _withoutFallback(UgamText.body)), 1)),
      );
    });

    test('the Sora half of the ladder falls back too', () {
      // Two families, two fallback chains. A wiring that covered only the
      // Inter steps would leave every page title on the platform face.
      expect(
        _width(_gujarati, UgamText.titleM),
        closeTo(
          _width(_gujarati, _directly(UgamText.titleM, 'NotoSansGujarati')),
          0.01,
        ),
      );
      expect(
        _width(_gujarati, UgamText.titleM),
        isNot(closeTo(_width(_gujarati, _withoutFallback(UgamText.titleM)), 1)),
      );
    });

    test('the text is SHAPED, not a row of notdef boxes', () {
      // The strongest available proof that no tofu is being drawn, because it
      // does not depend on any absolute width: a combining mark costs nothing
      // when the face owns it, and costs a whole glyph box when it does not.
      final em = UgamText.body.fontSize!;

      expect(
        _markDelta(UgamText.body),
        closeTo(0, 0.01),
        reason: 'U+0AC1 must attach below the બ with zero advance; a non-zero '
            'cost means it was rendered as its own box',
      );
      expect(
        _markDelta(_withoutFallback(UgamText.body)),
        greaterThan(0.5 * em),
        reason: 'control: without the fallback the mark DOES cost a box — if '
            'this ever stops being true the assertion above proves nothing',
      );

      // Corollary at the whole-word level: six codepoints that shape down to
      // three bases plus three marks must come out far under six boxes.
      expect(
        _width(_gujarati, UgamText.body),
        lessThan(_gujarati.runes.length * em * 0.75),
      );
    });

    test('an unresolvable family name is silently ignored — which is why '
        'this file measures instead of asserting on the list', () {
      // Mutation guard. This is what a typo in indicFallback (or a pubspec
      // family renamed without updating the ladder) actually looks like: no
      // error, no warning, just different glyphs. It is only detectable by
      // measurement, so if anyone ever "simplifies" this file down to
      // `expect(style.fontFamilyFallback, isNotEmpty)`, this case explains
      // why that would be worthless.
      final typo = UgamText.body.copyWith(
        fontFamilyFallback: const <String>['NotoSansGujaratiii'],
      );
      expect(
        _width(_gujarati, typo),
        isNot(closeTo(_width(_gujarati, UgamText.body), 1.0)),
      );
      expect(_markDelta(typo), greaterThan(0.5 * UgamText.body.fontSize!));
    });

    test('Latin is untouched, to the pixel', () {
      // The app-wide safety claim. A fallback is consulted only for codepoints
      // the primary family cannot draw, so no English/numeric layout anywhere
      // in the app can move. Measured, not asserted from the docs.
      for (final TextStyle style in <TextStyle>[
        UgamText.body,
        UgamText.titleM,
        UgamText.numXl,
        UgamText.micro,
      ]) {
        expect(
          _width('$_latin 12,450', style),
          closeTo(_width('$_latin 12,450', _withoutFallback(style)), 0.001),
        );
      }
    });
  });

  group('every step of the ladder carries it', () {
    // theme.dart derives all 14 of its TextTheme slots from these, and a
    // hand-rolled TextStyle at a call site inherits from those slots, so the
    // ladder is the single place the fallback has to be present.
    const ladder = <String, TextStyle>{
      'hero': UgamText.hero,
      'display': UgamText.display,
      'titleXl': UgamText.titleXl,
      'titleL': UgamText.titleL,
      'titleM': UgamText.titleM,
      'titleS': UgamText.titleS,
      'bodyLg': UgamText.bodyLg,
      'body': UgamText.body,
      'bodyStrong': UgamText.bodyStrong,
      'caption': UgamText.caption,
      'captionStrong': UgamText.captionStrong,
      'label': UgamText.label,
      'micro': UgamText.micro,
      'numLg': UgamText.numLg,
      'numXl': UgamText.numXl,
    };

    for (final MapEntry<String, TextStyle> step in ladder.entries) {
      test('${step.key} declares indicFallback', () {
        expect(
          step.value.fontFamilyFallback,
          UgamText.indicFallback,
          reason: 'a step without the fallback renders the primary language '
              'in an undefined platform face',
        );
      });
    }

    test('copyWith at a call site preserves it', () {
      // ~330 call sites do exactly this. TextStyle.copyWith keeps a null
      // argument as the existing value, so the fallback survives — but that is
      // load-bearing enough to pin.
      expect(
        UgamText.body.copyWith(color: const Color(0xFFFFFFFF)).
            fontFamilyFallback,
        UgamText.indicFallback,
      );
      expect(
        UgamText.tabular(UgamText.captionStrong).fontFamilyFallback,
        UgamText.indicFallback,
      );
    });

    test('every step still pins height, so a fallback cannot move a line box',
        () {
      // Mixed-font runs take their line height from the tallest face UNLESS
      // the style fixes it. All 15 do, which is why this change cannot shift
      // vertical metrics anywhere in the app.
      for (final MapEntry<String, TextStyle> step in ladder.entries) {
        expect(step.value.height, isNotNull, reason: step.key);
      }
    });
  });

  group('pubspec registration', () {
    test('declares the families the ladder names, against the real files', () {
      final declared = _declaredFontFamilies();

      // This is the link between what the test rigged with FontLoader and what
      // the app gets at runtime. Without it the measurements above would prove
      // the FILES work while the app still shipped no registration at all.
      expect(
        UgamText.indicFallback,
        _indicFiles.keys.toList(),
        reason: 'the ladder must ask for exactly the families this test loads',
      );
      for (final MapEntry<String, String> e in _indicFiles.entries) {
        expect(
          declared[e.key],
          <String>[e.value],
          reason: 'pubspec.yaml must register ${e.key} against ${e.value}',
        );
      }
      // Inter and Sora must still be there — a fallback is only a fallback if
      // something primary sits in front of it.
      expect(declared.keys, containsAll(<String>['Inter', 'Sora']));
    });

    test('keeps the raw asset declarations SeatChartPdf loads by path', () {
      // lib/services/seat_chart_pdf.dart calls
      // rootBundle.load('assets/fonts/NotoSansGujarati-Regular.ttf') directly.
      // Registering these files under `fonts:` does not replace that; both
      // declarations are required and this is the guard that says so.
      final lines =
          _pubspecLines().map((String l) => l.trim()).toList(growable: false);
      for (final String path in <String>[
        '$_fontDir/NotoSans-Regular.ttf',
        '$_fontDir/NotoSans-Bold.ttf',
        ..._indicFiles.values,
      ]) {
        expect(
          lines,
          contains('- $path'),
          reason: '$path must stay in the assets: block — the WhatsApp seat '
              'chart PDF loads it by literal path',
        );
      }
    });
  });

  group('reaches unstyled and hand-rolled text', () {
    // Why theme.dart needed no fallback wiring of its own: it builds its whole
    // TextTheme out of UgamText, and everything downstream inherits from that.
    // These two cases are the evidence for that claim.

    Future<TextStyle> resolvedStyle(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(
        MaterialApp(theme: UgamTheme.dark(), home: Scaffold(body: child)),
      );
      return tester.renderObject<RenderParagraph>(find.byType(RichText)).text
          .style!;
    }

    testWidgets('a bare Text with no style at all', (tester) async {
      // Resolves through DefaultTextStyle -> theme.textTheme.bodyMedium ->
      // UgamText.body.
      final style = await resolvedStyle(tester, const Text(_gujarati));
      expect(style.fontFamilyFallback, UgamText.indicFallback);
    });

    testWidgets('a hand-rolled TextStyle that names no family', (
      tester,
    ) async {
      // The tour_status_badge.dart / main.dart shape. `inherit` defaults to
      // true, so TextStyle.merge fills the null fontFamilyFallback from the
      // ambient style — which is why ~27 raw TextStyle literals across lib/
      // are covered without touching any of them.
      final style = await resolvedStyle(
        tester,
        const Text(
          _gujarati,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      );
      expect(style.fontFamilyFallback, UgamText.indicFallback);
      expect(style.fontSize, 11);
    });
  });
}
