part of '../trip_pnl_screen.dart';

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
  String get _headline =>
      switch ((total.totalNetBilled >= 0, confidence.isProjected)) {
        (true, true) => tr('trip_pnl.net_projected'),
        (true, false) => tr('trip_pnl.net_profit'),
        (false, true) => tr('trip_pnl.net_projected_loss'),
        (false, false) => tr('trip_pnl.net_loss'),
      };

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
          Text(_headline, style: UgamText.micro.copyWith(color: c.ink3)),
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
            child: Text(message, style: UgamText.micro.copyWith(color: c.ink2)),
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
