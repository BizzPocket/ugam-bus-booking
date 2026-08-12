// test/overflow/overflow_guard.dart
//
// THE GUJARATI OVERFLOW GUARD — shared harness.
//
// WHY THIS EXISTS
// ---------------
// Gujarati is this app's PRIMARY language and runs ~30% longer than English,
// but every layout in here was built and eyeballed in English. Three separate
// reviews have independently found the same class of breakage, always the same
// way: by hand, once, and then the test was thrown away.
//
//   * a Row with an unbounded natural-width trailing child, where the longer
//     translation silently pushes its sibling off the card;
//   * a label truncated mid-word to unreadability ("બાકી સોં…");
//   * a segmented control that fits at 1.0 and clips at the 1.3x accessibility
//     text scale `app.dart` permits.
//
// None of that reproduces in English at 390pt, which is the only combination a
// developer ever looks at. This file makes the hostile combination automatic.
//
// HOW IT DETECTS BREAKAGE
// -----------------------
// Flutter does NOT throw on a layout overflow. `RenderFlex.paint` (and every
// other renderer that calls `paintOverflowIndicator`) *reports* the overflow
// through `FlutterError.reportError` inside an `assert`, paints the yellow-and-
// black hazard stripes, and carries on. A test that only checks widget
// positions therefore passes while the UI is visibly broken.
//
// [collectOverflow] installs its own `FlutterError.onError` for the duration of
// the pump, so every reported error lands in a list instead of the console. An
// error is classified as an overflow when its message contains "overflowed by"
// — the shared wording of `RenderBox.paintOverflowIndicator`, which covers
// RenderFlex (Row/Column), RenderConstraintsTransformBox (UnconstrainedBox) and
// friends. `tester.takeException()` is drained on the way in and on the way out
// so nothing recorded by the test binding leaks past the classifier.
//
// Two further, opt-in detectors cover the failures Flutter reports *nothing*
// for:
//
//   * [OverflowOptions.checkTextBleed] — a `RenderParagraph` whose painted rect
//     lands outside the device's horizontal bounds. This is the "pushed off the
//     card" case, which does not always come from a RenderFlex (a Stack, an
//     OverflowBox or a natural-width Row child inside a clip can all do it
//     silently). Text inside a horizontally scrollable Scrollable is exempt —
//     bleeding is the whole point of a scroll strip.
//   * [OverflowOptions.checkLeakedAnimations] — a ticker still asking for
//     frames after the subject's tree was disposed. Not a layout defect, but it
//     is the reason a guard run "does not complete": the binding only notices
//     once the whole test is over, with no clue which subject did it.
//   * [OverflowOptions.forbidTruncation] — any `RenderParagraph` that reports
//     `didExceedMaxLines`, i.e. the ellipsis case. OFF by default because
//     ellipsising a person's name is correct behaviour; turn it ON for the
//     widgets whose labels must survive whole (tab pills, dock labels, stat
//     tile captions), where an ellipsis IS the bug.
//
// HOW THE HOSTILE CONDITIONS ARE BUILT
// ------------------------------------
// [pumpUnderScenario] rebuilds production's runtime *exactly*, not
// approximately:
//
//   * the surface is set through `tester.view.physicalSize` at dpr 1.0, so
//     `MediaQuery.size.width` is the literal logical width under test;
//   * the OS text-scale preference is set through
//     `platformDispatcher.textScaleFactorTestValue`, so it arrives at the app
//     root the same way a user's accessibility setting does;
//   * the host's `builder` is a line-for-line copy of `MyApp.build`'s builder:
//     `userFactor = mq.textScaler.scale(1.0).clamp(0.9, 1.3)` multiplied by
//     `UgamScale.of(context)`. Getting this wrong in either direction tests a
//     device that does not exist. See [effectiveTextScale].
//   * real `assets/translations/<lang>.json` is loaded off disk and handed both
//     to the static `Localization.load` (so `tr()` is right on frame one) and
//     to a real `EasyLocalization` ancestor (so screens that read
//     `context.locale` can be pumped at all).
//
// HOW TO ADD A SCREEN OR COMPONENT — see test/overflow/README.md.

import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// `get` also exports a `Translations` type, so this one is prefixed.
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart' as ez;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/config/i18n_config.dart';
import 'package:occubusbooking/design/theme.dart';
import 'package:occubusbooking/design/ui_scale.dart';

// ---------------------------------------------------------------------------
// The matrix
// ---------------------------------------------------------------------------

/// Locales the guard runs. English is deliberately NOT here: it is the only
/// language the layouts were ever eyeballed in, so it proves nothing. Gujarati
/// is the primary language and the longest; Hindi is second and has its own
/// (taller) Devanagari line box, which is a different stressor.
const List<String> guardLocales = <String>['gu', 'hi'];

