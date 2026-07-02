import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import '../utils/formatters.dart';


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
                  );
                }
                final buses = tour.buses;
                if (buses.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.insights_outlined,
                    title: tr('tour_money_board.no_buses'),
                  );
                }

                // Touch the obs lists so Obx re-runs on any money change.
                final total = _money.tourSummary();
                final handlers = _money.handlerSummaries();
                final busSummaries = _money.summariesForBuses(
                  buses.map((b) => b.id),
                );
                final busById = {for (final b in buses) b.id: b};

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xxl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _TripTotalCard(total: total, c: c),
                    const SizedBox(height: UgamSpacing.xl),
                    if (handlers.isNotEmpty) ...[
                      _SectionLabel(tr('trip_pnl.by_handler'), c: c),
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
                            netBilled: h.netBilled,
                            netCollected: h.netCollected,
                            c: c,
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.lg),
                    ],
                    _SectionLabel(tr('trip_pnl.by_bus'), c: c),
                    const SizedBox(height: UgamSpacing.md),
                    for (final s in busSummaries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UgamSpacing.md),
                        child: _PnlCard(
                          title: busById[s.busId]?.name ?? '',
                          subtitle: tr(
                            'trip_pnl.rent',
                            namedArgs: {
                              'n': Formatters.formatMoneyInr(
                                busById[s.busId]?.busPrice ?? 0,
                              ),
                            },
                          ),
                          revenueBilled: s.revenueBilled,
                          collected: s.collected,
                          costs: s.expensesTotal,
                          income: s.income,
                          netBilled: s.netBilled,
                          netCollected: s.netCollected,
                          c: c,
                        ),
                      ),
                  ],
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
  final UgamColorSet c;
  const _TripTotalCard({required this.total, required this.c});

  @override
  Widget build(BuildContext context) {
    final billed = total.totalNetBilled;
    final tone = billed >= 0 ? c.good : c.danger;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.xl),
      tone: billed >= 0 ? UgamCardTone.none : UgamCardTone.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            billed >= 0 ? tr('trip_pnl.net_profit') : tr('trip_pnl.net_loss'),
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
          const SizedBox(height: UgamSpacing.lg),
          Container(height: 1, color: c.border),
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
  final double netBilled;
  final double netCollected;
  final UgamColorSet c;

  const _PnlCard({
    required this.title,
    required this.subtitle,
    required this.revenueBilled,
    required this.collected,
    required this.costs,
    required this.income,
    required this.netBilled,
    required this.netCollected,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final tone = netBilled >= 0 ? c.good : c.danger;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
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
          Container(height: 1, color: c.border),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  final UgamColorSet c;
  const _SectionLabel(this.text, {required this.c});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: UgamSpacing.xs),
        child: Text(
          text,
          style: UgamText.titleM.copyWith(color: c.ink, fontSize: 16),
        ),
      );
}
