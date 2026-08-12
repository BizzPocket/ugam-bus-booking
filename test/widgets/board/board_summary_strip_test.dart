import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/text_styles.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/widgets/board/board_summary_strip.dart';

/// The strip is the one number a handler must never lose (spec §3), so it is
/// tested as arithmetic first and as a widget second.
///
/// Gujarati throughout: it is the primary language, it runs ~30% longer than
/// English, and the strip is the most width-constrained thing on the Board.
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

  BoardBerth seated(
    String code, {
    double fare = 0,
    double paid = 0,
    BerthBoarding boarding = BerthBoarding.expected,
    String? stopId,
    String? stopName,
    String? groupId,
  }) => BoardBerth(
    code: code,
    isOccupied: true,
    occupantName: 'Rider $code',
    fareDue: fare,
    paid: paid,
    boarding: boarding,
    pickupStopId: stopId,
    pickupStopName: stopName,
    groupId: groupId,
  );

  group('every key exists in all three locales', () {
    test('board_strip and board_canvas are complete', () {
      for (final namespace in const ['board_strip', 'board_canvas']) {
        final keys = (en[namespace] as Map).keys.toSet();
        expect(keys, isNotEmpty, reason: 'en/$namespace');
        expect(
          (gu[namespace] as Map).keys.toSet(),
          keys,
          reason: 'gu/$namespace',
        );
        expect(
          (hi[namespace] as Map).keys.toSet(),
          keys,
          reason: 'hi/$namespace',
        );
        // A key whose Gujarati is byte-identical to the English is a key
        // somebody pasted rather than translated.
        for (final k in keys) {
          expect(
            gu[namespace][k],
            isNot(equals(en[namespace][k])),
            reason: 'gu/$namespace.$k is still English',
          );
          expect(
            hi[namespace][k],
            isNot(equals(en[namespace][k])),
            reason: 'hi/$namespace.$k is still English',
          );
        }
      }
    });
  });

  group('occupancy — 73/74 · 1 ખાલી', () {
    test('blocked berths are in neither number', () {
      final s = BoardStripSummary.of(BoardStripMetric.seatsFilled, [
        seated('A1'),
        seated('A2'),
        const BoardBerth(code: 'A3'),
        const BoardBerth(code: 'A4', isBlocked: true),
      ]);

      expect(s.primary, '2/3');
      expect(s.secondary, '1 ખાલી');
      expect(s.tone, BoardStripTone.neutral);
    });

    test('a full bus says so instead of counting to zero', () {
      final s = BoardStripSummary.of(BoardStripMetric.seatsFilled, [
        seated('A1'),
        seated('A2'),
      ]);

      expect(s.primary, '2/2');
      expect(s.secondary, 'બસ ભરાઈ ગઈ');
      expect(s.tone, BoardStripTone.good);
    });
  });

  group('money — ₹55,200 બાકી · 32% એકઠી', () {
    test('sums what is owed and what share is in', () {
      final s = BoardStripSummary.of(BoardStripMetric.moneyOutstanding, [
        seated('A1', fare: 1000, paid: 1000),
        seated('A2', fare: 1000, paid: 400),
        seated('A3', fare: 1000),
        const BoardBerth(code: 'A4'), // empty: contributes nothing
      ]);

      expect(s.primary, '₹1,600 બાકી');
      expect(s.secondary, '47% એકઠી');
      expect(s.tone, BoardStripTone.danger);
    });

    test('over half collected reads as warm, all of it as good', () {
      final half = BoardStripSummary.of(BoardStripMetric.moneyOutstanding, [
        seated('A1', fare: 1000, paid: 900),
        seated('A2', fare: 1000, paid: 200),
      ]);
      expect(half.tone, BoardStripTone.warn);

      final done = BoardStripSummary.of(BoardStripMetric.moneyOutstanding, [
        seated('A1', fare: 1000, paid: 1000),
      ]);
      expect(done.primary, '₹0 બાકી');
      expect(done.tone, BoardStripTone.good);
    });

    test('an over-collected bus never reads over 100%', () {
      final s = BoardStripSummary.of(BoardStripMetric.moneyOutstanding, [
        seated('A1', fare: 1000, paid: 1200),
      ]);

      expect(s.secondary, '100% એકઠી');
    });

    test('no fares set says so — never ₹0 everywhere (spec §13)', () {
      final s = BoardStripSummary.of(BoardStripMetric.moneyOutstanding, [
        seated('A1'),
        seated('A2'),
      ]);

      expect(s.primary, 'વસૂલી જોવા માટે ભાડું નક્કી કરો');
      expect(s.secondary, isNull);
    });
  });

  group('boarding — 52/60 ચઢ્યા', () {
    test('counts heads over occupied berths only', () {
      final s = BoardStripSummary.of(BoardStripMetric.boardedCount, [
        seated('A1', boarding: BerthBoarding.boarded),
        seated('A2', boarding: BerthBoarding.boarded),
        seated('A3'),
        const BoardBerth(code: 'A4'),
      ]);

      expect(s.primary, '2/3');
      expect(s.secondary, 'ચઢ્યા');
      expect(s.tone, BoardStripTone.neutral);
    });

    test('everyone aboard is a good state', () {
      final s = BoardStripSummary.of(BoardStripMetric.boardedCount, [
        seated('A1', boarding: BerthBoarding.boarded),
      ]);
      expect(s.tone, BoardStripTone.good);
    });
  });

  group('pickup — 18/22 અડાજણ', () {
    test('names the first unfinished stop, not the whole tour', () {
      final s = BoardStripSummary.of(BoardStripMetric.stopProgress, [
        seated(
          'A1',
          stopId: 'surat',
          stopName: 'સુરત',
          boarding: BerthBoarding.boarded,
        ),
        seated(
          'A2',
          stopId: 'surat',
          stopName: 'સુરત',
          boarding: BerthBoarding.boarded,
        ),
        seated('A3', stopId: 'adajan', stopName: 'અડાજણ'),
        seated(
          'A4',
          stopId: 'adajan',
          stopName: 'અડાજણ',
          boarding: BerthBoarding.boarded,
        ),
      ]);

      expect(s.primary, '1/2');
      expect(s.secondary, 'અડાજણ');
    });

    test('no stops configured is stated, not rendered as 0/0', () {
      final s = BoardStripSummary.of(BoardStripMetric.stopProgress, [
        seated('A1'),
      ]);

      expect(s.primary, 'હજી પિકઅપ સ્થળ નથી');
      expect(s.secondary, isNull);
    });
  });

  group('groups — 12 ગ્રુપ · 3 વિભાજિત', () {
    test('a group broken up along the walk counts as split', () {
      // Aisle order: g1, g1, g2, (empty), g1  → g1 is in two runs.
      final s = BoardStripSummary.of(BoardStripMetric.groupSpread, [
        seated('A1', groupId: 'g1'),
        seated('A2', groupId: 'g1'),
        seated('A3', groupId: 'g2'),
        const BoardBerth(code: 'A4'),
        seated('A5', groupId: 'g1'),
      ]);

      expect(s.primary, '2 ગ્રુપ');
      expect(s.secondary, '1 વિભાજિત');
      expect(s.tone, BoardStripTone.warn);
    });

    test('a group sitting together is not split', () {
      final s = BoardStripSummary.of(BoardStripMetric.groupSpread, [
        seated('A1', groupId: 'g1'),
        seated('A2', groupId: 'g1'),
        seated('A3', groupId: 'g2'),
      ]);

      expect(s.primary, '2 ગ્રુપ');
      expect(s.secondary, isNull);
    });
  });

  group('the widget', () {
    Future<void> pump(
      WidgetTester tester, {
      required BoardStripMetric metric,
      required List<BoardBerth> berths,
      Widget? trailing,
      int pending = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardSummaryStrip(
              metric: metric,
              berths: berths,
              trailing: trailing,
              pendingSyncCount: pending,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('pins the figure and its qualifier', (tester) async {
      await pump(
        tester,
        metric: BoardStripMetric.seatsFilled,
        berths: [seated('A1'), const BoardBerth(code: 'A2')],
      );

      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('1 ખાલી'), findsOneWidget);
    });

    testWidgets('a zero-state sentence is not set as a 20pt figure', (
      tester,
    ) async {
      // `વસૂલી જોવા માટે ભાડું નક્કી કરો` beside the "next outstanding" control
      // on a 390pt phone: at figure size this ellipsizes to nothing useful, so
      // the strip drops to body size and two lines for a message.
      tester.view.physicalSize = const Size(390, 844) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      const label = 'વસૂલી જોવા માટે ભાડું નક્કી કરો';
      await pump(
        tester,
        metric: BoardStripMetric.moneyOutstanding,
        berths: [seated('A1')],
      );

      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.fontSize, UgamText.bodyStrong.fontSize);
      expect(text.maxLines, 2);

      // And the whole sentence is on screen. Measured with the test font, whose
      // glyphs are square and so WIDER than real Gujarati at the same size —
      // if it fits here it fits on the device.
      final painted = tester.renderObject<RenderParagraph>(find.text(label));
      expect(painted.didExceedMaxLines, isFalse);
    });

    testWidgets('makes room for the next-outstanding control', (tester) async {
      await pump(
        tester,
        metric: BoardStripMetric.seatsFilled,
        berths: [seated('A1')],
        trailing: const Text('આગળનું બાકી'),
      );

      expect(find.text('આગળનું બાકી'), findsOneWidget);
    });

    testWidgets('offline shows the pending count, not just a cloud', (
      tester,
    ) async {
      await pump(
        tester,
        metric: BoardStripMetric.seatsFilled,
        berths: [seated('A1')],
        pending: 3,
      );

      expect(find.text('3 ક્રિયા બાકી · સિંક થશે'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    });

    testWidgets('says nothing about sync when there is nothing pending', (
      tester,
    ) async {
      await pump(
        tester,
        metric: BoardStripMetric.seatsFilled,
        berths: [seated('A1')],
      );

      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
    });
  });
}
