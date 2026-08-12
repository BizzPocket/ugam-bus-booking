import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/pnl_confidence.dart';
import '../models/tour.dart';
import '../utils/app_nav.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
import 'add_bus_screen.dart';
import 'bus_money_screen.dart';

/// Per-trip Profit & Loss — the breakdown the agent lands on when they open a
/// trip's money and want "did this trip make money, and where".
///
/// Shows, for ONE tour:
///   * a trip total with BOTH nets — *billed* (true profit: fares owed −
///     rent − expenses) and *collected* (cash so far − rent − expenses);
///   * a per-HANDLER breakdown (a handler runs whole buses, so their P&L is
///     the sum of their buses');
///   * a per-BUS breakdown.
///
/// Read-only: every figure comes from [MoneyController]'s pure aggregation
/// helpers. Bus rent (`Bus.busPrice`) is already folded into each bus's
/// expenses, so it never has to be added here.
class TripPnlScreen extends StatefulWidget {
  final String tourId;
  const TripPnlScreen({super.key, required this.tourId});

  @override
  State<TripPnlScreen> createState() => _TripPnlScreenState();
}

class _TripPnlScreenState extends State<TripPnlScreen> {
  MoneyController get _money => Get.find<MoneyController>();
  TourController get _tours => Get.find<TourController>();

  /// True only when the money load failed AND nothing is already held — so a
  /// transient read failure shows a retry instead of an all-zero P&L. Reads the
  /// money obs inside the calling [Obx] to stay reactive across a retry.
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

  String _handlerName(Tour tour, String? id) {
    if (id == null) return tr('trip_pnl.no_handler');
    final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
    final n = p?.name.trim() ?? '';
    return n.isEmpty ? tr('trip_pnl.no_handler') : n;
  }

  String _busCount(int n) => n == 1
      ? tr('trip_pnl.bus_one')
      : tr('trip_pnl.bus_many', namedArgs: {'n': '$n'});

