import 'package:flutter/material.dart';

import '../../models/seat_type.dart';
import '../../utils/tour_capacity.dart';
import '../group_color.dart';
import '../text_styles.dart';
import '../tokens.dart';

/// Glanceable "what's free on this bus" indicator: a small berth glyph + count
/// per free seat type — no words, no legend.
///
/// Why a custom glyph, not an icon: the old berth number ("4 ખાલી") was
/// ambiguous because a Double Sofa is two berths but ONE seat, and Material's
/// bed icons all read the same at 16px. Here a Single Sofa draws ONE bar, a
/// Double Sofa draws TWO bars, and a Seater a small upright square — so
/// "2 single + 1 double" is legible from the shapes alone, and "double = 2"
/// is visual, not arithmetic.
///
/// Leg colour carries one-way availability the way the seat chart does:
/// round-trip-free seats are neutral, a going-only surplus is GO-cyan, a
/// return-only surplus is RET-violet — so a one-way opening needs no arrow and
/// no key. Counts are in tiles (a Double Sofa = 1). Renders nothing when the bus
/// has no free seats (the caller shows a "full" flag instead).
class UgamFreeSeats extends StatelessWidget {
  /// This bus's free tiles by seat type (from actual assignments).
  final Map<SeatType, SeatTypeFree> freeByType;
  final UgamColorSet c;

  const UgamFreeSeats({super.key, required this.freeByType, required this.c});

  /// Stable render order: single · double · seater.
  static const _order = [
    SeatType.singleSofa,
    SeatType.doubleSofa,
    SeatType.seater,
  ];

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[];
    for (final t in _order) {
      final f = freeByType[t];
      if (f == null) continue;
      // Round-trip-free leads in neutral ink; one-way surpluses ride behind it
      // in their leg colour (GO-cyan / RET-violet) so the colour itself signals
      // the leg — no arrow, no key.
      if (f.round > 0) {
        groups.add(_Group(type: t, n: f.round, glyph: c.ink2, num: c.ink));
      }
      if (f.goOnly > 0) {
        groups.add(_Group(type: t, n: f.goOnly, glyph: kOneWayTint, num: kOneWayTint));
      }
      if (f.retOnly > 0) {
        groups.add(_Group(type: t, n: f.retOnly, glyph: kReturnTint, num: kReturnTint));
      }
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 18, runSpacing: 8, children: groups);
  }
}

class _Group extends StatelessWidget {
  final SeatType type;
  final int n;
  final Color glyph;
  final Color num;

  const _Group({
    required this.type,
    required this.n,
    required this.glyph,
    required this.num,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _BerthGlyph(type: type, color: glyph),
        const SizedBox(width: 7),
        Text(
          '$n',
          style: UgamText.tabular(
            UgamText.bodyStrong.copyWith(
              color: num,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// The berth shape: one bar (single), two bars (double), or a small upright
/// square (seater). Bar COUNT is the single/double signal, so the two never
/// look alike the way the bed icons did.
class _BerthGlyph extends StatelessWidget {
  final SeatType type;
  final Color color;

  const _BerthGlyph({required this.type, required this.color});

  Widget _bar(double w) => Container(
        width: w,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2.5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case SeatType.singleSofa:
        return _bar(15);
      case SeatType.doubleSofa:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [_bar(7), const SizedBox(width: 3), _bar(7)],
        );
      case SeatType.seater:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2.5),
          ),
        );
    }
  }
}
