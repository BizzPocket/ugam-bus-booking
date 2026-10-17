part of '../tour_overview_screen.dart';

// ─── First-load placeholder ──────────────────────────────────────────────

/// Shaped like the cockpit it stands in for — the summary card, the buses
/// eyebrow, then the buses card — so the load lands as a fill change rather
/// than a spinner popping into a new layout. Gutters match the real
/// [ListView] above it, so nothing shifts sideways when the data arrives.
class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 150, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            UgamSkeleton(height: 14, width: 64, radius: 6),
            SizedBox(width: UgamSpacing.sm),
            UgamSkeleton(height: 14, width: 22, radius: 6),
          ],
        ),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 196, radius: UgamRadius.card),
      ],
    );
  }
}

// ─── Summary card (seats placed + bus requirements) ──────────────────────

/// One compact card on the 8pt grid: the seats-placed progress on top, a
/// hairline divider, then what the agent still has to book (single/double/
/// seater counts + total). Replaces the two tall stat + requirements cards.
class _SummaryCard extends StatelessWidget {
  /// ACTUAL-assignment snapshot driving the seats-placed meter — the SAME real
  /// seats the grid shows, so "placed" means placed, not "the plan would place".
  /// Null only when the tour has no buses yet (total == 0) — then the meter row
  /// collapses to a plain "0 / total".
  final ActualCapacity? actual;
  final int total;
  final int singles;
  final int doubles;
  final int seaters;
  final VoidCallback onEditRequests;
  final UgamColorSet c;

  const _SummaryCard({
    required this.actual,
    required this.total,
    required this.singles,
    required this.doubles,
    required this.seaters,
    required this.onEditRequests,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final units = singles + doubles + seaters;
    final chips = <String>[
      '$singles ${tr('tour_overview.single_sofa')}',
      '$doubles ${tr('tour_overview.double_sofa')}',
      if (seaters > 0) '$seaters ${tr('tour_overview.seater')}',
    ].join('  ·  ');

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Seats placed — eyebrow, then the shared two-leg meter. The meter
          // owns the count ("placed / cap"), the per-leg GO/RET split, the
          // "{n} free" label and the bar — no percentage, no merged fraction,
          // and every figure a whole seat.
          //
          // ONE branch, not two. The `else` here used to hand-roll a literal
          // "0 / $total" — and `actual` is null EXACTLY when `total == 0`, so
          // that string was always, unavoidably, "0 / 0": a fraction with a
          // zero denominator, printed directly under a "SEATS PLACED" eyebrow,
          // above a "no buses yet" empty state. The meter now owns the
          // zero-capacity case as an explicit third state ("no seat plan yet"),
          // so routing the null snapshot through it deletes the contradiction
          // instead of duplicating a worse version of it here.
          Text(
            tr('tour_overview.seats_placed'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamCapacityMeter.tourCounts(
            capacity: actual?.capacity ?? total,
            goOccupied: actual?.goOccupied ?? 0,
            retOccupied: actual?.retOccupied ?? 0,
          ),
          const SizedBox(height: UgamSpacing.md),
          Container(height: 1, color: c.border),
          // Bus requirements — eyebrow + Edit, then the chips + total.
          //
          // "Edit" is the only inline door from the seats cockpit to the
          // Requests editor and it was a ~34 px target: the previous pass got
          // there by folding the surrounding whitespace into the link's own
          // padding, then stopped short of 44 rather than resize the card
          // without being asked. The row is now a real 44 px band — the
          // vertical space it used to pad with is simply inside the band, so
          // the card grows ~12 px, on a screen that had void below it anyway.
          // The left padding on the link widens the box further into the gap
          // beside it, at no visual cost.
          //
          // The label is also no longer champagne: tokens.dart reserves the
          // accent for "this is yours" and names links explicitly as NOT that.
          // Weight carries the affordance instead.
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Text(
                  tr('tour_overview.bus_requirements'),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onEditRequests,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.only(left: UgamSpacing.lg),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('app.action.edit'),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: c.ink2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Two lines, no ellipsis: these are system labels ("સિંગલ સોફા ·
          // ડબલ સોફા · સીટર"), which run past a single 375 pt line in
          // Gujarati. Truncating a requirements list to "3 સિંગલ સો…" loses
          // the very numbers the agent came here to read.
          Text(
            chips,
            style: UgamText.caption.copyWith(color: c.ink),
            maxLines: 2,
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('tour_overview.total_to_book', namedArgs: {'n': '$units'}),
            style: UgamText.micro.copyWith(color: c.ink3),
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}

// ─── "N need your decision" chip ─────────────────────────────────────────

class _DecisionChip extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _DecisionChip({
    required this.count,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // The single entry to the seating-conflict resolver was a 38 px
        // target. `minHeight: 44` floors it; `centerLeft` is MANDATORY beside
        // it — without an alignment the Row would top-align inside the taller
        // box, and `center` would re-centre it horizontally too (the parent is
        // a full-width ListView). Matches charts_screen.dart:463.
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.tight,
        ),
        decoration: BoxDecoration(
          color: c.warmFill,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.warm),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              tr('tour_overview.need_decision', namedArgs: {'n': '$count'}),
              style: UgamText.bodyStrong.copyWith(color: c.warm),
            ),
            const SizedBox(width: UgamSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.warm),
          ],
        ),
      ),
    );
  }
}

// ─── Capacity / overflow banner ──────────────────────────────────────────

/// Warm, action-bearing banner shown when demand can't fit the buses.
///
/// BEFORE the agent taps Fill it shows the pre-fill berth shortfall (an
/// estimate from requested-vs-available berths). AFTER a Fill that overflowed
/// it shows the authoritative count of passengers the engine could not seat.
/// Either way it offers the two real remedies — add capacity, or change /
/// waitlist requests — so the agent is never stranded on a read-only screen.
class _CapacityBanner extends StatelessWidget {
  final int overflowCount;
  final int demandBerths;
  final int capacityBerths;
  final int shortfall;
  final VoidCallback onAddBus;