/// Logical widths the guard runs, chosen from what `lib/design/ui_scale.dart`
/// actually claims:
///
///   * `UgamScale.baseline` is 390 — the width everything was tuned at, and
///     therefore the width that proves nothing.
///   * `375` is the small-phone class (iPhone SE2/7/8/12-mini). The scale
///     factor there is 375/390 = 0.962, i.e. text shrinks by ~4% while the box
///     shrinks by ~4% — the ratio is unchanged, so this width isolates the
///     "4% less room, same relative type" case.
///   * `320` is the honest floor. `UgamScale` clamps its factor at 0.85, which
///     bottoms out at 390 * 0.85 = 331.5pt: below that the app deliberately
///     STOPS shrinking text while the screen keeps narrowing, so type gets
///     relatively LARGER. `test/design/ui_scale_test.dart` already asserts the
///     floor's behaviour at 300pt and 200pt, so sub-331 widths are in-scope by
///     the repo's own definition. 320 is the narrowest mainstream phone
///     (iPhone SE 1st gen, Galaxy-class small Androids) and is where the floor
///     bites hardest — it is the single most hostile width the app supports.
const List<double> guardWidths = <double>[375, 320];

/// The OS text-scale preferences to run. `app.dart` clamps the user's
/// accessibility factor to `[0.9, 1.3]`, so 1.3 is not a hypothetical — it is
/// the largest type the app will ever render, and it is reachable from the
/// system settings of every device.
const List<double> guardTextScales = <double>[1.0, 1.3];

/// Both themes. Cheap here: the theme changes type colour and container fills,
/// not metrics — but it also changes which branches of a widget build (borders,
/// elevation shims, tone overlays), and a branch that only exists in one theme
/// is exactly the kind of thing that goes untested forever.
const List<Brightness> guardBrightnesses = <Brightness>[
  Brightness.light,
  Brightness.dark,
];

/// Viewport height. Taller than any phone on purpose: height does not affect
/// horizontal overflow, but a taller viewport builds and PAINTS more of a lazy
/// list, and an overflow is only reported from `paint()`. A row that never gets
/// painted never reports. Vertical overflow inside a fixed-height box (a Column
/// in a 60pt card at 1.3x type) still reports regardless of viewport height,
/// which is the vertical case that actually matters here.
const double guardHeight = 1600;

/// One cell of the matrix.
@immutable
class OverflowScenario {
  final String locale;
  final double width;

  /// The OS-level accessibility factor, BEFORE `app.dart`'s clamp and before
  /// `UgamScale`. See [effectiveTextScale] for what actually reaches the text.
  final double userTextScale;
  final Brightness brightness;

  const OverflowScenario({
    required this.locale,
    required this.width,
    required this.userTextScale,
    required this.brightness,
  });

  /// The text scale the widget tree really sees, computed the way
  /// `MyApp.build`'s builder computes it:
  ///
  ///   userFactor.clamp(0.9, 1.3) * UgamScale.of(context)
  ///
  /// e.g. 1.3 at 320pt is 1.3 * 0.85 = 1.105, NOT 1.3. Reporting the raw OS
  /// factor in a failure message would send the next reader chasing a number
  /// that never existed.
  double get effectiveTextScale =>
      userTextScale.clamp(0.9, 1.3) * (width / UgamScale.baseline).clamp(0.85, 1.0);

  @override
  String toString() => '$locale · ${width.toInt()}pt · '
      'text x$userTextScale (effective '
      '${effectiveTextScale.toStringAsFixed(3)}) · '
      '${brightness == Brightness.dark ? 'dark' : 'light'}';

  @override
  bool operator ==(Object other) =>
      other is OverflowScenario &&
      other.locale == locale &&
      other.width == width &&
      other.userTextScale == userTextScale &&
      other.brightness == brightness;

  @override
  int get hashCode => Object.hash(locale, width, userTextScale, brightness);
}

/// The full 2 x 2 x 2 x 2 matrix: {gu, hi} x {375, 320} x {1.0, 1.3} x
/// {light, dark} = 16 pumps.
List<OverflowScenario> get fullMatrix => <OverflowScenario>[
      for (final locale in guardLocales)
        for (final width in guardWidths)
          for (final scale in guardTextScales)
            for (final brightness in guardBrightnesses)
              OverflowScenario(
                locale: locale,
                width: width,
                userTextScale: scale,
                brightness: brightness,
              ),
    ];

/// Half the matrix: light theme only. For subjects heavy enough that 16 pumps
/// hurt, drop the theme axis first — it is the axis least likely to change
/// metrics.
List<OverflowScenario> get lightOnlyMatrix => fullMatrix
    .where((s) => s.brightness == Brightness.light)
    .toList(growable: false);

