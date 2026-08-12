// The "in hand" money hero and its breakdown.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../design/ugam.dart';
import '../../models/collection.dart';
import '../../utils/formatters.dart';

class HandlerMoneyHero extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;
  final double spent;
  final double income;
  final double inHand;

  /// Cash already handed to the admin, and what is still outstanding.
  final double handedOver;
  final double outstanding;
  final bool settled;

  const HandlerMoneyHero({
    super.key,
    required this.collected,
    required this.toReturn,
    required this.toCollect,
    required this.spent,
    required this.income,
    required this.inHand,
    this.handedOver = 0,
    required this.outstanding,
    this.settled = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasHandover = handedOver.abs() > Collection.kMoneyEpsilon;

    // ONE money hero. The headline is what the handler STILL has to hand over,
    // not the gross take: once they settle on the roadside the number they are
    // looking at must actually go down. With no handover recorded the two are
    // identical, so this changes nothing until settlement is used.
    return UgamHeroStat(
      label: settled
          ? tr('handler_chart.stat_settled')
          : tr('handler_chart.stat_in_hand'),
      value: Formatters.formatMoneyInr(settled ? handedOver : outstanding),
      secondary: hasHandover
          ? tr(
              'handler_chart.handed_secondary',
              namedArgs: {
                'handed': Formatters.formatMoneyInr(handedOver),
                'total': Formatters.formatMoneyInr(inHand),
              },
            )
          : tr(
              'handler_chart.in_hand_secondary',
              namedArgs: {'amount': Formatters.formatMoneyInr(collected)},
            ),
      breakdown: [
        HeroStatLine(
          tr('handler_chart.stat_collected'),
          Formatters.formatMoneyInr(collected),
          tone: c.good,
        ),
        HeroStatLine(
          tr('handler_chart.stat_to_collect'),
          Formatters.formatMoneyInr(toCollect),
          tone: c.accent,
        ),
        HeroStatLine(
          tr('handler_chart.stat_to_return'),
          Formatters.formatMoneyInr(toReturn),
          tone: c.warm,
        ),
        HeroStatLine(
          tr('handler_chart.stat_income'),
          Formatters.formatMoneyInr(income),
          tone: c.good,
        ),
        HeroStatLine(
          tr('handler_chart.stat_spent'),
          Formatters.formatMoneyInr(spent),
          tone: c.warm,
        ),
        // Closes the arithmetic: collected + income − spent = what goes to the
        // admin. The bus owner's rent is deliberately absent — that is the
        // admin's cost, settled out of this handover, never the handler's.
        HeroStatLine(
          tr('handler_chart.stat_to_admin'),
          Formatters.formatMoneyInr(inHand),
          tone: c.ink,
        ),
        // Only once cash has actually moved — an always-on ₹0 "handed over"
        // line would be noise on the majority of buses that never settle
        // partially.
        if (hasHandover) ...[
          HeroStatLine(
            tr('handler_chart.stat_handed_over'),
            Formatters.formatMoneyInr(handedOver),
            tone: c.good,
          ),
          HeroStatLine(
            tr('handler_chart.stat_outstanding'),
            Formatters.formatMoneyInr(outstanding),
            tone: settled ? c.good : c.accent,
          ),
        ],
      ],
    );
  }
}
