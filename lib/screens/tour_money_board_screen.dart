import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import '../utils/formatters.dart';
import 'bus_money_screen.dart';
import 'collection_screen.dart';
import 'trip_pnl_screen.dart';

/// TOUR MONEY BOARD — a scannable, mostly read-only roll-up of every bus on
/// a tour. Each row shows that bus's money summary (collected / to-collect /
/// to-return / expenses / outstanding handover) and carries a warm attention
/// ring ONLY when it needs action (outstanding handover or a shortfall still
/// to collect), a `good` ring when fully settled, and a neutral edge
/// otherwise. A sticky tour-totals capsule pins the [TourMoneySummary] in the
/// thumb zone. Tapping a bus opens the existing per-bus [BusMoneyScreen].
///
/// All aggregation is delegated to [MoneyController] (read-only helpers); this
/// screen never mutates money state. Colour comes exclusively from
/// [UgamColors.of] and every figure uses tabular numerals, per the locked DNA.
class TourMoneyBoardScreen extends StatefulWidget {
  final String tourId;

  const TourMoneyBoardScreen({super.key, required this.tourId});

  @override
  State<TourMoneyBoardScreen> createState() => _TourMoneyBoardScreenState();
}

class _TourMoneyBoardScreenState extends State<TourMoneyBoardScreen> {
  MoneyController get _money => Get.find<MoneyController>();
  TourController get _tours => Get.find<TourController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _money.loadForTour(widget.tourId);
    });
  }

  void _openBus(Tour tour, Bus bus) {
    Get.to(
      () => BusMoneyScreen(tour: tour, bus: bus),
      transition: Transition.cupertino,
    );
  }

  void _openPnl() {
    Get.to(
      () => TripPnlScreen(tourId: widget.tourId),
      transition: Transition.cupertino,
    );
  }

  /// Shortcut into the existing per-bus [CollectionScreen] — the same
  /// destination [BusMoneyScreen]'s "Collect from passengers" CTA reaches,
  /// but jumped to in one tap from the board (no detour through BusMoney).
  void _collectForBus(Tour tour, Bus bus) {
    Get.to(
      () => CollectionScreen(tour: tour, bus: bus),
      transition: Transition.cupertino,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(() {
              final title = _tours.getTour(widget.tourId)?.title ?? '';
              return UgamAppBar(
                eyebrow: tr('tour_money_board.eyebrow'),
                title: title.isEmpty
                    ? tr('tour_money_board.tour_money')
                    : title,
              );
            }),
            Expanded(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  return Center(
                    child: Text(
                      tr('tour_money_board.tour_not_found'),
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  );
                }

                final buses = tour.buses;
                // Touch the money obs lists so Obx re-renders on any change.
                final summaries = _money.summariesForBuses(
                  buses.map((b) => b.id),
                );

                if (buses.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.account_balance_wallet_outlined,
                    title: tr('tour_money_board.no_buses'),
                  );
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _PnlEntryCard(
                      summary: _money.tourSummary(),
                      onTap: _openPnl,
                      c: c,
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    Text(
                      tr('tour_money_board.per_bus'),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.md),
                    for (var i = 0; i < buses.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UgamSpacing.md),
                        child: _BusMoneyRow(
                          bus: buses[i],
                          summary: summaries[i],
                          state: _money.stateForBusSummary(summaries[i]),
                          onTap: () => _openBus(tour, buses[i]),
                          onCollect: () => _collectForBus(tour, buses[i]),
                          c: c,
                        ),
                      ),
                  ],
                );
              }),
            ),
            // Sticky tour-totals capsule in the thumb zone.
            Obx(() {
              final tour = _tours.getTour(widget.tourId);
              if (tour == null || tour.buses.isEmpty) {
                return const SizedBox.shrink();
              }
              return _TotalsCapsule(summary: _money.tourSummary(), c: c);
            }),
          ],
        ),
      ),
    );
  }
}

// ─── Profit & Loss entry card ───────────────────────────────────────────────

