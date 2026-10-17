part of '../bus_money_screen.dart';

/// The screen's single focal figure: the outstanding handover this bus still
/// owes the admin, shown as a large tabular number. Expected handover sits
/// beneath it as quiet context. Carries the view's one champagne signal when
/// money is still owed; settles to a calm `good` tone at zero.
class _OutstandingHero extends StatelessWidget {
  final double amount;
  final double expected;

  const _OutstandingHero({required this.amount, required this.expected});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Within-rupee residual reads as fully handed over: once dues are whole
    // rupees a handover of expected.round() may leave a sub-rupee remainder
    // that should still settle the tile to a calm `good` tone.
    final settled = amount.abs() < 0.5;
    final figureColor = settled ? c.good : c.accent;
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('bus_money.stat_outstanding').toUpperCase(),
            style: UgamText.micro.copyWith(
              color: c.ink3,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          // The screen's single focal figure — a big Sora number set over a
          // soft copper halo. Sized for the cockpit, not a showroom (§A5).
          SizedBox(
            // The band and its halo are decorative, so both ride
            // [UgamScale.px] and follow the figure's own text scaling — left
            // fixed, the number visibly floated inside an over-tall glow on a
            // small phone. `fontSize: 38` stays: text already scales at the
            // app root, which is exactly why the boxes must follow it.
            height: UgamScale.px(context, 72),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: UgamScale.px(context, 150),
                  height: UgamScale.px(context, 150),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [c.glow, c.glow.withValues(alpha: 0)],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg,
                  ),
                  // Scale the focal figure down (never ellipsize) so lakh/crore
                  // amounts stay fully legible — mirrors trip_pnl's
                  // _TripTotalCard.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Formatters.formatMoneyInr(amount),
                      style: UgamText.tabular(
                        UgamText.hero.copyWith(
                          color: figureColor,
                          fontSize: 38,
                        ),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          // Expected handover sits beneath as quiet context.
          Text(
            tr('bus_money.stat_expected_handover').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            Formatters.formatMoneyInr(expected),
            style: UgamText.tabular(UgamText.numLg.copyWith(color: c.ink2)),
          ),
        ],
      ),
    );
  }
}

/// One heading for every ledger section. The action is OPTIONAL so a section
/// without one (Extra income, which the admin only views) still routes through
/// this row instead of dropping to a bare `Text` at a different height.
class _SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            title,
            style: UgamText.titleM.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onAction != null && actionLabel != null) ...[
          const SizedBox(width: UgamSpacing.sm),
          // Section add/record action — TONAL quiet-primary, never solid gold.
          UgamButton(
            label: actionLabel!,
            icon: Icons.add_rounded,
            kind: UgamButtonKind.tonal,
            onPressed: onAction,
          ),
        ],
      ],
    );
  }
}

/// Explains cash on this bus that its own seated riders can't account for:
/// money taken from people who have since moved to another bus or been
/// unseated. Collections stay with the bus that physically took the cash, while
/// billed revenue is recomputed from who is seated now — so without this card a
/// bus can silently read "collected ₹14,250 against ₹8,550 of fares".
///
/// Purely informational: [amount] is already inside the collected/net figures
/// above and nothing here changes them. It names the payers because the agent's
/// next question is always "whose money is this, and do I owe it back?".
class _DetachedCashCard extends StatelessWidget {
  final double amount;
  final List<String> names;

