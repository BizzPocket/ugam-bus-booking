part of '../finance_screen.dart';

// ── Incomplete-ledger notice ─────────────────────────────────────────────────

/// Shown when the finance ledger answered with nothing while the agent
/// demonstrably has buses (see [FinanceController.ledgerEmpty]).
///
/// Deliberately a warm NOTICE and not [UgamEmpty.error]: this is not a failed
/// fetch, so there is nothing to retry — the report really did load, and what
/// it loaded is empty. Saying so is the whole point; a bare ₹0 reads as "you
/// earned nothing" rather than "I could not find out", and that is the reading
/// this closes.
class _LedgerEmptyNotice extends StatelessWidget {
  const _LedgerEmptyNotice();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Was a hand-rolled Container: warm fill, no border, and — because it
    // predates the elevation scale — no shadow, so the one thing on the screen
    // that most needed to be noticed sat FLATTER than the cards under it.
    // `UgamCardTone.warm` is the same fill plus the system's hairline and
    // `UgamElevation.rest`.
    return UgamCard.plain(
      tone: UgamCardTone.warm,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('finance.ledger_empty_title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: UgamSpacing.xs),
                Text(
                  tr('finance.ledger_empty_body'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Zero state ───────────────────────────────────────────────────────────────

/// The screen's answer to "so what would put a number here?".
///
/// This replaces (a) the centred [UgamEmpty] that said "no trips with money
/// yet" and offered no way to change that, and (b) the half-viewport of void
/// underneath it. It is a card, so it takes `UgamElevation.rest` from
/// [UgamCard] like everything else on the page, and it always ends in ONE
/// button that goes to a destination that really exists:
///
/// * [_ReportState.periodEmpty] → widen the period, in place. No navigation:
///   the trips are already loaded, the filter was just narrower than the data.
/// * [_ReportState.noTrips]     → `CreateTourScreen`.
/// * [_ReportState.noMoney]     → the newest trip's `TourMoneyBoardScreen`,
///   the same destination a trip row opens.
class _ZeroStateCard extends StatelessWidget {
  final _ReportState state;
  final VoidCallback onShowAllTime;
  final VoidCallback onCreateTour;

  /// Null when the period holds no trip to open — the button is disabled
  /// rather than hidden, so the card never changes shape mid-refresh.
  final VoidCallback? onOpenMoney;

  const _ZeroStateCard({
    required this.state,
    required this.onShowAllTime,
    required this.onCreateTour,
    required this.onOpenMoney,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final noMoney = state == _ReportState.noMoney;
    final periodEmpty = state == _ReportState.periodEmpty;

    final (IconData icon, String title, String body) = switch (state) {
      _ReportState.periodEmpty => (
        Icons.event_busy_rounded,
        tr('finance.zero_period_title'),
        tr('finance.zero_period_body'),
      ),
      _ReportState.noMoney => (
        Icons.savings_rounded,
        tr('finance.zero_money_title'),
        tr('finance.zero_money_body'),
      ),
      _ => (
        Icons.route_rounded,
        tr('finance.zero_start_title'),
        tr('finance.zero_start_body'),
      ),
    };

    final (
      String ctaLabel,
      IconData ctaIcon,
      VoidCallback? onCta,
    ) = switch (state) {
      _ReportState.periodEmpty => (
        tr('finance.zero_period_cta'),
        Icons.all_inclusive_rounded,
        onShowAllTime,
      ),
      _ReportState.noMoney => (
        tr('finance.zero_money_cta'),
        Icons.account_balance_wallet_rounded,
        onOpenMoney,
      ),
      _ => (tr('finance.zero_start_cta'), Icons.add_rounded, onCreateTour),
    };

    // The three things that actually create a rupee in this report, in the
    // order they happen. Skipped when the only problem is the period filter,
    // and the "create a trip" step is dropped once trips exist.
    final steps = <Widget>[
      if (!periodEmpty && !noMoney)
        _ZeroStep(
          icon: Icons.add_road_rounded,
          title: tr('finance.zero_step_trip_title'),
          body: tr('finance.zero_step_trip_body'),
        ),
      if (!periodEmpty) ...[
        _ZeroStep(
          icon: Icons.payments_rounded,
          title: tr('finance.zero_step_cash_title'),
          body: tr('finance.zero_step_cash_body'),
        ),
        _ZeroStep(
          icon: Icons.receipt_long_rounded,
          title: tr('finance.zero_step_expense_title'),
          body: tr('finance.zero_step_expense_body'),
        ),
      ],
    ];

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Decorative medallion — [UgamScale.px], never `tap`: nothing
              // here takes a finger, the button at the bottom does.
              Container(
                width: UgamScale.px(context, 40),
                height: UgamScale.px(context, 40),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: UgamScale.px(context, 20),
                  color: c.ink2,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // No maxLines anywhere in this card: Gujarati runs ~30%
                    // longer and these sentences carry the whole explanation,
                    // so they wrap rather than ellipsise.
                    Text(title, style: UgamText.titleM.copyWith(color: c.ink)),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(body, style: UgamText.body.copyWith(color: c.ink2)),
                  ],
                ),
              ),
            ],
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.lg),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            for (var i = 0; i < steps.length; i++) ...[
              steps[i],
              if (i < steps.length - 1) const SizedBox(height: UgamSpacing.md),
            ],
          ],
          const SizedBox(height: UgamSpacing.lg),
          // The screen's single primary control. `UgamButton` floors itself at
          // the 44pt tap target via UgamScale.tap, and `primary` is the neutral
          // max-contrast fill — it spends no accent, so the rationing law is
          // untouched.
          UgamButton(
            label: ctaLabel,
            icon: ctaIcon,
            kind: UgamButtonKind.primary,
            expand: true,
            onPressed: onCta,
          ),
        ],
      ),
    );
  }
}

/// One "this is what creates a number" line inside [_ZeroStateCard].
class _ZeroStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _ZeroStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: UgamScale.px(context, 30),
          height: UgamScale.px(context, 30),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: UgamScale.px(context, 15), color: c.ink2),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: UgamText.titleS.copyWith(color: c.ink)),
              const SizedBox(height: 2),
              Text(body, style: UgamText.caption.copyWith(color: c.ink3)),
            ],
          ),
        ),
      ],
    );
  }
}
