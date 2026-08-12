/// The Board's sticky summary strip — spec §3 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`:
/// *"Vertical scroll keeps a sticky summary strip (counts / money total /
/// boarded count, per lens) pinned at top. The number must never scroll
/// away."*
///
/// **The number is the point.** A handler working a 74-berth coach scrolls
/// twelve to eighteen rows; if `₹55,200 બાકી` is drawn at the top of the chart
/// it is off screen for the entire round, which is the whole reason the eleven
/// screens each grew a header of their own. The strip is therefore a SIBLING of
/// the scroll view (see `BoardCanvas`), never a child of it.
///
/// The arithmetic lives in [BoardStripSummary], which is pure: berths in, two
/// strings + a tone out. No widget, no controller, no clock — so every metric
/// in spec §5's table is provable in a unit test rather than eyeballed on a
/// device.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/text_styles.dart';
import '../../design/tokens.dart';
import '../../models/board_lens.dart';
import '../../models/collection.dart';
import '../../utils/formatters.dart';

/// How the strip's headline number should FEEL. Colour is decoration here — the
/// number and its word already say everything — so this only ever tints the
/// primary figure, never becomes the sole carrier of meaning (spec §11).
enum BoardStripTone {
  /// Nothing to celebrate or chase.
  neutral,

  /// The round is done: fully collected, fully boarded, fully seated.
  good,

  /// Work outstanding, but the bulk is behind you.
  warn,

  /// Most of the job is still ahead.
  danger,
}

/// The strip's content for one lens, computed from the berths on screen.
///
/// [primary] is the figure (`73/74`, `₹55,200 બાકી`), [secondary] the quiet
/// qualifier beside it (`1 ખાલી`, `32% એકઠી`). Both are already translated.
@immutable
class BoardStripSummary {
  final String primary;
  final String? secondary;
  final BoardStripTone tone;

  /// True when [primary] is a SENTENCE rather than a figure — the honest
  /// per-lens zero states of spec §13 ("set fares to track collection", "add
  /// pickup points").
  ///
  /// It exists for layout, not for meaning. The figure styles are 20pt display
  /// numerals, and Gujarati is the primary language and runs about 30% longer
  /// than English: `વસૂલી જોવા માટે ભાડું નક્કી કરો` set at 20pt beside the
  /// "next outstanding" control ellipsizes to `વસૂલી જોવા…`, which tells a
  /// handler nothing. A message wraps at body size instead.
  final bool isMessage;

  const BoardStripSummary({
    required this.primary,
    this.secondary,
    this.tone = BoardStripTone.neutral,
    this.isMessage = false,
  });

  /// What a screen reader hears instead of two separate fragments.
  String get semanticLabel =>
      secondary == null ? primary : '$primary, $secondary';

  /// Builds the strip content for [metric].
  ///
  /// [berths] must be the berths of the bus on screen **in aisle order** — the
  /// order `BoardCanvas` feeds them in. Only [BoardStripMetric.groupSpread]
  /// actually depends on the order (a group is "split" when its berths are not
  /// contiguous along the walk), but passing anything else would make that one
  /// number quietly wrong, so the requirement is stated for all of them.
  factory BoardStripSummary.of(
    BoardStripMetric metric,
    Iterable<BoardBerth> berths,
  ) {
    final list = berths.toList(growable: false);
    switch (metric) {
      case BoardStripMetric.seatsFilled:
        return _seats(list);
      case BoardStripMetric.moneyOutstanding:
        return _money(list);
      case BoardStripMetric.boardedCount:
        return _boarded(list);
      case BoardStripMetric.stopProgress:
        return _stops(list);
      case BoardStripMetric.groupSpread:
        return _groups(list);
    }
  }

  /// `73/74 · 1 ખાલી`. Blocked berths are excluded from BOTH numbers — a wheel
  /// arch is not a seat somebody failed to sell.
  static BoardStripSummary _seats(List<BoardBerth> berths) {
    var occupied = 0;
    var vacant = 0;
    for (final b in berths) {
      if (b.isBlocked) continue;
      if (b.isOccupied) {
        occupied++;
      } else {
        vacant++;
      }
    }
    return BoardStripSummary(
      primary: '$occupied/${occupied + vacant}',
      secondary: vacant == 0
          ? tr('board_strip.seats_full')
          : tr('board_strip.seats_empty', namedArgs: {'count': '$vacant'}),
      tone: vacant == 0 && occupied > 0
          ? BoardStripTone.good
          : BoardStripTone.neutral,
    );
  }