  /// Set only once a plan has actually overflowed — jumps to the waitlist
  /// decisions. Null before the first overflowing Fill.
  final VoidCallback? onReview;
  final VoidCallback onEditRequests;
  final UgamColorSet c;

  const _CapacityBanner({
    required this.overflowCount,
    required this.demandBerths,
    required this.capacityBerths,
    required this.shortfall,
    required this.onAddBus,
    required this.onReview,
    required this.onEditRequests,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final overflowed = overflowCount > 0;
    final title = overflowed
        ? tr(
            'tour_overview.capacity_overflow_title',
            namedArgs: {'n': '$overflowCount'},
          )
        : tr('tour_overview.capacity_short_title');
    final message = overflowed
        ? tr('tour_overview.capacity_overflow_message')
        : tr(
            'tour_overview.capacity_short_message',
            namedArgs: {
              'demand': '$demandBerths',
              'berthWord': _berthWord(demandBerths),
              'capacity': '$capacityBerths',
              'shortfall': '$shortfall',
            },
          );

    final secondaryLabel = overflowed
        ? tr('tour_overview.review_waitlist')
        : tr('tour_overview.edit_requests');
    final secondaryTap = overflowed ? onReview : onEditRequests;

    // The shared card, tinted warm — NOT a hand-rolled Container. The tone
    // resolves to the same warmFill + warm hairline this used to spell out by
    // hand, and composing the component means the banner picks up the app's
    // elevation instead of sitting flat on the page like a wireframe block.
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                // DECORATIVE badge (nothing taps it) -> px, not tap. Radius 10
                // was off the UgamRadius scale entirely; `input` (14) is what
                // every other icon chip in the tours cluster uses
                // (e.g. tour_detail's `_NextActionCard` / `_TourToolRow`).
                width: UgamScale.px(context, 34),
                height: UgamScale.px(context, 34),
                decoration: BoxDecoration(
                  color: c.warm.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.event_busy_rounded, size: 18, color: c.warm),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: UgamText.titleS.copyWith(color: c.ink)),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(
                      message,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Expanded(
                child: _BannerAction(
                  label: tr('tour_overview.add_a_bus'),
                  icon: Icons.add_rounded,
                  filled: true,
                  onTap: onAddBus,
                  c: c,
                ),
              ),
              if (secondaryTap != null) ...[
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: _BannerAction(
                    label: secondaryLabel,
                    icon: overflowed
                        ? Icons.error_outline_rounded
                        : Icons.edit_note_rounded,
                    filled: false,
                    onTap: secondaryTap,
                    c: c,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _berthWord(int n) =>
      n == 1 ? tr('tour_overview.berth') : tr('tour_overview.berths');
}

class _BannerAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _BannerAction({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // ROSE ON ROSE DOES NOT WORK. These two buttons used to be warm@20% /
    // warm@10% fills carrying a `c.warm` label, sitting on a `warmFill` card —
    // rose ink on a rose wash on a rose ground. Measured on the current tokens
    // (warm-tone card ground: #F8E2EC Daylight / #322126 Midnight):
    //
    //                            Daylight   Midnight   needs
    //   primary label            3.50       4.56       4.5
    //   secondary label          4.00       5.54       4.5
    //   primary fill vs card     1.30       1.47       3.0
    //   secondary fill vs card   1.14       1.21       3.0
    //   hairline warm@40 vs card 1.74       2.24       3.0
    //
    // Only the two Midnight labels cleared anything; both buttons dissolved
    // into the card in BOTH themes, so the remedies the banner exists to offer
    // were invisible as controls. The fix separates the pair by WEIGHT instead
    // of by 10 points of alpha:
    //
    //  * primary  — solid, full-strength `c.warm` with `c.onAction` ink.
    //               label 5.60 / 8.38, fill vs card 4.56 / 6.71.
    //  * secondary— keeps the tonal wash but takes a full-strength `c.ink`
    //               label (13.39 / 11.37) and a full-strength `c.warm` border
    //               (4.56 / 6.71 vs the card, 4.00 / 5.54 vs its own fill).
    //               No alpha on a warm fill can clear 3:1 against warmFill —
    //               the boundary has to come from the border. Do not retry it.
    //
    // Still WARM, deliberately not danger: "not enough seats" is an actionable
    // warning, and this app rations red for things that need intervention.
    //
    // `c.onAction` is the ink on BOTH themes' solid fill with no brightness
    // branch: it is white in Daylight and the #12100E ground in Midnight, which
    // is exactly the flip `warm` needs (a mid-tone rose in light, a pale rose in
    // dark). It beats `c.onAccent` in Midnight too (8.38 vs 8.20).
    final Color bg = filled ? c.warm : c.warm.withValues(alpha: 0.10);
    final Color fg = filled ? c.onAction : c.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // The comment above says this mirrors UgamButton's tonal geometry at
        // "50-h" but the code wrote 48, so these two were the only buttons in
        // the app 2 px short of every other one. `tap` (never `px` — this is a
        // finger target) corrects the value AND puts it on the scale factor,
        // so it tracks the text inside it on a small phone: 50 at 390 pt,
        // floored at the 44 pt minimum below that.
        height: UgamScale.tap(context, 50),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          // No border on the solid one — its own fill already draws the edge at
          // 4.56 / 6.71 against the card, and a warm hairline on a warm slab is
          // just an invisible line. The bordered-vs-borderless difference is
          // part of what now separates the two silhouettes.
          border: filled ? null : Border.all(color: c.warm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            // `sm`, matching the icon->label gap UgamButton uses at
            // ugam_button.dart:132 — the component this row mirrors.
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.captionStrong.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