// ---------------------------------------------------------------------------
// Real translations
// ---------------------------------------------------------------------------

final Map<String, Map<String, dynamic>> _catalogues = <String, Map<String, dynamic>>{};

/// The parsed `assets/translations/<lang>.json`, loaded off disk.
///
/// Read from the filesystem rather than `rootBundle` so the guard depends on
/// the file a translator edits, not on the test asset bundle. `flutter test`
/// runs with the package root as the working directory, which the repo's
/// existing tests (`test/widgets/board/lens_switcher_test.dart`) already rely
/// on.
Map<String, dynamic> catalogue(String lang) => _catalogues.putIfAbsent(
      lang,
      () => jsonDecode(
        File('assets/translations/$lang.json').readAsStringSync(),
      ) as Map<String, dynamic>,
    );

/// The locale the scenario currently being pumped is running in.
///
/// [pumpUnderScenario] sets this immediately before it calls the subject's
/// builder, so [realText] resolves in the language the surrounding app is
/// actually displaying. Without it the `hi` half of the matrix renders Gujarati
/// copy inside a Hindi app and silently duplicates the `gu` half — sixteen
/// pumps' worth of cost for eight pumps' worth of coverage.
String _activeLang = 'gu';

/// The real translated value of [key] — the string a user actually reads.
///
/// Resolves in the CURRENT SCENARIO'S language by default (see [_activeLang]),
/// so one call site covers every locale in the matrix. Pass [lang] explicitly
/// only when a test is specifically about one language.
///
/// Throws rather than falling back, because a guard fed an invented string is
/// worse than no guard: it would go green on copy that shipped months ago and
/// no longer exists.
///
/// `{placeholders}` are substituted from [args] so the value is realistic
/// length; an unsubstituted `{n}` is both shorter and unrepresentative.
///
/// MUST be called from inside the subject's builder, not hoisted above
/// `expectNoOverflow` — a string resolved before the pump is resolved in the
/// PREVIOUS scenario's language.
String realText(String key, {String? lang, Map<String, String> args = const {}}) {
  lang ??= _activeLang;
  final parts = key.split('.');
  Object? node = catalogue(lang);
  for (final p in parts) {
    if (node is Map<String, dynamic>) {
      node = node[p];
    } else {
      node = null;
      break;
    }
  }
  if (node is! String) {
    throw StateError(
      'Translation key "$key" is missing from assets/translations/$lang.json. '
      'The overflow guard only ever feeds REAL strings — if this key was '
      'renamed, point the guard at the new one rather than inlining a literal.',
    );
  }
  var out = node;
  args.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// The longest real value under a dotted key [prefix] — used when a component
/// takes free text and several different keys plausibly land there (e.g. the
/// label of a tab pill). Picking the longest is the point: it is the string
/// that will break first, and it is a string that genuinely ships.
String longestUnder(String prefix, {String? lang, bool Function(String key)? where}) {
  lang ??= _activeLang;
  final flat = <String, String>{};
  void walk(Map<String, dynamic> m, String p) {
    m.forEach((k, v) {
      final nk = p.isEmpty ? k : '$p.$k';
      if (v is Map<String, dynamic>) {
        walk(v, nk);
      } else if (v is String) {
        flat[nk] = v;
      }
    });
  }

  walk(catalogue(lang), '');
  final hits = flat.entries
      .where((e) => e.key.startsWith(prefix))
      .where((e) => where == null || where(e.key))
      .toList();
  if (hits.isEmpty) {
    throw StateError('No translation keys start with "$prefix" in $lang.json.');
  }
  hits.sort((a, b) => b.value.length.compareTo(a.value.length));
  return hits.first.value;
}

/// Loads every guarded locale's catalogue into the static
/// `Localization.instance`, leaving [primary] active.
///
/// MUST be called from `setUpAll`. `easy_localization`'s `plural()` reads a
/// `late` `_locale` and throws `LateInitializationError` in a widget test
/// unless something has called `Localization.load` first; `tr()` survives but
/// returns raw keys, which would make this whole guard measure the wrong
/// strings. `ignorePluralRules: true` keeps it off the CLDR tables, matching
/// the other screen tests in this repo.
void loadGuardTranslations({String primary = 'gu'}) {
  // easy_localization logs four DEBUG lines per pump; at 16 pumps a subject
  // that is ~1000 lines of noise around the one report that matters.
  EasyLocalization.logger.enableBuildModes = const [];
  for (final lang in guardLocales) {
    catalogue(lang); // parse + cache now so the first pump is not doing IO
  }
  Localization.load(
    Locale(primary),
    translations: ez.Translations(catalogue(primary)),
    ignorePluralRules: true,
  );
}

/// An [AssetLoader] that serves the already-parsed catalogues, so the
/// `EasyLocalization` ancestor resolves without touching `rootBundle`.
class _PreloadedLoader extends AssetLoader {
  const _PreloadedLoader();

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async =>
      catalogue(locale.languageCode);
}

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

enum OverflowKind {
  /// `RenderFlex`/`RenderBox` reported "overflowed by N pixels".
  overflow,

  /// Text painted outside the device's horizontal bounds.
  bleed,

  /// Text ellipsised where the caller declared it must not be.
  truncation,

  /// The subject left an animation running after its tree was disposed. Not a
  /// layout defect, but it is why a guard run "does not complete": the leaked
  /// ticker keeps requesting frames forever, and the test binding reports it
  /// long after the test body returned, with no clue which subject did it.
  leakedAnimation,

  /// Something else was thrown/reported while pumping. Not an overflow, but a
  /// screen that throws is a screen that is not being guarded, so it fails too.
  error,
}

@immutable
class OverflowFinding {
  final OverflowKind kind;
  final OverflowScenario scenario;
  final String subject;
  final String summary;

  /// Extra lines (widget chain, measured rect, the text itself).
  final String detail;

  const OverflowFinding({
    required this.kind,
    required this.scenario,
    required this.subject,
    required this.summary,
    this.detail = '',
  });

  @override
  String toString() {
    final b = StringBuffer()
      ..writeln('  [${kind.name}] $subject')
      ..writeln('      $scenario')
      ..writeln('      $summary');
    for (final line in detail.split('\n').where((l) => l.trim().isNotEmpty)) {
      b.writeln('      $line');
    }
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

@immutable
class OverflowOptions {
  /// Report a `RenderParagraph` painted outside the device's horizontal
  /// bounds. ON by default — this is the "pushed off the card" case, and
  /// restricting it to TEXT keeps it free of the false positives a generic
  /// render-bounds sweep would collect from decorative bleeds.
  final bool checkTextBleed;

  /// Report ANY ellipsised text. OFF by default (ellipsising a passenger's
  /// name is correct). Turn it on for widgets whose own labels must stay
  /// whole — a clipped tab pill or dock caption is unusable, not merely terse.
  final bool forbidTruncation;

  /// Report a subject that still has a frame callback registered once its tree
  /// has been disposed — i.e. an `AnimationController`/`Ticker` nobody stopped.
  ///
  /// ON by default. This is not a layout question, but it is the failure the
  /// test binding otherwise reports as a bare "An animation is still running
  /// even after the widget tree was disposed" AFTER the test body has returned
  /// — no subject, no scenario, and every later test in the file poisoned.
  /// Catching it per scenario turns that into a named, reproducible finding.
  ///
  /// Turn it OFF for a subject that deliberately owns an app-lifetime ticker
  /// (the shared shimmer driver in `ugam_skeleton.dart` is the one in this
  /// repo), and say so at the call site.
  final bool checkLeakedAnimations;

  /// Scroll every `Scrollable` to its end after the first check and check
  /// again, so content below the fold gets PAINTED (and therefore gets to
  /// report). ON by default; harmless when nothing scrolls.
  final bool scrollThrough;

  /// Non-overflow errors (a controller that is not registered, a service that
  /// needs the network) fail the run by default: an exception means the subject
  /// never rendered, so a green result would be a lie.
  final bool failOnOtherErrors;

  /// Substrings of error messages to ignore. Use sparingly and always with a
  /// comment at the call site saying why the noise is not the guard's problem.
  final List<String> ignoreErrorsContaining;

  /// Frames to pump after `pumpWidget`, at 120ms each. Fixed pumps rather than
  /// `pumpAndSettle` on purpose: several of these screens host an indefinite
  /// shimmer/pulse animation, and `pumpAndSettle` would time out on them
  /// instead of testing them.
  final int settleFrames;

  const OverflowOptions({
    this.checkTextBleed = true,
    this.forbidTruncation = false,
    this.checkLeakedAnimations = true,
    this.scrollThrough = true,
    this.failOnOtherErrors = true,
    this.ignoreErrorsContaining = const <String>[],
    this.settleFrames = 4,
  });
}

// ---------------------------------------------------------------------------
// The pump
// ---------------------------------------------------------------------------

/// Builds the production host for [scenario] around [child].
///
/// [child] is the subject; it is placed as the `home` of the app, so a screen
/// can be passed whole and a component can be passed wrapped in whatever
/// scaffolding its real callers give it.
Widget buildHost({
  required OverflowScenario scenario,
  required Widget child,
  required bool useGetX,
}) {
  Widget appBuilder(BuildContext context, Widget? inner) {
    // Line-for-line with MyApp.build's builder. The two multiplications are
    // the whole point: UgamScale shrinks type on narrow devices, the user's
    // accessibility factor grows it, and only their product is real.
    final mq = MediaQuery.of(context);
    final ui = UgamScale.of(context);
    final userFactor = mq.textScaler.scale(1.0).clamp(0.9, 1.3);
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(userFactor * ui)),
      child: inner ?? const SizedBox.shrink(),
    );
  }

  final theme = scenario.brightness == Brightness.dark
      ? UgamTheme.dark()
      : UgamTheme.light();

  return EasyLocalization(
    supportedLocales: I18nConfig.supportedLocales,
    path: I18nConfig.assetPath,
    fallbackLocale: const Locale('gu'),
    startLocale: Locale(scenario.locale),
    useOnlyLangCode: true,
    // Never touches rootBundle, so the guard cannot fail for asset-bundle
    // reasons that have nothing to do with layout.
    assetLoader: const _PreloadedLoader(),
    // saveLocale would reach for SharedPreferences, which is not mocked here.
    saveLocale: false,
    child: Builder(
      builder: (context) {
        if (useGetX) {
          return GetMaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            builder: appBuilder,
            home: child,
          );
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          builder: appBuilder,
          home: child,
        );
      },
    ),
  );
}