  /// `₹55,200 બાકી · 32% એકઠી`.
  ///
  /// A bus with no fares set does NOT render `₹0 બાકી · 0% એકઠી` — spec §13
  /// calls that out by name ("do not show ₹0 everywhere"). It says so instead.
  static BoardStripSummary _money(List<BoardBerth> berths) {
    var due = 0.0;
    var paid = 0.0;
    var fare = 0.0;
    for (final b in berths) {
      if (!b.isOccupied) continue;
      due += b.outstanding;
      paid += b.paid;
      fare += b.fareDue;
    }

    if (fare <= Collection.kMoneyEpsilon && paid <= Collection.kMoneyEpsilon) {
      return BoardStripSummary(
        primary: tr('board_strip.money_no_fares'),
        isMessage: true,
      );
    }

    // Cash in hand can exceed the fare (a rider overpaid and is owed change),
    // and a strip reading "104% collected" would look like a bug rather than
    // like the one berth that needs ₹50 handed back.
    final billed = fare > Collection.kMoneyEpsilon ? fare : paid;
    final pct = ((paid > billed ? billed : paid) / billed * 100).round();

    return BoardStripSummary(
      primary: tr(
        'board_strip.money_due',
        namedArgs: {'amount': Formatters.formatMoneyInr(due)},
      ),
      secondary: tr(
        'board_strip.money_collected_pct',
        namedArgs: {'pct': '$pct'},
      ),
      tone: due <= Collection.kMoneyEpsilon
          ? BoardStripTone.good
          : (pct >= 50 ? BoardStripTone.warn : BoardStripTone.danger),
    );
  }

  /// `52/60 ચડ્યા`. Counted over occupied berths only — an empty berth cannot
  /// fail to board.
  static BoardStripSummary _boarded(List<BoardBerth> berths) {
    var boarded = 0;
    var total = 0;
    for (final b in berths) {
      if (!b.isOccupied) continue;
      total++;
      if (b.boarding == BerthBoarding.boarded) boarded++;
    }
    return BoardStripSummary(
      primary: '$boarded/$total',
      secondary: tr('board_strip.boarded'),
      tone: total > 0 && boarded == total
          ? BoardStripTone.good
          : BoardStripTone.neutral,
    );
  }

  /// `18/22 અડાજણ` — the stop the bus is WORKING, not a tour-wide total.
  ///
  /// "Working" is the same forgiving rule `BoardingProgress.currentIndex`
  /// already uses: the first stop that is not finished. Stop order here is
  /// first-appearance along the walk rather than the admin's route serial,
  /// because a berth carries its stop but not the route's ordering; the two
  /// agree often enough to be useful and the strip names the stop either way,
  /// so a handler is never told the wrong number for the stop shown.
  static BoardStripSummary _stops(List<BoardBerth> berths) {
    final order = <String>[];
    final names = <String, String>{};
    final total = <String, int>{};
    final boarded = <String, int>{};

    for (final b in berths) {
      if (!b.isOccupied) continue;
      final id = b.pickupStopId ?? b.pickupStopName;
      if (id == null || id.isEmpty) continue;
      if (!total.containsKey(id)) {
        order.add(id);
        names[id] = b.pickupStopName ?? id;
      }
      total[id] = (total[id] ?? 0) + 1;
      if (b.boarding == BerthBoarding.boarded) {
        boarded[id] = (boarded[id] ?? 0) + 1;
      }
    }

    if (order.isEmpty) {
      return BoardStripSummary(
        primary: tr('board_strip.no_stops'),
        isMessage: true,
      );
    }

    final current = order.firstWhere(
      (id) => (boarded[id] ?? 0) < (total[id] ?? 0),
      orElse: () => order.last,
    );
    final done = boarded[current] ?? 0;
    final expected = total[current] ?? 0;

    return BoardStripSummary(
      primary: '$done/$expected',
      secondary: names[current],
      tone: done >= expected ? BoardStripTone.good : BoardStripTone.neutral,
    );
  }