/// Tappable banner at the top of the board → opens the per-trip [TripPnlScreen]
/// (per-bus + per-handler P&L). Previews the trip's TRUE net (billed − costs)
/// so the headline answer is visible before tapping in.
class _PnlEntryCard extends StatelessWidget {
  final TourMoneySummary summary;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _PnlEntryCard({
    required this.summary,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final billed = summary.totalNetBilled;
    final tone = billed >= 0 ? c.good : c.danger;
    return UgamCard.plain(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.stat),
            ),
            child: Icon(Icons.insights_rounded, size: 20, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('trip_pnl.title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('trip_pnl.entry_sub'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                Formatters.formatMoneyInr(billed.abs()),
                style: UgamText.numLg.copyWith(color: tone, fontSize: 18),
              ),
              const SizedBox(height: 2),
              Text(
                billed >= 0 ? tr('trip_pnl.profit') : tr('trip_pnl.loss'),
                style: UgamText.micro.copyWith(color: tone),
              ),
            ],
          ),
          const SizedBox(width: UgamSpacing.xs),
          Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
        ],
      ),
    );
  }
}

// ─── Per-bus money row ──────────────────────────────────────────────────────

class _BusMoneyRow extends StatelessWidget {
  final Bus bus;
  final BusMoneySummary summary;
  final BusMoneyState state;
  final VoidCallback onTap;
  final VoidCallback onCollect;
  final UgamColorSet c;

