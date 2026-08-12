import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/tokens.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/handler_phase.dart';

/// The lens model is the Board's spine: it decides what every berth on a
/// 74-berth chart looks like, what the legend filters, what the sheet's primary
/// button does and which lens the Board even opens on. All of it is pure, so
/// all of it is tested here with no widget, no network and no controller —
/// against BOTH palettes, because a colour function that only works in dark
/// mode is a colour function that fails in Gujarat sun.
void main() {
  // Real translations, loaded off the real asset. This makes the i18n group a
  // genuine check that every key the model asks for actually ships in all
  // three languages, instead of tr() quietly echoing the key back.
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  setUpAll(() {
    Localization.load(
      const Locale('en'),
      translations: Translations(en),
      ignorePluralRules: true,
    );
  });

  const palettes = <String, UgamColorSet>{
    'Midnight': UgamColors.dark,
    'Daylight': UgamColors.light,
  };

  // One berth per state the model can be in, reused across every matrix test.
  const vacant = BoardBerth(code: 'A1');
  const blocked = BoardBerth(code: 'A2', isBlocked: true);
  const seated = BoardBerth(
    code: 'A3',
    isOccupied: true,
    occupantName: 'Ramesh Patel',
    fareDue: 1000,
    paid: 1000,
    boarding: BerthBoarding.boarded,
    pickupStopId: 's1',
    pickupStopName: 'Adajan',
    groupId: 'g1',
    groupName: 'Patel family',
    seatTypeLabel: 'Double sofa',
  );
  final ladies = seated.copyWith(
    code: 'A4',
    occupantName: 'Priti Patel',
    isLadies: true,
  );
  final halfPaid = seated.copyWith(code: 'B1', fareDue: 1000, paid: 450);
  final owing = seated.copyWith(code: 'B2', fareDue: 550, paid: 0);
  final overpaid = seated.copyWith(code: 'B3', fareDue: 1000, paid: 1200);
  final noFare = seated.copyWith(code: 'B4', fareDue: 0, paid: 0);
  final expected = seated.copyWith(
    code: 'C1',
    boarding: BerthBoarding.expected,
  );
  final noShow = seated.copyWith(code: 'C2', boarding: BerthBoarding.noShow);

  final everyBerth = <BoardBerth>[
    vacant,
    blocked,
    seated,
    ladies,
    halfPaid,
    owing,
    overpaid,
    noFare,
    expected,
    noShow,
  ];

  // ───────────────────────────────────────────────────────────────────────────
  group('BoardBerth — derived facts', () {
    test('occupancy covers every case', () {
      expect(vacant.occupancy, BerthOccupancy.vacant);
      expect(blocked.occupancy, BerthOccupancy.blocked);
      expect(seated.occupancy, BerthOccupancy.occupied);
      expect(ladies.occupancy, BerthOccupancy.ladies);
      expect(vacant.isVacant, isTrue);
      // A blocked berth is NOT free: assignment must never walk onto it.
      expect(blocked.isVacant, isFalse);
    });

    test('money covers every case', () {
      expect(vacant.money, BerthMoney.none);
      expect(blocked.money, BerthMoney.none);
      expect(seated.money, BerthMoney.paid);
      expect(halfPaid.money, BerthMoney.half);
      expect(owing.money, BerthMoney.due);
      expect(overpaid.money, BerthMoney.paid);
      // Occupied but unpriced reads as "nothing to collect", not as paid —
      // spec §13 refuses to show ₹0 everywhere.
      expect(noFare.money, BerthMoney.none);
    });

    test('outstanding and change never go negative', () {
      expect(owing.outstanding, 550);
      expect(owing.changeOwed, 0);
      expect(overpaid.outstanding, 0);
      expect(overpaid.changeOwed, 200);
      expect(halfPaid.outstanding, 550);
    });

    test('sub-rupee residue settles square', () {
      // Fare splits (sofa/2, bus/seats) leave paise behind; without the shared
      // epsilon a fully-paid rider would owe forever.
      const dust = BoardBerth(
        code: 'D1',
        isOccupied: true,
        fareDue: 1000,
        paid: 999.999,
      );
      expect(dust.money, BerthMoney.paid);
      expect(dust.outstanding, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  palettes.forEach((name, c) {
    group('occupancy lens colours ($name)', () {
      const lens = OccupancyLens();

      test('occupied is the solid surface', () {
        expect(
          lens.paint(seated, c),
          BerthPaint(fill: c.cardElev, ink: c.ink, glyph: '●'),
        );
      });

      test('a lady is the rose treatment', () {
        expect(
          lens.paint(ladies, c),
          BerthPaint(fill: c.warmFill, ink: c.warm, glyph: '♀'),
        );
      });

      test('empty is a hole in the chart', () {
        expect(
          lens.paint(vacant, c),
          BerthPaint(fill: c.bg, ink: c.ink3, glyph: '—'),
        );
      });

      test('blocked is not empty', () {
        final paint = lens.paint(blocked, c);
        expect(paint.glyph, '✕');
        expect(paint, isNot(lens.paint(vacant, c)));
      });
    });

    group('money lens colours ($name)', () {
      const lens = MoneyLens();

      test('paid is mint with a tick', () {
        expect(
          lens.paint(seated, c),
          BerthPaint(fill: c.goodFill, ink: c.good, glyph: '✓'),
        );
      });

      test('part paid is rose with a half', () {
        expect(
          lens.paint(halfPaid, c),
          BerthPaint(fill: c.warmFill, ink: c.warm, glyph: '½'),
        );
      });

      test('the amount owed IS the glyph', () {
        expect(
          lens.paint(owing, c),
          BerthPaint(fill: c.dangerFill, ink: c.danger, glyph: '₹550'),
        );
      });

      test('a big balance compacts so it survives a 20pt tile', () {
        final big = owing.copyWith(fareDue: 12000, paid: 0);
        expect(lens.paint(big, c).glyph, '₹12K');
      });

      // The fourth money state the 3-colour legend cannot afford, carried by
      // the glyph instead of by a colour.
      test('over-collected stays mint but says change is held', () {
        final paint = lens.paint(overpaid, c);
        expect(paint.fill, c.goodFill);
        expect(paint.glyph, '↩');
      });

      test('occupied with no fare is neutral, not paid', () {
        final paint = lens.paint(noFare, c);
        expect(paint.fill, isNot(c.goodFill));
        expect(paint.glyph, '—');
      });

      test('empty and blocked berths fall through to the shared hole', () {
        expect(lens.paint(vacant, c).glyph, '—');
        expect(lens.paint(vacant, c).fill, c.bg);
        expect(lens.paint(blocked, c).glyph, '✕');
      });
    });

    group('boarding lens colours ($name)', () {
      const lens = BoardingLens();

      test('every boarding state has its own fill and glyph', () {
        expect(
          lens.paint(seated, c),
          BerthPaint(fill: c.goodFill, ink: c.good, glyph: '●'),
        );
        expect(
          lens.paint(expected, c),
          BerthPaint(fill: c.cardElev, ink: c.ink2, glyph: '○'),
        );
        expect(
          lens.paint(noShow, c),
          BerthPaint(fill: c.dangerFill, ink: c.danger, glyph: '✕'),
        );
      });

      test('an empty berth is not "expected"', () {
        expect(lens.paint(vacant, c).glyph, '—');
      });
    });

    group('tinted lens colours ($name)', () {
      final scale = BoardTintScale.fromSeeds(const [
        BoardTintSeed(id: 's1', label: 'Adajan', count: 18),
        BoardTintSeed(id: 's2', label: 'Vesu', count: 9),
      ]);
      final lens = PickupLens(scale);

      test('a tinted berth paints the generated hue at the shared alpha', () {
        expect(
          lens.paint(seated, c),
          BerthPaint(
            fill: scale.colorOf(0).withValues(alpha: kTintFillAlpha),
            ink: c.ink,
            glyph: 'A',
          ),
        );
      });

      test('a berth in no bucket at all is marked, not blank', () {
        final noStop = seated.copyWith(code: 'E1').copyWithNoPickup();
        expect(lens.paint(noStop, c).glyph, kUnbucketedGlyph);
        expect(lens.paint(noStop, c).fill, c.cardElev);
      });

      test('empty berths still read as empty under a tinted lens', () {
        expect(lens.paint(vacant, c).glyph, '—');
      });
    });

    group('the accessibility contract holds for every lens ($name)', () {
      test('every lens × every berth state yields a non-empty glyph', () {
        for (final id in BoardLensId.values) {
          final lens = BoardLens.of(
            id,
            tints: BoardTintScale.fromSeeds(const [
              BoardTintSeed(id: 's1', label: 'Adajan', count: 3),
              BoardTintSeed(id: 'g1', label: 'Patel family', count: 3),
            ]),
          );
          for (final berth in everyBerth) {
            expect(
              lens.paint(berth, c).glyph,
              isNotEmpty,
              reason: '${id.name} left ${berth.code} without a glyph',
            );
          }
        }
      });

      test('legend states are distinguishable by fill AND by glyph', () {
        for (final id in BoardLensId.values) {
          final lens = BoardLens.of(id);
          final entries = lens.legend(c);
          expect(
            entries.map((e) => e.swatch).toSet().length,
            entries.length,
            reason: '${id.name} legend repeats a colour',
          );
          expect(
            entries.map((e) => e.glyph).toSet().length,
            entries.length,
            reason: '${id.name} legend repeats a glyph',
          );
        }
      });
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('legends', () {
    const c = UgamColors.dark;

    test('the fixed lenses carry exactly three entries', () {
      for (final id in [
        BoardLensId.occupancy,
        BoardLensId.money,
        BoardLensId.boarding,
      ]) {
        final lens = BoardLens.of(id);
        expect(lens.maxLegendEntries, 3);
        expect(lens.legend(c), hasLength(3), reason: id.name);
      }
    });

    test('a legend entry selects the berths it stands for', () {
      const lens = MoneyLens();
      final entries = {for (final e in lens.legend(c)) e.id: e};
      expect(entries['paid']!.selects(seated), isTrue);
      expect(entries['paid']!.selects(owing), isFalse);
      expect(entries['half']!.selects(halfPaid), isTrue);
      expect(entries['due']!.selects(owing), isTrue);
      // Filtering by a money state must never light up an empty berth.
      expect(entries.values.any((e) => e.selects(vacant)), isFalse);
    });

    test('no berth is claimed by two swatches at once', () {
      for (final id in BoardLensId.values) {
        final lens = BoardLens.of(
          id,
          tints: BoardTintScale.fromSeeds(const [
            BoardTintSeed(id: 's1', label: 'Adajan', count: 3),
            BoardTintSeed(id: 'g1', label: 'Patel family', count: 3),
          ]),
        );
        for (final berth in everyBerth) {
          final hits = lens.legend(c).where((e) => e.selects(berth)).length;
          expect(
            hits,
            lessThanOrEqualTo(1),
            reason: '${id.name} double-claims ${berth.code}',
          );
        }
      }
    });

    // Spec §13: never render a legend for berths that do not exist.
    test('legendFor drops states nothing on this bus is in', () {
      const lens = MoneyLens();
      final allPaid = [seated, seated.copyWith(code: 'A9'), vacant];
      final ids = lens.legendFor(allPaid, c).map((e) => e.id).toList();
      expect(ids, ['paid']);
      expect(lens.legendFor(const [], c), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('the five-tint cap', () {
    const c = UgamColors.dark;

    List<BoardTintSeed> seeds(int n) => [
      for (var i = 0; i < n; i++)
        BoardTintSeed(id: 'x$i', label: 'Stop $i', count: 100 - i),
    ];

    test('five or fewer buckets all get a tint and there is no other', () {
      final scale = BoardTintScale.fromSeeds(seeds(5));
      expect(scale.tinted, hasLength(5));
      expect(scale.hasOther, isFalse);
      expect(scale.otherBuckets, 0);
      expect(scale.otherBerths, 0);
    });

    test('nine stops tint the five largest and bucket the rest', () {
      final scale = BoardTintScale.fromSeeds(seeds(9));
      expect(scale.tinted, hasLength(BoardTintScale.maxTints));
      expect(scale.tinted.map((b) => b.id), ['x0', 'x1', 'x2', 'x3', 'x4']);
      expect(scale.tinted.map((b) => b.tintIndex), [0, 1, 2, 3, 4]);
      expect(scale.otherBuckets, 4);
      // 95 + 94 + 93 + 92.
      expect(scale.otherBerths, 374);
    });

    test('ranking is by size, not by input order', () {
      final scale = BoardTintScale.fromSeeds(const [
        BoardTintSeed(id: 'small', label: 'Kamrej', count: 2),
        BoardTintSeed(id: 'big', label: 'Adajan', count: 30),
      ]);
      expect(scale.tinted.first.id, 'big');
      expect(scale.tintIndexOf('big'), 0);
      expect(scale.tintIndexOf('small'), 1);
    });

    test('equal-sized buckets keep the order they arrived in (route order)', () {
      final scale = BoardTintScale.fromSeeds(const [
        BoardTintSeed(id: 'first', label: 'A', count: 4),
        BoardTintSeed(id: 'second', label: 'B', count: 4),
        BoardTintSeed(id: 'third', label: 'C', count: 4),
      ]);
      expect(scale.tinted.map((b) => b.id), ['first', 'second', 'third']);
    });

    test('a bucket with no berths is dropped entirely', () {
      final scale = BoardTintScale.fromSeeds(const [
        BoardTintSeed(id: 'used', label: 'Adajan', count: 3),
        BoardTintSeed(id: 'unused', label: 'Kim', count: 0),
      ]);
      expect(scale.tinted.map((b) => b.id), ['used']);
      expect(scale.hasOther, isFalse);
      expect(scale.tintIndexOf('unused'), isNull);
    });

    test('unknown and null ids fall to the other bucket', () {
      final scale = BoardTintScale.fromSeeds(seeds(6));
      expect(scale.tintIndexOf('x5'), isNull);
      expect(scale.tintIndexOf(null), isNull);
      expect(scale.labelOf('x0'), 'Stop 0');
      expect(scale.labelOf('x5'), isNull);
    });

    test('the empty scale tints nothing', () {
      expect(BoardTintScale.empty.isEmpty, isTrue);
      expect(BoardTintScale.empty.hasOther, isFalse);
      expect(BoardTintScale.fromSeeds(const []).tinted, isEmpty);
    });

    test('the five tints are five different colours', () {
      final scale = BoardTintScale.fromSeeds(seeds(5));
      final colours = {for (final b in scale.tinted) scale.colorOf(b.tintIndex)};
      expect(colours, hasLength(5));
    });

    test('there is exactly one glyph per tint slot', () {
      expect(kTintGlyphs, hasLength(BoardTintScale.maxTints));
      expect(kTintGlyphs.toSet(), hasLength(BoardTintScale.maxTints));
      expect(kTintGlyphs, isNot(contains(kOtherGlyph)));
    });

    test('the legend never exceeds five tints plus one other', () {
      for (final id in [BoardLensId.pickup, BoardLensId.group]) {
        final lens = BoardLens.of(id, tints: BoardTintScale.fromSeeds(seeds(9)));
        expect(lens.maxLegendEntries, 6);
        expect(lens.legend(c), hasLength(6), reason: id.name);
        expect(lens.legend(c).last.isOther, isTrue);
        expect(lens.legend(c).where((e) => e.isOther), hasLength(1));
      }
    });

    test('the other swatch selects everything that missed a tint', () {
      final scale = BoardTintScale.fromSeeds(seeds(6));
      final lens = PickupLens(scale);
      final other = lens.legend(c).firstWhere((e) => e.isOther);
      final tinted = seated.copyWith(pickupStopId: 'x0');
      final bucketed = seated.copyWith(code: 'Z1', pickupStopId: 'x5');
      expect(other.selects(tinted), isFalse);
      expect(other.selects(bucketed), isTrue);
      // An empty berth belongs to no bucket at all.
      expect(other.selects(vacant), isFalse);
    });

    test('with no scale at all every occupied berth is other', () {
      const lens = PickupLens();
      expect(lens.tints.isEmpty, isTrue);
      expect(lens.legend(c), isEmpty);
      expect(lens.paint(seated, UgamColors.dark).glyph, kOtherGlyph);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('lens wiring', () {
    test('each lens carries its own action and strip metric', () {
      expect(BoardLens.of(BoardLensId.occupancy).primaryAction,
          BoardAction.call);
      expect(BoardLens.of(BoardLensId.money).primaryAction,
          BoardAction.collect);
      expect(BoardLens.of(BoardLensId.pickup).primaryAction, BoardAction.call);
      expect(BoardLens.of(BoardLensId.group).primaryAction, BoardAction.move);
      expect(BoardLens.of(BoardLensId.boarding).primaryAction,
          BoardAction.checkIn);

      expect(BoardLens.of(BoardLensId.occupancy).stripMetric,
          BoardStripMetric.seatsFilled);
      expect(BoardLens.of(BoardLensId.money).stripMetric,
          BoardStripMetric.moneyOutstanding);
      expect(BoardLens.of(BoardLensId.pickup).stripMetric,
          BoardStripMetric.stopProgress);
      expect(BoardLens.of(BoardLensId.group).stripMetric,
          BoardStripMetric.groupSpread);
      expect(BoardLens.of(BoardLensId.boarding).stripMetric,
          BoardStripMetric.boardedCount);
    });

    test('the factory returns the lens it was asked for', () {
      for (final id in BoardLensId.values) {
        expect(BoardLens.of(id).id, id);
      }
    });

    test('only occupancy and money are wired up in this wave', () {
      expect(kShippedBoardLenses, {BoardLensId.occupancy, BoardLensId.money});
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('aisle-order advance targets', () {
    test('occupancy walks to the next empty berth', () {
      const lens = OccupancyLens();
      expect(lens.needsAction(vacant), isTrue);
      expect(lens.needsAction(seated), isFalse);
      // Never stop on a berth nobody can be put in.
      expect(lens.needsAction(blocked), isFalse);
    });

    test('money walks to anyone still holding cash back', () {
      const lens = MoneyLens();
      expect(lens.needsAction(owing), isTrue);
      expect(lens.needsAction(halfPaid), isTrue);
      expect(lens.needsAction(seated), isFalse);
      expect(lens.needsAction(overpaid), isFalse);
      expect(lens.needsAction(noFare), isFalse);
      expect(lens.needsAction(vacant), isFalse);
    });

    test('boarding walks to the next un-boarded rider', () {
      const lens = BoardingLens();
      expect(lens.needsAction(expected), isTrue);
      expect(lens.needsAction(seated), isFalse);
      expect(lens.needsAction(noShow), isFalse);
      expect(lens.needsAction(vacant), isFalse);
    });

    test('the tinted lenses drive no walk', () {
      for (final berth in everyBerth) {
        expect(const PickupLens().needsAction(berth), isFalse);
        expect(const GroupLens().needsAction(berth), isFalse);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('semantic labels (spec §11)', () {
    test('a berth reads as more than its code', () {
      final label = const MoneyLens().semanticLabel(owing);
      expect(label, startsWith('B2, Ramesh Patel, '));
      expect(label, contains('₹550'));
      expect(label, contains('Double sofa'));
      expect(label, contains('Adajan'));
    });

    test('the state word follows the lens', () {
      expect(const OccupancyLens().semanticLabel(ladies), contains('Ladies'));
      expect(const BoardingLens().semanticLabel(seated), contains('Boarded'));
      expect(const BoardingLens().semanticLabel(noShow), contains('No show'));
      expect(const MoneyLens().semanticLabel(seated), contains('Paid'));
      expect(
        const MoneyLens().semanticLabel(overpaid),
        contains('₹200'),
      );
      expect(
        const MoneyLens().semanticLabel(halfPaid),
        contains('part paid'),
      );
    });

    test('a tinted lens names the bucket, or says there is none', () {
      final lens = PickupLens(
        BoardTintScale.fromSeeds(const [
          BoardTintSeed(id: 's1', label: 'Adajan', count: 4),
        ]),
      );
      expect(lens.semanticLabel(seated), contains('Adajan'));
      expect(
        lens.semanticLabel(seated.copyWithNoPickup()),
        contains('No pickup point'),
      );
      expect(
        const GroupLens().semanticLabel(seated.copyWithNoGroup()),
        contains('No group'),
      );
    });

    test('an empty berth still announces itself fully', () {
      final label = const MoneyLens().semanticLabel(
        vacant.copyWith(seatTypeLabel: 'Lower berth'),
      );
      expect(label, 'A1, Empty, Lower berth');
    });

    test('every lens labels every berth without a bare code', () {
      for (final id in BoardLensId.values) {
        final lens = BoardLens.of(id);
        for (final berth in everyBerth) {
          expect(
            lens.semanticLabel(berth),
            isNot(berth.code),
            reason: '${id.name} announced ${berth.code} as just its code',
          );
        }
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('phase-driven default lens (spec §6)', () {
    test('every HandlerPhase maps to a lens', () {
      expect(defaultLensForPhase(HandlerPhase.boardingGo),
          BoardLensId.boarding);
      expect(defaultLensForPhase(HandlerPhase.boardingRet),
          BoardLensId.boarding);
      expect(defaultLensForPhase(HandlerPhase.enRouteGo), BoardLensId.pickup);
      expect(defaultLensForPhase(HandlerPhase.enRouteRet), BoardLensId.pickup);
      expect(defaultLensForPhase(HandlerPhase.settling), BoardLensId.money);
      expect(defaultLensForPhase(HandlerPhase.closed), BoardLensId.occupancy);
    });

    test('no phase is left without an answer', () {
      for (final phase in HandlerPhase.values) {
        expect(defaultLensForPhase(phase), isNotNull);
      }
    });

    test('a bus nobody has stamped yet is still being filled', () {
      expect(defaultLensForPhase(null), BoardLensId.occupancy);
      expect(
        defaultLensForPhase(null, daysUntilDeparture: 30),
        BoardLensId.occupancy,
      );
    });

    test('the T-2d window turns the default into the money chase', () {
      expect(
        defaultLensForPhase(null, daysUntilDeparture: 2),
        BoardLensId.money,
      );
      expect(
        defaultLensForPhase(null, daysUntilDeparture: 1),
        BoardLensId.money,
      );
      expect(
        defaultLensForPhase(null, daysUntilDeparture: 3),
        BoardLensId.occupancy,
      );
    });

    test('departure day counts heads; the day before chases balances', () {
      expect(
        defaultLensForPhase(HandlerPhase.boardingGo, daysUntilDeparture: 1),
        BoardLensId.money,
      );
      expect(
        defaultLensForPhase(HandlerPhase.boardingGo, daysUntilDeparture: 0),
        BoardLensId.boarding,
      );
      // Unknown date: the handler holding the phone at a pickup point is
      // counting heads, so that is the safe assumption.
      expect(
        defaultLensForPhase(HandlerPhase.boardingGo),
        BoardLensId.boarding,
      );
    });

    test('an unavailable lens falls back to occupancy, never to nothing', () {
      for (final phase in HandlerPhase.values) {
        final lens = defaultLensForPhase(
          phase,
          available: kShippedBoardLenses,
        );
        expect(kShippedBoardLenses, contains(lens), reason: phase.name);
      }
      expect(
        defaultLensForPhase(
          HandlerPhase.enRouteGo,
          available: kShippedBoardLenses,
        ),
        BoardLensId.occupancy,
      );
      // Money is shipped, so settling still opens where the spec says.
      expect(
        defaultLensForPhase(
          HandlerPhase.settling,
          available: kShippedBoardLenses,
        ),
        BoardLensId.money,
      );
    });

    test('a single-lens Board still resolves', () {
      expect(
        defaultLensForPhase(
          HandlerPhase.settling,
          available: const {BoardLensId.boarding},
        ),
        BoardLensId.boarding,
      );
    });
  });

  group('resolveBoardLens', () {
    test('a manual choice is never overridden by the phase', () {
      for (final phase in HandlerPhase.values) {
        expect(
          resolveBoardLens(phase: phase, manualChoice: BoardLensId.group),
          BoardLensId.group,
          reason: phase.name,
        );
      }
    });

    test('with no manual choice the phase decides', () {
      expect(
        resolveBoardLens(phase: HandlerPhase.enRouteRet),
        BoardLensId.pickup,
      );
      expect(resolveBoardLens(phase: null), BoardLensId.occupancy);
    });

    test('a manual choice for an unavailable lens falls back to the phase', () {
      expect(
        resolveBoardLens(
          phase: HandlerPhase.settling,
          manualChoice: BoardLensId.group,
          available: kShippedBoardLenses,
        ),
        BoardLensId.money,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('i18n', () {
    Map<String, dynamic> block(Map<String, dynamic> doc) =>
        doc['board_lens'] as Map<String, dynamic>;

    test('every key the model asks for exists in all three languages', () {
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

    test('placeholders survive translation', () {
      for (final entry in block(en).entries) {
        final placeholders = RegExp(r'\{(\w+)\}')
            .allMatches(entry.value as String)
            .map((m) => m.group(1))
            .toSet();
        for (final doc in [gu, hi]) {
          final translated = block(doc)[entry.key] as String;
          for (final p in placeholders) {
            expect(
              translated,
              contains('{$p}'),
              reason: '${entry.key} lost {$p}',
            );
          }
        }
      }
    });

    test('the lens names and actions resolve, not echo', () {
      for (final id in BoardLensId.values) {
        expect(id.label, isNot(startsWith('board_lens.')), reason: id.name);
        expect(id.label, isNotEmpty);
      }
      for (final a in BoardAction.values) {
        expect(a.label, isNot(startsWith('board_lens.')), reason: a.name);
      }
    });

    // Gujarati is the primary language and runs ~30% longer, so a lens name
    // that fits in English can still blow the switcher apart. Nothing here is
    // allowed to grow into a sentence.
    test('lens names stay short enough for the switcher in Gujarati', () {
      for (final k in ['occupancy', 'money', 'pickup', 'group', 'boarding']) {
        final label = block(gu)['name_$k'] as String;
        expect(label.length, lessThanOrEqualTo(12), reason: 'gu name_$k');
        expect(label, isNot(contains(' ')), reason: 'gu name_$k is two words');
      }
    });
  });
}

/// Small readability helpers for the "berth belongs to no bucket" cases — the
/// generated `copyWith` cannot clear a field back to null.
extension on BoardBerth {
  BoardBerth copyWithNoPickup() => BoardBerth(
    code: code,
    isOccupied: isOccupied,
    occupantName: occupantName,
    isLadies: isLadies,
    isBlocked: isBlocked,
    fareDue: fareDue,
    paid: paid,
    groupId: groupId,
    groupName: groupName,
    boarding: boarding,
    seatTypeLabel: seatTypeLabel,
  );

  BoardBerth copyWithNoGroup() => BoardBerth(
    code: code,
    isOccupied: isOccupied,
    occupantName: occupantName,
    isLadies: isLadies,
    isBlocked: isBlocked,
    fareDue: fareDue,
    paid: paid,
    pickupStopId: pickupStopId,
    pickupStopName: pickupStopName,
    boarding: boarding,
    seatTypeLabel: seatTypeLabel,
  );
}