  const _DetachedCashCard({required this.amount, required this.names});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      tone: UgamCardTone.warm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: c.warm),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('bus_money.detached_cash_title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                Formatters.formatMoneyInr(amount),
                style: UgamText.numLg.copyWith(color: c.warm, fontSize: 17),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('bus_money.detached_cash_body'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          if (names.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            Wrap(
              spacing: UgamSpacing.sm,
              runSpacing: UgamSpacing.xs,
              children: [
                for (final n in names)
                  UgamReqChip(label: n, variant: UgamChipVariant.neutral),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The auto bus-owner rent shown at the top of the expense ledger. It mirrors
/// [_ExpenseRow] styling but is derived from [Bus.busPrice] (the single source
/// of truth, already folded into expensesTotal) — so it is non-deletable and
/// not editable.
bool _rollupExpenseInMalikCard(Expense e, BusMoneySummary s) {
  if (!s.rentIncludesFuel) return false;
  return e.category.isFuel || e.category.isOwnerPayment;
}

/// Bus Malik settlement (A1): agreed bhadu minus diesel and advances paid on
/// the trip.
class _BusMalikSettlementCard extends StatelessWidget {
  final Bus bus;
  final BusMoneySummary summary;

  const _BusMalikSettlementCard({required this.bus, required this.summary});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final reg = bus.busNumber.trim();
    final title = reg.isEmpty
        ? tr('bus_money.malik_title')
        : tr('bus_money.malik_title_bus', namedArgs: {'bus': reg});

    Widget line(String label, double amount, {bool deduct = false}) {
      final text = deduct
          ? '-${Formatters.formatMoneyInr(amount)}'
          : Formatters.formatMoneyInr(amount);
      return Padding(
        padding: const EdgeInsets.only(bottom: UgamSpacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
            Text(
              text,
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: deduct ? c.warm : c.ink),
              ),
            ),
          ],
        ),
      );
    }

    return UgamCard.plain(
      radius: UgamRadius.card,
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.directions_bus_rounded, size: 18, color: c.accent),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          line(tr('bus_money.malik_bhadu'), summary.busRent),
          if (summary.rentIncludesFuel && summary.fuelTotal > 0)
            line(tr('bus_money.malik_diesel'), summary.fuelTotal, deduct: true),
          // Driver pay is inside a pakku rent (like diesel) — it only shrinks
          // what is still owed to the owner.
          if (summary.rentIncludesFuel && summary.driverTotal > 0)
            line(
              tr('bus_money.malik_driver'),
              summary.driverTotal,
              deduct: true,
            ),
          if (summary.ownerAdvanceTotal > 0)
            line(
              tr('bus_money.malik_advance'),
              summary.ownerAdvanceTotal,
              deduct: true,
            ),
          const Divider(height: UgamSpacing.lg),
          line(tr('bus_money.malik_remaining'), summary.busMalikPayable),
        ],
      ),
    );
  }
}

class _TourRollupCard extends StatelessWidget {
  final TourMoneySummary summary;

  const _TourRollupCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // The whole tour rollup collapses into ONE hero: NET is the big figure;
    // the six component lines hide behind the chevron (progressive disclosure).
    final net = summary.totalNet;
    final netTone = net < -0.005 ? c.warm : c.good;
    return UgamHeroStat(
      label: tr('bus_money.tour_totals'),
      value: Formatters.formatMoneyInr(net),
      tone: netTone,
      // Was "Across the whole tour", which restated the "Tour totals" label
      // directly above it. The scarce caption line buys more as the basis: this
      // net is CASH, and the trip's own P&L headlines the BILLED one.
      secondary: tr('money.basis_cash'),
      breakdown: [
        HeroStatLine(
          tr('bus_money.rollup_total_collected'),
          Formatters.formatMoneyInr(summary.totalCollected),
          tone: c.good,
        ),
        HeroStatLine(
          tr('bus_money.rollup_total_income'),
          Formatters.formatMoneyInr(summary.totalIncome),
          tone: c.good,
        ),
        HeroStatLine(
          tr('bus_money.rollup_total_expenses'),
          Formatters.formatMoneyInr(summary.totalExpenses),
          tone: c.warm,
        ),
        HeroStatLine(
          tr('bus_money.stat_outstanding'),
          Formatters.formatMoneyInr(summary.totalOutstandingHandover),
        ),
        HeroStatLine(
          tr('bus_money.rollup_to_return'),
          Formatters.formatMoneyInr(summary.totalToReturn),
        ),
      ],
    );
  }
}
