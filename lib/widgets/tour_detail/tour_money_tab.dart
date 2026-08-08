import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/money_controller.dart';
import '../../design/ugam.dart';
import '../../models/tour.dart';
import '../../screens/tour_money_board_screen.dart';
import '../../utils/formatters.dart';

/// Money tab summary — deep-links to [TourMoneyBoardScreen].
class TourMoneyTab extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;

  const TourMoneyTab({super.key, required this.tour, required this.c});

  @override
  State<TourMoneyTab> createState() => _TourMoneyTabState();
}

class _TourMoneyTabState extends State<TourMoneyTab> {
  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<MoneyController>()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Get.find<MoneyController>().loadForTour(widget.tour.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tour = widget.tour;

    if (!Get.isRegistered<MoneyController>()) {
      return SliverToBoxAdapter(
        child: UgamEmpty(
          icon: Icons.account_balance_wallet_outlined,
          title: tr('tour_detail.money_empty_title'),
          body: tr('tour_detail.money_empty_body'),
        ),
      );
    }

    return Obx(() {
      final money = Get.find<MoneyController>();
      // Touch obs so Obx rebuilds when load finishes.
      final _ = money.collections.length + money.expenses.length;
      final summary = money.tourSummary();

      return SliverList(
        delegate: SliverChildListDelegate.fixed([
          UgamCard.plain(
            elev: true,
            padding: const EdgeInsets.all(UgamSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('tour_detail.money_expected'),
                    style: UgamText.caption.copyWith(color: c.ink2)),
                const SizedBox(height: 4),
                Text(
                  Formatters.formatMoneyInr(summary.totalRevenueBilled),
                  style: UgamText.tabular(
                    UgamText.titleL.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: UgamSpacing.md),
                Row(
                  children: [
                    _MoneyStat(
                      c: c,
                      label: tr('tour_detail.money_collected'),
                      value: Formatters.formatMoneyInr(summary.totalCollected),
                      color: c.good,
                    ),
                    _MoneyStat(
                      c: c,
                      label: tr('tour_detail.money_due'),
                      value: Formatters.formatMoneyInr(summary.totalToCollect),
                      color: c.accent,
                    ),
                    _MoneyStat(
                      c: c,
                      label: tr('tour_detail.money_claims'),
                      value: '${money.pendingClaims.length}',
                      color: c.ink2,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          for (final bus in tour.buses) ...[
            Builder(builder: (context) {
              final busSummary = money.summaryForBus(bus.id);
              return Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: UgamCard.plain(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(bus.displayLabel,
                                style:
                                    UgamText.titleS.copyWith(color: c.ink)),
                            Text(
                              tr('tour_detail.vitals_riders_other', namedArgs: {
                                'n': '${tour.occupiedBerthsFor(bus.id)}',
                              }),
                              style:
                                  UgamText.caption.copyWith(color: c.ink2),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            Formatters.formatMoneyInr(
                                busSummary.toCollectTotal),
                            style: UgamText.tabular(
                              UgamText.bodyStrong.copyWith(color: c.ink),
                            ),
                          ),
                          Text(
                            tr('tour_detail.money_due'),
                            style:
                                UgamText.micro.copyWith(color: c.ink3),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
          const SizedBox(height: UgamSpacing.md),
          UgamCTA(
            label: tr('tour_detail.money_open_board'),
            leadingIcon: Icons.account_balance_wallet_rounded,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TourMoneyBoardScreen(tourId: tour.id),
              ),
            ),
          ),
        ]),
      );
    });
  }
}

class _MoneyStat extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final String value;
  final Color color;

  const _MoneyStat({
    required this.c,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: color)),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}
