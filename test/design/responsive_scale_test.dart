// test/design/responsive_scale_test.dart
//
// RESPONSIVE PROOF — the regression lock for the "oversized on small phones"
// complaint.
//
// The original defect (RC-1) was a HALF-APPLIED scale system: `app.dart` fed
// `UgamScale.of` into `MediaQuery.textScaler`, so all TEXT shrank on a narrow
// phone while every fixed-pixel box (button heights, field heights, circles,
// medallions) stayed frozen at the 390pt baseline. The boxes therefore grew
// *relative to their own labels* — which is what reads as "oversized with big
// buttons".
//
// The fix added two opt-in helpers whose whole point is that they behave
// DIFFERENTLY:
//
//   * `UgamScale.px(v)`  — decorative chrome. Scales freely, so 360pt is
//                          strictly smaller than 390pt.
//   * `UgamScale.tap(v)` — interactive chrome. Scales too, but floored at 44pt
//                          so shrinking never costs a tap target.
//
// Both halves are asserted, because either alone is satisfiable by a broken
// build: a test that only checked the 44pt floor would pass on the original
// frozen-chrome app, and a test that only checked shrinkage would pass on a
// build that shrank tap targets into uselessness.
//
// Each primitive therefore declares its EXPECTED behaviour ([_Expect]) as data.
// That distinction is the point of the file — "did not shrink" is a PASS for a
// box pinned at the 44pt floor and a FAILURE for decorative chrome, and a
// blanket rule cannot tell those apart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/ugam.dart';

/// The two widths under test. 390 is [UgamScale.baseline] (factor 1.0); 360 is
/// the common small-Android / iPhone-mini class.
const double _wide = 390;
const double _narrow = 360;

/// The factor the narrow device should resolve to: 360 / 390.
const double _narrowFactor = _narrow / _wide;

/// The minimum tap target this whole exercise is defending.
const double _minTap = 44.0;

/// What a primitive is contractually required to do between 390pt and 360pt.
enum _Expect {
  /// Height must strictly shrink. The box sits above the 44pt floor, so
  /// `px()`/`tap()` must bring it down with the device.
  shrinksInHeight,

  /// Width must strictly shrink. Used for intrinsic chrome whose HEIGHT is
  /// quantised by the font's line box (a ~1pt type delta can round to the same
  /// integer line height) but whose width tracks the scaled text faithfully.
  shrinksInWidth,

  /// Identical at both widths, and never under 44pt. The box is pinned by a
  /// tap-target floor — `UgamScale.tap`'s 44, or Material's own padded target.
  /// Staying frozen is the CORRECT behaviour here, not the RC-1 bug.
  pinnedAtTapFloor,
}

