// The Board canvas ASSEMBLED WITH ITS REAL BERTH TILE.
//
// Spec: docs/superpowers/specs/2026-08-12-board-interaction-design.md
//
// *** HOW THIS DIFFERS FROM test/widgets/board/board_canvas_test.dart ***
// That file proves the canvas's own arithmetic — lanes, tile metrics, grid
// geometry, reveal offsets, the drag/scroll arbitration — against a deliberately
// dumb stub tile. It has to: a stub is the only way to assert a slot's size and
// dim flag without a real widget's opinions in the way.
//
// This file is the other half. It wires the canvas to the things a SCREEN wires
// it to — `BerthTile`, `BoardLens`, `BoardController` — and asserts on what is
// actually painted. Almost everything that can go wrong on the Board is a seam
// between those parts rather than a fault inside one of them:
//
//   * the canvas computes a dim flag; the TILE has to fade its paint by it, and
//     a tinted fill has to fade proportionally instead of jumping to a flat 30%;
//   * the lens picks a glyph; the tile has to draw that glyph, so a colourblind
//     handler reads a state change on a lens switch (spec §11);
//   * the canvas resolves a compact tap to the NEAREST berth; that only helps if
//     the real tile leaves gutters for the resolver to catch (spec §3);
//   * `BerthTileMetrics.slotSize` decides a footprint the canvas must reserve —
//     and on a six-lane bench coach it does not fit across a phone, so the whole
//     bus has to scale rather than lose a lane;
//   * the tile speaks the semantic sentence the canvas computed (spec §11).
//
// Every assertion below is on the assembled result, never on a flag the canvas
// handed to a stub.

