part of '../finance_screen.dart';

// ── Hero net card ────────────────────────────────────────────────────────────

class _HeroCard extends StatelessWidget {
  final FinanceTotals totals;
  final _ReportState state;
  final UgamColorSet c;
  const _HeroCard({required this.totals, required this.state, required this.c});

  @override
  Widget build(BuildContext context) {
    // "Has a real answer" — the only three states where a rupee figure is an
    // honest thing to print. Everything below branches on this.
    final hasFigures = state.hasFigures;

    final label = switch (state) {
      _ReportState.profit => tr('finance.net_profit'),
      _ReportState.loss => tr('finance.net_loss'),
      _ReportState.breakEven => tr('finance.flat'),
      _ => tr('finance.net_pending'),
    };

    // A dash, not ₹0. Break-even keeps ink (a real zero); profit/loss keep
    // their semantic colour.
    // Headline = Σ of the rows' trip profit (billed basis), the same figure
    // each trip's own P&L headlines; "cash so far" rides beneath it.
    final value = hasFigures ? _signedInr(totals.tripProfit) : _noFigure;
    final netColor = switch (state) {
      _ReportState.profit => c.good,
      _ReportState.loss => c.danger,
      _ReportState.breakEven => c.ink,
      _ => c.ink3,
    };

    // The badge used to paint a green "from 0 tours" over ₹0 — a confident
    // success signal attached to nothing. Neutral for every non-answer.
    final (Color chipBg, Color chipFg, IconData chipIcon) = switch (state) {
      _ReportState.profit => (c.goodFill, c.good, Icons.trending_up_rounded),
      _ReportState.loss => (
        c.dangerFill,
        c.danger,
        Icons.trending_down_rounded,
      ),
      _ReportState.breakEven => (
        c.cardElev,
        c.ink2,
        Icons.trending_flat_rounded,
      ),
      _ReportState.noMoney => (
        c.cardElev,
        c.ink2,
        Icons.hourglass_empty_rounded,
      ),
      _ => (c.cardElev, c.ink3, Icons.event_busy_rounded),
    };
    final chipText = switch (totals.tourCount) {
      0 => tr('finance.chip_no_trips'),
      1 => tr('finance.from_tours_one', namedArgs: {'n': '1'}),
      final n => tr('finance.from_tours_other', namedArgs: {'n': '$n'}),
    };

    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 3:2 split rather than `spaceBetween`: in Gujarati the label
          // ("હજી કોઈ આંકડો નથી") and the badge ("કોઈ પ્રવાસ નથી") are BOTH
          // long, and two intrinsically-sized children on one line is exactly
          // how that row used to overflow.
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  label,
                  style: UgamText.micro.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Flexible(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.sm,
                      vertical: UgamSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(chipIcon, size: 13, color: chipFg),
                        const SizedBox(width: UgamSpacing.xs),
                        Flexible(
                          child: Text(
                            chipText,
                            style: UgamText.micro.copyWith(color: chipFg),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            value,
            style: UgamText.tabular(UgamText.numXl.copyWith(color: netColor)),
          ),
          if (hasFigures) ...[
            const SizedBox(height: 2),
            CashSoFarLine(value: totals.cashSoFar, format: _signedInr),
          ],
          // Everything below the headline is an ANSWER about money that moved.
          // With no figures there is no proportion to draw, no legend to read
          // and no accounting basis to disclaim — an empty grey bar over three
          // ₹0 columns is four separate pieces of furniture communicating
          // nothing. The zero-state card below carries the meaning instead.
          if (hasFigures) ...[
            const SizedBox(height: UgamSpacing.md),
            _MarginBar(
              revenue: totals.billed + totals.income,
              expenses: totals.expenses,
              c: c,
            ),
            const SizedBox(height: UgamSpacing.md),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            Row(
              children: [
                Expanded(
                  // Billed revenue — the term the headline is built from, and
                  // what "Revenue" means on the Trip P&L. Cash received is the
                  // "cash so far" line above.
                  child: _HeroMetric(
                    label: tr('trip_pnl.revenue'),
                    value: _inr(totals.billed),
                    color: c.ink,
                    dot: c.good,
                    c: c,
                  ),
                ),
                if (totals.income != 0)
                  Expanded(
                    child: _HeroMetric(
                      label: tr('bus_money.stat_income'),
                      value: _inr(totals.income),
                      color: c.ink,
                      dot: c.accent,
                      c: c,
                    ),
                  ),
                Expanded(
                  child: _HeroMetric(
                    label: tr('finance.expenses'),
                    value: _inr(totals.expenses),
                    color: c.ink2,
                    dot: c.warm,
                    c: c,
                  ),
                ),
              ],
            ),
            // The headline is BILLED basis, like every trip's own P&L (it used
            // to be cash here and billed there, under the same word "profit").
            // Naming the basis costs one line.
            const SizedBox(height: UgamSpacing.sm),
            Text(
              tr('money.basis_billed'),
              style: UgamText.micro.copyWith(color: c.ink3),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color dot;
  final UgamColorSet c;
  const _HeroMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.dot,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // 6pt dot + `sm` gap — the same geometry [UgamStatusDot] ships, so
            // the hero legend matches every other dot+label pair in the app.
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: UgamText.micro.copyWith(color: c.ink3),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          value,
          style: UgamText.tabular(UgamText.numLg.copyWith(color: color)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Slim proportion bar: warm = the slice of revenue eaten by expenses, good =
/// the profit slice. A loss paints the whole bar danger.
///
/// It draws a PROPORTION, so with nothing to divide it has nothing to say — the
/// old empty grey capsule under a ₹0 was pure furniture, and worse, it looked
/// like a progress bar stuck at 0%, implying the report was still loading. It
/// now renders nothing at all; the caller only mounts it when money moved.
class _MarginBar extends StatelessWidget {
  final double revenue;
  final double expenses;
  final UgamColorSet c;
  const _MarginBar({
    required this.revenue,
    required this.expenses,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    if (revenue <= 0 && expenses <= 0) return const SizedBox.shrink();

    final net = revenue - expenses;
    Widget bar;
    if (net < 0) {
      bar = Container(color: c.danger);
    } else {
      final expFrac = revenue <= 0 ? 1.0 : (expenses / revenue).clamp(0.0, 1.0);
      final expFlex = (expFrac * 1000).round();
      final profFlex = ((1 - expFrac) * 1000).round();
      bar = Row(
        children: [
          if (expFlex > 0)
            Expanded(
              flex: expFlex,
              child: Container(color: c.warm),
            ),
          if (profFlex > 0)
            Expanded(
              flex: profFlex,
              child: Container(color: c.good),
            ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: SizedBox(height: 10, child: bar),
    );
  }
}

// ── Stat triple ──────────────────────────────────────────────────────────────

/// Trips / average / best. Each tile is a [UgamStatTile], which is a
/// [UgamCard] — so all three sit at `UgamElevation.rest` while the hero above
/// them sits on the `cardElev` fill, and the two rows read as two surfaces
/// rather than one flat block. Values come from [UgamText.numLg], which carries
/// `FontFeature.tabularFigures` already.
class _StatTriple extends StatelessWidget {
  final FinanceTotals totals;
  const _StatTriple({required this.totals});

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label, String value})>[
      (
        icon: Icons.event_rounded,
        label: tr('finance.stat_tours'),
        value: '${totals.tourCount}',
      ),
      (
        icon: Icons.bar_chart_rounded,
        label: tr('finance.stat_avg'),
        value: totals.tourCount == 0
            ? _noFigure
            : _compactSigned(totals.avgTripProfit),
      ),
      (
        icon: Icons.workspace_premium_rounded,
        label: tr('finance.stat_best'),
        value: totals.best == null
            ? _noFigure
            : _compactSigned(totals.best!.tripProfit),
      ),
    ];

    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          Expanded(
            child: UgamStatTile(
              icon: items[i].icon,
              value: items[i].value,
              label: items[i].label,
              variant: UgamStatVariant.neutral,
            ),
          ),
          if (i < items.length - 1) const SizedBox(width: UgamSpacing.sm),
        ],
      ],
    );
  }
}
