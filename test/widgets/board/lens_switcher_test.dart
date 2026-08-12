import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
// Also re-exports package:flutter/semantics.dart, which is where
// `SemanticsRole` and `SemanticsNode` come from.
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/widgets/board/lens_switcher.dart';

/// The lens switcher is the Board's whole navigation model, so the things that
/// are tested here are the things that would silently undo it:
///
///  * it must read its labels out of `BoardLensId`, not out of a list in the
///    widget — proven by asserting the GUJARATI strings, which only appear if
///    the model's `tr()` call is what produced them;
///  * it must never squeeze or clip a label (the live bug on `charts_screen`),
///    which means it scrolls and fades instead of sharing flex;
///  * it must be a TAB BAR to a screen reader, with the selected state
///    announced (spec §11) — not five identical buttons.
///
/// Gujarati is loaded rather than English on purpose: it is the primary
/// language and runs ~30% longer, so it is the one the layout has to survive.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  setUpAll(() {
    Localization.load(
      const Locale('gu'),
      translations: Translations(gu),
      ignorePluralRules: true,
    );
  });

  /// The two lenses actually wired to data in this wave.
  final shipped = <BoardLensId>[BoardLensId.occupancy, BoardLensId.money];

  /// All five — the state the switcher reaches once the remaining data sources
  /// land, and the widest the strip ever gets.
  const all = BoardLensId.values;

  Future<void> pump(
    WidgetTester tester, {
    required List<BoardLensId> lenses,
    required BoardLensId current,
    ValueChanged<BoardLensId>? onChanged,
    Size surface = const Size(390, 800),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BoardLensSwitcher(
                lenses: lenses,
                current: current,
                onChanged: onChanged ?? (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('content comes from the lens model', () {
    testWidgets('renders one pill per lens, labelled by the model', (
      tester,
    ) async {
      await pump(tester, lenses: all, current: BoardLensId.occupancy);
      for (final lens in all) {
        expect(
          find.text(lens.label),
          findsOneWidget,
          reason: '${lens.name} should be offered exactly once',
        );
      }
    });

    testWidgets('the labels really are the Gujarati ones', (tester) async {
      await pump(tester, lenses: all, current: BoardLensId.occupancy);
      // Hard-coded here and NOWHERE in the widget: if the switcher ever grows
      // its own label table, these still pass while the model's stop being
      // used, so the assertion is paired with the tr() lookups above.
      expect(find.text('બેઠક'), findsOneWidget);
      expect(find.text('બોર્ડિંગ'), findsOneWidget);
    });
  });

  testWidgets('renders on Midnight as well as Daylight', (tester) async {
    // Dark is the app's primary mode; a switcher that only resolves colours
    // through the light set would fail on the device the handler actually uses.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              BoardLensSwitcher(
                lenses: shipped,
                current: BoardLensId.money,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(BoardLensId.money.label), findsOneWidget);
  });

  group('selection', () {
    testWidgets('tapping a pill reports that lens', (tester) async {
      final picked = <BoardLensId>[];
      await pump(
        tester,
        lenses: shipped,
        current: BoardLensId.occupancy,
        onChanged: picked.add,
      );
      await tester.tap(find.text(BoardLensId.money.label));
      expect(picked, [BoardLensId.money]);
    });

    testWidgets('tapping the ACTIVE pill still reports', (tester) async {
      // The controller treats a tap as the handler *saying* which lens they
      // want, which pins it against a later phase change (spec §6). Swallowing
      // a tap on the active pill would quietly lose that.
      final picked = <BoardLensId>[];
      await pump(
        tester,
        lenses: shipped,
        current: BoardLensId.occupancy,
        onChanged: picked.add,
      );
      await tester.tap(find.text(BoardLensId.occupancy.label));
      expect(picked, [BoardLensId.occupancy]);
    });
  });

  group('tab semantics (spec §11)', () {
    testWidgets('every pill is a tab, and the active one is selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, lenses: shipped, current: BoardLensId.money);

      final active = tester.getSemantics(find.text(BoardLensId.money.label));
      expect(active.role, SemanticsRole.tab);
      expect(
        active,
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );

      final idle = tester.getSemantics(
        find.text(BoardLensId.occupancy.label),
      );
      expect(idle.role, SemanticsRole.tab);
      expect(idle, isSemantics(isSelected: false));

      handle.dispose();
    });

    testWidgets('the pills sit inside a tab-bar node', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, lenses: shipped, current: BoardLensId.occupancy);

      // A tab's parent has to be the tab bar; the framework's own role check
      // enforces the other half (every child of a tab bar must be a tab), and
      // it runs on every semantics update while this handle is alive.
      final bar = tester
          .getSemantics(find.text(BoardLensId.money.label))
          .parent;
      expect(bar, isNotNull);
      expect(bar!.role, SemanticsRole.tabBar);
      expect(bar.childrenCount, shipped.length);

      handle.dispose();
    });

    testWidgets('the announced label names the lens and its position', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, lenses: shipped, current: BoardLensId.occupancy);
      expect(
        tester.getSemantics(find.text(BoardLensId.money.label)).label,
        contains(BoardLensId.money.label),
      );
      expect(
        tester.getSemantics(find.text(BoardLensId.money.label)).label,
        contains('2'),
      );
      handle.dispose();
    });
  });

  group('no mid-word clipping (the charts_screen bug)', () {
    testWidgets('five Gujarati labels on a 320pt phone scroll, not squeeze', (
      tester,
    ) async {
      await pump(
        tester,
        lenses: all,
        current: BoardLensId.occupancy,
        surface: const Size(320, 800),
      );
      expect(tester.takeException(), isNull);

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'five Gujarati pills cannot fit 320pt — the strip must scroll',
      );

      // No pill ellipsizes: every label is laid out at its natural width.
      for (final lens in all) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(lens.label),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '${lens.name} was truncated instead of scrolled',
        );
        expect(paragraph.size.width, greaterThan(0));
      }
    });

    testWidgets('an overflowing strip fades its edge', (tester) async {
      await pump(
        tester,
        lenses: all,
        current: BoardLensId.occupancy,
        surface: const Size(320, 800),
      );
      expect(
        find.byType(ShaderMask),
        findsOneWidget,
        reason: 'the cut edge must read as "there is more", not as a bug',
      );
    });

    testWidgets('a strip that fits paints no fade at all', (tester) async {
      await pump(
        tester,
        lenses: [BoardLensId.occupancy],
        current: BoardLensId.occupancy,
        surface: const Size(390, 800),
      );
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('scrolling to the end moves the fade to the other side', (
      tester,
    ) async {
      await pump(
        tester,
        lenses: all,
        current: BoardLensId.occupancy,
        surface: const Size(320, 800),
      );
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      // Still masked — now because there is content behind the LEADING edge.
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('touch targets', () {
    testWidgets('each pill clears 44pt', (tester) async {
      await pump(tester, lenses: shipped, current: BoardLensId.occupancy);
      for (final lens in shipped) {
        final box = tester.getSize(
          find.ancestor(
            of: find.text(lens.label),
            matching: find.byType(ConstrainedBox),
          ).first,
        );
        expect(box.height, greaterThanOrEqualTo(44));
      }
    });
  });

  group('i18n', () {
    Map<String, dynamic> block(Map<String, dynamic> doc) =>
        doc['board_lens_switcher'] as Map<String, dynamic>;

    test('every key ships in all three languages', () {
      final keys = block(en).keys.toList();
      expect(keys, isNotEmpty);
      for (final k in keys) {
        expect(block(gu)[k], isA<String>(), reason: 'gu missing $k');
        expect(block(hi)[k], isA<String>(), reason: 'hi missing $k');
        expect((block(gu)[k] as String).trim(), isNotEmpty, reason: 'gu $k');
        expect((block(hi)[k] as String).trim(), isNotEmpty, reason: 'hi $k');
      }
    });

    test('nothing is the English string pasted across', () {
      for (final k in block(en).keys) {
        expect(block(gu)[k], isNot(block(en)[k]), reason: 'gu $k');
        expect(block(hi)[k], isNot(block(en)[k]), reason: 'hi $k');
        expect(block(gu)[k], isNot(block(hi)[k]), reason: '$k gu == hi');
      }
    });

    test('every placeholder survives translation', () {
      for (final k in block(en).keys) {
        final source = block(en)[k] as String;
        for (final token in RegExp(r'\{\w+\}').allMatches(source)) {
          final name = token.group(0)!;
          expect(block(gu)[k], contains(name), reason: 'gu $k lost $name');
          expect(block(hi)[k], contains(name), reason: 'hi $k lost $name');
        }
      }
    });
  });

  testWidgets('selecting a lens scrolls it into view', (tester) async {
    // The last lens starts off-screen on a narrow phone; choosing it must not
    // leave the handler looking at a strip whose active pill is invisible.
    var current = BoardLensId.occupancy;
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                BoardLensSwitcher(
                  lenses: all,
                  current: current,
                  onChanged: (next) => setState(() => current = next),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(position.pixels, 0);

    // Drive the change the way the controller would, rather than tapping a
    // pill that is off-screen.
    position.jumpTo(0);
    await tester.pumpAndSettle();
    final switcher = tester.widget<BoardLensSwitcher>(
      find.byType(BoardLensSwitcher),
    );
    switcher.onChanged(BoardLensId.boarding);
    await tester.pumpAndSettle();

    expect(
      position.pixels,
      greaterThan(0),
      reason: 'the newly active lens should have been revealed',
    );
  });

  testWidgets('a reordered lens set re-reveals the still-active pill', (
    tester,
  ) async {
    // `availableLenses` is rebuilt as data sources land, and the active lens
    // can keep its identity while its PILL moves to the far end of the strip.
    // Watching only `current` (or only the list's length) misses that and
    // leaves the handler on a lens whose pill is scrolled off-screen.
    var lenses = all.toList();
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  BoardLensSwitcher(
                    lenses: lenses,
                    // Deliberately unchanged across the rebuild.
                    current: BoardLensId.occupancy,
                    onChanged: (_) {},
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(position.pixels, 0, reason: 'occupancy starts first, so at rest');

    // Same length, same active lens — only the order changed, which puts
    // occupancy last.
    rebuild(() => lenses = all.reversed.toList());
    await tester.pumpAndSettle();

    expect(
      position.pixels,
      greaterThan(0),
      reason: 'the active pill moved to the end and must be scrolled back to',
    );
  });
}
