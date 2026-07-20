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

  /// True only when the money load failed AND there is nothing already held to
  /// keep on screen — so a transient read failure shows a retry instead of an
  /// all-zero board. Reads the money obs inside the calling [Obx], so it stays
  /// reactive: a successful retry flips [MoneyController.loadFailed] and refills
  /// the lists, re-running the builder.
  bool get _showLoadError =>
      _money.loadFailed.value &&
      _money.collections.isEmpty &&
      _money.expenses.isEmpty &&
      _money.handovers.isEmpty &&
      _money.incomes.isEmpty;

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

                // A failed money load leaves the obs lists empty; without this
                // the board would render every bus at ₹0 as if the trip had no
                // money. Swap in the shared retry only when nothing is held.
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => _money.loadForTour(widget.tourId),
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
                    const SizedBox(height: UgamSpacing.md),
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
              // Hide the totals strip while the retry state is showing — an
              // all-zero capsule under a load-error message would contradict it.
              if (tour == null || tour.buses.isEmpty || _showLoadError) {
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
    // A bus that still owes money leads with its ONE action figure — the
    // handover still due, else the passenger shortfall to collect. A settled
    // bus shows what it collected in mint; a bus with nothing owed and nothing
    // collected reads as a quiet "no activity". The card tone carries the same
    // attention signal the old ring did; a status WORD is added only where it
    // says something the tinted figure doesn't (settled / not-started).
    final hasHandoverDue = summary.outstandingHandover > 0.005;
    final (
      UgamCardTone cardTone,
      String numLabel,
      double numAmount,
      Color numColor,
      String? statusWord,
      UgamStatusTone statusTone,
    ) = switch (state) {
      BusMoneyState.actionNeeded => (
        // Tone tracks the figure: a collect shortfall is red, a handover due
        // is rose — so the card's tint says WHICH action at a glance (§A2/§A4).
        hasHandoverDue ? UgamCardTone.warm : UgamCardTone.danger,
        hasHandoverDue
            ? tr('tour_money_board.handover')
            : tr('tour_money_board.to_collect'),
        hasHandoverDue ? summary.outstandingHandover : summary.toCollectTotal,
        hasHandoverDue ? c.warm : c.danger,
        null,
        UgamStatusTone.warm,
      ),
      BusMoneyState.settled => (
        UgamCardTone.good,
        tr('tour_money_board.collected'),
        summary.collected,
        c.good,
        tr('tour_money_board.settled'),
        UgamStatusTone.good,
      ),
      BusMoneyState.neutral => (
        UgamCardTone.none,
        tr('tour_money_board.to_collect'),
        summary.toCollectTotal,
        c.ink2,
        tr('tour_money_board.no_activity'),
        UgamStatusTone.neutral,
      ),
    };

    // Collected / handover only carry information once cash has changed hands —
    // until then they are ₹0 filler, so the strip is hidden and the card
    // collapses to identity + action figure + collect.
    final hasMoved = summary.collected > 0.005 ||
        summary.handedOver > 0.005 ||
        summary.income > 0.005;

    return UgamCard.plain(
      key: ValueKey('bus-money-row-${bus.id}'),
      tone: cardTone,
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Identity + the ONE action figure, on a single line ─────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.seat),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.directions_bus_filled_rounded,
                  size: 17,
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
                    const SizedBox(height: 1),
                    // Type + a compact status word (settled / not-started);
                    // action-needed shows none — its tinted figure says it.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            bus.busType,
                            style: UgamText.caption.copyWith(color: c.ink3),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (statusWord != null) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          UgamStatusDot(label: statusWord, tone: statusTone),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // The action figure rides on the identity line — right-aligned,
              // tabular, tinted by state — so the row answers "how much?" in
              // one glance without a second full-width headline block. Skipped
              // when settled: the mint "Settled" dot + the collected/handover
              // pills below already tell that story, so a figure here would
              // just duplicate a pill.
              if (state != BusMoneyState.settled) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      numLabel.toUpperCase(),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      Formatters.formatMoneyInr(numAmount),
                      style: UgamText.tabular(
                        UgamText.numLg.copyWith(color: numColor),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                const SizedBox(width: UgamSpacing.xs),
              ],
              Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
            ],
          ),
          // Extra income the handler holds (cabin/gallery/other) — surfaced
          // compactly, and only when there is any.
          if (summary.income > 0.005) ...[
            const SizedBox(height: UgamSpacing.sm),
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
          // ── Collected + handover — only once money has moved ───────
          if (hasMoved) ...[
            const SizedBox(height: UgamSpacing.md),
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
          ],
          const SizedBox(height: UgamSpacing.md),
          // One-tap shortcut straight into this bus's CollectionScreen. The row
          // itself still opens the full per-bus detail view (to-collect,
          // to-return, expenses live there). Tonal so it never competes with the
          // single solid-champagne totals capsule below.
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
                      Flexible(
                        child: Text(
                          tr('tour_money_board.outstanding_handover')
                              .toUpperCase(),
                          style: UgamText.micro.copyWith(color: c.ink3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                  // Scale a long outstanding figure down to fit rather than
                  // ellipsize it — the thumb-zone capsule must never clip the
                  // very number it exists to show (e.g. "-₹1,81,000").
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      Formatters.formatMoneyInr(outstanding),
                      style: UgamText.tabular(
                        UgamText.numXl.copyWith(
                          color: settled ? c.good : c.warm,
                        ),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            // ── Two compact pills: collected + net ─────────────────
            Flexible(
              child: _CapsulePill(
                label: tr('tour_money_board.collected'),
                value: Formatters.formatMoneyInr(summary.totalCollected),
                c: c,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: _CapsulePill(
                label: tr('tour_money_board.net'),
                value: Formatters.formatMoneyInr(summary.totalNet),
                c: c,
              ),
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