/// Puts [build]'s widget on screen under [scenario]'s device, locale, theme and
/// text scale. Exposed separately from [collectOverflow] so a test can pump a
/// single hostile scenario and then poke at it (tap a tab, open a sheet) before
/// asking for findings.
Future<void> pumpUnderScenario(
  WidgetTester tester,
  OverflowScenario scenario,
  Widget Function() build, {
  bool useGetX = true,
  int settleFrames = 4,
}) async {
  // The device.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(scenario.width, guardHeight);
  // The user's accessibility setting, delivered the way the OS delivers it —
  // through the platform dispatcher and into MediaQuery.fromView — so
  // app.dart's clamp is exercised rather than bypassed.
  tester.platformDispatcher.textScaleFactorTestValue = scenario.userTextScale;

  // Scenario independence. Every scenario pumps the SAME root widget type
  // (EasyLocalization > Builder > MaterialApp), so without this Flutter
  // reconciles instead of rebuilding and the previous scenario's State objects
  // — field controllers, expansion flags, scroll offsets, animation
  // controllers — survive into the next one. That makes results depend on
  // matrix ORDER, which is exactly how a guard starts lying.
  //
  // [collectOverflow] already tears the tree down at the END of each scenario
  // (see [disposeScenarioTree] for why the difference matters). This one is the
  // belt to that braces, and it is what makes [pumpUnderScenario] safe to call
  // directly from a bespoke test.
  await disposeScenarioTree(tester);

  // Correct on frame one, before EasyLocalization's async delegate resolves.
  Localization.load(
    Locale(scenario.locale),
    translations: ez.Translations(catalogue(scenario.locale)),
    ignorePluralRules: true,
  );

  // Point `realText` at this scenario's catalogue BEFORE the subject builds,
  // so a Hindi scenario is fed Hindi copy rather than Gujarati copy wearing a
  // Hindi locale.
  _activeLang = scenario.locale;

  await tester.pumpWidget(buildHost(
    scenario: scenario,
    child: build(),
    useGetX: useGetX,
  ));
  // Frame 1 resolves the localization delegate future (Localizations renders an
  // empty container until then), the rest let entrance animations land.
  for (var i = 0; i < settleFrames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Unmounts whatever is on screen, so the next `pumpWidget` builds a genuinely
/// new tree instead of reconciling into the old one.
///
/// Pumping a `SizedBox` changes the ROOT widget type (the host's root is an
/// `EasyLocalization`), which is what forces Flutter to unmount rather than
/// update in place. Reusing the identical `const` instance is deliberate: two
/// consecutive calls are then a no-op rather than a second teardown.
///
/// WHEN this runs is as important as that it runs. Unmounting a tree runs
/// `State.dispose`, cancels tickers and drains post-frame callbacks, and any of
/// those can report an error. If teardown happens at the START of the next
/// scenario, that error is captured under the NEXT scenario's coordinates and
/// the reader chases a width/locale that had nothing to do with it — and the
/// final scenario's teardown lands after the test body has returned, where the
/// harness is no longer listening at all. So [collectOverflow] calls this at the
/// END of every scenario, while that scenario's error handler is still
/// installed.
///
/// The second `pump` lets anything the teardown scheduled (post-frame
/// callbacks, a route's exit animation) actually run rather than sit pending
/// past the end of the test, which is what turns a leaked animation into a
/// "did not complete" hang.
Future<void> disposeScenarioTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Resets everything [pumpUnderScenario] mutated on the test view.
void resetScenario(WidgetTester tester) {
  tester.view.reset();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  // Back to the primary language, so a `realText` call made OUTSIDE any
  // scenario (an assertion in the self-test, say) does not silently inherit
  // whichever locale happened to run last.
  _activeLang = 'gu';
}

/// Empties the test binding's pending-exception slot into [into].
///
/// `takeException()` returns ONE exception per call, so a single call in front
/// of a scenario leaves any others queued to be blamed on it. Loop until dry.
void _drainBinding(WidgetTester tester, List<_CapturedError>? into) {
  for (var guard = 0; guard < 64; guard++) {
    final leaked = tester.takeException();
    if (leaked == null) return;
    into?.add(_CapturedError.fromThrown(leaked, null));
  }
}

// ---------------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------------

bool _isOverflowError(FlutterErrorDetails d) {
  // Every renderer that overflows funnels through
  // RenderObject.paintOverflowIndicator -> _reportOverflow, which formats
  // 'A $runtimeType overflowed by $overflowText.'. Matching the shared phrase
  // rather than 'RenderFlex' also catches RenderConstraintsTransformBox and
  // any future renderer that uses the same helper.
  final s = d.exception.toString();
  return s.contains('overflowed by');
}

/// Collapses a Flutter error into one useful line.
String _summarise(FlutterErrorDetails d) {
  final raw = d.exception.toString().replaceAll('\n', ' ').trim();
  return raw.length > 220 ? '${raw.substring(0, 220)}…' : raw;
}

/// The widget chain around a reported error, so the failure names a widget
/// rather than a render object.
///
/// MUST be called while the reporting tree is still mounted. Flutter's
/// `debugCreator` holds the live `Element`, and `Element.toString()` degrades to
/// `MultiChildRenderObjectElement#c0a7d(DEFUNCT)` the moment that element is
/// unmounted. Resolve it late and every finding names nothing at all — which is
/// exactly what happened when the harness tore trees down before formatting.
/// See [_capture].
String _contextOf(FlutterErrorDetails d) {
  final lines = <String>[];
  final ctx = d.context?.toDescription();
  // `context` already reads "during layout" / "while painting"; prefixing it
  // produced "during during layout".
  if (ctx != null && ctx.isNotEmpty) lines.add('phase: $ctx');
  final node = d.informationCollector == null
      ? const <DiagnosticsNode>[]
      : d.informationCollector!().toList();
  for (final n in node.take(4)) {
    final t = n.toString().replaceAll('\n', ' ').trim();
    if (t.isEmpty) continue;
    lines.add(t.length > 320 ? '${t.substring(0, 320)}…' : t);
  }
  final owner = _likelyOwner(node);
  if (owner != null) lines.insert(0, 'likely owner: $owner');
  return lines.join('\n');
}

/// The innermost design-system widget above the render object that reported —
/// i.e. the component whose file a fixer should open first.
///
/// Read off the live element tree rather than the printed `debugCreator` chain:
/// Flutter caps that chain at twelve entries and elides the rest with `⋯`, and
/// the owning component is routinely deeper than twelve (`Row ← Padding ←
/// DecoratedBox ← Container ← Transform ← ScaleTransition ← … ← UgamCTA`). The
/// element walk has no such limit.
String? _likelyOwner(List<DiagnosticsNode> information) {
  for (final n in information) {
    final creator = n.value;
    if (creator is! DebugCreator) continue;
    String? found;
    void consider(Element e) {
      if (found != null) return;
      final name = e.widget.runtimeType.toString();
      if (name.startsWith('Ugam')) found = name;
    }

    final start = creator.element;
    if (!start.mounted) continue;
    consider(start);
    start.visitAncestorElements((a) {
      consider(a);
      return found == null;
    });
    if (found != null) return found;
  }
  return null;
}

/// A reported error, with every diagnostic ALREADY rendered to a string.
///
/// The harness formats findings after the scenario has been torn down, but the
/// interesting parts of a `FlutterErrorDetails` (`debugCreator`, the render
/// object's own description) are live objects that go `(DEFUNCT)` on unmount.
/// So they are flattened at report time, not at print time.
@immutable
class _CapturedError {
  final String raw;
  final String summary;
  final String detail;
  final bool isOverflow;

  const _CapturedError({
    required this.raw,
    required this.summary,
    required this.detail,
    required this.isOverflow,
  });

  factory _CapturedError.from(FlutterErrorDetails d) => _CapturedError(
        raw: d.exception.toString(),
        summary: _summarise(d),
        detail: _contextOf(d),
        isOverflow: _isOverflowError(d),
      );

  factory _CapturedError.fromThrown(Object e, StackTrace? st) =>
      _CapturedError.from(FlutterErrorDetails(exception: e, stack: st));
}

bool _insideHorizontalScroll(Element element) {
  var horizontal = false;
  element.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Scrollable &&
        axisDirectionToAxis(w.axisDirection) == Axis.horizontal) {
      horizontal = true;
      return false;
    }
    return true;
  });
  return horizontal;
}