import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/board_controller.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/utils/aisle_order.dart';
import 'package:occubusbooking/widgets/board/berth_tile.dart';
import 'package:occubusbooking/widgets/board/board_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  // Gujarati is the primary language and runs ~30% longer than English, so the
  // layout assertions below (no overflow, six lanes still fit) are made against
  // the strings that actually ship. `plural()` would throw without this load;
  // `tr()` would silently echo the key back and every assertion would pass on
  // nonsense.
  setUpAll(() {
    Localization.load(
      const Locale('gu'),
      translations: Translations(load('gu')),
      ignorePluralRules: true,
    );
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── Fixtures ────────────────────────────────────────────────────────────────

  /// A coach of [rows] full rows — single upper/lower down the left, double
  /// lower/upper down the right — optionally with a back bench that puts an
  /// upper + lower pair in the aisle column and so takes the chart to SIX lanes.
  BusLayout coach({int rows = 3, bool bench = false}) {
    final grid = <SeatCell>[];
    for (var r = 0; r < rows; r++) {
      grid.addAll([
        SeatCell(
          row: r,
          col: SeatGridCols.singleUpper,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
          seatId: 'SU${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.singleLower,
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
          seatId: 'SL${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.doubleUpper,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
          seatId: 'DU${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.doubleLower,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'DL${r + 1}',
        ),
      ]);
    }
    if (bench) {
      grid.addAll([
        SeatCell(
          row: rows,
          col: SeatGridCols.aisle,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
          seatId: 'BU1',
        ),
        SeatCell(
          row: rows,
          col: SeatGridCols.aisle,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'BL1',
        ),
      ]);
    }
    return BusLayout(
      rows: rows + (bench ? 1 : 0),
      cols: SeatGridCols.count,
      grid: grid,
    );
  }

  const names = <String>[
    'Priti Patel',
    'Ramesh Shah',
    'Anjali Desai',
    'Kiran Mehta',
  ];

  /// A manifest in WALKING order, so berth `i` below is the i-th berth a handler
  /// passes. The first four are taken and carry, in order: square, part paid,
  /// and two owing ₹550 — one of every money state the three-colour legend has
  /// to carry, which is what makes a lens switch visible at the tile.
  Map<String, BoardBerth> crew(BusLayout layout, {int occupy = 4}) {
    final cells = AisleWalk.of(layout).berths;
    final out = <String, BoardBerth>{};
    for (var i = 0; i < cells.length; i++) {
      final id = cells[i].seatId;
      if (id == null) continue;
      final taken = i < occupy;
      out[id] = BoardBerth(
        code: id,
        isOccupied: taken,
        occupantName: taken ? names[i % names.length] : null,
        fareDue: taken ? 550 : 0,
        paid: taken
            ? switch (i) {
                0 => 550.0,
                1 => 200.0,
                _ => 0.0,
              }
            : 0,
        pickupStopName: taken ? 'અડાજણ' : null,
        seatTypeLabel: cells[i].typeLabel,
        boarding: BerthBoarding.expected,
      );
    }
    return out;
  }

  // ── Harness ─────────────────────────────────────────────────────────────────

  late BoardController controller;
  late List<BoardBerthSlot> tapped;

  setUp(() {
    controller = BoardController();
    tapped = [];
  });

  /// The tile builder a screen ships: the canvas host owns the gestures (tap,
  /// long-press, drag), so the tile is handed state and nothing else. Passing
  /// `onTap` here as well would put a second recogniser inside the host's and
  /// the canvas would never see the tap that moves its walk cursor.
  Widget berthTile(BuildContext context, BoardBerthSlot slot) => BerthTile(
    berth: slot.berth,
    lens: slot.lens,
    density: slot.density,
    isSelected: slot.isSelected,
    isCurrent: slot.isCursor,
    isDimmed: slot.isDimmed,
    isDropTarget: slot.dropState == BoardDropState.valid,
    isDropRejected: slot.dropState == BoardDropState.invalid,
  );

  Future<void> pump(
    WidgetTester tester, {
    BusLayout? layout,
    int occupy = 4,
    Size view = const Size(390, 844),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = view * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final plan = layout ?? coach();
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(brightness: brightness),
          child: Scaffold(
            body: BoardCanvas(
              controller: controller,
              buses: [
                BoardBusPage(
                  busId: 'bus-1',
                  layout: plan,
                  berths: crew(plan, occupy: occupy),
                ),
              ],
              berthTileBuilder: berthTile,
              // The real footprint. This is the path the shipped tile takes and
              // the one that can fail to fit across a phone.
              slotSizeOf: BerthTileMetrics.slotSize,
              onBerthTap: tapped.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder tileOf(String code) =>
      find.ancestor(of: find.text(code), matching: find.byType(BerthTile));

  BoxDecoration faceOf(WidgetTester tester, String code) =>
      tester
              .widget<DecoratedBox>(
                find.descendant(
                  of: tileOf(code),
                  matching: find.byKey(BerthTile.faceKey),
                ),
              )
              .decoration
          as BoxDecoration;

  BerthTile tileWidget(WidgetTester tester, String code) =>
      tester.widget<BerthTile>(tileOf(code));

  // ── What is actually painted ────────────────────────────────────────────────

  group('the tile the canvas draws', () {
    testWidgets('comfortable carries the occupant name, compact drops it', (
      tester,
    ) async {
      await pump(tester);
      controller.setDensity(BoardDensity.comfortable);
      await tester.pump();

      // The name on the tile is the entire reason the Board replaces a chart
      // you can only look at.
      expect(find.text('Priti Patel'), findsOneWidget);
      expect(find.text('SU1'), findsOneWidget);
      final comfortable = tester.getSize(tileOf('SU1'));

      controller.setDensity(BoardDensity.compact);
      await tester.pump();

      expect(find.text('Priti Patel'), findsNothing);
      expect(find.text('SU1'), findsOneWidget, reason: 'the code always shows');
      expect(tester.getSize(tileOf('SU1')).height, lessThan(comfortable.height));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a lens switch repaints every glyph, not just the fills', (
      tester,
    ) async {
      await pump(tester, occupy: 4);

      // Occupancy: four riders aboard, eight holes in the chart.
      expect(find.text('●'), findsNWidgets(4));
      expect(find.text('—'), findsNWidgets(8));
      expect(find.text('✓'), findsNothing);

      controller.selectLens(BoardLensId.money);
      await tester.pump();

      // Money: one square, one part paid, two owing — spec §11's "₹550 due"
      // glyph, which is the amount itself.
      expect(find.text('✓'), findsOneWidget);
      expect(find.text('½'), findsOneWidget);
      expect(find.text('₹550'), findsNWidgets(2));
      expect(
        find.text('●'),
        findsNothing,
        reason: 'the occupancy glyph must not survive the lens switch',
      );
    });

    testWidgets('the money fill and the occupancy fill are different colours', (
      tester,
    ) async {
      await pump(tester, occupy: 4);
      // SU3 is the third berth along the walk: occupied, nothing paid.
      final seated = faceOf(tester, 'DL1').color;

      controller.selectLens(BoardLensId.money);
      await tester.pump();

      expect(
        faceOf(tester, 'DL1').color,
        isNot(seated),
        reason: 'a lens is a colour function; switching one must recolour',
      );
    });

    testWidgets('a legend filter fades the painted fill and then restores it', (
      tester,
    ) async {
      await pump(tester, occupy: 4);

      final litOccupied = faceOf(tester, 'SU1').color!;
      final litEmpty = faceOf(tester, 'SU2').color!;

      // "Show me only the empty berths."
      controller.toggleLegendFilter('empty');
      await tester.pump();

      final dimmed = faceOf(tester, 'SU1').color!;
      expect(tileWidget(tester, 'SU1').isDimmed, isTrue);
      // Faded by its OWN alpha, not dropped to a flat 30% — a tinted fill has to
      // dim proportionally or it reads as MORE solid than it was.
      expect(dimmed.a, closeTo(litOccupied.a * kBerthDimAlpha, 0.001));
      expect(faceOf(tester, 'SU2').color!.a, closeTo(litEmpty.a, 0.001));

      // The legend is the filter UI, so it must be able to undo itself.
      controller.toggleLegendFilter('empty');
      await tester.pump();

      expect(tileWidget(tester, 'SU1').isDimmed, isFalse);
      expect(faceOf(tester, 'SU1').color!.a, closeTo(litOccupied.a, 0.001));
    });

    testWidgets('a search dims everything it did not match', (tester) async {
      await pump(tester, occupy: 4);

      controller.setSearch('Ramesh');
      await tester.pump(kBoardSearchRevealDelay + const Duration(milliseconds: 20));

      // SL1 is the second berth along the walk — Ramesh Shah.
      expect(tileWidget(tester, 'SL1').isDimmed, isFalse);
      expect(tileWidget(tester, 'SU1').isDimmed, isTrue);
      expect(faceOf(tester, 'SU1').color!.a, lessThan(1));

      controller.clearSearch();
      await tester.pump();
      expect(tileWidget(tester, 'SU1').isDimmed, isFalse);
    });

    testWidgets('the walk cursor rings exactly one berth, and glows', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      controller.setCursor('DL2');
      await tester.pump();

      final ringed = tester
          .widgetList<BerthTile>(find.byType(BerthTile))
          .where((t) => t.isCurrent)
          .toList();
      expect(ringed.length, 1);
      expect(ringed.single.berth.code, 'DL2');

      // The amber halo is the cursor's own signal, and nothing else on the
      // chart carries one.
      expect(faceOf(tester, 'DL2').boxShadow, isNotNull);
      expect(faceOf(tester, 'DL1').boxShadow, isNull);
    });
  });

  // ── Accessibility, on the assembled tile ────────────────────────────────────

  group('accessibility', () {
    testWidgets('every berth speaks a sentence, never a bare code', (
      tester,
    ) async {
      // Disposed inline rather than via addTearDown: the framework's
      // "SemanticsHandle was active" check runs BEFORE registered tear-downs.
      final handle = tester.ensureSemantics();

      await pump(tester, occupy: 4);

      final spoken = tester.getSemantics(tileOf('SU1')).label;
      expect(spoken, contains('SU1'));
      expect(spoken, contains('Priti Patel'));
      // The seat type and the pickup point, exactly as spec §11 writes it out:
      // "DL3, Priti Patel, paid, double sofa, boarding at Adajan".
      expect(spoken, contains('અડાજણ'));
      expect(
        spoken.length,
        greaterThan('SU1'.length + 'Priti Patel'.length),
        reason: 'the state word and the seat type must be in there too',
      );

      // The word changes with the lens, because "what state is this berth in"
      // is exactly what a lens answers.
      final underOccupancy = tester.getSemantics(tileOf('DL1')).label;
      controller.selectLens(BoardLensId.money);
      await tester.pump();
      expect(tester.getSemantics(tileOf('DL1')).label, isNot(underOccupancy));

      handle.dispose();
    });

    testWidgets('an empty berth still says what it is', (tester) async {
      final handle = tester.ensureSemantics();

      await pump(tester, occupy: 4);

      final spoken = tester.getSemantics(tileOf('DU3')).label;
      expect(spoken, contains('DU3'));
      expect(
        spoken,
        contains(
          const OccupancyLens().stateLabel(const BoardBerth(code: 'DU3')),
        ),
      );

      handle.dispose();
    });
  });

  // ── Scale: the whole reason the Board is hard ───────────────────────────────

  group('a real coach, not the four rows the mockups showed', () {
    testWidgets('76 berths open compact and every one of them is drawn', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 19), occupy: 40);

      expect(
        controller.isCompact,
        isTrue,
        reason: '76 berths is past the compact threshold (spec §3)',
      );
      expect(find.byType(BerthTile), findsNWidgets(76));
      expect(tester.takeException(), isNull);
    });

    testWidgets('landscape turns the coach nose-left without overflowing', (
      tester,
    ) async {
      await pump(
        tester,
        layout: coach(rows: 19),
        occupy: 40,
        view: const Size(844, 390),
      );

      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scroll.scrollDirection, Axis.horizontal);
      expect(find.byType(BerthTile), findsNWidgets(76));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a six-lane bench coach scales down rather than losing a lane', (
      tester,
    ) async {
      // A back bench splits the aisle into two lanes: six lanes of a 68pt fixed
      // tile is 408pt, wider than the 390pt phone. The chart only scrolls the
      // other way, so a lane that did not fit would simply be GONE.
      await pump(tester, layout: coach(rows: 4, bench: true), occupy: 8);

      expect(find.byType(BerthTile), findsNWidgets(18));
      for (final code in ['SU1', 'SL1', 'BU1', 'BL1', 'DL1', 'DU1']) {
        expect(find.text(code), findsOneWidget, reason: '$code must be drawn');
      }

      // The PAINTED extent, left wall to right wall. `getRect` walks the
      // FittedBox transform, so this is the scaled-down chart rather than the
      // tile's nominal 68pt footprint.
      final chartWidth =
          tester.getRect(tileOf('DU1')).right - tester.getRect(tileOf('SU1')).left;
      expect(
        chartWidth,
        lessThanOrEqualTo(390),
        reason: 'six lanes must fit across the phone',
      );
      // ...and it really was scaled, not merely clipped: the tile is laid out
      // at its natural footprint and PAINTED smaller.
      expect(
        tester.getRect(tileOf('SU1')).width,
        lessThan(tester.getSize(tileOf('SU1')).width),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the drawn order down the screen IS the walking order', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 4), occupy: 16);

      // Row by row, and inside a row left wall → aisle → right wall. If the
      // paint disagreed with `aisleOrder`, "next outstanding" would highlight a
      // berth that jumps backwards across the screen.
      final walk = AisleWalk.of(coach(rows: 4)).seatIds;
      Offset? previous;
      for (final id in walk) {
        final centre = tester.getCenter(tileOf(id));
        if (previous != null) {
          final movedDown = centre.dy > previous.dy + 0.5;
          final sameRowRightwards =
              (centre.dy - previous.dy).abs() <= 0.5 && centre.dx > previous.dx;
          expect(
            movedDown || sameRowRightwards,
            isTrue,
            reason: '$id is drawn before the berth walked before it',
          );
        }
        previous = centre;
      }
    });
  });

  // ── The compact-mode bargain ────────────────────────────────────────────────

  group('compact tiles are under the touch minimum by design', () {
    testWidgets('a tap in the aisle still opens the nearest berth', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 12), occupy: 24);
      controller.setDensity(BoardDensity.compact);
      await tester.pump();

      // The painted tile is genuinely smaller than 44pt — that is the deal
      // spec §3 strikes, and the nearest-berth resolver is what pays for it.
      expect(tester.getSize(tileOf('SL1')).height, lessThan(44));

      final left = tester.getRect(tileOf('SL1'));
      final right = tester.getRect(tileOf('DL1'));
      expect(
        right.left,
        greaterThan(left.right),
        reason: 'the walkway lane sits between them',
      );

      // A thumb that lands in the walkway, a shade closer to the left pair.
      await tester.tapAt(
        Offset(left.right + (right.left - left.right) * 0.25, left.center.dy),
      );
      await tester.pump();

      expect(tapped.single.berth.code, 'SL1');
      expect(controller.cursor.value, 'SL1');
    });

    testWidgets('comfortable does not install the gap catcher', (tester) async {
      await pump(tester, layout: coach(rows: 3), occupy: 4);
      controller.setDensity(BoardDensity.comfortable);
      await tester.pump();

      final left = tester.getRect(tileOf('SL1'));
      final right = tester.getRect(tileOf('DL1'));
      await tester.tapAt(
        Offset((left.right + right.left) / 2, left.center.dy),
      );
      await tester.pump();

      expect(
        tapped,
        isEmpty,
        reason:
            'in the working mode a tap that misses a berth means nothing — '
            'nearest-berth resolution exists to pay for tiles that are too '
            'small, and comfortable tiles are not',
      );
    });
  });

  // ── Direct manipulation, end to end ─────────────────────────────────────────

  group('gestures reach the controller through the real tile', () {
    testWidgets('a tap parks the walk where the handler actually is', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      await tester.tap(tileOf('DL2'));
      await tester.pump();

      expect(tapped.single.berth.code, 'DL2');
      expect(controller.cursor.value, 'DL2');
      expect(tileWidget(tester, 'DL2').isCurrent, isTrue);
    });

    testWidgets('a long-press selects, and the badge appears on the tile', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      await tester.longPress(tileOf('SU1'));
      await tester.pump();

      expect(controller.selection, {'SU1'});
      expect(tileWidget(tester, 'SU1').isSelected, isTrue);
      expect(
        find.descendant(
          of: tileOf('SU1'),
          matching: find.byKey(BerthTile.selectionBadgeKey),
        ),
        findsOneWidget,
        reason: 'selection is a shape, not only a colour (spec §11)',
      );

      // A second tap in select mode adds rather than opening a sheet.
      await tester.tap(tileOf('SL1'));
      await tester.pump();
      expect(controller.selection, {'SU1', 'SL1'});
      expect(tapped, isEmpty);
    });
  });
}
