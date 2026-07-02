import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../utils/tour_capacity.dart';
import '../text_styles.dart';
import '../tokens.dart';

/// How dense the meter renders.
enum UgamMeterDensity { tour, bus, hero }

/// Two-leg, whole-seat capacity meter — the ONE way the app answers "how full?"
///
/// Why it exists: the old surfaces showed a single merged fraction ("36/80")
/// plus a percentage computed off `max(GO, RET)`. That hid the fact that the
/// outbound and return legs carry different loads, and it leaked the engine's
/// fractional `seatLoad` (0.5 / 1.5 / 2.5) — numbers no one can book. Splitting
/// by leg makes every figure a whole seat automatically (the half only ever
/// came from averaging the two legs together) and shows the agent the one thing
/// they act on: how many seats are still free, per leg.
///
/// Densities:
///  - [UgamMeterDensity.tour]  two stacked leg rows with labels + bars.
///  - [UgamMeterDensity.hero]  the same two-leg shape, tighter — dashboard hero.
///  - [UgamMeterDensity.bus]   one compact line per bus: `Go x/n · Ret y/n` over
///                             a single thin bar of the busier leg.
///
/// When both legs carry the same load the meter collapses to a SINGLE bar, so a
/// symmetric or no-return tour never shows a redundant second row. Fill is
/// neutral [UgamColorSet.ink2] (copper stays reserved for CTAs) and turns
/// [UgamColorSet.good] mint only when a leg is genuinely full.
class UgamCapacityMeter extends StatelessWidget {
  final int capacity;
  final int goOccupied;
  final int retOccupied;
  final UgamMeterDensity density;

  const UgamCapacityMeter._({
    super.key,
    required this.capacity,
    required this.goOccupied,
    required this.retOccupied,
    required this.density,
  });

  /// Tour-wide meter from the engine snapshot.
  factory UgamCapacityMeter.tour(TourCapacity cap, {Key? key}) =>
      UgamCapacityMeter._(
        key: key,
        capacity: cap.capacity,
        goOccupied: cap.goOccupied,
        retOccupied: cap.retOccupied,
        density: UgamMeterDensity.tour,
      );

  /// Dashboard-hero meter — same data, tighter type.
  factory UgamCapacityMeter.hero(TourCapacity cap, {Key? key}) =>
      UgamCapacityMeter._(
        key: key,
        capacity: cap.capacity,
        goOccupied: cap.goOccupied,
        retOccupied: cap.retOccupied,
        density: UgamMeterDensity.hero,
      );

  /// One bus's meter from its [BusCapacity] slice.
  factory UgamCapacityMeter.bus(BusCapacity cap, {Key? key}) =>
      UgamCapacityMeter._(
        key: key,
        capacity: cap.capacity,
        goOccupied: cap.goOccupied,
        retOccupied: cap.retOccupied,
        density: UgamMeterDensity.bus,
      );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final cap = capacity < 0 ? 0 : capacity;
    final go = goOccupied.clamp(0, cap);
    final ret = retOccupied.clamp(0, cap);
    final symmetric = go == ret;

    if (density == UgamMeterDensity.bus) {
      return _busLine(c, cap, go, ret, symmetric);
    }
    return _twoLeg(c, cap, go, ret, symmetric);
  }

  // ── tour / hero : stacked leg rows ──────────────────────────────────────

  Widget _twoLeg(UgamColorSet c, int cap, int go, int ret, bool symmetric) {
    final hero = density == UgamMeterDensity.hero;
    final barH = hero ? 8.0 : 7.0;
    if (symmetric) {
      // One leg's worth of load on both legs — a single bar tells the whole
      // story (also the no-return-leg case: ret == go == 0 demand).
      return _legRow(c, label: null, placed: go, cap: cap, barH: barH);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _legRow(
          c,
          label: tr('capacity.going'),
          placed: go,
          cap: cap,
          barH: barH,
        ),
        SizedBox(height: hero ? UgamSpacing.sm : UgamSpacing.md),
        _legRow(
          c,
          label: tr('capacity.return_leg'),
          placed: ret,
          cap: cap,
          barH: barH,
        ),
      ],
    );
  }

  Widget _legRow(
    UgamColorSet c, {
    required String? label,
    required int placed,
    required int cap,
    required double barH,
  }) {
    final free = (cap - placed).clamp(0, cap);
    final full = free == 0;
    final frac = cap == 0 ? 0.0 : (placed / cap).clamp(0.0, 1.0);
    final count = Text(
      '$placed / $cap',
      style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
    );
    final freeLabel = Text(
      full ? tr('capacity.full') : tr('capacity.free_n', namedArgs: {'n': '$free'}),
      style: UgamText.caption.copyWith(color: full ? c.ink3 : c.good),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (label != null)
              Expanded(
                child: Text(
                  label,
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            count,
            const SizedBox(width: UgamSpacing.sm),
            freeLabel,
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        _bar(c, frac, barH, full),
      ],
    );
  }

  // ── bus : one compact line ──────────────────────────────────────────────

  Widget _busLine(UgamColorSet c, int cap, int go, int ret, bool symmetric) {
    final fuller = go > ret ? go : ret;
    final free = (cap - fuller).clamp(0, cap);
    final full = free == 0;
    final frac = cap == 0 ? 0.0 : (fuller / cap).clamp(0.0, 1.0);
    final detail = symmetric
        ? '$go/$cap'
        : '${tr('capacity.go_short')} $go/$cap'
            '  ·  ${tr('capacity.ret_short')} $ret/$cap';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                detail,
                style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink2)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              full
                  ? tr('capacity.full')
                  : tr('capacity.free_n', namedArgs: {'n': '$free'}),
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: full ? c.ink3 : c.good),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _bar(c, frac, 5, full),
      ],
    );
  }

  // ── shared bar ──────────────────────────────────────────────────────────

  Widget _bar(UgamColorSet c, double frac, double height, bool full) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: c.cardElev),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: frac <= 0 ? 0.0 : frac,
              child: ColoredBox(color: full ? c.good : c.ink2),
            ),
          ],
        ),
      ),
    );
  }
}