/// Text painted outside the device's horizontal bounds — the silent half of the
/// "pushed off the card" bug, which a clip or a Stack can hide from RenderFlex.
List<OverflowFinding> _findTextBleed(
  WidgetTester tester,
  OverflowScenario scenario,
  String subject,
) {
  final out = <OverflowFinding>[];
  for (final element in find.byType(RichText).evaluate()) {
    final ro = element.renderObject;
    if (ro is! RenderParagraph || !ro.hasSize || !ro.attached) continue;
    final text = ro.text.toPlainText().trim();
    if (text.isEmpty) continue;
    // A horizontal scroll strip is SUPPOSED to have children past the edge.
    if (_insideHorizontalScroll(element)) continue;
    final rect = MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
    final overRight = rect.right - scenario.width;
    final overLeft = -rect.left;
    if (overRight <= 0.5 && overLeft <= 0.5) continue;
    final by = overRight > overLeft ? overRight : overLeft;
    final side = overRight > overLeft ? 'right' : 'left';
    out.add(OverflowFinding(
      kind: OverflowKind.bleed,
      scenario: scenario,
      subject: subject,
      summary: 'Text painted ${by.toStringAsFixed(1)}pt past the $side edge '
          'of a ${scenario.width.toInt()}pt screen.',
      detail: 'text: "${text.length > 80 ? '${text.substring(0, 80)}…' : text}"\n'
          'rect: ${rect.left.toStringAsFixed(1)}..${rect.right.toStringAsFixed(1)}',
    ));
  }
  return out;
}