  const _BusMoneyRow({
    required this.bus,
    required this.summary,
    required this.state,
    required this.onTap,
    required this.onCollect,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // warm = needs action (outstanding handover / shortfall) — attention only.
    // good = settled. neutral = nothing has moved yet → no tint.
    final (
      UgamCardTone cardTone,
      UgamStatusTone tone,
      String statusLabel,
    ) = switch (state) {
      BusMoneyState.actionNeeded => (
        UgamCardTone.warm,
        UgamStatusTone.warm,
        summary.outstandingHandover > 0.005
            ? tr(
                'tour_money_board.handover_due',
                namedArgs: {
                  'n': Formatters.formatMoneyInr(summary.outstandingHandover),
                },
              )
            : tr(
                'tour_money_board.to_collect_amount',
                namedArgs: {
                  'n': Formatters.formatMoneyInr(summary.toCollectTotal),
                },
              ),
      ),
      BusMoneyState.settled => (
        UgamCardTone.good,
        UgamStatusTone.good,
        tr('tour_money_board.settled'),
      ),
      BusMoneyState.neutral => (
        UgamCardTone.none,
        UgamStatusTone.neutral,
        tr('tour_money_board.no_activity'),
      ),
    };

    return UgamCard.plain(
      tone: cardTone,
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Title row: icon + name/type + status dot ───────────────
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.seat),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 18,
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bus.name,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(
                      bus.busType,
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Extra income the handler holds (cabin/gallery/other).
                    // It already folds into the headline outstanding figure
                    // above; surface it compactly so the row shows WHERE the
                    // extra cash came from. Only when there is income.
                    if (summary.income > 0.005) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Text(
                        '+${Formatters.formatMoneyInr(summary.income)} '
                        '${tr('bus_money.stat_income')}',
                        style: UgamText.tabular(
                          UgamText.micro.copyWith(
                            color: c.good,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Headline: the ONE action number for this bus ───────────
          // Outstanding handover when there's cash still owed to admin,
          // else what's still to collect — shown large and tabular so the
          // row's action lands first. Quiet ink when nothing's due.
          Builder(
            builder: (_) {
              final hasHandoverDue = summary.outstandingHandover > 0.005;
              final hasToCollect = summary.toCollectTotal > 0.005;
              final actionAmount = hasHandoverDue
                  ? summary.outstandingHandover
                  : summary.toCollectTotal;
              final actionLabel = hasHandoverDue
                  ? tr('tour_money_board.outstanding_handover')
                  : tr('tour_money_board.to_collect');
              final figureColor = hasHandoverDue
                  ? c.warm
                  : (hasToCollect ? c.danger : c.ink2);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel.toUpperCase(),
                    style: UgamText.micro.copyWith(
                      color: c.ink3,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Formatters.formatMoneyInr(actionAmount),
                    style: UgamText.numXl.copyWith(color: figureColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Two compact tonal pills: collected + handover ──────────
          // The two figures the agent glances at most, side by side as quiet
          // tonal chips — no metric grid, no second-tier ink competing with
          // the headline above.
          Row(
            children: [
              Expanded(
                child: _MoneyPill(
                  label: tr('tour_money_board.collected'),
                  value: Formatters.formatMoneyInr(summary.collected),
                  c: c,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _MoneyPill(
                  label: tr('tour_money_board.handover'),
                  value: Formatters.formatMoneyInr(summary.handedOver),
                  c: c,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // ── Secondary figures, folded behind a tap ─────────────────
          // To-collect / to-return / expenses are rarely the first question,
          // so they hide inside an expandable breakdown rather than sitting in
          // an always-on 3-number strip.
          UgamHeroStat(
            label: tr('tour_money_board.more_detail'),
            value: Formatters.formatMoneyInr(summary.expensesTotal),
            tone: c.ink2,
            breakdown: [
              HeroStatLine(
                tr('tour_money_board.to_collect'),
                Formatters.formatMoneyInr(summary.toCollectTotal),
                tone: summary.toCollectTotal > 0.005 ? c.danger : c.ink2,
              ),
              HeroStatLine(
                tr('tour_money_board.to_return'),
                Formatters.formatMoneyInr(summary.toReturnTotal),
                tone: summary.toReturnTotal > 0.005 ? c.warm : c.ink2,
              ),
              HeroStatLine(
                tr('tour_money_board.expenses'),
                Formatters.formatMoneyInr(summary.expensesTotal),
                tone: c.ink2,
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          // Status dot only — the outstanding figure now leads the row as the
          // headline, so the trailing amount duplicate is dropped here.
          Align(
            alignment: Alignment.centerLeft,
            child: UgamStatusDot(label: statusLabel, tone: tone),
          ),
          const SizedBox(height: UgamSpacing.lg),
          // One-tap shortcut straight into this bus's CollectionScreen —
          // no detour through BusMoneyScreen. The row itself still opens
          // the full per-bus detail view. Tonal (quiet primary) so it never
          // competes with the single solid-champagne totals capsule below.
          UgamButton(
            label: tr('tour_money_board.collect'),
            icon: Icons.groups_rounded,
            kind: UgamButtonKind.tonal,
            expand: true,
            onPressed: onCollect,
          ),
        ],
      ),
    );
  }
}

/// Compact tonal money chip — a quiet `accentFill` pill carrying a micro label
/// over a tabular value. Used in pairs on a bus row so the two everyday figures
/// (collected / handover) read as one calm strip instead of a metric grid.
class _MoneyPill extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _MoneyPill({
    required this.label,
    required this.value,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.numLg.copyWith(color: c.ink2, fontSize: 15),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Sticky tour-totals capsule ─────────────────────────────────────────────

class _TotalsCapsule extends StatelessWidget {
  final TourMoneySummary summary;
  final UgamColorSet c;

  const _TotalsCapsule({required this.summary, required this.c});

  @override
  Widget build(BuildContext context) {
    final outstanding = summary.totalOutstandingHandover;
    final settled = outstanding.abs() <= 0.005;

    // One hero number (outstanding) on the left, two compact pills (collected,
    // net) on the right — a single tight strip in the thumb zone instead of the
    // old 5-number grid. Kept short (~88dp content) so the chart still breathes.
    return UgamStickyCTA(
      child: UgamCard.plain(
        elev: true,
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── Hero: outstanding handover ─────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        tr('tour_money_board.outstanding_handover')
                            .toUpperCase(),
                        style: UgamText.micro.copyWith(color: c.ink3),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      UgamStatusDot(
                        label: settled
                            ? tr('tour_money_board.all_settled')
                            : tr('tour_money_board.open'),
                        tone:
                            settled ? UgamStatusTone.good : UgamStatusTone.warm,
                      ),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  Text(
                    Formatters.formatMoneyInr(outstanding),
                    style: UgamText.tabular(
                      UgamText.numXl.copyWith(
                        color: settled ? c.good : c.warm,
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // ── Two compact pills: collected + net ─────────────────
            _CapsulePill(
              label: tr('tour_money_board.collected'),
              value: Formatters.formatMoneyInr(summary.totalCollected),
              c: c,
            ),
            const SizedBox(width: UgamSpacing.sm),
            _CapsulePill(
              label: tr('tour_money_board.net'),
              value: Formatters.formatMoneyInr(summary.totalNet),
              c: c,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tight tonal chip used inside the sticky totals capsule: a micro cap over a
/// tabular value, sized for a thumb-zone strip rather than a full metric tile.
class _CapsulePill extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _CapsulePill({
    required this.label,
    required this.value,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.numLg.copyWith(color: c.ink, fontSize: 15),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