  /// `12 ગ્રુપ · 3 વિભાજિત`.
  ///
  /// A group is **split** when its berths are not contiguous along the walk —
  /// i.e. somebody else sits between two of its members. That is exactly the
  /// thing a handler is looking for when they open the group lens, and it is
  /// only computable because [berths] arrive in aisle order.
  static BoardStripSummary _groups(List<BoardBerth> berths) {
    final runs = <String, int>{};
    String? previous;
    for (final b in berths) {
      if (!b.isOccupied) {
        previous = null;
        continue;
      }
      final id = b.groupId;
      if (id == null || id.isEmpty) {
        previous = null;
        continue;
      }
      if (id != previous) runs[id] = (runs[id] ?? 0) + 1;
      previous = id;
    }

    final split = runs.values.where((n) => n > 1).length;
    return BoardStripSummary(
      primary: tr('board_strip.groups', namedArgs: {'count': '${runs.length}'}),
      secondary: split == 0
          ? null
          : tr('board_strip.groups_split', namedArgs: {'count': '$split'}),
      tone: split == 0 ? BoardStripTone.neutral : BoardStripTone.warn,
    );
  }
}

/// The pinned strip itself.
///
/// Deliberately shallow: one row, one big number, one qualifier, an optional
/// offline badge and an optional [trailing] slot. The "next outstanding →"
/// control of spec §4 belongs in that slot — it is the lens switcher's to build
/// and this widget's to make room for.
class BoardSummaryStrip extends StatelessWidget {
  /// Which number this lens pins. Take it from `lens.stripMetric`.
  final BoardStripMetric metric;

  /// The bus on screen, in aisle order. See [BoardStripSummary.of].
  final Iterable<BoardBerth> berths;

  /// Usually the "next outstanding →" control.
  final Widget? trailing;

  /// Board mutations queued locally (spec §9). Above zero the strip shows the
  /// plain `3 ક્રિયા બાકી · સિંક થશે` indicator; the count IS the reassurance,
  /// so it is never collapsed to a bare cloud icon.
  final int pendingSyncCount;

  const BoardSummaryStrip({
    super.key,
    required this.metric,
    required this.berths,
    this.trailing,
    this.pendingSyncCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final summary = BoardStripSummary.of(metric, berths);

    final Color figureInk = switch (summary.tone) {
      BoardStripTone.neutral => c.ink,
      BoardStripTone.good => c.good,
      BoardStripTone.warn => c.warm,
      BoardStripTone.danger => c.danger,
    };

    return Container(
      // Flush with the page (level 0): the strip IS the page's top edge, not a
      // card floating on it. Separation comes from the hairline below.
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: summary.semanticLabel,
              child: ExcludeSemantics(
                child: summary.isMessage
                    // A sentence, not a figure: body size, two lines, no
                    // baseline row to align it against. See
                    // [BoardStripSummary.isMessage] — this is what keeps the
                    // Gujarati zero states readable next to the trailing
                    // control instead of ellipsized into uselessness.
                    ? Text(
                        summary.primary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.bodyStrong.copyWith(color: c.ink2),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              summary.primary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.numLg.copyWith(color: figureInk),
                            ),
                          ),
                          if (summary.secondary != null) ...[
                            const SizedBox(width: UgamSpacing.sm),
                            Flexible(
                              child: Text(
                                summary.secondary!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: UgamText.caption.copyWith(color: c.ink2),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
          ),
          if (pendingSyncCount > 0) ...[
            const SizedBox(width: UgamSpacing.sm),
            _OfflinePill(count: pendingSyncCount),
          ],
          if (trailing != null) ...[
            const SizedBox(width: UgamSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// `3 ક્રિયા બાકી · સિંક થશે` — plain, unalarming, and never a blocker: the
/// action already happened locally (spec §9).
class _OfflinePill extends StatelessWidget {
  final int count;

  const _OfflinePill({required this.count});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final label = tr(
      'board_strip.offline_pending',
      namedArgs: {'count': '$count'},
    );
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.sm,
            vertical: UgamSpacing.badgeV,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 12, color: c.ink2),
              const SizedBox(width: UgamSpacing.xs),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