/// Ellipsised text. Only consulted when the caller declared that this subject's
/// labels must stay whole.
List<OverflowFinding> _findTruncation(
  WidgetTester tester,
  OverflowScenario scenario,
  String subject,
) {
  final out = <OverflowFinding>[];
  for (final element in find.byType(RichText).evaluate()) {
    final ro = element.renderObject;
    if (ro is! RenderParagraph || !ro.hasSize || !ro.attached) continue;
    if (!ro.didExceedMaxLines) continue;
    final text = ro.text.toPlainText().trim();
    if (text.isEmpty) continue;
    // How much room the string actually wanted, so the report says "needs
    // 152pt, got 115pt" rather than leaving the reader to measure it.
    double wanted;
    try {
      wanted = ro.getMaxIntrinsicWidth(double.infinity);
    } catch (_) {
      wanted = double.nan;
    }
    final shortBy = wanted.isNaN ? '' : ' (short by '
        '${(wanted - ro.size.width).toStringAsFixed(1)}pt)';
    out.add(OverflowFinding(
      kind: OverflowKind.truncation,
      scenario: scenario,
      subject: subject,
      summary: 'Label was ellipsised, but this subject declared its labels '
          'must render whole.',
      detail: 'text: "$text"\n'
          'wants ${wanted.isNaN ? '?' : wanted.toStringAsFixed(1)}pt, '
          'got ${ro.size.width.toStringAsFixed(1)}pt$shortBy',
    ));
  }
  return out;
}