  /// Drill from "this bus lost money" into that bus's ledger — the same
  /// destination, entry style and transition the board one screen back uses
  /// (tour_money_board_screen.dart:61-66).
  void _openBus(Tour tour, Bus bus) {
    Get.to(
      () => BusMoneyScreen(tour: tour, bus: bus),
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
                eyebrow: tr('trip_pnl.eyebrow'),
                title: title.isEmpty ? tr('trip_pnl.title') : title,
                subtitle: tr('trip_pnl.title'),
              );
            }),
            Expanded(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  return UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: tr('tour_money_board.tour_not_found'),
                    // A dead end otherwise: the P&L of a tour that no longer
                    // exists offered nothing but the OS back gesture.
                    cta: UgamCTA(
                      label: tr('app.action.back'),
                      leadingIcon: Icons.arrow_back_rounded,
                      onPressed: () => AppNav.pop(context),
                    ),
                  );
                }
                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }

                final buses = tour.buses;
                if (buses.isEmpty) {
                  // "No buses YET" — a setup gap, not a zero P&L, so it gets
                  // the action that closes it rather than leaving the agent to
                  // back out twice to find the bus wizard. (A tour that HAS
                  // buses and simply hasn't earned anything falls through to
                  // the real breakdown below, which prints honest zeroes.)
                  return UgamEmpty(
                    icon: Icons.directions_bus_outlined,
                    title: tr('tour_money_board.no_buses'),
                    cta: UgamCTA(
                      label: tr('add_bus.title'),
                      leadingIcon: Icons.add_rounded,
                      onPressed: () => Get.to(
                        () => AddBusScreen(tourId: tour.id),
                        transition: Transition.cupertino,
                      ),
                    ),
                  );
                }

                // A failed money load leaves the obs lists empty; show the
                // shared retry instead of an all-zero (false break-even) P&L.
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => _money.loadForTour(widget.tourId),
                  );
                }

                // Touch the obs lists so Obx re-runs on any money change.
                final total = _money.tourSummary();
                final handlers = _money.handlerSummaries();
                final busSummaries = _money.summariesForBuses(
                  buses.map((b) => b.id),
                );
                final busById = {for (final b in buses) b.id: b};

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  // (Unset used to mean `colorScheme.primary`, i.e. the accent;
                  // there is no theme hook for a refresh spinner.)
                  color: c.ink2,
                  onRefresh: () => _money.refreshForTour(widget.tourId),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.sm,
                      UgamSpacing.gutter,
                      UgamSpacing.xxl,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      _TripTotalCard(
                        total: total,
                        confidence: PnlConfidence.of(total, tour.status),
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.xl),
                      if (handlers.isNotEmpty) ...[
                        UgamSectionLabel(tr('trip_pnl.by_handler')),
                        const SizedBox(height: UgamSpacing.md),
                        for (final h in handlers)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: UgamSpacing.md,
                            ),
                            child: _PnlCard(
                              title: _handlerName(tour, h.handlerPassengerId),
                              subtitle: _busCount(h.busIds.length),
                              revenueBilled: h.revenueBilled,
                              collected: h.collected,
                              costs: h.expensesTotal,
                              income: h.income,
                              detachedCash: h.detachedCash,
                              detachedCashKey: 'trip_pnl.detached_cash_handler',
                              netBilled: h.netBilled,
                              netCollected: h.netCollected,
                              c: c,
                            ),
                          ),
                        const SizedBox(height: UgamSpacing.lg),
                      ],
                      UgamSectionLabel(tr('trip_pnl.by_bus')),
                      const SizedBox(height: UgamSpacing.md),
                      for (final s in busSummaries)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.md,
                          ),
                          child: _PnlCard(
                            // Null only if the summary outlives its bus; the
                            // card then stays inert rather than pushing a
                            // screen with no bus to render.
                            onTap: busById[s.busId] == null
                                ? null
                                : () => _openBus(tour, busById[s.busId]!),
                            title: busById[s.busId]?.name ?? '',
                            // "Rent ₹0" is the exact ambiguity that lets a
                            // missing cost pass for a free bus, so an unentered
                            // rent says so in words instead of printing a zero.
                            subtitle: (busById[s.busId]?.busPrice ?? 0) <= 0
                                ? tr('trip_pnl.rent_not_set')
                                : tr(
                                    'trip_pnl.rent',
                                    namedArgs: {
                                      'n': Formatters.formatMoneyInr(
                                        busById[s.busId]!.busPrice,
                                      ),
                                    },
                                  ),
                            revenueBilled: s.revenueBilled,
                            collected: s.collected,
                            costs: s.expensesTotal,
                            income: s.income,
                            detachedCash: s.detachedCash,
                            detachedCashKey: 'trip_pnl.detached_cash_bus',
                            netBilled: s.netBilled,
                            netCollected: s.netCollected,
                            c: c,
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trip-wide hero: the headline net (billed) with the cash net beneath, then a
/// revenue / costs / collected stat triple.
class _TripTotalCard extends StatelessWidget {
  final TourMoneySummary total;
  final PnlConfidence confidence;
  final UgamColorSet c;
  const _TripTotalCard({
    required this.total,
    required this.confidence,
    required this.c,
  });

  /// Headline label. A projected net is named as a projection so the number is
  /// never read as money the trip has already made; a loss keeps its own
  /// wording either way.
  String get _headline {
    if (total.totalNetBilled >= 0) {
      return confidence.isProjected
          ? tr('trip_pnl.net_projected')
          : tr('trip_pnl.net_profit');
    }
    return confidence.isProjected
        ? tr('trip_pnl.net_projected_loss')
        : tr('trip_pnl.net_loss');
  }

  @override
  Widget build(BuildContext context) {
    final billed = total.totalNetBilled;
    // A provisional positive net is painted neutral rather than "good": green
    // is the app's signal for a settled, trustworthy result, and this figure is
    // either a forecast or missing a cost. A negative net stays red — a loss
    // that might be understated still deserves the alarm.
    final tone = billed < 0
        ? c.danger
        : (confidence.isProvisional ? c.ink : c.good);
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.xl),
      tone: billed >= 0 ? UgamCardTone.none : UgamCardTone.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _headline,
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              Formatters.formatMoneyInr(billed.abs()),
              maxLines: 1,
              style: UgamText.hero.copyWith(color: tone, fontSize: 44),
            ),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('trip_pnl.true_billed'),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
          // This hero is BILLED; the Finance report's headline is CASH. Both are
          // right and they will not match. Naming the basis is what stops the
          // two screens looking like they contradict each other.
          const SizedBox(height: 2),
          Text(
            tr('money.basis_billed'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          // A projection is not a fault — it is the same class of thing as the
          // basis line above, so it is set the same way. Only the rent gap
          // below earns a container; giving both one would leave the hero with
          // two competing alarms and no hierarchy between them.
          if (confidence.isProjected) ...[
            const SizedBox(height: 2),
            Text(
              tr('trip_pnl.projected_note'),
              style: UgamText.micro.copyWith(color: c.ink3, height: 1.35),
            ),
          ],
          // A missing rent, by contrast, is a data gap the agent can close, and
          // it names the direction of the error ("overstated") rather than just
          // reporting that something is absent. This is the hero's one point of
          // emphasis — and it is [UgamCaveat]'s WARM tone, not the amber
          // accent: this screen deliberately spends no accent at all, because
          // nothing on a P&L is "yours" in the sense the accent means.
          if (confidence.costsIncomplete) ...[
            const SizedBox(height: UgamSpacing.md),
            UgamCaveat(
              message: total.busesMissingRent == 1
                  ? tr('trip_pnl.rent_missing_one')
                  : tr(
                      'trip_pnl.rent_missing_many',
                      namedArgs: {'n': '${total.busesMissingRent}'},
                    ),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          _NetLine(
            label: tr('trip_pnl.cash_collected'),
            value: total.totalNet,
            c: c,
          ),
          if (total.totalIncome != 0) ...[
            const SizedBox(height: UgamSpacing.sm),
            _NetLine(
              label: tr('bus_money.stat_income'),
              value: total.totalIncome,
              c: c,
            ),
          ],
          if (total.totalDetachedCash.abs() > 0.005) ...[
            const SizedBox(height: UgamSpacing.md),
            _DetachedCashNote(
              amount: total.totalDetachedCash,
              // Trip level, so the wording is "not on this trip": a rider merely
              // moved between two buses is NOT counted here (see
              // TourMoneySummary.totalDetachedCash).
              message: tr(
                'trip_pnl.detached_cash_trip',
                namedArgs: {
                  'n': Formatters.formatMoneyInr(total.totalDetachedCash),
                },
              ),
              c: c,
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),
          Divider(height: 1, thickness: 1, color: c.border),
          const SizedBox(height: UgamSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.revenue'),
                  value: Formatters.formatMoneyInr(total.totalRevenueBilled),
                  tone: c.ink,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.costs'),
                  value: Formatters.formatMoneyInr(total.totalExpenses),
                  tone: c.warm,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.collected'),
                  value: Formatters.formatMoneyInr(total.totalCollected),
                  tone: c.ink,
                  c: c,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One P&L card for a handler or a bus: title + subtitle, the two nets (billed
/// and collected), and a revenue/costs line.
class _PnlCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final double revenueBilled;
  final double collected;
  final double costs;
  final double income;

  /// Cash inside [collected] paid by riders who no longer sit here (see
  /// [BusMoneySummary.detachedCash]). Rendered as its own explanatory line
  /// whenever it's non-zero — it is the ONLY reason cash-net can exceed what
  /// this bus/handler billed, and without it that gap reads as a wrong number.
  final double detachedCash;

  /// Translation key for [detachedCash]'s wording. A bus card says "no longer
  /// on this bus", a handler card "no longer on their buses" — same figure,
  /// different scope (see [MoneyController.handlerSummaries]).
  final String detachedCashKey;

  final double netBilled;
  final double netCollected;
  final UgamColorSet c;

  /// Set only on the per-BUS cards, which drill into that bus's ledger. The
  /// per-handler cards leave this null — there is no per-handler destination,
  /// and a card that looks tappable but isn't is the defect this closes.
  final VoidCallback? onTap;

  const _PnlCard({
    required this.title,
    required this.subtitle,
    required this.revenueBilled,
    required this.collected,
    required this.costs,
    required this.income,
    required this.detachedCash,
    required this.detachedCashKey,
    required this.netBilled,
    required this.netCollected,
    required this.c,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tone = netBilled >= 0 ? c.good : c.danger;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.titleM.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Formatters.formatMoneyInr(netBilled.abs()),
                    style: UgamText.numLg.copyWith(color: tone),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    netBilled >= 0
                        ? tr('trip_pnl.profit')
                        : tr('trip_pnl.loss'),
                    style: UgamText.micro.copyWith(color: tone),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Divider(height: 1, thickness: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.revenue'),
                  value: Formatters.formatMoneyInr(revenueBilled),
                  tone: c.ink2,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.costs'),
                  value: Formatters.formatMoneyInr(costs),
                  tone: c.warm,
                  c: c,
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: tr('trip_pnl.cash_net'),
                  value: Formatters.formatMoneyInr(netCollected),
                  tone: netCollected >= 0 ? c.ink2 : c.danger,
                  c: c,
                ),
              ),
            ],
          ),
          if (income != 0) ...[
            const SizedBox(height: UgamSpacing.md),
            _NetLine(label: tr('bus_money.stat_income'), value: income, c: c),
          ],
          if (detachedCash.abs() > 0.005) ...[
            const SizedBox(height: UgamSpacing.md),
            _DetachedCashNote(
              amount: detachedCash,
              message: tr(
                detachedCashKey,
                namedArgs: {'n': Formatters.formatMoneyInr(detachedCash)},
              ),
              c: c,
            ),
          ],
        ],
      ),
    );
  }
}

/// The quiet footnote that explains a cash figure larger than the revenue above
/// it: "₹5,700 of this is from riders who are no longer on this bus".
///
/// Deliberately a note, not a stat — the amount is already counted inside the
/// cash figures and changes no net, so promoting it to its own tile would read
/// as another number to reconcile. It only exists so the gap is never a mystery.
class _DetachedCashNote extends StatelessWidget {
  final double amount;
  final String message;
  final UgamColorSet c;

  const _DetachedCashNote({
    required this.amount,
    required this.message,
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
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: UgamText.micro.copyWith(color: c.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

class _NetLine extends StatelessWidget {
  final String label;
  final double value;
  final UgamColorSet c;
  const _NetLine({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    final tone = value >= 0 ? c.good : c.danger;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            label,
            style: UgamText.body.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Text(
          Formatters.formatMoneyInr(value),
          style: UgamText.numLg.copyWith(color: tone, fontSize: 17),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color tone;
  final UgamColorSet c;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.tone,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: UgamText.numLg.copyWith(color: tone, fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          label,
          style: UgamText.micro.copyWith(color: c.ink3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
