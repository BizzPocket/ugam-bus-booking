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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(() {
              final title = _tours.getTour(widget.tourId)?.title ?? '';
              return UgamAppBar(
                eyebrow: tr('tour_money_board.eyebrow'),
                title:
                    title.isEmpty ? tr('tour_money_board.tour_money') : title,
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
                final summaries =
                    _money.summariesForBuses(buses.map((b) => b.id));

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
                    UgamSpacing.sm,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    Text(
                      tr('tour_money_board.per_bus'),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    for (var i = 0; i < buses.length; i++)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: UgamSpacing.md),
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
    final (UgamCardTone cardTone, UgamStatusTone tone, String statusLabel) =
        switch (state) {
      BusMoneyState.actionNeeded => (
          UgamCardTone.warm,
          UgamStatusTone.warm,
          summary.outstandingHandover > 0.005
              ? tr(
                  'tour_money_board.handover_due',
                  namedArgs: {
                    'n': Formatters.formatMoneyInr(summary.outstandingHandover)
                  },
                )
              : tr(
                  'tour_money_board.to_collect_amount',
                  namedArgs: {
                    'n': Formatters.formatMoneyInr(summary.toCollectTotal)
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
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // ── Headline money pair: collected + expected handover ─────
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: tr('tour_money_board.collected'),
                  value: Formatters.formatMoneyInr(summary.collected),
                  valueColor: c.ink,
                  c: c,
                ),
              ),
              Expanded(
                child: _Metric(
                  label: tr('tour_money_board.handover'),
                  value: Formatters.formatMoneyInr(summary.handedOver),
                  valueColor: c.ink,
                  c: c,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // ── Secondary money triplet ────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: tr('tour_money_board.to_collect'),
                  value: Formatters.formatMoneyInr(summary.toCollectTotal),
                  valueColor:
                      summary.toCollectTotal > 0.005 ? c.danger : c.ink2,
                  c: c,
                ),
              ),
              Expanded(
                child: _Metric(
                  label: tr('tour_money_board.to_return'),
                  value: Formatters.formatMoneyInr(summary.toReturnTotal),
                  valueColor:
                      summary.toReturnTotal > 0.005 ? c.warm : c.ink2,
                  c: c,
                ),
              ),
              Expanded(
                child: _Metric(
                  label: tr('tour_money_board.expenses'),
                  value: Formatters.formatMoneyInr(summary.expensesTotal),
                  valueColor: c.ink2,
                  c: c,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Divider(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              UgamStatusDot(label: statusLabel, tone: tone),
              Text(
                tr(
                  'tour_money_board.outstanding_amount',
                  namedArgs: {
                    'n': Formatters.formatMoneyInr(summary.outstandingHandover)
                  },
                ),
                style: UgamText.tabular(
                  UgamText.caption.copyWith(
                    color: summary.outstandingHandover > 0.005
                        ? c.warm
                        : c.ink3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
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

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  final UgamColorSet c;

  const _Metric({
    required this.label,
    required this.value,
    required this.valueColor,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          value,
          style:
              UgamText.tabular(UgamText.bodyStrong.copyWith(color: valueColor)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
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

    return UgamStickyCTA(
      child: UgamCard.plain(
        elev: true,
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  tr('tour_money_board.tour_totals'),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                UgamStatusDot(
                  label: settled
                      ? tr('tour_money_board.all_settled')
                      : tr('tour_money_board.open'),
                  tone: settled
                      ? UgamStatusTone.good
                      : UgamStatusTone.warm,
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _TotalCol(
                    label: tr('tour_money_board.collected'),
                    value: Formatters.formatMoneyInr(summary.totalCollected),
                    color: c.ink,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _TotalCol(
                    label: tr('tour_money_board.expenses'),
                    value: Formatters.formatMoneyInr(summary.totalExpenses),
                    color: c.ink2,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _TotalCol(
                    label: tr('tour_money_board.net'),
                    value: Formatters.formatMoneyInr(summary.totalNet),
                    color: c.ink,
                    c: c,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  tr('tour_money_board.outstanding_handover'),
                  style: UgamText.body.copyWith(color: c.ink2),
                ),
                Text(
                  Formatters.formatMoneyInr(outstanding),
                  style: UgamText.tabular(
                    UgamText.titleS.copyWith(
                      color: settled ? c.good : c.warm,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalCol extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final UgamColorSet c;

  const _TotalCol({
    required this.label,
    required this.value,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          value,
          style: UgamText.tabular(
              UgamText.numLg.copyWith(color: color, fontSize: 17)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
