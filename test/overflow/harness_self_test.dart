// test/overflow/harness_self_test.dart
//
// THE GUARD THAT GUARDS THE GUARD.
//
// A layout-overflow harness has one interesting failure mode: silently
// detecting nothing. Flutter reports overflows through `FlutterError` instead
// of throwing them, so a harness that captures the wrong handler, pumps the
// wrong frame, or never paints the subject will report a clean sweep over
// visibly broken UI — and it will keep doing that forever, because a
// permanently-green test looks exactly like a healthy one.
//
// So the harness is itself under test. Each case below builds a layout that is
// KNOWN to be broken, with a REAL Gujarati string, and asserts the harness
// finds it. If someone refactors `collectOverflow` and breaks detection, these
// go red immediately rather than the whole suite going quietly green.
//
// Run: flutter test test/overflow/harness_self_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'overflow_guard.dart';

void main() {
  setUpAll(loadGuardTranslations);
  tearDown(resetGuardState);

  // The one scenario used for the self-test: gu at the narrowest supported
  // width, largest permitted type. Sixteen pumps to prove one boolean would be
  // waste.
  const worst = OverflowScenario(
    locale: 'gu',
    width: 320,
    userTextScale: 1.3,
    brightness: Brightness.light,
  );

  testWidgets('the harness sees translations, not raw keys', (tester) async {
    // If this fails, every "no overflow" result in the suite is meaningless:
    // raw keys like `tours.empty.subtitle` are ASCII and short, so nothing
    // would ever overflow.
    final real = realText('tours.empty.subtitle');
    expect(real, isNot(contains('tours.')));
    expect(real.codeUnits.any((c) => c >= 0x0A80 && c <= 0x0AFF), isTrue,
        reason: 'expected Gujarati code points in $real');

    // ...and the same key in Hindi resolves to Devanagari, not to the Gujarati
    // fallback.
    final hi = realText('tours.empty.subtitle', lang: 'hi');
    expect(hi.codeUnits.any((c) => c >= 0x0900 && c <= 0x097F), isTrue,
        reason: 'expected Devanagari code points in $hi');
  });

  testWidgets('the effective text scale matches app.dart, not the raw OS value',
      (tester) async {
    // app.dart: clamp(0.9, 1.3) * UgamScale.of(context), and UgamScale is
    // width/390 clamped to [0.85, 1.0].
    expect(worst.effectiveTextScale, closeTo(1.3 * 0.85, 0.0001));
    expect(
      const OverflowScenario(
        locale: 'gu',
        width: 375,
        userTextScale: 1.3,
        brightness: Brightness.light,
      ).effectiveTextScale,
      closeTo(1.3 * (375 / 390), 0.0001),
    );
    // The clamp floor is real too: a 0.5 OS factor cannot shrink type below
    // 0.9 * the responsive factor.
    expect(
      const OverflowScenario(
        locale: 'gu',
        width: 390,
        userTextScale: 0.5,
        brightness: Brightness.light,
      ).effectiveTextScale,
      closeTo(0.9, 0.0001),
    );
  });

  testWidgets('DETECTS a fixed-width box too small for its Gujarati string',
      (tester) async {
    // The canonical known-bad case: a Row pinned narrower than its content.
    // `tours.empty.subtitle` is a real 57-character Gujarati sentence that
    // ships today.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: 90pt box around a real gu sentence',
      matrix: const [worst],
      build: () => guardBody(
        SizedBox(
          width: 90,
          child: Row(
            children: [Text(realText('tours.empty.subtitle'), maxLines: 1)],
          ),
        ),
      ),
    );

    expect(
      findings.where((f) => f.kind == OverflowKind.overflow),
      isNotEmpty,
      reason: 'the harness failed to see a RenderFlex overflow — every other '
          'green result in test/overflow/ is therefore worthless',
    );
  });

  testWidgets('DETECTS the unbounded trailing child that pushes a sibling out',
      (tester) async {
    // The exact shape found (twice) in customer_tour_list_screen: a Row whose
    // trailing child takes its natural width, so the longer translation eats
    // the whole row and shoves the sibling past the edge.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: Row[Text(long gu), Text(long gu)] with no flex',
      matrix: const [worst],
      build: () => guardBody(
        Row(
          children: [
            Text(realText('customer_tour_list.empty_subtitle'), maxLines: 1),
            Text(realText('customer_tour_list.tap_to_book'), maxLines: 1),
          ],
        ),
      ),
    );

    expect(findings.where((f) => f.kind == OverflowKind.overflow), isNotEmpty);
  });

  testWidgets('DETECTS text painted off the right edge of the device',
      (tester) async {
    // The silent variant: an OverflowBox lets the text lay out at its natural
    // width and paint past the screen. RenderFlex never complains — only the
    // bleed detector sees this.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: text pushed past the device edge by a Stack',
      matrix: const [worst],
      build: () => Scaffold(
        body: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 250,
              top: 40,
              child: Text(
                realText('tour_overview.capacity_overflow_message'),
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );

    expect(
      findings.where((f) => f.kind == OverflowKind.bleed),
      isNotEmpty,
      reason: 'the bleed detector missed text painted past the screen edge',
    );
  });

  testWidgets('DETECTS a mid-word ellipsis when the caller forbids truncation',
      (tester) async {
    // "બાકી સોં…" — the tour_money_board symptom. Flutter reports NOTHING for
    // this; only `forbidTruncation` sees it.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: ellipsised label',
      matrix: const [worst],
      options: const OverflowOptions(forbidTruncation: true),
      build: () => guardBody(
        SizedBox(
          width: 60,
          child: Text(
            realText('settings.biometric_title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    expect(findings.where((f) => f.kind == OverflowKind.truncation), isNotEmpty);
  });

  testWidgets('is QUIET on a layout that genuinely fits', (tester) async {
    // The other half of the proof. A detector that fires on everything is as
    // useless as one that fires on nothing — this asserts the harness produces
    // zero findings for a correctly-flexed row carrying the same real strings,
    // across the whole 16-cell matrix.
    await expectNoOverflow(
      tester,
      subject: 'self-test: correctly flexed row',
      build: () => guardBody(
        Row(
          children: [
            Expanded(
              child: Text(
                realText('customer_tour_list.empty_subtitle'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Scenario isolation
  //
  // Every scenario pumps the same ROOT WIDGET TYPE, so if the harness simply
  // called `pumpWidget` sixteen times in a row Flutter would reconcile instead
  // of rebuilding and each scenario would inherit the last one's State — field
  // text, expansion flags, scroll offsets, animation controllers. Results would
  // then depend on matrix ORDER, and reordering `fullMatrix` would silently
  // change what the guard reports.
  // ---------------------------------------------------------------------------

  testWidgets('gives every scenario a brand-new State object', (tester) async {
    _Probe.inits = 0;
    _Probe.disposes = 0;
    _Probe.dirtyOnEntry = 0;

    await collectOverflow(
      tester,
      subject: 'self-test: scenario isolation',
      build: () => guardBody(const _Probe()),
    );

    expect(_Probe.inits, fullMatrix.length,
        reason: 'expected one initState per scenario; a lower count means '
            'Flutter reconciled and the scenarios share State');
    expect(_Probe.dirtyOnEntry, 0,
        reason: 'a scenario started with the PREVIOUS scenario\'s mutated '
            'state still in place');
    expect(_Probe.disposes, fullMatrix.length,
        reason: 'collectOverflow must dispose the last scenario too, not leave '
            'it mounted for whatever test runs next');
  });

  testWidgets('blames the scenario that owned the tree for a teardown error',
      (tester) async {
    // Unmounting runs dispose(), cancels tickers and drains post-frame
    // callbacks — all of which can report. If teardown happens at the START of
    // the next scenario, those land under the NEXT scenario's coordinates and
    // send the reader chasing a width that had nothing to do with it.
    const first = OverflowScenario(
      locale: 'gu',
      width: 375,
      userTextScale: 1.0,
      brightness: Brightness.light,
    );

    final findings = await collectOverflow(
      tester,
      subject: 'self-test: dispose-time error',
      matrix: const [first, worst],
      build: () => guardBody(const _ThrowsOnDispose()),
    );

    final blamed = findings
        .where((f) => f.summary.contains(_ThrowsOnDispose.marker))
        .toList();
    expect(blamed, isNotEmpty,
        reason: 'a throw from dispose() escaped the harness entirely');
    expect(blamed.first.scenario, first,
        reason: 'the first scenario\'s teardown was blamed on '
            '${blamed.first.scenario} instead of $first');
  });

  testWidgets('reports an animation left running after teardown', (tester) async {
    // The "(did not complete)" class. A ticker nobody stopped keeps asking for
    // frames forever; the binding only notices once the whole test is over, by
    // which point nothing can say which subject or which scenario did it.
    _LeaksATicker.escaped = null;
    try {
      final findings = await collectOverflow(
        tester,
        subject: 'self-test: leaked ticker',
        matrix: const [worst],
        build: () => guardBody(const _LeaksATicker()),
      );
      expect(
        findings.where((f) => f.kind == OverflowKind.leakedAnimation),
        isNotEmpty,
        reason: 'a never-stopped AnimationController went unreported',
      );
    } finally {
      // Stop the leak we deliberately created, or it poisons every test after
      // this one exactly as described above.
      _LeaksATicker.escaped?.dispose();
      _LeaksATicker.escaped = null;
    }
  });

  testWidgets('resolves diagnostics before the tree is torn down',
      (tester) async {
    // `debugCreator` holds live Elements. Format a finding after unmount and
    // the whole chain degrades to "…#c0a7d(DEFUNCT)", which names nothing —
    // the finding survives but stops being actionable.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: live widget chain',
      matrix: const [worst],
      build: () => guardBody(
        SizedBox(
          width: 90,
          child: Row(
            children: [Text(realText('tours.empty.subtitle'), maxLines: 1)],
          ),
        ),
      ),
    );

    final overflow =
        findings.firstWhere((f) => f.kind == OverflowKind.overflow);
    expect(overflow.detail, contains('debugCreator'));
    expect(overflow.detail, isNot(contains('DEFUNCT')),
        reason: 'the widget chain was resolved after unmount, so every finding '
            'now names a dead element instead of a widget');
  });

  // ---------------------------------------------------------------------------
  // Locale coverage
  // ---------------------------------------------------------------------------

  testWidgets('feeds each scenario its OWN language, not always Gujarati',
      (tester) async {
    // The `hi` half of the matrix is only worth its runtime if it actually
    // renders Hindi. A `realText` that always read gu.json would make those
    // eight pumps an exact duplicate of the other eight — twice the cost, none
    // of the coverage — while still LOOKING like two locales in the report.
    final seen = <String>[];
    await collectOverflow(
      tester,
      subject: 'self-test: per-scenario locale',
      build: () {
        seen.add(realText('collection.filter_to_return'));
        return guardBody(Text(seen.last));
      },
    );

    expect(seen, hasLength(fullMatrix.length));
    bool isGujarati(String s) =>
        s.codeUnits.any((c) => c >= 0x0A80 && c <= 0x0AFF);
    bool isDevanagari(String s) =>
        s.codeUnits.any((c) => c >= 0x0900 && c <= 0x097F);

    expect(seen.where(isGujarati), hasLength(fullMatrix.length ~/ 2));
    expect(seen.where(isDevanagari), hasLength(fullMatrix.length ~/ 2));
  });

  testWidgets('reports the exact locale/width/scale that broke', (tester) async {
    // A finding nobody can reproduce is a finding nobody fixes. This asserts
    // the failure text carries the repro coordinates.
    final findings = await collectOverflow(
      tester,
      subject: 'self-test: repro coordinates',
      matrix: const [worst],
      build: () => guardBody(
        SizedBox(
          width: 90,
          child: Row(
            children: [Text(realText('tours.empty.subtitle'), maxLines: 1)],
          ),
        ),
      ),
    );

    final text = findings.first.toString();
    expect(text, contains('gu'));
    expect(text, contains('320pt'));
    expect(text, contains('1.3'));
    expect(text, contains('self-test: repro coordinates'));
  });
}

// ---------------------------------------------------------------------------
// Deliberately misbehaving widgets, used only by the isolation tests above.
// ---------------------------------------------------------------------------

/// Counts its own lifecycle and dirties itself after its first frame, so a
/// scenario that inherited a previous scenario's State is detectable: it would
/// start life already `_dirty`.
class _Probe extends StatefulWidget {
  const _Probe();

  static int inits = 0;
  static int disposes = 0;
  static int dirtyOnEntry = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _Probe.inits++;
  }

  @override
  void dispose() {
    _Probe.disposes++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_dirty) {
      // Mutate after the first frame, the way a real widget accumulates state
      // (a controller filled, a section expanded, a list scrolled).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _dirty = true);
      });
    }
    return const SizedBox(width: 10, height: 10);
  }
}

/// Throws from `dispose`, to prove teardown errors are attributed to the
/// scenario whose tree was being torn down.
class _ThrowsOnDispose extends StatefulWidget {
  const _ThrowsOnDispose();

  static const String marker = 'self-test-teardown-marker';

  @override
  State<_ThrowsOnDispose> createState() => _ThrowsOnDisposeState();
}

class _ThrowsOnDisposeState extends State<_ThrowsOnDispose> {
  @override
  void dispose() {
    super.dispose();
    throw StateError(_ThrowsOnDispose.marker);
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

/// Starts a repeating animation and never stops it — the shape that turns a
/// guard run into a "did not complete". The controller is parked on a static so
/// the test can put the leak back after asserting it was caught; a real leak
/// here would break every test that runs afterwards.
class _LeaksATicker extends StatefulWidget {
  const _LeaksATicker();

  static AnimationController? escaped;

  @override
  State<_LeaksATicker> createState() => _LeaksATickerState();
}

class _LeaksATickerState extends State<_LeaksATicker>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    _LeaksATicker.escaped =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}