Future<void> _scrollEverything(WidgetTester tester) async {
  for (final element in find.byType(Scrollable).evaluate().toList()) {
    final state = element is StatefulElement ? element.state : null;
    if (state is! ScrollableState) continue;
    try {
      final pos = state.position;
      if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
        pos.jumpTo(pos.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 60));
      }
    } catch (_) {
      // A detached/disposed position mid-sweep is not a layout defect.
    }
  }
}

// ---------------------------------------------------------------------------
// The public entry points
// ---------------------------------------------------------------------------

/// Pumps [build] across [matrix] and RETURNS every finding without asserting.
///
/// Use this to test the guard itself (see the self-test in
/// `harness_self_test.dart`), or when a subject has a known, reported defect
/// you want to enumerate rather than fail on.
Future<List<OverflowFinding>> collectOverflow(
  WidgetTester tester, {
  required String subject,
  required Widget Function() build,
  List<OverflowScenario>? matrix,
  OverflowOptions options = const OverflowOptions(),
  bool useGetX = true,
  Future<void> Function(WidgetTester tester)? after,
}) async {
  final findings = <OverflowFinding>[];
  final scenarios = matrix ?? fullMatrix;

  for (final scenario in scenarios) {
    // Flattened AT REPORT TIME, while the reporting tree is still mounted —
    // see [_CapturedError].
    final captured = <_CapturedError>[];
    final previous = FlutterError.onError;
    // Drain anything the binding is already holding so it cannot be
    // misattributed to this scenario.
    _drainBinding(tester, null);
    // Baseline, not an absolute: a ticker leaked by an EARLIER scenario is
    // still registered now, and re-reporting it against all sixteen cells
    // would bury the one cell that actually did it.
    final callbacksBefore = tester.binding.transientCallbackCount;
    FlutterError.onError = (d) => captured.add(_CapturedError.from(d));
    try {
      await pumpUnderScenario(
        tester,
        scenario,
        build,
        useGetX: useGetX,
        settleFrames: options.settleFrames,
      );
      if (options.checkTextBleed) {
        findings.addAll(_findTextBleed(tester, scenario, subject));
      }
      if (options.forbidTruncation) {
        findings.addAll(_findTruncation(tester, scenario, subject));
      }
      if (after != null) {
        await after(tester);
        await tester.pump(const Duration(milliseconds: 120));
      }
      if (options.scrollThrough) {
        await _scrollEverything(tester);
        if (options.checkTextBleed) {
          findings.addAll(_findTextBleed(tester, scenario, subject));
        }
      }
    } catch (e, st) {
      captured.add(_CapturedError.fromThrown(e, st));
    } finally {
      // Tear the tree down HERE, not at the top of the next scenario, and do it
      // before restoring the previous handler — see [disposeScenarioTree]. A
      // teardown that itself explodes is a finding, not a reason to skip the
      // rest of the cleanup.
      try {
        await disposeScenarioTree(tester);
      } catch (e, st) {
        captured.add(_CapturedError.fromThrown(e, st));
      }
      final leakedCallbacks =
          tester.binding.transientCallbackCount - callbacksBefore;
      if (options.checkLeakedAnimations && leakedCallbacks > 0) {
        findings.add(OverflowFinding(
          kind: OverflowKind.leakedAnimation,
          scenario: scenario,
          subject: subject,
          summary: '$leakedCallbacks animation frame callback(s) were still '
              'registered after this subject\'s tree was disposed.',
          detail: 'A Ticker/AnimationController was started and never stopped. '
              'The test binding reports this as "An animation is still running '
              'even after the widget tree was disposed" once the WHOLE test '
              'has finished, which is why a run like this looks like a hang '
              'rather than a failure.\n'
              'Fix the widget, or — if the ticker is deliberately '
              'app-lifetime — set OverflowOptions(checkLeakedAnimations: '
              'false) and say why at the call site.',
        ));
      }
      FlutterError.onError = previous;
      // Anything the binding recorded while our handler was NOT installed.
      _drainBinding(tester, captured);
      resetScenario(tester);
    }

    for (final d in captured) {
      // Match the ignore list against the FULL message: the summary truncates
      // at 220 characters and a Flutter error's distinguishing sentence is
      // frequently past that.
      if (options.ignoreErrorsContaining.any(d.raw.contains)) continue;
      findings.add(OverflowFinding(
        kind: d.isOverflow ? OverflowKind.overflow : OverflowKind.error,
        scenario: scenario,
        subject: subject,
        summary: d.summary,
        detail: d.detail,
      ));
    }
  }

  // Dedupe: the same render object can report on both the pre- and post-scroll
  // pass, and the same defect usually fires in light AND dark.
  final seen = <String>{};
  return findings
      .where((f) => seen.add('${f.kind}|${f.scenario}|${f.summary}'))
      .toList(growable: false);
}