/// Renders [child] at a given logical width and returns the size the measured
/// widget actually laid out at.
///
/// The host replicates `app.dart`'s builder exactly — including feeding
/// `UgamScale.of` back into `MediaQuery.textScaler` — because that coupling IS
/// the bug under test. Measuring chrome without the matching text scale would
/// compare against a screen that exists on no device.
///
/// [probe] narrows the measurement to a descendant (e.g. the app bar's back
/// button rather than the whole bar); it defaults to the subject itself.
Future<Size> _measure(
  WidgetTester tester,
  double width,
  Widget child, {
  Finder? probe,
}) async {
  const key = ValueKey('subject');
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: UgamTheme.dark(),
      home: Builder(
        builder: (context) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            // Mirrors app.dart: text rides the same factor the chrome does.
            data: mq.copyWith(
              textScaler: TextScaler.linear(UgamScale.of(context)),
            ),
            child: Scaffold(
              // Center hands down LOOSE constraints — the same shape a
              // `Column(crossAxisAlignment: start)` gives, which is how these
              // primitives are laid out on real screens.
              body: Center(child: KeyedSubtree(key: key, child: child)),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();

  return tester.getSize(probe ?? find.byKey(key));
}

/// One primitive's measurement at both widths, plus its declared contract.
class _Probe {
  final String name;
  final Size wide;
  final Size narrow;
  final _Expect expect;

  /// True when a finger lands on this box — it must hold the 44pt floor.
  final bool interactive;

  const _Probe(
    this.name,
    this.wide,
    this.narrow, {
    required this.interactive,
    required this.expect,
  });

  bool get holdsFloor =>
      narrow.width >= _minTap - 0.01 && narrow.height >= _minTap - 0.01;

  /// Did the box move on the axis its contract is about?
  ///
  /// Deliberately NOT "either axis": a full-width widget's width always tracks
  /// the screen, so an `||` here would report "shrank" for chrome that is in
  /// fact frozen at the baseline — the very thing this file must detect.
  bool get tracksDevice => switch (expect) {
    _Expect.shrinksInWidth => narrow.width < wide.width - 0.01,
    _Expect.shrinksInHeight ||
    _Expect.pinnedAtTapFloor => narrow.height < wide.height - 0.01,
  };
}

String _fmt(Size s) =>
    '${s.width.toStringAsFixed(1)} x ${s.height.toStringAsFixed(1)}';

void main() {
  /// Every [UgamButton] kind, so a new enum arm cannot quietly ship a sub-44
  /// or frozen variant.
  Future<List<_Probe>> buttons(WidgetTester tester) async {
    final out = <_Probe>[];
    for (final kind in UgamButtonKind.values) {
      Widget build() => UgamButton(
        label: 'Confirm',
        icon: Icons.check_rounded,
        kind: kind,
        onPressed: () {},
      );
      out.add(
        _Probe(
          'UgamButton(${kind.name})',
          await _measure(tester, _wide, build()),
          await _measure(tester, _narrow, build()),
          interactive: true,
          // UgamScale.tap(50): 50 -> 46.2. Above the floor, so it must move.
          expect: _Expect.shrinksInHeight,
        ),
      );
    }
    return out;
  }

  Future<List<_Probe>> singles(WidgetTester tester) async {
    Future<_Probe> one(
      String name,
      Widget Function() build, {
      required bool interactive,
      required _Expect expect,
      Finder? probe,
    }) async => _Probe(
      name,
      await _measure(tester, _wide, build(), probe: probe),
      await _measure(tester, _narrow, build(), probe: probe),
      interactive: interactive,
      expect: expect,
    );

    return [
      // md padding + titleS resolves to ~43.5, so the explicit minHeight 44
      // wins on BOTH widths. Pinned, by design.
      await one(
        'UgamCTA',
        () => UgamCTA(label: 'Save', onPressed: () {}),
        interactive: true,
        expect: _Expect.pinnedAtTapFloor,
      ),
      // Default size is exactly 44, so tap()'s floor makes it a no-op. Larger
      // callers shrink toward 44; the default never moves.
      await one(
        'UgamIconButton',
        () => UgamIconButton(icon: Icons.close_rounded, onTap: () {}),
        interactive: true,
        expect: _Expect.pinnedAtTapFloor,
      ),
      // Height comes from the theme's contentPadding + the scaled text.
      await one(
        'UgamInput',
        () => const UgamInput(hint: 'Name'),
        interactive: true,
        expect: _Expect.shrinksInHeight,
      ),
      // Material's Switch is intrinsically 60x48 (its own padded tap target),
      // which already clears 44 — so UgamSwitch's ConstrainedBox never binds
      // and the control does not scale. Pinned by Material, not by us.
      await one(
        'UgamSwitch',
        () => UgamSwitch(value: true, onChanged: (_) {}),
        interactive: true,
        expect: _Expect.pinnedAtTapFloor,
      ),
      // The bar is chrome, but its height is max(44pt back button, title) plus
      // fixed padding — so the tap floor sets it and it correctly does not
      // shrink. Measured to lock that reasoning in place.
      await one(
        'UgamAppBar (bar)',
        () => const UgamAppBar(title: 'Tour detail'),
        interactive: false,
        expect: _Expect.pinnedAtTapFloor,
      ),
      await one(
        'UgamAppBar (back)',
        () => const UgamAppBar(title: 'Tour detail'),
        interactive: true,
        expect: _Expect.pinnedAtTapFloor,
        probe: find.descendant(
          of: find.byType(UgamAppBar),
          matching: find.byType(UgamIconButton),
        ),
      ),
      // Decorative. Its 15pt height is the font's quantised line box, so the
      // faithful signal is width: 80.6 -> 75.5 as the label scales.
      await one(
        'UgamReqChip',
        () => const UgamReqChip(label: 'PENDING'),
        interactive: false,
        expect: _Expect.shrinksInWidth,
      ),
      await one(
        'UgamSectionLabel',
        () => const UgamSectionLabel('Seat types'),
        interactive: false,
        expect: _Expect.shrinksInHeight,
      ),
      // A bare px() box. Not a component — this isolates the helper itself, so
      // if a component stops shrinking the table shows whether px() regressed
      // or only that component's adoption did.
      await one(
        'UgamScale.px(200) probe',
        () => Builder(
          builder: (context) => SizedBox(
            width: UgamScale.px(context, 200),
            height: UgamScale.px(context, 200),
          ),
        ),
        interactive: false,
        expect: _Expect.shrinksInHeight,
      ),
    ];
  }

  Future<List<_Probe>> all(WidgetTester tester) async => [
    ...await buttons(tester),
    ...await singles(tester),
  ];

  testWidgets('measured sizes at 390pt vs 360pt', (tester) async {
    final probes = await all(tester);

    final b = StringBuffer()
      ..writeln()
      ..writeln('RESPONSIVE SCALE — measured at 390pt and 360pt')
      ..writeln(
        '| primitive                 | 390pt          | 360pt          '
        '| interactive | >=44 at 360 | tracks | contract         |',
      )
      ..writeln(
        '|---------------------------|----------------|----------------'
        '|-------------|-------------|--------|------------------|',
      );
    for (final p in probes) {
      b.writeln(
        '| ${p.name.padRight(25)} | ${_fmt(p.wide).padRight(14)} '
        '| ${_fmt(p.narrow).padRight(14)} '
        '| ${(p.interactive ? 'yes' : 'no').padRight(11)} '
        '| ${(p.holdsFloor ? 'yes' : 'n/a').padRight(11)} '
        '| ${(p.tracksDevice ? 'yes' : 'no').padRight(6)} '
        '| ${p.expect.name.padRight(16)} |',
      );
    }
    // ignore: avoid_print
    print(b);
  });

  testWidgets('the narrow device resolves to the expected factor', (
    tester,
  ) async {
    // Anchors every number below. If this drifts, the whole table drifts with
    // it and the other failures would be misleading.
    final probe = await _measure(
      tester,
      _narrow,
      Builder(
        builder: (context) =>
            SizedBox.square(dimension: UgamScale.px(context, 100)),
      ),
    );
    expect(probe.width, closeTo(100 * _narrowFactor, 0.01));
  });

  testWidgets('every interactive box holds 44x44 at 360pt', (tester) async {
    final probes = (await all(tester)).where((p) => p.interactive);

    expect(probes, isNotEmpty);
    for (final p in probes) {
      expect(
        p.narrow.width,
        greaterThanOrEqualTo(_minTap - 0.01),
        reason:
            '${p.name} is ${_fmt(p.narrow)} at 360pt — width is under the 44pt '
            'tap-target floor. Route it through UgamScale.tap(); px() on a '
            'tappable box is exactly this bug.',
      );
      expect(
        p.narrow.height,
        greaterThanOrEqualTo(_minTap - 0.01),
        reason:
            '${p.name} is ${_fmt(p.narrow)} at 360pt — height is under the '
            '44pt tap-target floor. Route it through UgamScale.tap(); px() on '
            'a tappable box is exactly this bug.',
      );
    }
  });

  testWidgets('chrome above the floor tracks the device, not the baseline', (
    tester,
  ) async {
    final probes = await all(tester);
    final scaling = probes.where((p) => p.expect != _Expect.pinnedAtTapFloor);

    expect(
      scaling,
      isNotEmpty,
      reason: 'Nothing is expected to scale — the fixture drifted.',
    );
    for (final p in scaling) {
      final (actual, baseline, axis) = switch (p.expect) {
        _Expect.shrinksInHeight => (p.narrow.height, p.wide.height, 'height'),
        _Expect.shrinksInWidth => (p.narrow.width, p.wide.width, 'width'),
        _Expect.pinnedAtTapFloor => throw StateError('filtered out above'),
      };
      expect(
        actual,
        lessThan(baseline),
        reason:
            '${p.name} is ${_fmt(p.wide)} at 390pt and ${_fmt(p.narrow)} at '
            '360pt — its $axis did NOT shrink. Chrome above the 44pt floor '
            'must ride UgamScale.px()/tap() (or scaled text); a frozen box is '
            'the "oversized on small phones" bug this file exists to catch.',
      );
    }
  });

  testWidgets('pinned chrome is identical at both widths and never under 44', (
    tester,
  ) async {
    // The mirror of the test above. These boxes are SUPPOSED to stay put — but
    // "stays put" must mean "held at the floor", not "drifted upward". Locking
    // the equality stops a future edit from re-freezing them at some larger
    // value and calling it intentional.
    final pinned = (await all(
      tester,
    )).where((p) => p.expect == _Expect.pinnedAtTapFloor);

    expect(pinned, isNotEmpty);
    for (final p in pinned) {
      expect(
        p.narrow.height,
        closeTo(p.wide.height, 0.01),
        reason:
            '${p.name} changed height (${_fmt(p.wide)} -> ${_fmt(p.narrow)}) '
            'but is declared pinned at the tap floor. Either it now scales '
            '(move it to shrinksInHeight) or the floor broke.',
      );
      expect(
        p.narrow.height,
        greaterThanOrEqualTo(_minTap - 0.01),
        reason: '${p.name} is pinned BELOW the 44pt floor at 360pt.',
      );
    }
  });

  testWidgets('UgamButton shrinks to exactly tap(50) on a 360pt device', (
    tester,
  ) async {
    // The single most-used interactive primitive, pinned to an exact number so
    // a regression reads as a value change rather than a vague "looks off".
    final size = await _measure(
      tester,
      _narrow,
      UgamButton(label: 'Confirm', onPressed: () {}),
    );
    expect(size.height, closeTo(50 * _narrowFactor, 0.01)); // 46.15
    expect(size.height, greaterThanOrEqualTo(_minTap));
  });
}
