import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import 'bus_money_screen.dart';

String _money(num v) {
  final neg = v < 0;
  final abs = v.abs().toStringAsFixed(0);
  return neg ? '-₹$abs' : '₹$abs';
}

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

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              title: _tours.getTour(widget.tourId)?.title ?? '',
              c: c,
            ),
            Expanded(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  return Center(
                    child: Text(
                      'Tour not found.',
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  );
                }

                final buses = tour.buses;
                // Touch the money obs lists so Obx re-renders on any change.
                final summaries =
                    _money.summariesForBuses(buses.map((b) => b.id));

                if (buses.isEmpty) {
                  return _Empty(c: c);
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
                      'PER BUS',
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

// ─── Header (matches tour_overview_screen idiom) ────────────────────────────

class _Header extends StatelessWidget {
  final String title;
  final UgamColorSet c;

  const _Header({required this.title, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'MONEY BOARD',
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const SizedBox(height: 2),
                Text(
                  title.isEmpty ? 'Tour money' : title,
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
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
  final UgamColorSet c;

  const _BusMoneyRow({
    required this.bus,
    required this.summary,
    required this.state,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // warm = needs action (outstanding handover / shortfall) — attention only.
    // good = settled. neutral = nothing has moved yet → no ring.
    final (Color? ring, UgamStatusTone tone, String statusLabel) =
        switch (state) {
      BusMoneyState.actionNeeded => (
          c.warm,
          UgamStatusTone.warm,
          summary.outstandingHandover > 0.005
              ? 'Handover ${_money(summary.outstandingHandover)} due'
              : 'To collect ${_money(summary.toCollectTotal)}',
        ),
      BusMoneyState.settled => (c.good, UgamStatusTone.good, 'Settled'),
      BusMoneyState.neutral => (null, UgamStatusTone.neutral, 'No activity'),
    };

    return Container(
      decoration: ring == null
          ? null
          : BoxDecoration(
              borderRadius: BorderRadius.circular(UgamRadius.card),
              border: Border.all(color: ring.withValues(alpha: 0.55)),
            ),
      child: UgamCard.plain(
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
                    borderRadius: BorderRadius.circular(12),
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
                      const SizedBox(height: 2),
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
                    label: 'COLLECTED',
                    value: _money(summary.collected),
                    valueColor: c.ink,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'HANDOVER',
                    value: _money(summary.handedOver),
                    valueColor: c.ink,
                    c: c,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm + 2),
            // ── Secondary money triplet ────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: 'TO COLLECT',
                    value: _money(summary.toCollectTotal),
                    valueColor:
                        summary.toCollectTotal > 0.005 ? c.danger : c.ink2,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'TO RETURN',
                    value: _money(summary.toReturnTotal),
                    valueColor:
                        summary.toReturnTotal > 0.005 ? c.warm : c.ink2,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: 'EXPENSES',
                    value: _money(summary.expensesTotal),
                    valueColor: c.ink2,
                    c: c,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.md),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.sm + 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                UgamStatusDot(label: statusLabel, tone: tone),
                Text(
                  'Outstanding ${_money(summary.outstandingHandover)}',
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
          ],
        ),
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
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: valueColor)),
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
                  'TOUR TOTALS',
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                UgamStatusDot(
                  label: settled ? 'All settled' : 'Open',
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
                    label: 'COLLECTED',
                    value: _money(summary.totalCollected),
                    color: c.ink,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _TotalCol(
                    label: 'EXPENSES',
                    value: _money(summary.totalExpenses),
                    color: c.ink2,
                    c: c,
                  ),
                ),
                Expanded(
                  child: _TotalCol(
                    label: 'NET',
                    value: _money(summary.totalNet),
                    color: c.ink,
                    c: c,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm + 2),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.sm + 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Outstanding handover',
                  style: UgamText.body.copyWith(color: c.ink2),
                ),
                Text(
                  _money(outstanding),
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
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.tabular(UgamText.numLg.copyWith(color: color, fontSize: 17)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ─── Empty state ────────────────────────────────────────────────────────────

class _Empty extends StatelessWidget {
  final UgamColorSet c;

  const _Empty({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                size: 40, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              'No buses on this tour yet.',
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
