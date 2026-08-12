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
///
/// THREE states, not two. `capacity == 0` — a bus whose seat layout has not
/// landed (or was never drawn) — is neither full nor empty: it is "no seat plan
/// yet". It used to fall through the `free == 0 -> full` test and announce
/// itself SOLD OUT in the done-tone on a bus that has no seats at all, so the
/// agent could not tell a finished tour from one that had not started. It now
/// renders `capacity.no_layout` over an EMPTY track in [UgamColorSet.ink3] and
/// never borrows the mint. The grid face already refuses to render at all in
/// this case (`tour_seat_assignment_screen.dart`, the `capacity <= 0` guard) —
/// this is the same intent, expressed as copy instead of silence.
class UgamCapacityMeter extends StatelessWidget {
  final int capacity;
  final int goOccupied;
  final int retOccupied;
  final UgamMeterDensity density;

  /// Bus density only: whether to render the trailing "{n} free" / "full" text.
  /// The tour Summary sets this false and shows a typed seat-icon free indicator
  /// instead (a Double Sofa reads as ONE double-berth glyph, not an ambiguous
  /// berth count), so the meter line stays just "placed/cap" over the bar.
  final bool showFreeLabel;

  const UgamCapacityMeter._({
    super.key,
    required this.capacity,
    required this.goOccupied,
    required this.retOccupied,
    required this.density,
    this.showFreeLabel = true,
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

  /// Tour-wide meter from raw leg counts — used when the occupancy comes from
  /// ACTUAL assignments ([computeActualCapacity]) rather than the engine plan,
  /// so the "seats placed" headline matches the grid. Same two-leg rendering as
  /// [UgamCapacityMeter.tour].
  factory UgamCapacityMeter.tourCounts({
    required int capacity,
    required int goOccupied,
    required int retOccupied,
    Key? key,
  }) =>
      UgamCapacityMeter._(
        key: key,
        capacity: capacity,
        goOccupied: goOccupied,
        retOccupied: retOccupied,
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

  /// One bus's meter from its [BusCapacity] slice. Set [showFreeLabel] false to
  /// drop the trailing "{n} free" text (the Summary renders typed seat icons in
  /// its place); a full bus is then flagged by the caller, not this text.
  factory UgamCapacityMeter.bus(
    BusCapacity cap, {
    Key? key,
    bool showFreeLabel = true,
  }) =>
      UgamCapacityMeter._(
        key: key,
        capacity: cap.capacity,
        goOccupied: cap.goOccupied,
        retOccupied: cap.retOccupied,
        density: UgamMeterDensity.bus,
        showFreeLabel: showFreeLabel,
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
    // No seat plan -> the third state. MUST come before the `free == 0` test
    // below, which is what used to call an empty-capacity bus "full".
    if (cap == 0) return _noPlanRow(c, label: label, barH: barH);
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

  /// The `cap == 0` face for the stacked densities. It deliberately prints NO
  /// fraction: "0 / 0" is the sentence that contradicted itself, because a
  /// denominator of zero cannot express how full anything is. The leg label
  /// survives when the caller passed one, and the status slot — where the count
  /// and the free/full pair normally sit — carries the plain-language third
  /// state instead, in [UgamColorSet.ink2].
  ///
  /// `ink2`, NOT the `ink3` the sibling "full" label wears: this string is the
  /// ONLY thing in the row saying what is going on (it replaces both the count
  /// and the free/full pair), and `ink3` measures 2.74:1 on `card` in Daylight
  /// — below AA for body copy. `ink2` is 5.50:1 light / 5.95:1 dark on `card`
  /// (4.90 / 5.18 on `cardElev`) and still reads a clear step quieter than the
  /// `ink` count it stands in for.
  ///
  /// The track still renders at zero fill rather than collapsing, so the row
  /// keeps its height and a layout arriving mid-session lands as a bar filling
  /// in, not as a jump.
  Widget _noPlanRow(
    UgamColorSet c, {
    required String? label,
    required double barH,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (label != null) ...[
              Text(
                label,
                style: UgamText.caption.copyWith(color: c.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(width: UgamSpacing.sm),
            ],
            // Expanded + end-aligned, NOT a Spacer beside a Flexible: two flex
            // children would split the row in half and clip Gujarati at 1.3x.
            Expanded(
              child: Text(
                tr('capacity.no_layout'),
                style: UgamText.caption.copyWith(color: c.ink2),
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        _bar(c, 0, barH, false),
      ],
    );
  }

  // ── bus : one compact line ──────────────────────────────────────────────

  Widget _busLine(UgamColorSet c, int cap, int go, int ret, bool symmetric) {
    // Same third state as [_legRow], in the compact geometry: the no-plan copy
    // takes the slot the "0/0" fraction used to occupy (leading, where this
    // density puts its detail), the trailing free/full slot stays empty, and
    // the track paints at zero fill — never the done-tone.
    if (cap == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('capacity.no_layout'),
            // ink2 for the same AA reason as [_noPlanRow].
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          _bar(c, 0, 5, false),
        ],
      );
    }
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
            if (showFreeLabel) ...[
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