/// The guard. Pumps [build] across the matrix and FAILS with a full, grouped
/// report if anything overflowed, bled off screen, or threw.
Future<void> expectNoOverflow(
  WidgetTester tester, {
  required String subject,
  required Widget Function() build,
  List<OverflowScenario>? matrix,
  OverflowOptions options = const OverflowOptions(),
  bool useGetX = true,
  Future<void> Function(WidgetTester tester)? after,
}) async {
  final findings = await collectOverflow(
    tester,
    subject: subject,
    build: build,
    matrix: matrix,
    options: options,
    useGetX: useGetX,
    after: after,
  );
  final relevant = options.failOnOtherErrors
      ? findings
      : findings.where((f) => f.kind != OverflowKind.error).toList();
  if (relevant.isEmpty) return;

  final b = StringBuffer()
    ..writeln('')
    ..writeln('$subject broke in ${relevant.length} '
        'locale/width/text-scale combination(s).')
    ..writeln('')
    ..writeln('Every string below is the REAL value from '
        'assets/translations/<lang>.json — this is what users see.')
    ..writeln('');
  for (final f in relevant) {
    b.write(f);
    b.writeln('');
  }
  fail(b.toString());
}

/// Convenience: the plain Scaffold body most components live in on a real
/// screen — full-bleed width, gutter padding, top-aligned.
Widget guardBody(Widget child, {EdgeInsets padding = const EdgeInsets.all(12)}) =>
    Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

/// Clears GetX between subjects so a controller registered by one test cannot
/// leak into the next. Call from `tearDown`.
void resetGuardState() => Get.reset();
